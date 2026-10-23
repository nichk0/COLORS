import SwiftUI
import UIKit
import AVFoundation
import Photos
import MediaPlayer

/// Schermo esterno (monitor o TV collegati con USB-C/HDMI): invece di copiare lo schermo del telefono,
/// Colors ci mette un'interfaccia "desktop" sul modello della pagina Color di DaVinci.
/// I comandi restano sul telefono (con l'iPhone il monitor esterno non si tocca e non ha il puntatore).
/// La scena del monitor è dichiarata in Info.plist (UIApplicationSceneManifest, ruolo
/// UIWindowSceneSessionRoleExternalDisplayNonInteractive): così la finestra principale SwiftUI non cambia.
@objc(DelegatoMonitor)
final class DelegatoMonitor: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let s = scene as? UIWindowScene else { return }
        GestoreMonitor.scrivi("Info.plist delegate called (\(session.role.rawValue))")
        MainActor.assumeIsolated {
            let w = UIWindow(windowScene: s)
            w.rootViewController = UIHostingController(rootView: VistaMonitor(studio: Studio.condiviso))
            w.overrideUserInterfaceStyle = .dark
            w.isHidden = false
            window = w
            Studio.condiviso.monitorCollegato = true
        }
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        MainActor.assumeIsolated {
            window = nil
            Studio.condiviso.monitorCollegato = false
        }
    }
}

/// Secondo modo di riconoscere il monitor, indipendente dal delegato dichiarato in Info.plist:
/// ogni scena "schermo esterno" che si collega e non ha ancora una finestra riceve quella del monitor.
/// Scrive nel registro (MONITOR: …) cosa vede, per capire i casi in cui il monitor non viene rilevato.
@MainActor
enum GestoreMonitor {
    /// Scrive una riga del registro anche in Documents/registro-monitor.txt (con il monitor attaccato il telefono non è collegato al Mac).
    static func scrivi(_ s: String) {
        print("MONITOR: " + s)
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("registro-monitor.txt")
        let riga = ISO8601DateFormatter().string(from: Date()) + " " + s + "\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(riga.utf8)); try? h.close() }
        else { try? Data(riga.utf8).write(to: url) }
    }

    private static var avviato = false
    private static var finestre: [ObjectIdentifier: UIWindow] = [:]

    static func avvia() {
        guard !avviato else { return }
        avviato = true
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIScene.willConnectNotification, object: nil, queue: .main) { n in
            let s = n.object as? UIWindowScene
            // dopo un attimo: prima lascia lavorare il delegato dell'Info.plist
            DispatchQueue.main.async { MainActor.assumeIsolated { if let s { collega(s) } } }
        }
        nc.addObserver(forName: UIScene.didDisconnectNotification, object: nil, queue: .main) { n in
            let id = (n.object as? UIScene).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                if let id, finestre.removeValue(forKey: id) != nil { GestoreMonitor.scrivi("monitor scene disconnected") }
                aggiornaStato()
            }
        }
        nc.addObserver(forName: UIScreen.didConnectNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { GestoreMonitor.scrivi("screen connected, screens = \(UIScreen.screens.count)"); controlla() }
        }
        nc.addObserver(forName: UIScreen.didDisconnectNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { GestoreMonitor.scrivi("screen disconnected"); aggiornaStato() }
        }
        // duplicazione dello schermo (cavo o AirPlay): l'app passa da sola alla modalità desktop
        nc.addObserver(forName: UIScreen.capturedDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { controllaDuplicazione() }
        }
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { controllaDuplicazione() }
        }
        controlla()
        controllaDuplicazione()
        MouseMonitor.condiviso.avvia()
        // la finestra SwiftUI deve esistere: si registra appena dopo l'avvio
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated { registraCompagno() } }
    }

    /// Lo stesso meccanismo che usa ProDocktive (visto nei log di sistema del 22/10): un view controller
    /// "registra" uno schermo compagno esterno. Così, quando c'è un monitor (cavo o AirPlay), iOS crea la scena
    /// ExternalDisplayNonInteractive con DelegatoMonitor invece di duplicare lo schermo del telefono.
    /// È una funzione interna di iOS 26+ (non documentata): se manca, non succede nulla e resta la duplicazione.
    private static var compagno: AnyObject?

    static func registraCompagno() {
        guard compagno == nil else { return }
        guard let scena = UIApplication.shared.connectedScenes.first(where: { $0.session.role == .windowApplication }) as? UIWindowScene,
              let vc = scena.keyWindow?.rootViewController ?? scena.windows.first?.rootViewController else {
            scrivi("companion: main window not ready"); return
        }
        let crea = NSSelectorFromString("externalNonInteractiveCompanionWithConfiguration:")
        let registra = NSSelectorFromString("_registerSceneCompanion:")
        guard let classe = NSClassFromString("_UISceneCompanion") as? NSObject.Type,
              classe.responds(to: crea), vc.responds(to: registra) else {
            scrivi("companion: iOS doesn't have the function"); return
        }
        let config = UISceneConfiguration(name: "External monitor", sessionRole: .windowExternalDisplayNonInteractive)
        config.delegateClass = DelegatoMonitor.self
        guard let c = classe.perform(crea, with: config)?.takeUnretainedValue() else {
            scrivi("companion: not created"); return
        }
        _ = vc.perform(registra, with: c)
        compagno = c
        controllore = vc
        scrivi("external companion registered on \(type(of: vc))")
    }

    private static weak var controllore: UIViewController?

    /// Lascia per un momento lo schermo esterno: iOS torna a duplicare il telefono, così le finestre di iOS
    /// (scelta di file e cartelle) si vedono anche sul monitor e si usano col mouse (come fa Feather).
    static func sospendiCompagno() {
        guard let c = compagno, let vc = controllore else { return }
        let togli = NSSelectorFromString("_unregisterSceneCompanion:")
        guard vc.responds(to: togli) else { return }
        _ = vc.perform(togli, with: c)
        compagno = nil
        // la scena del monitor va chiusa, altrimenti iOS la tiene e non torna a duplicare
        for sc in UIApplication.shared.connectedScenes where sc.session.role == .windowExternalDisplayNonInteractive || sc.session.role.rawValue.contains("ExternalDisplay") {
            (sc as? UIWindowScene)?.windows.forEach { $0.isHidden = true }
            UIApplication.shared.requestSceneSessionDestruction(sc.session, options: nil) { e in
                MainActor.assumeIsolated { scrivi("closing the monitor scene failed: \(e.localizedDescription)") }
            }
        }
        scrivi("companion suspended (mirroring for the file picker)")
    }

    /// Torna all'interfaccia desktop sul monitor.
    static func riprendiCompagno() {
        guard compagno == nil else { return }
        registraCompagno()
    }

    static func controllaDuplicazione() {
        let scena = UIApplication.shared.connectedScenes.first { $0.session.role == .windowApplication } as? UIWindowScene
        let attiva = scena?.traitCollection.sceneCaptureState == .active
        if attiva != Studio.condiviso.duplicazione {
            GestoreMonitor.scrivi("screen mirroring: \(attiva ? "yes" : "no")")
            Studio.condiviso.duplicazione = attiva
        }
    }

    /// Chiede a iOS una sessione "schermo esterno": su iPhone iOS duplica lo schermo finché un'app non la chiede
    /// (come fa Keynote quando parte la presentazione). Senza monitor collegato iOS risponde con un errore: va bene.
    static func richiedi() {
        let r = UISceneSessionActivationRequest(role: .windowExternalDisplayNonInteractive)
        GestoreMonitor.scrivi("asking iOS for the external screen")
        UIApplication.shared.activateSceneSession(for: r) { errore in
            let testo = errore.localizedDescription
            let codice = (errore as NSError).code
            MainActor.assumeIsolated { GestoreMonitor.scrivi("iOS replied: \(testo) (code \(codice))") }
        }
        // la risposta positiva non arriva qui: arriva come nuova scena (willConnect)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { controlla() } }
    }

    static func controlla() {
        let scene = UIApplication.shared.connectedScenes
        GestoreMonitor.scrivi("open sessions = \(UIApplication.shared.openSessions.map { $0.role.rawValue }), multiple = \(UIApplication.shared.supportsMultipleScenes)")
        GestoreMonitor.scrivi("screens = \(UIScreen.screens.count), scenes = \(scene.map { $0.session.role.rawValue })")
        for s in scene { if let ws = s as? UIWindowScene { collega(ws) } }
        aggiornaStato()
    }

    private static func collega(_ s: UIWindowScene) {
        let ruolo = s.session.role
        GestoreMonitor.scrivi("scene \(ruolo.rawValue), delegate \(s.delegate.map { String(describing: type(of: $0)) } ?? "none"), windows \(s.windows.count)")
        guard ruolo == .windowExternalDisplayNonInteractive || ruolo.rawValue.contains("ExternalDisplay") else { return }
        if s.windows.contains(where: { !$0.isHidden }) { aggiornaStato(); return }
        let w = UIWindow(windowScene: s)
        w.rootViewController = UIHostingController(rootView: VistaMonitor(studio: Studio.condiviso))
        w.overrideUserInterfaceStyle = .dark
        w.isHidden = false
        finestre[ObjectIdentifier(s)] = w
        GestoreMonitor.scrivi("monitor window created (fallback)")
        aggiornaStato()
    }

    private static func aggiornaStato() {
        let esterne = UIApplication.shared.connectedScenes.contains {
            $0.session.role == .windowExternalDisplayNonInteractive || $0.session.role.rawValue.contains("ExternalDisplay")
        }
        Studio.condiviso.monitorCollegato = esterne
    }
}

/// Cosa mostra il monitor esterno.
struct ImpostazioniMonitor: Codable, Equatable {
    /// true: interfaccia desktop; false: solo l'immagine a tutto schermo (come il "clean feed" di DaVinci).
    var desktop = true
    var galleria = true
    var clip = true
    var nodi = true
    var keyframe = true
    var scope = true
    /// Quando lo schermo viene duplicato (monitor col cavo o AirPlay) l'app passa da sola alla modalità desktop.
    var desktopAutomatico = true
    /// Misure dei pannelli (trascinando i divisori): quota della larghezza o dell'altezza.
    var quotaGalleria = 0.13
    var quotaNodi = 0.30
    var quotaPalette = 0.31

    static func carica() -> ImpostazioniMonitor {
        guard let d = UserDefaults.standard.data(forKey: "monitorEsterno"),
              var m = try? JSONDecoder().decode(ImpostazioniMonitor.self, from: d) else { return ImpostazioniMonitor() }
        // i nodi restano sempre visibili (nasconderli per sbaglio confondeva)
        m.nodi = true
        return m
    }

    func salva() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: "monitorEsterno") }
    }
}

// MARK: - Interfaccia del monitor

struct VistaMonitor: View {
    @ObservedObject var studio: Studio
    /// Modalità desktop sul telefono: sempre l'interfaccia desktop (la scelta "Solo immagine" vale per il monitor).
    var forzaDesktop = false

    var body: some View {
        Group {
            if studio.schermoInteroMonitor { schermoInteroVista }
            else if studio.monitor.desktop || forzaDesktop { desktop } else { immagine.background(Color.black) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // menu del tasto destro
        .overlay { if studio.benvenutoMonitor { BenvenutoMonitor(studio: studio) } }
        .overlay { if studio.testoMonitor != nil { DialogoTestoMonitor(studio: studio) } }
        .overlay(alignment: .bottomTrailing) { AvvisoAssistiveTouchMonitor() }
        .overlay(alignment: .top) {
            if let t = studio.sceltaSulTelefono {
                Label(t, systemImage: "iphone").font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Tema.accento))
                    .foregroundStyle(.black)
                    .padding(.top, 60)
            }
        }
        .overlay { VistaMenuMonitor() }
        // puntatore del trackpad o del mouse (il telefono lo muove)
        .overlay(alignment: .topLeading) { FantasmaTrascino() }
        .overlay(alignment: .topLeading) { CursoreMonitor() }
        .coordinateSpace(name: "monitor")
        // tutto quello che è disegnato qui si comanda col puntatore: tasti, interruttori, cursori, scelte
        .environment(\.suMonitor, true)
        .buttonStyle(StilePulsante())
        .toggleStyle(StileInterruttore())
        .onGeometryChange(for: CGSize.self) { $0.size } action: { ZoneMonitor.condivise.dimensione = $0 }
        .ignoresSafeArea()
        // testo chiaro ovunque (anche i valori dentro i riquadri scuri)
        .foregroundStyle(Color(white: 0.9))
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
    }

    private var desktop: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let m = studio.monitor
            VStack(spacing: 0) {
                BarraAltaMonitor(studio: studio)
                if studio.paginaMonitor == .deliver {
                    // pagina Deliver come in DaVinci: impostazioni a sinistra, viewer al centro, coda di render a destra
                    HStack(spacing: 0) {
                        ImpostazioniRenderMonitor(studio: studio).frame(width: max(300, w * 0.25))
                        Rectangle().fill(Color(white: 0.17)).frame(width: 1)
                        VStack(spacing: 0) {
                            viewer
                            BarraRenderMonitor(studio: studio)
                        }
                        Rectangle().fill(Color(white: 0.17)).frame(width: 1)
                        CodaRenderMonitor(studio: studio).frame(width: max(250, w * 0.2))
                    }
                    .frame(maxHeight: .infinity)
                    ClipMonitor(studio: studio).frame(height: max(110, h * 0.14)).padding(.top, 2)
                } else if studio.paginaMonitor == .edit {
                    // pagina Edit come in DaVinci: Media Pool e viewer in alto, strumenti e timeline sotto
                    HStack(spacing: 0) {
                        MediaPoolMonitor(studio: studio).frame(width: w * 0.24)
                        Divisore(verticale: true, id: "mediapool") { _ in }
                        viewer
                        Rectangle().fill(Color(white: 0.17)).frame(width: 1)
                        InspectorMonitor(studio: studio).frame(width: max(290, w * 0.24))
                    }
                    .frame(height: h * 0.5)
                    TimelineMonitor(studio: studio)
                        .frame(maxHeight: .infinity)
                } else if studio.paginaMonitor == .media {
                    // pagina Media: la libreria del telefono sul monitor, un clic importa
                    HStack(spacing: 0) {
                        MediaMonitor(studio: studio)
                        Divisore(verticale: true, id: "media") { studio.monitor.quotaNodi = min(0.5, max(0.12, studio.monitor.quotaNodi - $0 / w)) }
                        viewer.frame(width: w * max(0.3, m.quotaNodi + 0.1))
                    }
                    .frame(maxHeight: .infinity)
                } else {
                HStack(spacing: 0) {
                    if m.galleria {
                        GalleriaMonitor(studio: studio).frame(width: w * m.quotaGalleria)
                        Divisore(verticale: true, id: "galleria") { studio.monitor.quotaGalleria = min(0.3, max(0.07, studio.monitor.quotaGalleria + $0 / w)) }
                    }
                    viewer
                    if m.nodi {
                        Divisore(verticale: true, id: "nodi") { studio.monitor.quotaNodi = min(0.5, max(0.12, studio.monitor.quotaNodi - $0 / w)) }
                        NodiMonitor(studio: studio).frame(width: w * m.quotaNodi)
                    }
                }
                .frame(maxHeight: .infinity)
                }
                if studio.paginaMonitor != .edit && studio.paginaMonitor != .deliver {
                if m.clip { ClipMonitor(studio: studio).frame(height: max(110, h * 0.14)).padding(.top, 2) }
                // trascinando questo divisore il video diventa più grande o più piccolo
                Divisore(verticale: false, id: "palette") { studio.monitor.quotaPalette = min(0.6, max(0.15, studio.monitor.quotaPalette - $0 / h)) }
                HStack(spacing: 2) {
                    PaletteMonitor(studio: studio)
                    if m.keyframe { KeyframeMonitor(studio: studio).frame(width: w * 0.21) }
                    if m.scope { ScopeMonitor(studio: studio).frame(width: w * 0.28) }
                }
                .frame(height: max(120, h * m.quotaPalette))
                }
                BarraPagineMonitor(studio: studio)
            }
            .background(Color(white: 0.05))
        }
    }

    // MARK: viewer

    @ViewBuilder
    private var immagine: some View {
        if studio.inEdit {
            VistaPlayer(player: studio.playerSequenza)
        } else if studio.inRiproduzione {
            VistaPlayer(player: studio.player)
        } else if let img = studio.risultato {
            Image(uiImage: img).resizable().scaledToFit()
        } else {
            Text("No image").foregroundStyle(Tema.testo2)
        }
    }

    /// Il filmato a tutto monitor, con i comandi essenziali in basso (clic su ✕ o sul tasto per tornare).
    private var schermoInteroVista: some View {
        ZStack(alignment: .bottom) {
            Color.black
            immagine.frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 22) {
                comando("backward.end.fill", "si.inizio") { studio.vaiA(0) }
                comando("chevron.left", "si.indietro") { studio.passo(-1) }
                comando(studio.inRiproduzione ? "pause.fill" : "play.fill", "si.play", accento: true) { studio.playPausa() }
                comando("chevron.right", "si.avanti") { studio.passo(1) }
                comando("forward.end.fill", "si.fine") { studio.vaiA(1) }
                Text(VistaMonitor.timecode(studio.inEdit ? studio.tempoSequenza : studio.tempo))
                    .font(.system(size: 14, design: .monospaced))
                comando("arrow.down.right.and.arrow.up.left", "si.esci") { studio.schermoInteroMonitor = false }
            }
            .padding(.horizontal, 18).frame(height: 40)
            .background(Capsule().fill(Color.black.opacity(0.6)))
            .padding(.bottom, 18)
        }
    }

    var viewer: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(studio.nomeClip).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(studio.dimensioni).font(.system(size: 11)).foregroundStyle(Tema.testo2).lineLimit(1)
                Spacer()
                if studio.inRiproduzione {
                    Label("Playback", systemImage: "play.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(Tema.accento)
                }
                Text(VistaMonitor.timecode(studio.inEdit ? studio.tempoSequenza : studio.tempo))
                    .font(.system(size: 14, design: .monospaced))
                // maschera del nodo in bianco e nero o trasparente (come "Highlight" di DaVinci)
                Label("Mask", systemImage: studio.mostraMaschera ? "circle.lefthalf.filled" : "circle.dashed")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 8).frame(height: 22)
                    .background(Capsule().fill(studio.mostraMaschera ? Tema.accento.opacity(0.2) : Tema.campo))
                    .foregroundStyle(studio.mostraMaschera ? Tema.accento : Color(white: 0.8))
                    .zonaMonitor("viewer.maschera", clic: { _ in Studio.condiviso.mostraMaschera.toggle() })
                comando("arrow.up.left.and.arrow.down.right", "schermoIntero") { studio.schermoInteroMonitor = true }
            }
            .padding(.horizontal, 12).frame(height: 30)
            .background(Tema.pannello)
            immagine
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // finestre (cerchio e lineare) da spostare col mouse sul video, come le Power Window di DaVinci
                .overlay { FinestreSulMonitor(studio: studio) }
                // contagocce attivo (bilanciamento, qualificatore, curve): il clic sul video prende il colore lì
                .overlay { ContagocceSulMonitor(studio: studio) }
                // il colore appena preso: quadratino e valori RGB
                .overlay(alignment: .bottomLeading) { ColorePresoMonitor(studio: studio) }
                .padding(8)
                .background(Color.black)
            // barra di scorrimento e comandi (solo da guardare: si usano dal telefono)
            let durata = studio.inEdit ? studio.durataMontaggio : studio.durata
            let t = studio.inEdit ? studio.tempoSequenza : studio.tempo
            let parte = durata > 0 ? min(1, max(0, t / durata)) : 0
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Tema.campo).frame(height: 4)
                    Capsule().fill(Tema.accento).frame(width: g.size.width * parte, height: 4)
                    Circle().fill(Color.white).frame(width: 11, height: 11)
                        .offset(x: g.size.width * parte - 5.5)
                }
                .frame(maxHeight: .infinity)
            }
            .padding(.horizontal, 14).frame(height: 22)
            .background(Tema.pannello)
            .zonaMonitor("barraTempo", clic: { p in studio.vaiA(p.x) }, trascina: { _, p in studio.vaiA(p.x) })
            HStack(spacing: 22) {
                // contagocce del bianco, come quello sotto al viewer di DaVinci
                Image(systemName: "eyedropper").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(studio.contagocce != .nessuno ? Tema.accento : Color(white: 0.8))
                    .frame(width: 34, height: 28)
                    .background(RoundedRectangle(cornerRadius: 5).fill(studio.contagocce != .nessuno ? Tema.accento.opacity(0.2) : .clear))
                    .zonaMonitor("viewer.contagocce", clic: { _ in
                        let s = Studio.condiviso
                        s.contagocce = s.contagocce == .nessuno ? .bianco : .nessuno
                    })
                comando("backward.end.fill", "inizio") { studio.vaiA(0) }
                comando("chevron.left", "indietro") { studio.passo(-1) }
                comando(studio.inRiproduzione ? "pause.fill" : "play.fill", "play", accento: true) { studio.playPausa() }
                comando("chevron.right", "avanti") { studio.passo(1) }
                comando("forward.end.fill", "fine") { studio.vaiA(1) }
            }
            .frame(maxWidth: .infinity).frame(height: 34)
            .background(Tema.pannello)
        }
    }

    private func comando(_ simbolo: String, _ id: String, accento: Bool = false, _ azione: @escaping () -> Void) -> some View {
        Image(systemName: simbolo).font(.system(size: 14, weight: .semibold))
            .foregroundStyle(accento ? Tema.accento : Color(white: 0.8))
            .frame(width: 34, height: 28)
            .zonaMonitor("comando." + id, clic: { _ in azione() })
    }

    static func timecode(_ t: Double) -> String {
        let f = Int((t * 25).rounded())
        return String(format: "%02d:%02d:%02d:%02d", f / 90000, f / 1500 % 60, f / 25 % 60, f % 25)
    }
}

/// Titolo di un pannello, come le intestazioni grigie di DaVinci.
private struct TestataMonitor: View {
    let titolo: String
    var destra = ""
    var body: some View {
        HStack {
            Text(titolo).font(.system(size: 12, weight: .semibold)).foregroundStyle(Tema.testo2)
            Spacer()
            Text(destra).font(.system(size: 11, design: .monospaced)).foregroundStyle(Tema.testo2)
        }
        .padding(.horizontal, 12).frame(height: 28)
        .overlay(alignment: .bottom) { Rectangle().fill(Color(white: 0.17)).frame(height: 1) }
    }
}

// MARK: barra in alto e barra delle pagine

private struct BarraAltaMonitor: View {
    @ObservedObject var studio: Studio
    var body: some View {
        HStack(spacing: 4) {
            Text("Colors").font(.system(size: 15, weight: .bold)).foregroundStyle(Tema.accento).padding(.trailing, 6)
            // menu in alto come la barra dei menu di DaVinci (si aprono col clic)
            ForEach(BarraAltaMonitor.menu, id: \.0) { titolo, voci in
                Text(titolo).font(.system(size: 13))
                    .padding(.horizontal, 8).frame(height: 26)
                    .foregroundStyle(Color(white: 0.85))
                    .zonaMonitor("menuBarra." + titolo, clic: { _ in MenuMonitor.condiviso.apri(voci()) })
            }
            Spacer()
            Text(studio.progetto.nome).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(white: 0.82))
            Spacer()
            // annulla / ripeti, come le frecce in alto
            freccia("arrow.uturn.backward", "Cancel") { Studio.condiviso.annulla() }
            freccia("arrow.uturn.forward", "Redo") { Studio.condiviso.ripeti() }
                .padding(.trailing, 8)
            voce("Gallery", "photo.stack", \.galleria)
            voce("Clip", "film.stack", \.clip)
            voce("Keyframes", "diamond", \.keyframe)
            voce("Scope", "waveform.path.ecg", \.scope)
        }
        .padding(.horizontal, 12).frame(height: 38)
        .background(Color(red: 0.12, green: 0.12, blue: 0.135))
    }

    /// Le voci dei menu in alto.
    static let menu: [(String, () -> [VoceMenuMonitor])] = [
        ("File", {
            let s = Studio.condiviso
            return [
                VoceMenuMonitor(titolo: "New project", icona: "doc.badge.plus") {
                    // il progetto aperto resta salvato nei Progetti; quello nuovo prende un nome che si può cambiare dal telefono
                    let n = (Archivio.elencoArchiviati().count) + 2
                    Task { await s.nuovoProgetto(nome: "Project \(n)") }
                },
                VoceMenuMonitor(titolo: "Open project…", icona: "folder") {
                    let altri = Archivio.elencoArchiviati()
                    if altri.isEmpty { s.messaggio = "There are no other saved projects."; return }
                    let data = DateFormatter(); data.dateStyle = .short; data.timeStyle = .short
                    MenuMonitor.condiviso.apri(altri.prefix(14).map { p in
                        VoceMenuMonitor(titolo: "\(p.nome) · \(p.clips.count) clips · \(data.string(from: p.modificato))", icona: "film.stack") {
                            Task { await s.apriProgetto(p.id) }
                        }
                    })
                },
                VoceMenuMonitor(titolo: "Import media…", icona: "photo.on.rectangle") { s.richiestaPagina = .media },
                VoceMenuMonitor(titolo: "Save project version", icona: "square.and.arrow.down") { s.salvaVersione() },
                VoceMenuMonitor(titolo: "Deliver (export)", icona: "paperplane") { s.richiestaPalette = .consegna },
            ]
        }),
        ("Edit", {
            let s = Studio.condiviso
            return [
                VoceMenuMonitor(titolo: "Cancel", icona: "arrow.uturn.backward") { s.annulla() },
                VoceMenuMonitor(titolo: "Redo", icona: "arrow.uturn.forward") { s.ripeti() },
                VoceMenuMonitor(titolo: "Reset node", icona: "arrow.counterclockwise") { s.azzeraNodo() },
            ]
        }),
        ("Clip", {
            let s = Studio.condiviso
            return [
                VoceMenuMonitor(titolo: "Previous clip", icona: "chevron.up") { s.clipVicina(-1) },
                VoceMenuMonitor(titolo: "Next clip", icona: "chevron.down") { s.clipVicina(1) },
                VoceMenuMonitor(titolo: "Remove clip from project", icona: "trash", distruttiva: true) {
                    if let id = s.clipAttiva { Task { await s.eliminaClip(id); s.aggiornaSequenza(ritardo: 0) } }
                },
            ]
        }),
        ("Nodes", {
            let s = Studio.condiviso
            return [
                VoceMenuMonitor(titolo: "Add serial node", icona: "plus.square.on.square") { NodiMonitor.aggiungi(.serie) },
                VoceMenuMonitor(titolo: "Add parallel node", icona: "square.split.1x2") { NodiMonitor.aggiungi(.parallelo) },
                VoceMenuMonitor(titolo: "Add layer node", icona: "square.stack") { NodiMonitor.aggiungi(.layer) },
                VoceMenuMonitor(titolo: "Add CST node", icona: "camera.filters") { s.aggiungi(.cst) },
                VoceMenuMonitor(titolo: s.nodo.attivo ? "Disable node" : "Enable node", icona: "eye") { s.nodo.attivo.toggle() },
            ]
        }),
        ("View", {
            let s = Studio.condiviso
            return [
                VoceMenuMonitor(titolo: "Full-screen video", icona: "arrow.up.left.and.arrow.down.right") { s.schermoInteroMonitor = true },
                VoceMenuMonitor(titolo: s.mostraMaschera ? "Hide mask" : "Show mask", icona: "circle.lefthalf.filled") { s.mostraMaschera.toggle() },
                VoceMenuMonitor(titolo: "Black and white mask", icona: "circle.righthalf.filled") { s.mascheraBN = true; s.mostraMaschera = true },
                VoceMenuMonitor(titolo: "Transparent mask", icona: "circle.dashed") { s.mascheraBN = false; s.mostraMaschera = true },
            ]
        }),
        ("Playback", {
            let s = Studio.condiviso
            return [
                VoceMenuMonitor(titolo: s.inRiproduzione ? "Pause" : "Play", icona: s.inRiproduzione ? "pause.fill" : "play.fill") { s.playPausa() },
                VoceMenuMonitor(titolo: "Next frame", icona: "chevron.right") { s.passo(1) },
                VoceMenuMonitor(titolo: "Previous frame", icona: "chevron.left") { s.passo(-1) },
                VoceMenuMonitor(titolo: "Go to start", icona: "backward.end.fill") { s.vaiA(0) },
                VoceMenuMonitor(titolo: "Go to end", icona: "forward.end.fill") { s.vaiA(1) },
            ]
        }),
        ("Workspace", {
            let s = Studio.condiviso
            return [
                VoceMenuMonitor(titolo: "Reset panel sizes", icona: "rectangle.3.group") {
                    let b = ImpostazioniMonitor()
                    s.monitor.quotaGalleria = b.quotaGalleria; s.monitor.quotaNodi = b.quotaNodi; s.monitor.quotaPalette = b.quotaPalette
                },
                VoceMenuMonitor(titolo: "Show all panels", icona: "square.grid.2x2") {
                    s.monitor.galleria = true; s.monitor.clip = true; s.monitor.nodi = true; s.monitor.keyframe = true; s.monitor.scope = true
                },
            ]
        }),
    ]

    private func freccia(_ simbolo: String, _ nome: String, _ azione: @escaping () -> Void) -> some View {
        Image(systemName: simbolo).font(.system(size: 14, weight: .semibold))
            .frame(width: 32, height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.2)))
            .foregroundStyle(Color(white: 0.9))
            .zonaMonitor("barra." + nome, clic: { _ in azione() })
    }

    private func voce(_ nome: String, _ simbolo: String, _ kp: WritableKeyPath<ImpostazioniMonitor, Bool>) -> some View {
        let attiva = studio.monitor[keyPath: kp]
        return Label(nome, systemImage: simbolo).font(.system(size: 12))
            .padding(.horizontal, 9).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(attiva ? Tema.accento.opacity(0.16) : .clear))
            .foregroundStyle(attiva ? Tema.accento : Tema.testo2)
            .zonaMonitor("pannello." + nome, clic: { _ in Studio.condiviso.monitor[keyPath: kp].toggle() })
    }
}

private struct BarraPagineMonitor: View {
    @ObservedObject var studio: Studio
    var body: some View {
        HStack(spacing: 6) {
            ForEach(Pagina.visibili) { p in
                let attiva = p == studio.paginaMonitor
                Label(p.rawValue, systemImage: p.icona).font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 16).frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 8).fill(attiva ? Tema.accento.opacity(0.16) : .clear))
                    .foregroundStyle(attiva ? Tema.accento : Tema.testo2)
                    .zonaMonitor("pagina." + p.rawValue, clic: { _ in Studio.condiviso.richiestaPagina = p })
            }
        }
        .frame(maxWidth: .infinity).frame(height: 44)
        .background(Color(red: 0.12, green: 0.12, blue: 0.135))
    }
}

// MARK: galleria

private struct GalleriaMonitor: View {
    @ObservedObject var studio: Studio
    var body: some View {
        VStack(spacing: 0) {
            TestataMonitor(titolo: "Gallery · Stills", destra: "\(studio.progetto.stills.count)")
            if studio.progetto.stills.isEmpty {
                Text("No stills. They are grabbed from the phone (Gallery palette) and are used for comparison and Color Match.")
                    .font(.system(size: 11)).foregroundStyle(Tema.testo2).padding(12)
                Spacer()
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(studio.progetto.stills.prefix(12)) { s in
                        VStack(alignment: .leading, spacing: 3) {
                            ZStack {
                                if let img = Archivio.immagine("Stills", s.file) {
                                    Image(uiImage: img).resizable().scaledToFill()
                                } else { Rectangle().fill(Tema.campo) }
                            }
                            .aspectRatio(16 / 9, contentMode: .fit).clipped()
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(s.id == studio.confronto?.id ? Tema.accento : .clear, lineWidth: 2))
                            Text(s.nome).font(.system(size: 10)).foregroundStyle(Tema.testo2).lineLimit(1)
                        }
                        // clic su uno still: confronto (split screen) acceso o spento
                        .zonaMonitor("still." + s.id.uuidString, clic: { _ in
                            let st = Studio.condiviso
                            st.confronto = st.confronto?.id == s.id ? nil : s
                        })
                    }
                }
                .padding(10)
                Spacer(minLength: 0)
            }
        }
        .background(Tema.pannello)
    }
}

// MARK: nodi

private struct NodiMonitor: View {
    @ObservedObject var studio: Studio

    /// Nodo correttore nuovo dopo quello scelto, in serie, in parallelo o come layer.
    static func aggiungi(_ modo: ModoNodo) {
        let s = Studio.condiviso
        s.aggiungi(.correzione)
        if modo != .serie { s.nodo.modo = modo }
    }

    private func menuSfondo() {
        let s = Studio.condiviso
        MenuMonitor.condiviso.apri([
            VoceMenuMonitor(titolo: "Add serial node", icona: "plus.square.on.square") { NodiMonitor.aggiungi(.serie) },
            VoceMenuMonitor(titolo: "Add parallel node", icona: "square.split.1x2") { NodiMonitor.aggiungi(.parallelo) },
            VoceMenuMonitor(titolo: "Add layer node", icona: "square.stack") { NodiMonitor.aggiungi(.layer) },
            VoceMenuMonitor(titolo: "Add CST node", icona: "camera.filters") { s.aggiungi(.cst) },
        ])
    }

    /// Tasto destro su un nodo: le stesse voci del menu del telefono.
    private func menuNodo(_ n: Nodo) {
        let s = Studio.condiviso
        s.selezionato = n.id
        MenuMonitor.condiviso.apri([
            VoceMenuMonitor(titolo: n.attivo ? "Disable node" : "Enable node", icona: n.attivo ? "eye.slash" : "eye") {
                if let i = s.nodi.firstIndex(where: { $0.id == n.id }) { s.nodi[i].attivo.toggle() }
            },
            VoceMenuMonitor(titolo: "Add serial node", icona: "plus.square.on.square") { s.selezionato = n.id; NodiMonitor.aggiungi(.serie) },
            VoceMenuMonitor(titolo: "Add parallel node", icona: "square.split.1x2") { s.selezionato = n.id; NodiMonitor.aggiungi(.parallelo) },
            VoceMenuMonitor(titolo: "Add layer node", icona: "square.stack") { s.selezionato = n.id; NodiMonitor.aggiungi(.layer) },
            VoceMenuMonitor(titolo: "Move left", icona: "arrow.left") { s.sposta(n.id, di: -1) },
            VoceMenuMonitor(titolo: "Move right", icona: "arrow.right") { s.sposta(n.id, di: 1) },
            VoceMenuMonitor(titolo: "Reset grade", icona: "arrow.counterclockwise") { s.selezionato = n.id; s.azzeraNodo() },
            VoceMenuMonitor(titolo: "Delete node", icona: "trash", distruttiva: true) { s.elimina(n.id) },
        ])
    }

    /// Colonne del grafo: un nodo in serie apre una colonna, quelli in parallelo/layer gli si mettono sotto.
    private var colonne: [[Int]] {
        var c: [[Int]] = []
        for (i, n) in studio.nodi.enumerated() {
            if i == 0 || n.modo == .serie { c.append([i]) } else { c[c.count - 1].append(i) }
        }
        return c
    }

    var body: some View {
        VStack(spacing: 0) {
            TestataMonitor(titolo: "Nodes", destra: "\(studio.nodi.count)")
            GeometryReader { g in
                let col = colonne
                let lw = g.size.width, lh = g.size.height
                let passo = min(150, (lw - 70) / CGFloat(max(1, col.count)))
                let nw = max(60, passo - 30), nh: CGFloat = 78
                let x0 = (lw - passo * CGFloat(col.count)) / 2 + 15
                let posizioni: [Int: CGPoint] = {
                    var p: [Int: CGPoint] = [:]
                    for (ci, gruppo) in col.enumerated() {
                        for (k, i) in gruppo.enumerated() {
                            let y = lh / 2 + (CGFloat(k) - CGFloat(gruppo.count - 1) / 2) * (nh + 18)
                            p[i] = CGPoint(x: x0 + CGFloat(ci) * passo + nw / 2, y: y)
                        }
                    }
                    return p
                }()
                ZStack {
                    // collegamenti: ingresso → prima colonna → … → uscita
                    Path { path in
                        let entrata = CGPoint(x: 14, y: lh / 2), uscita = CGPoint(x: lw - 14, y: lh / 2)
                        func curva(_ a: CGPoint, _ b: CGPoint) {
                            path.move(to: a)
                            path.addCurve(to: b, control1: CGPoint(x: (a.x + b.x) / 2, y: a.y), control2: CGPoint(x: (a.x + b.x) / 2, y: b.y))
                        }
                        var prima = [entrata]
                        for gruppo in col {
                            let ingressi = gruppo.compactMap { posizioni[$0] }.map { CGPoint(x: $0.x - nw / 2, y: $0.y) }
                            for a in prima { for b in ingressi { curva(a, b) } }
                            prima = gruppo.compactMap { posizioni[$0] }.map { CGPoint(x: $0.x + nw / 2, y: $0.y) }
                        }
                        for a in prima { curva(a, uscita) }
                    }
                    .stroke(Color(red: 0.3, green: 0.75, blue: 0.44), lineWidth: 2)
                    Circle().fill(Color(red: 0.3, green: 0.75, blue: 0.44)).frame(width: 12, height: 12).position(x: 14, y: lh / 2)
                    Circle().fill(Color(red: 0.3, green: 0.75, blue: 0.44)).frame(width: 12, height: 12).position(x: lw - 14, y: lh / 2)
                    Text("RGB").font(.system(size: 9)).foregroundStyle(Tema.testo2).position(x: 16, y: lh / 2 + 16)
                    Text("OUT").font(.system(size: 9)).foregroundStyle(Tema.testo2).position(x: lw - 16, y: lh / 2 + 16)
                    ForEach(Array(studio.nodi.enumerated()), id: \.element.id) { i, n in
                        if let p = posizioni[i] {
                            nodo(i, n).frame(width: nw, height: nh)
                                .zonaMonitor("nodo." + n.id.uuidString, clic: { _ in Studio.condiviso.selezionato = n.id },
                                             destro: { menuNodo(n) })
                                .position(p)
                        }
                    }
                }
            }
            .background(RadialGradient(colors: [Color(white: 0.135), Color(white: 0.095)], center: .center, startRadius: 0, endRadius: 500))
            // tasto destro nello spazio vuoto: aggiungi un nodo (come in DaVinci)
            .zonaMonitor("nodi.sfondo", destro: { menuSfondo() })
        }
        .background(Tema.pannello)
    }

    private func nodo(_ i: Int, _ n: Nodo) -> some View {
        let scelto = n.id == studio.selezionato
        let miniatura = studio.progetto.clips.first { $0.id == studio.clipAttiva }.flatMap { Archivio.immagine("Miniature", $0.miniatura) }
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 2) {
                Text(String(format: "%02d", i + 1)).font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(scelto ? Tema.accento : Tema.testo2)
                Spacer(minLength: 0)
                if n.modo == .parallelo { Text("∥").font(.system(size: 10, weight: .bold)).foregroundStyle(Tema.testo2) }
                if n.modo == .layer { Text("L").font(.system(size: 10, weight: .bold)).foregroundStyle(Tema.testo2) }
                if n.haMaschera { Image(systemName: "circle.dashed").font(.system(size: 9)).foregroundStyle(Color(red: 0.3, green: 0.55, blue: 0.95)) }
            }
            ZStack {
                if let miniatura { Image(uiImage: miniatura).resizable().scaledToFill() } else { Rectangle().fill(Tema.campo) }
            }
            .frame(maxWidth: .infinity).frame(height: 34).clipped()
            .clipShape(RoundedRectangle(cornerRadius: 3))
            Text(n.etichetta).font(.system(size: 10)).lineLimit(1)
        }
        .padding(5)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color(white: 0.19)))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(scelto ? Tema.accento : Color(white: 0.28), lineWidth: 2))
        .opacity(n.attivo ? 1 : 0.45)
    }
}

// MARK: clip e mini timeline

private struct ClipMonitor: View {
    @ObservedObject var studio: Studio
    @State private var posizione = ScrollPosition(edge: .leading)
    @State private var x: CGFloat = 0
    @State private var massimo: CGFloat = 0
    /// Clip che si sta trascinando e di quanto (si sposta di un posto ogni larghezza di clip).
    @State private var trascinata: UUID?
    @State private var spostamento: CGFloat = 0
    @State private var fine: Task<Void, Never>?

    private func trascina(_ id: UUID, _ dx: CGFloat) {
        if trascinata != id { trascinata = id; spostamento = 0 }
        spostamento += dx
        let passo: CGFloat = 148
        if abs(spostamento) > passo / 2 {
            let d = spostamento > 0 ? 1 : -1
            Studio.condiviso.spostaClip(id, di: d)
            spostamento -= CGFloat(d) * passo
        }
        // lasciato il tasto (nessun movimento per un attimo): la clip torna al suo posto
        fine?.cancel()
        fine = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.15)) { trascinata = nil; spostamento = 0 }
        }
    }

    private func menuClip(_ id: UUID) {
        let s = Studio.condiviso
        MenuMonitor.condiviso.apri([
            VoceMenuMonitor(titolo: "Open in viewer", icona: "play.rectangle") { Task { await s.apriClip(id) } },
            VoceMenuMonitor(titolo: "Move left", icona: "arrow.left") { s.spostaClip(id, di: -1) },
            VoceMenuMonitor(titolo: "Move right", icona: "arrow.right") { s.spostaClip(id, di: 1) },
            VoceMenuMonitor(titolo: "Remove from project", icona: "trash", distruttiva: true) {
                Task { await s.eliminaClip(id); s.aggiornaSequenza(ritardo: 0) }
            },
        ])
    }

    var body: some View {
        let clips = studio.progetto.clips
        let durate = studio.durateClip
        let totale = max(0.001, durate.reduce(0, +))
        VStack(spacing: 4) {
            ScrollViewReader { lettore in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(clips.enumerated()), id: \.element.id) { i, c in
                            let attiva = c.id == studio.clipAttiva
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(String(format: "%02d", i + 1)).font(.system(size: 10, design: .monospaced))
                                    Spacer()
                                    if i < durate.count { Text(VistaMonitor.timecode(durate[i])).font(.system(size: 9, design: .monospaced)) }
                                    Spacer()
                                    Text("V1").font(.system(size: 9))
                                }
                                .foregroundStyle(attiva ? Tema.accento : Tema.testo2)
                                ZStack {
                                    if let img = Archivio.immagine("Miniature", c.miniatura) { Image(uiImage: img).resizable().scaledToFill() }
                                    else { Rectangle().fill(Tema.campo) }
                                }
                                .frame(width: 132, height: 56).clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                                Text(c.nome).font(.system(size: 9)).foregroundStyle(Tema.testo2).lineLimit(1)
                            }
                            .frame(width: 132)
                            .padding(4)
                            .background(RoundedRectangle(cornerRadius: 5).fill(attiva ? Color(white: 0.15) : .clear))
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(attiva ? Tema.accento : .clear, lineWidth: 2))
                            .offset(x: trascinata == c.id ? spostamento : 0)
                            .zIndex(trascinata == c.id ? 1 : 0)
                            // clic = apri; tieni premuto e trascina = sposta nella timeline; destro = menu
                            .zonaMonitor("clip." + c.id.uuidString,
                                         clic: { _ in Task { await Studio.condiviso.apriClip(c.id) } },
                                         trascina: { d, _ in trascina(c.id, d.width) },
                                         destro: { menuClip(c.id) })
                            .id(c.id)
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollPosition($posizione)
                .onScrollGeometryChange(for: CGFloat.self) { max(0, $0.contentSize.width - $0.containerSize.width) } action: { _, m in massimo = m }
                // rotella: scorre la striscia delle clip
                .zonaMonitor("clip.scorri", trascina: { d, _ in
                    x = min(massimo, max(0, x - d.height - d.width))
                    posizione.scrollTo(x: x)
                })
                .onChange(of: studio.clipAttiva) { _, id in withAnimation { lettore.scrollTo(id, anchor: .center) } }
                // qui si lasciano i media trascinati dalla Galleria
                .zonaMonitor("timeline.area")
            }
            // mini timeline: le clip in proporzione alla durata, la testina rossa
            GeometryReader { g in
                let iAttiva = clips.firstIndex { $0.id == studio.clipAttiva } ?? 0
                let inizioAttiva = durate.prefix(iAttiva).reduce(0, +)
                let t = studio.inEdit ? studio.tempoSequenza : inizioAttiva + studio.tempo
                ZStack(alignment: .leading) {
                    HStack(spacing: 1) {
                        ForEach(Array(durate.enumerated()), id: \.offset) { i, d in
                            let attiva = i == iAttiva
                            RoundedRectangle(cornerRadius: 2)
                                .fill(attiva ? Tema.accento.opacity(0.35) : Color(red: 0.17, green: 0.23, blue: 0.3))
                                .overlay(RoundedRectangle(cornerRadius: 2).stroke(attiva ? Tema.accento : Color(white: 0.24), lineWidth: 1))
                                .frame(width: max(2, (g.size.width - CGFloat(durate.count)) * d / totale))
                                .zonaMonitor("segmento.\(i)", clic: { _ in
                                    if i < clips.count { Task { await Studio.condiviso.apriClip(clips[i].id) } }
                                })
                        }
                    }
                    Rectangle().fill(Color.red).frame(width: 2, height: 20)
                        .offset(x: g.size.width * min(1, max(0, t / totale)))
                }
            }
            .frame(height: 14)
            .padding(.horizontal, 12).padding(.bottom, 6)
        }
        .padding(.top, 6)
        .background(Tema.pannello)
    }
}

// MARK: palette

private struct PaletteMonitor: View {
    @ObservedObject var studio: Studio

    var body: some View {
        VStack(spacing: 0) {
            // come DaVinci: una fila di sole icone sottili, separate da lineette; il nome compare passandoci sopra
            HStack(spacing: 0) {
                ForEach(Array(Palette.visibili.enumerated()), id: \.element) { i, p in
                    if i > 0 { Rectangle().fill(Color(white: 0.2)).frame(width: 1, height: 22) }
                    IconaPalette(palette: p, attiva: p == studio.paletteMonitor)
                }
            }
            .padding(.horizontal, 4).frame(height: 42)
            .background(Color(white: 0.1))
            .overlay(alignment: .bottom) { Rectangle().fill(Color(white: 0.17)).frame(height: 1) }
            contenuto.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Tema.pannello)
    }

    @ViewBuilder
    private var contenuto: some View {
        let g = studio.nodo.grade
        switch studio.paletteMonitor {
        case .primarie:
            // tutto nello spazio della palette: se è poco si rimpicciolisce insieme (ruote comprese)
            AdattaAltezza {
            VStack(spacing: 6) {
                // in alto come DaVinci: A (bilanciamento automatico) e contagocce del bianco, poi Temp, Tint, Contrasto…
                HStack(spacing: 14) {
                    Text("A").font(.system(size: 12, weight: .bold))
                        .frame(width: 24, height: 22)
                        .background(Circle().stroke(Color(white: 0.6), lineWidth: 1))
                        .zonaMonitor("primarie.auto", clic: { _ in Studio.condiviso.autoBilancia() })
                    Image(systemName: "eyedropper").font(.system(size: 13))
                        .frame(width: 28, height: 22)
                        .background(RoundedRectangle(cornerRadius: 5).fill(studio.contagocce == .bianco ? Tema.accento.opacity(0.25) : .clear))
                        .foregroundStyle(studio.contagocce == .bianco ? Tema.accento : Color(white: 0.8))
                        .zonaMonitor("primarie.contagocce", clic: { _ in
                            let s = Studio.condiviso
                            s.contagocce = s.contagocce == .bianco ? .nessuno : .bianco
                        })
                    valore("Temp", \.temperatura, -1...1, "%.2f"); valore("Tint", \.tinta, -1...1, "%.2f")
                    valore("Contrast", \.contrasto, 0...2, "%.3f"); valore("Pivot", \.pivot, 0...1, "%.3f")
                    valoreNodo("Mid/Detail", \.effetti.dettaglio, -1...1, "%.2f")
                    valore("Exposure", \.esposizione, -3...3, "%.2f")
                    HStack(spacing: 2) {
                        vista("circle.circle", "Wheels", !barre) { barre = false }
                        vista("chart.bar.fill", "Bars", barre) { barre = true }
                    }
                }
                HStack(spacing: 26) {
                    if barre {
                        barre("Lift", \.lift, base: 0, scala: 0.25)
                        barre("Gamma", \.gamma, base: 0, scala: 0.25)
                        barre("Gain", \.gain, base: 1, scala: 0.5)
                        barre("Offset", \.offset, base: 0, scala: 0.12)
                    } else {
                        ruota("Lift", \.lift, base: 0, scala: 0.25)
                        ruota("Gamma", \.gamma, base: 0, scala: 0.25)
                        ruota("Gain", \.gain, base: 1, scala: 0.5)
                        ruota("Offset", \.offset, base: 0, scala: 0.12)
                    }
                }
                .frame(maxHeight: .infinity)
                // in basso come DaVinci: Color Boost, Shadows, Highlights, Saturation, Hue, Lum Mix
                HStack(spacing: 14) {
                    valore("Color Boost", \.colorBoost, -1...1, "%.2f")
                    valore("Shadows", \.ombre, -1...1, "%.2f"); valore("Highlights", \.luci, -1...1, "%.2f")
                    valore("Saturation", \.saturazione, 0...2, "%.2f")
                    valore("Hue", \.rotazioneTinta, -180...180, "%.0f°"); valore("Lum Mix", \.lumMix, 0...1, "%.2f")
                }
            }
            .padding(10)
            }
        case .hdr:
            // come la palette HDR di DaVinci: 3 fasce alla volta (frecce e pallini per scorrere) + la ruota Globale,
            // sotto ogni ruota Exp, Sat, X, Y e ampiezza; in fondo i controlli generali
            AdattaAltezza {
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Spacer()
                    freccia("chevron.left", "hdr.prima") { primaZona = max(0, primaZona - 1) }
                    ForEach(0..<6, id: \.self) { k in
                        Circle().stroke(Color(white: 0.6), lineWidth: 1)
                            .background(Circle().fill((primaZona...primaZona + 2).contains(k) ? Color(white: 0.6) : .clear))
                            .frame(width: 9, height: 9)
                            .frame(width: 16, height: 18).contentShape(Rectangle())
                            .zonaMonitor("hdr.pallino.\(k)", clic: { _ in primaZona = min(3, max(0, k - 1)) })
                    }
                    freccia("chevron.right", "hdr.dopo") { primaZona = min(3, primaZona + 1) }
                    Spacer()
                    Label("Reset", systemImage: "arrow.counterclockwise").font(.system(size: 11))
                        .foregroundStyle(g.hdrModificato ? Tema.accento : Tema.testo2)
                        .zonaMonitor("hdr.azzera", clic: { _ in Studio.condiviso.nodo.grade.azzeraHDR() })
                }
                HStack(alignment: .top, spacing: 22) {
                    ForEach(primaZona..<(primaZona + 3), id: \.self) { i in
                        ruotaHDR(Grade.nomiZone[i], \.zone[i], sat: \.zoneSat[i], ampiezza: \.zoneAmpiezza[i])
                    }
                    ruotaHDR("Global", \.hdrGlobale, sat: nil, ampiezza: nil)
                }
                HStack(spacing: 12) {
                    valore("Temp", \.hdrTemp, -1...1, "%.2f"); valore("Tint", \.hdrTint, -1...1, "%.2f")
                    valore("Hue", \.hdrHue, -180...180, "%.0f°")
                    valore("Cont", \.hdrContrasto, 0...2, "%.3f"); valore("Pivot", \.hdrPivot, 0...1, "%.3f")
                    valoreNodo("MD", \.effetti.dettaglio, -1...1, "%.2f"); valore("B/Ofs", \.hdrNeroOffset, -1...1, "%.3f")
                }
            }
            .padding(10)
            }
        default:
            if studio.paletteMonitor == .galleria {
                // i media della libreria: clic = in fondo, tieni premuto e trascina sulla striscia delle clip = in quel punto
                MediaPoolMonitor(studio: studio)
            } else if studio.paletteMonitor == .warper {
                // il warper si adatta da solo all'altezza: a grandezza piena, si usa col mouse
                PannelloWarper(studio: studio).padding(12).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if studio.paletteMonitor == .curve, let vera = paletteVera {
                // curve e warper stanno tutte nello spazio: niente scorrimento, si modificano col mouse
                AdattaAltezza { vera.padding(12) }
            } else if studio.paletteMonitor == .consegna {
                ScrollView { ConsegnaMonitor(studio: studio).padding(12) }
                    .scrollBounceBehavior(.basedOnSize)
                    .scrollPosition($scorrimento)
                    .onScrollGeometryChange(for: CGFloat.self) { max(0, $0.contentSize.height - $0.containerSize.height) } action: { _, m in massimo = m }
                    .zonaMonitor("palette.scorri", trascina: { d, _ in
                        y = min(massimo, max(0, y - d.height))
                        scorrimento.scrollTo(y: y)
                    })
            } else if let vera = paletteVera {
                // la palette vera, comandata col puntatore; la rotellina (o tieni premuto e trascina) la fa scorrere
                ScrollView { vera.padding(12) }
                    // arrivati in fondo si ferma (niente rimbalzo)
                    .scrollBounceBehavior(.basedOnSize)
                    .scrollPosition($scorrimento)
                    .onScrollGeometryChange(for: CGFloat.self) { max(0, $0.contentSize.height - $0.containerSize.height) } action: { _, m in massimo = m }
                    .zonaMonitor("palette.scorri", trascina: { d, _ in
                        y = min(massimo, max(0, y - d.height))
                        scorrimento.scrollTo(y: y)
                    })
                    .onChange(of: studio.paletteMonitor) { _, _ in y = 0; scorrimento.scrollTo(edge: .top) }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: studio.paletteMonitor.icona).font(.system(size: 28)).foregroundStyle(Tema.accento)
                    Text("Palette \(studio.paletteMonitor.rawValue)").font(.system(size: 14, weight: .semibold))
                    Text(tattile ? "This palette opens from the normal interface (✕ at the top right)." : "Adjust it on the phone; here you see the result in the viewer and on the scopes.")
                        .font(.system(size: 12)).foregroundStyle(Tema.testo2)
                }
            }
        }
    }

    @Environment(\.tattile) private var tattile
    @State private var scorrimento = ScrollPosition(edge: .top)
    @State private var y: CGFloat = 0
    @State private var massimo: CGFloat = 0

    /// Le palette del telefono che si usano anche sul monitor.
    private var paletteVera: AnyView? {
        switch studio.paletteMonitor {
        case .ai: return AnyView(PannelloAI(studio: studio))
        case .curve: return AnyView(PannelloCurve(studio: studio))
        case .warper: return AnyView(PannelloWarper(studio: studio))
        case .mixer: return AnyView(PannelloMixer(studio: studio))
        case .qualificatore: return AnyView(PannelloQualificatore(studio: studio))
        case .finestre: return AnyView(PannelloFinestre(studio: studio))
        case .effetti: return AnyView(PannelloEffetti(studio: studio))
        case .regolazioni: return AnyView(PannelloRegolazioni(studio: studio))
        case .cst: return AnyView(PannelloCST(studio: studio))
        case .galleria: return AnyView(PannelloGalleria(studio: studio))
        default: return nil
        }
    }

    /// Valore numerico: col mouse (o tenendo premuto sul trackpad) si trascina a destra o a sinistra, come in DaVinci.
    private func valore(_ nome: String, _ kp: WritableKeyPath<Grade, Float>, _ intervallo: ClosedRange<Float>, _ formato: String) -> some View {
        HStack(spacing: 6) {
            Text(nome).font(.system(size: 11)).foregroundStyle(Tema.testo2)
            Text(String(format: formato, studio.nodo.grade[keyPath: kp])).font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.07)))
        }
        .padding(.horizontal, 4).padding(.vertical, 3)
        .zonaMonitor("valore." + nome, trascina: { d, _ in Studio.condiviso.spostaValore(kp, d.width, intervallo) },
                     destro: { Studio.condiviso.nodo.grade[keyPath: kp] = Grade()[keyPath: kp] })
    }

    @State private var barre = false
    @State private var primaZona = 0

    private func freccia(_ simbolo: String, _ id: String, _ azione: @escaping () -> Void) -> some View {
        Image(systemName: simbolo).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color(white: 0.7))
            .frame(width: 22, height: 20).contentShape(Rectangle())
            .zonaMonitor(id, clic: { _ in azione() })
    }

    /// Una ruota della palette HDR: colore, rotella dell'esposizione e i valori sotto (trascinabili).
    private func ruotaHDR(_ nome: String, _ kp: WritableKeyPath<Grade, Wheel>, sat: WritableKeyPath<Grade, Float>?, ampiezza: WritableKeyPath<Grade, Float>?) -> some View {
        let w = studio.nodo.grade[keyPath: kp]
        return VStack(spacing: 5) {
            HStack(spacing: 6) {
                Text(nome).font(.system(size: 12, weight: .semibold))
                if let ampiezza {
                    // ampiezza della fascia, come il numero accanto alla ruota in DaVinci
                    piccolo("⟷", String(format: "%.2f", studio.nodo.grade[keyPath: ampiezza]), "ampiezza." + nome, ampiezza, 0.3...3, base: 1)
                }
            }
            ColorWheel(x: .constant(w.x), y: .constant(w.y)).frame(width: 104, height: 104)
                .zonaMonitor("hdrruota." + nome, trascina: { d, _ in Studio.condiviso.spostaRuota(kp, d, raggio: 52) },
                             destro: { Studio.condiviso.azzeraRuota(kp, colore: true) })
            MasterRing(valore: .constant(w.master)).frame(maxWidth: 120)
                .zonaMonitor("hdrmaster." + nome, trascina: { d, _ in Studio.condiviso.spostaMaster(kp, d, larghezza: 120) },
                             destro: { Studio.condiviso.azzeraRuota(kp, colore: false) })
            HStack(spacing: 8) {
                piccolo("Exp", String(format: "%+.2f", w.master), "exp." + nome, kp.appending(path: \.master), -1...1, base: 0)
                if let sat { piccolo("Sat", String(format: "%.2f", studio.nodo.grade[keyPath: sat]), "sat." + nome, sat, 0...2, base: 1) }
            }
            HStack(spacing: 8) {
                piccolo("X", String(format: "%.2f", w.x), "x." + nome, kp.appending(path: \.x), -1...1, base: 0)
                piccolo("Y", String(format: "%.2f", w.y), "y." + nome, kp.appending(path: \.y), -1...1, base: 0)
            }
        }
    }

    /// Valore piccolo trascinabile (tasto destro = valore di partenza).
    private func piccolo(_ etichetta: String, _ testo: String, _ id: String, _ kp: WritableKeyPath<Grade, Float>, _ intervallo: ClosedRange<Float>, base: Float) -> some View {
        HStack(spacing: 3) {
            Text(etichetta).font(.system(size: 9)).foregroundStyle(Tema.testo2)
            Text(testo).font(.system(size: 10, design: .monospaced))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.07)))
        }
        .zonaMonitor("hdrval." + id, trascina: { d, _ in Studio.condiviso.spostaValore(kp, d.width, intervallo) },
                     destro: { Studio.condiviso.nodo.grade[keyPath: kp] = base })
    }

    private func vista(_ simbolo: String, _ nome: String, _ attiva: Bool, _ azione: @escaping () -> Void) -> some View {
        Image(systemName: simbolo).font(.system(size: 12))
            .frame(width: 28, height: 24)
            .background(RoundedRectangle(cornerRadius: 5).fill(attiva ? Tema.accento.opacity(0.2) : Color.clear))
            .foregroundStyle(attiva ? Tema.accento : Tema.testo2)
            .zonaMonitor("primarie.vista." + nome, clic: { _ in azione() })
    }

    /// Valore che sta nel nodo e non nella correzione (Mid/Detail è un effetto spaziale).
    private func valoreNodo(_ nome: String, _ kp: WritableKeyPath<Nodo, Float>, _ intervallo: ClosedRange<Float>, _ formato: String) -> some View {
        HStack(spacing: 6) {
            Text(nome).font(.system(size: 11)).foregroundStyle(Tema.testo2)
            Text(String(format: formato, studio.nodo[keyPath: kp])).font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.07)))
        }
        .padding(.horizontal, 4).padding(.vertical, 3)
        .zonaMonitor("valore." + nome, trascina: { d, _ in
            let s = Studio.condiviso
            let passo = Float(d.width / 300) * (intervallo.upperBound - intervallo.lowerBound)
            s.nodo[keyPath: kp] = min(intervallo.upperBound, max(intervallo.lowerBound, s.nodo[keyPath: kp] + passo))
        }, destro: { Studio.condiviso.nodo[keyPath: kp] = 0 })
    }

    /// Vista a barre (Color Bars): Y (master), R, G, B; tieni premuto e trascina su o giù, tasto destro = 0.
    private func barre(_ nome: String, _ kp: WritableKeyPath<Grade, Wheel>, base: Float, scala: Float) -> some View {
        let w = studio.nodo.grade[keyPath: kp]
        let v = w.colore * scala + SIMD3(repeating: base + w.master * scala * 2)
        let valori: [(String, Float, Color)] = [
            ("Y", base + w.master * scala * 2, Color(white: 0.85)),
            ("R", v.x, Color(red: 1, green: 0.4, blue: 0.35)),
            ("G", v.y, Color(red: 0.4, green: 0.9, blue: 0.45)),
            ("B", v.z, Color(red: 0.4, green: 0.6, blue: 1)),
        ]
        return VStack(spacing: 6) {
            Text(nome).font(.system(size: 12, weight: .semibold))
            HStack(spacing: 10) {
                ForEach(0..<4, id: \.self) { i in
                    let (canale, valore, colore) = valori[i]
                    VStack(spacing: 4) {
                        GeometryReader { g in
                            let t = CGFloat(min(1, max(0, (valore - base) / (scala * 2) * 0.5 + 0.5)))
                            ZStack(alignment: .bottom) {
                                RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.08))
                                RoundedRectangle(cornerRadius: 1).fill(colore).frame(height: 3)
                                    .offset(y: -t * (g.size.height - 3))
                            }
                        }
                        .frame(width: 18)
                        .zonaMonitor("barra." + nome + canale, trascina: { d, _ in
                            let s = Studio.condiviso
                            if s.nodo.tipo != .correzione { s.vaiACorrettore() }
                            let passo = Float(-d.height / 160)
                            if i == 0 { s.nodo.grade[keyPath: kp].master = min(1, max(-1, s.nodo.grade[keyPath: kp].master + passo)) }
                            else { s.nodo.grade[keyPath: kp].spostaCanale(i - 1, di: passo) }
                        }, destro: { Studio.condiviso.azzeraRuota(kp, colore: i != 0) })
                        Text(String(format: "%.2f", valore)).font(.system(size: 9, design: .monospaced)).foregroundStyle(colore)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func ruota(_ nome: String, _ kp: WritableKeyPath<Grade, Wheel>, base: Float, scala: Float) -> some View {
        let w = studio.nodo.grade[keyPath: kp]
        let v = w.colore * scala + SIMD3(repeating: base + w.master * scala * 2)
        let y = base + w.master * scala * 2
        return VStack(spacing: 5) {
            HStack(spacing: 6) {
                Text(nome).font(.system(size: 12, weight: .semibold))
                Text("YRGB").font(.system(size: 9)).foregroundStyle(Tema.testo2)
            }
            // col trackpad: tieni premuto sulla ruota (o sulla rotella) e muovi
            // stessa grandezza delle ruote HDR: entrambe ci stanno nello spazio delle palette
            ColorWheel(x: .constant(w.x), y: .constant(w.y)).frame(width: 104, height: 104)
                .zonaMonitor("ruota." + nome, trascina: { d, _ in Studio.condiviso.spostaRuota(kp, d, raggio: 52) },
                             destro: { Studio.condiviso.azzeraRuota(kp, colore: true) })
            MasterRing(valore: .constant(w.master)).frame(maxWidth: 120)
                .zonaMonitor("master." + nome, trascina: { d, _ in Studio.condiviso.spostaMaster(kp, d, larghezza: 120) },
                             destro: { Studio.condiviso.azzeraRuota(kp, colore: false) })
            HStack(spacing: 5) {
                Text(String(format: "%.2f", y))
                Text(String(format: "%.2f", v.x)).foregroundStyle(Color(red: 1, green: 0.45, blue: 0.4))
                Text(String(format: "%.2f", v.y)).foregroundStyle(Color(red: 0.45, green: 0.9, blue: 0.5))
                Text(String(format: "%.2f", v.z)).foregroundStyle(Color(red: 0.45, green: 0.65, blue: 1))
            }
            .font(.system(size: 10, design: .monospaced))
        }
    }
}

// MARK: keyframe

private struct KeyframeMonitor: View {
    @ObservedObject var studio: Studio

    var body: some View {
        let durata = max(0.001, studio.durata)
        VStack(spacing: 0) {
            TestataMonitor(titolo: "Keyframes", destra: VistaMonitor.timecode(studio.tempo))
            GeometryReader { g in
                let colonna: CGFloat = 120
                let larga = g.size.width - colonna
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        riga("Clip", tempi: [], larga: larga, durata: durata)
                        ForEach(Array(studio.nodi.enumerated()), id: \.element.id) { i, n in
                            riga(String(format: "%02d ", i + 1) + n.etichetta, tempi: n.keyframes.map(\.tempo), larga: larga, durata: durata)
                        }
                    }
                    if studio.eVideo {
                        Rectangle().fill(Color.red).frame(width: 2, height: g.size.height)
                            .offset(x: colonna + larga * min(1, max(0, studio.tempo / durata)))
                    }
                }
            }
        }
        .background(Tema.pannello)
    }

    private func riga(_ nome: String, tempi: [Double], larga: CGFloat, durata: Double) -> some View {
        HStack(spacing: 0) {
            Text(nome).font(.system(size: 10)).lineLimit(1).frame(width: 112, alignment: .leading).padding(.leading, 8)
            ZStack(alignment: .leading) {
                Rectangle().fill(Color(white: 0.085))
                ForEach(Array(tempi.enumerated()), id: \.offset) { _, t in
                    Rectangle().fill(Tema.accento).frame(width: 9, height: 9).rotationEffect(.degrees(45))
                        .offset(x: larga * min(1, max(0, t / durata)) - 4.5)
                }
            }
            .frame(width: larga)
        }
        .frame(height: 28)
        .overlay(alignment: .bottom) { Rectangle().fill(Color(white: 0.15)).frame(height: 1) }
    }
}

// MARK: scope

private struct ScopeMonitor: View {
    @ObservedObject var studio: Studio

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(TipoScope.allCases.filter { $0 != .nessuno }) { t in
                    let attivo = t == studio.scope
                    Text(t.rawValue).font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 9).frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: 6).fill(attivo ? Tema.accento.opacity(0.16) : Tema.campo))
                        .foregroundStyle(attivo ? Tema.accento : Color(white: 0.78))
                        .zonaMonitor("scope." + t.rawValue, clic: { _ in Studio.condiviso.scope = t })
                }
            }
            .padding(.horizontal, 8).frame(height: 52)
            .overlay(alignment: .bottom) { Rectangle().fill(Color(white: 0.17)).frame(height: 1) }
            ZStack {
                Color(white: 0.04)
                if let s = studio.immagineScope {
                    Image(uiImage: s).resizable().interpolation(.medium).scaledToFit().padding(8)
                } else {
                    Text("Scopes off: choose them on the phone.").font(.system(size: 12)).foregroundStyle(Tema.testo2)
                }
            }
        }
        .background(Tema.pannello)
    }
}

// MARK: - Pulsante Monitor sul telefono

/// Impostazioni del monitor esterno, dal pulsante Monitor in alto.
struct FoglioMonitor: View {
    @ObservedObject var studio: Studio
    /// Chiude questo foglio e apre il trackpad.
    var apriTrackpad: () -> Void = {}
    @Environment(\.dismiss) private var chiudi

    var body: some View {
        NavigationStack {
            Form {
                if !studio.monitorCollegato {
                    Section {
                        Text("Connect a monitor or a TV (USB-C/HDMI cable or AirPlay): the desktop interface appears on the monitor and the phone becomes a trackpad and keyboard.")
                            .font(.footnote).foregroundStyle(Tema.testo2)
                    }
                }
                if studio.monitorCollegato {
                    Section("On the monitor") {
                        Picker("On the monitor", selection: $studio.monitor.desktop) {
                            Text("Desktop interface").tag(true)
                            Text("Image only").tag(false)
                        }
                        .pickerStyle(.segmented)
                        .listRowBackground(Color.clear)
                        Button { apriTrackpad() } label: {
                            Label("Use as trackpad and keyboard", systemImage: "hand.point.up.left").foregroundStyle(Tema.accento)
                        }
                    }
                }
                if studio.monitor.desktop {
                    Section("Panels") {
                        Button("Reset panel sizes") {
                            let base = ImpostazioniMonitor()
                            studio.monitor.quotaGalleria = base.quotaGalleria; studio.monitor.quotaNodi = base.quotaNodi; studio.monitor.quotaPalette = base.quotaPalette
                        }
                        .foregroundStyle(Tema.accento)
                        Toggle("Stills gallery", isOn: $studio.monitor.galleria)
                        Toggle("Clip strip", isOn: $studio.monitor.clip)
                        Toggle("Keyframes", isOn: $studio.monitor.keyframe)
                        Toggle("Scope", isOn: $studio.monitor.scope)
                    }
                    .tint(Tema.accento)
                } else {
                    Section {
                        Text("The monitor shows only the graded image full screen, without controls: useful for showing the work to a client.")
                            .font(.footnote).foregroundStyle(Tema.testo2)
                    }
                }
            }
            .navigationTitle("External monitor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { chiudi() } } }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }
}

/// Divisore trascinabile tra due pannelli (come in DaVinci): sposta il confine e ridimensiona il video.
private struct Divisore: View {
    let verticale: Bool
    let id: String
    let sposta: (CGFloat) -> Void

    var body: some View {
        ZStack {
            Rectangle().fill(Color(white: 0.05))
            Capsule().fill(Color(white: 0.32))
                .frame(width: verticale ? 3 : 46, height: verticale ? 46 : 3)
        }
        .frame(width: verticale ? 10 : nil, height: verticale ? nil : 10)
        .frame(maxWidth: verticale ? nil : .infinity, maxHeight: verticale ? .infinity : nil)
        .zonaMonitor("divisore." + id, trascina: { d, _ in sposta(verticale ? d.width : d.height) })
    }
}

// MARK: - Desktop a finestre (modalità desktop sul telefono, come un piccolo Mac)

/// I pannelli che diventano finestre.
enum PannelloDesktop: String, Codable, CaseIterable, Identifiable {
    case viewer, nodi, galleria, clip, palette, keyframe, scope
    var id: String { rawValue }
    var titolo: String {
        switch self {
        case .viewer: return "Viewer"
        case .nodi: return "Nodes"
        case .galleria: return "Gallery"
        case .clip: return "Clip"
        case .palette: return "Palette"
        case .keyframe: return "Keyframes"
        case .scope: return "Scope"
        }
    }
    var icona: String {
        switch self {
        case .viewer: return "play.rectangle"
        case .nodi: return "point.3.connected.trianglepath.dotted"
        case .galleria: return "photo.stack"
        case .clip: return "film.stack"
        case .palette: return "slider.horizontal.3"
        case .keyframe: return "diamond"
        case .scope: return "waveform.path.ecg"
        }
    }
}

/// Una finestra: posizione e misura in quote dell'area di lavoro (0…1), così va bene su ogni schermo.
struct FinestraDesktop: Codable, Equatable, Identifiable {
    var pannello: PannelloDesktop
    var x: Double, y: Double, w: Double, h: Double
    var aperta = true
    var massima = false
    var id: PannelloDesktop { pannello }
}

/// Le finestre in ordine dal fondo al primo piano, ricordate tra un avvio e l'altro.
struct DisposizioneDesktop: Codable, Equatable {
    var finestre: [FinestraDesktop]

    static let base = DisposizioneDesktop(finestre: [
        .init(pannello: .clip, x: 0, y: 0.55, w: 1, h: 0.15),
        .init(pannello: .palette, x: 0, y: 0.70, w: 0.5, h: 0.30),
        .init(pannello: .keyframe, x: 0.5, y: 0.70, w: 0.2, h: 0.30),
        .init(pannello: .scope, x: 0.7, y: 0.70, w: 0.3, h: 0.30),
        .init(pannello: .galleria, x: 0, y: 0, w: 0.14, h: 0.55),
        .init(pannello: .nodi, x: 0.70, y: 0, w: 0.30, h: 0.55),
        .init(pannello: .viewer, x: 0.14, y: 0, w: 0.56, h: 0.55),
    ])

    static func carica() -> DisposizioneDesktop {
        guard let d = UserDefaults.standard.data(forKey: "disposizioneDesktop"),
              let v = try? JSONDecoder().decode(DisposizioneDesktop.self, from: d),
              Set(v.finestre.map(\.pannello)) == Set(PannelloDesktop.allCases) else { return .base }
        return v
    }

    func salva() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: "disposizioneDesktop") }
    }
}

struct DesktopFinestre: View {
    @ObservedObject var studio: Studio
    var esci: () -> Void
    @State private var disp = DisposizioneDesktop.carica()
    /// Finestra che si sta spostando o ridimensionando, con la sua misura all'inizio del gesto.
    @State private var gesto: (PannelloDesktop, FinestraDesktop)?

    private let altezzaBarra: CGFloat = 34
    private let altezzaDock: CGFloat = 70

    var body: some View {
        GeometryReader { g in
            let area = CGRect(x: 0, y: altezzaBarra, width: g.size.width, height: g.size.height - altezzaBarra - altezzaDock)
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [Color(red: 0.10, green: 0.11, blue: 0.14), Color(red: 0.05, green: 0.05, blue: 0.07)],
                               startPoint: .top, endPoint: .bottom)
                ForEach(disp.finestre.filter(\.aperta)) { f in
                    finestra(f, area: area)
                }
                barraMenu.frame(width: g.size.width, height: altezzaBarra)
                dock
                    .frame(maxWidth: .infinity)
                    .offset(y: g.size.height - altezzaDock + 6)
            }
        }
        .environment(\.tattile, true)
        .onChange(of: disp) { _, d in d.salva() }
    }

    // MARK: finestra

    private func riquadro(_ f: FinestraDesktop, _ a: CGRect) -> CGRect {
        if f.massima { return a }
        return CGRect(x: a.minX + f.x * a.width, y: a.minY + f.y * a.height, width: f.w * a.width, height: f.h * a.height)
    }

    private func finestra(_ f: FinestraDesktop, area a: CGRect) -> some View {
        let r = riquadro(f, a)
        let davanti = disp.finestre.last(where: \.aperta)?.pannello == f.pannello
        return VStack(spacing: 0) {
            // barra del titolo: trascinala per spostare la finestra
            HStack(spacing: 7) {
                pallino(Color(red: 1, green: 0.37, blue: 0.34)) { cambia(f.pannello) { $0.aperta = false; $0.massima = false } }
                pallino(Color(red: 0.16, green: 0.79, blue: 0.25)) { cambia(f.pannello) { $0.massima.toggle() }; portaDavanti(f.pannello) }
                Image(systemName: f.pannello.icona).font(.system(size: 11)).foregroundStyle(Tema.testo2).padding(.leading, 6)
                Text(f.pannello.titolo).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(davanti ? Color(white: 0.9) : Tema.testo2)
                Spacer()
            }
            .padding(.horizontal, 10).frame(height: 28)
            .frame(maxWidth: .infinity)
            .background(Color(white: davanti ? 0.20 : 0.15))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { v in
                    if gesto?.0 != f.pannello { gesto = (f.pannello, f); portaDavanti(f.pannello) }
                    guard let base = gesto?.1, !base.massima else { return }
                    cambia(f.pannello) {
                        $0.x = min(1 - base.w * 0.3, max(-base.w * 0.7, base.x + v.translation.width / a.width))
                        $0.y = min(0.95, max(0, base.y + v.translation.height / a.height))
                    }
                }
                .onEnded { _ in gesto = nil })
            contenuto(f.pannello)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
                .clipped()
        }
        .background(Tema.pannello)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(davanti ? Tema.accento.opacity(0.7) : Color(white: 0.25), lineWidth: davanti ? 1.5 : 1))
        // angolo in basso a destra: trascinalo per ridimensionare
        .overlay(alignment: .bottomTrailing) {
            if !f.massima {
                Image(systemName: "arrow.down.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color(white: 0.7))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.black.opacity(0.55)))
                    .padding(4)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 1)
                        .onChanged { v in
                            if gesto?.0 != f.pannello { gesto = (f.pannello, f); portaDavanti(f.pannello) }
                            guard let base = gesto?.1 else { return }
                            cambia(f.pannello) {
                                $0.w = min(1, max(220 / a.width, base.w + v.translation.width / a.width))
                                $0.h = min(1, max(150 / a.height, base.h + v.translation.height / a.height))
                            }
                        }
                        .onEnded { _ in gesto = nil })
            }
        }
        .shadow(color: .black.opacity(0.5), radius: davanti ? 14 : 6, y: 4)
        .frame(width: r.width, height: r.height)
        .offset(x: r.minX, y: r.minY)
        .simultaneousGesture(TapGesture().onEnded { portaDavanti(f.pannello) })
    }

    private func pallino(_ c: Color, _ azione: @escaping () -> Void) -> some View {
        Circle().fill(c).frame(width: 13, height: 13)
            .frame(width: 24, height: 26)
            .contentShape(Rectangle())
            .onTapGesture(perform: azione)
    }

    @ViewBuilder
    private func contenuto(_ p: PannelloDesktop) -> some View {
        switch p {
        case .viewer: VistaMonitor(studio: studio).viewer
        case .nodi: NodiMonitor(studio: studio)
        case .galleria: GalleriaMonitor(studio: studio)
        case .clip: ClipMonitor(studio: studio)
        case .palette: PaletteMonitor(studio: studio)
        case .keyframe: KeyframeMonitor(studio: studio)
        case .scope: ScopeMonitor(studio: studio)
        }
    }

    private func cambia(_ p: PannelloDesktop, _ modifica: (inout FinestraDesktop) -> Void) {
        guard let i = disp.finestre.firstIndex(where: { $0.pannello == p }) else { return }
        modifica(&disp.finestre[i])
    }

    private func portaDavanti(_ p: PannelloDesktop) {
        guard let i = disp.finestre.firstIndex(where: { $0.pannello == p }), i != disp.finestre.count - 1 else { return }
        disp.finestre.append(disp.finestre.remove(at: i))
    }

    // MARK: barra in alto (come quella del Mac)

    private var barraMenu: some View {
        HStack(spacing: 4) {
            Text("Colors").font(.system(size: 14, weight: .bold)).foregroundStyle(Tema.accento).padding(.trailing, 10)
            ForEach(Pagina.visibili) { p in
                let attiva = p == studio.paginaMonitor
                Text(p.rawValue).font(.system(size: 13, weight: attiva ? .semibold : .regular))
                    .padding(.horizontal, 10).frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 5).fill(attiva ? Tema.accento.opacity(0.18) : .clear))
                    .foregroundStyle(attiva ? Tema.accento : Color(white: 0.85))
                    .contentShape(Rectangle())
                    .onTapGesture { studio.richiestaPagina = p }
            }
            Spacer()
            Text(studio.progetto.nome).font(.system(size: 13)).foregroundStyle(Color(white: 0.8))
            TimelineView(.everyMinute) { t in
                Text(t.date, format: .dateTime.hour().minute()).font(.system(size: 13, weight: .semibold))
            }
            .padding(.leading, 12)
        }
        .padding(.horizontal, 12)
        .background(.ultraThinMaterial.opacity(0.9))
        .background(Color.black.opacity(0.5))
    }

    // MARK: Dock

    private var dock: some View {
        HStack(spacing: 6) {
            ForEach(PannelloDesktop.allCases) { p in
                let f = disp.finestre.first { $0.pannello == p }
                let aperta = f?.aperta ?? false
                VStack(spacing: 3) {
                    Image(systemName: p.icona).font(.system(size: 20))
                        .frame(width: 46, height: 46)
                        .background(RoundedRectangle(cornerRadius: 11).fill(Color(white: aperta ? 0.24 : 0.16)))
                        .foregroundStyle(aperta ? Tema.accento : Color(white: 0.75))
                    Circle().fill(aperta ? Color.white.opacity(0.85) : .clear).frame(width: 4, height: 4)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    // chiusa: si apre; aperta ma dietro: viene davanti; già davanti: si chiude
                    if !aperta { cambia(p) { $0.aperta = true }; portaDavanti(p) }
                    else if disp.finestre.last(where: \.aperta)?.pannello != p { portaDavanti(p) }
                    else { cambia(p) { $0.aperta = false; $0.massima = false } }
                }
                .accessibilityLabel(p.titolo)
            }
            Rectangle().fill(Color.white.opacity(0.25)).frame(width: 1, height: 40).padding(.horizontal, 6)
            iconaDock("square.grid.2x2", "Arrange") { withAnimation(.easeOut(duration: 0.25)) { disp = .base } }
            iconaDock("rectangle.portrait.and.arrow.right", "Exit") { esci() }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.15), lineWidth: 1))
    }

    private func iconaDock(_ simbolo: String, _ nome: String, _ azione: @escaping () -> Void) -> some View {
        VStack(spacing: 3) {
            Image(systemName: simbolo).font(.system(size: 19))
                .frame(width: 46, height: 46)
                .background(RoundedRectangle(cornerRadius: 11).fill(Color(white: 0.16)))
                .foregroundStyle(Color(white: 0.85))
            Circle().fill(.clear).frame(width: 4, height: 4)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: azione)
        .accessibilityLabel(nome)
    }
}

// MARK: - Media (libreria del telefono sul monitor)

/// La libreria Foto del telefono vista sul monitor: video e foto più recenti; un clic li importa nel progetto.
private struct MediaMonitor: View {
    @ObservedObject var studio: Studio
    @StateObject private var libreria = LibreriaMonitor()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Media Pool · Photo Library").font(.system(size: 12, weight: .semibold))
                Spacer()
                ForEach(LibreriaMonitor.Filtro.allCases, id: \.self) { f in
                    Text(f.rawValue).font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10).frame(height: 22)
                        .background(Capsule().fill(libreria.filtro == f ? Tema.accento.opacity(0.2) : Tema.campo))
                        .foregroundStyle(libreria.filtro == f ? Tema.accento : Color(white: 0.8))
                        .zonaMonitor("media.filtro." + f.rawValue, clic: { _ in libreria.filtro = f })
                }
                if libreria.importando { Text("Importing…").font(.system(size: 11)).foregroundStyle(Tema.accento) }
            }
            .padding(.horizontal, 12).frame(height: 34)
            .background(Tema.pannello)
            switch libreria.stato {
            case .negato:
                messaggio("Colors can't see the Photo library. Allow access in Settings › Colors › Photos.")
            case .attesa:
                messaggio("Answer on the phone: Colors is asking to see the Photo library.")
            case .pronta:
                GeometryReader { g in
                    let colonne = max(3, Int(g.size.width / 150))
                    let lato = (g.size.width - CGFloat(colonne + 1) * 8) / CGFloat(colonne)
                    let righe = max(1, Int((g.size.height - 8) / (lato + 8)))
                    let pagina = colonne * righe
                    let inizio = min(libreria.inizio, max(0, libreria.elementi.count - pagina))
                    let visibili = Array(libreria.elementi.dropFirst(inizio).prefix(pagina))
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(0..<righe, id: \.self) { r in
                            HStack(spacing: 8) {
                                ForEach(0..<colonne, id: \.self) { c in
                                    let i = r * colonne + c
                                    if i < visibili.count {
                                        Miniatura(elemento: visibili[i], libreria: libreria, lato: lato)
                                            .zonaMonitor("media." + visibili[i].id, clic: { _ in libreria.importa(visibili[i], in: studio) })
                                    }
                                }
                            }
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    // rotella del mouse (o trascinamento) per scorrere la libreria
                    .zonaMonitor("media.griglia", trascina: { d, _ in libreria.scorri(d.height + d.width, pagina: colonne) })
                    .overlay(alignment: .bottomTrailing) {
                        Text("\(min(inizio + 1, libreria.elementi.count))–\(min(inizio + pagina, libreria.elementi.count)) of \(libreria.elementi.count)")
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(Tema.testo2).padding(6)
                    }
                }
            }
        }
        .background(Color(white: 0.06))
        .onAppear { libreria.carica() }
    }

    private func messaggio(_ t: String) -> some View {
        Text(t).font(.system(size: 13)).foregroundStyle(Tema.testo2).multilineTextAlignment(.center)
            .padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct Miniatura: View {
    let elemento: LibreriaMonitor.Elemento
    @ObservedObject var libreria: LibreriaMonitor
    let lato: CGFloat
    @State private var immagine: UIImage?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Rectangle().fill(Color(white: 0.12))
            if let immagine { Image(uiImage: immagine).resizable().scaledToFill() }
            HStack(spacing: 4) {
                if libreria.importati.contains(elemento.id) { Image(systemName: "checkmark.circle.fill").foregroundStyle(Tema.accento) }
                if elemento.video { Text(VistaMonitor.durata(elemento.durata)).font(.system(size: 10, weight: .semibold, design: .monospaced)) }
            }
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Capsule().fill(Color.black.opacity(0.6)))
            .padding(4)
        }
        .frame(width: lato, height: lato)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(libreria.importati.contains(elemento.id) ? Tema.accento : .clear, lineWidth: 2))
        .task(id: elemento.id) { immagine = await libreria.miniatura(elemento, lato: lato) }
    }
}

extension VistaMonitor {
    static func durata(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }
}

@MainActor
final class LibreriaMonitor: ObservableObject {
    enum Stato { case attesa, negato, pronta }
    enum Filtro: String, CaseIterable { case tutto = "All", video = "Video", foto = "Photo" }
    struct Elemento: Identifiable { let id: String; let asset: PHAsset; var video: Bool { asset.mediaType == .video }; var durata: Double { asset.duration } }

    @Published var stato = Stato.attesa
    @Published var filtro = Filtro.tutto { didSet { inizio = 0; leggi() } }
    @Published private(set) var elementi: [Elemento] = []
    @Published var inizio = 0
    @Published var importati: Set<String> = []
    @Published private(set) var importando = false
    private let gestore = PHCachingImageManager()
    private var accumulo: CGFloat = 0

    func carica() {
        let s = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if s == .authorized || s == .limited { stato = .pronta; leggi(); return }
        if s == .denied || s == .restricted { stato = .negato; return }
        stato = .attesa
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { nuovo in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                self.stato = (nuovo == .authorized || nuovo == .limited) ? .pronta : .negato
                if self.stato == .pronta { self.leggi() }
            } }
        }
    }

    private func leggi() {
        let o = PHFetchOptions()
        o.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        o.fetchLimit = 600
        switch filtro {
        case .video: o.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        case .foto: o.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        case .tutto: o.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d", PHAssetMediaType.video.rawValue, PHAssetMediaType.image.rawValue)
        }
        let r = PHAsset.fetchAssets(with: o)
        var v: [Elemento] = []
        r.enumerateObjects { a, _, _ in v.append(Elemento(id: a.localIdentifier, asset: a)) }
        elementi = v
    }

    /// Scorre di una riga ogni 60 punti di rotella/trascinamento.
    func scorri(_ d: CGFloat, pagina colonne: Int) {
        accumulo += d
        while abs(accumulo) >= 60 {
            inizio = max(0, min(max(0, elementi.count - colonne), inizio + (accumulo < 0 ? colonne : -colonne)))
            accumulo += accumulo < 0 ? 60 : -60
        }
    }

    func miniatura(_ e: Elemento, lato: CGFloat) async -> UIImage? {
        let o = PHImageRequestOptions()
        o.deliveryMode = .opportunistic
        o.isNetworkAccessAllowed = true
        o.resizeMode = .fast
        let px = lato * 2
        return await withCheckedContinuation { c in
            var fatto = false
            gestore.requestImage(for: e.asset, targetSize: CGSize(width: px, height: px), contentMode: .aspectFill, options: o) { img, info in
                let provvisoria = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if !provvisoria, !fatto { fatto = true; c.resume(returning: img) }
                else if img == nil, !fatto { fatto = true; c.resume(returning: nil) }
            }
        }
    }

    /// Copia il file originale (anche da iCloud) e lo aggiunge al progetto come quando lo scegli sul telefono.
    /// Solo l'audio di un video della Libreria: diventa una traccia della musica (A1).
    func importaAudio(_ e: Elemento, in studio: Studio) {
        guard !importando, e.video else { return }
        importando = true
        let risorse = PHAssetResource.assetResources(for: e.asset)
        guard let r = risorse.first(where: { $0.type == .video }) ?? risorse.first else { importando = false; return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + r.originalFilename)
        let o = PHAssetResourceRequestOptions()
        o.isNetworkAccessAllowed = true
        PHAssetResourceManager.default().writeData(for: r, toFile: url, options: o) { errore in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                Task { @MainActor in
                    defer { try? FileManager.default.removeItem(at: url); self.importando = false }
                    if let errore { studio.messaggio = "Can't get the audio: \(errore.localizedDescription)"; return }
                    let nome = (r.originalFilename as NSString).deletingPathExtension
                    if await studio.aggiungiAudio(daVideo: url, nome: nome) { self.importati.insert(e.id) }
                    else { studio.messaggio = "This video has no audio." }
                }
            } }
        }
    }

    /// Copia il media nel Media Pool del progetto (non nella timeline).
    func importaNelPool(_ e: Elemento, in studio: Studio) {
        guard !importando else { return }
        importando = true
        let risorse = PHAssetResource.assetResources(for: e.asset)
        let tipo: PHAssetResourceType = e.video ? .video : .photo
        guard let r = risorse.first(where: { $0.type == tipo }) ?? risorse.first else { importando = false; return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + r.originalFilename)
        let o = PHAssetResourceRequestOptions()
        o.isNetworkAccessAllowed = true
        PHAssetResourceManager.default().writeData(for: r, toFile: url, options: o) { errore in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                Task { @MainActor in
                    defer { try? FileManager.default.removeItem(at: url); self.importando = false }
                    if let errore { studio.messaggio = "Can't import: \(errore.localizedDescription)"; return }
                    let nome = (r.originalFilename as NSString).deletingPathExtension
                    if e.video { await studio.importaNelPool(url, video: true, nome: nome) }
                    else if let d = try? Data(contentsOf: url), let img = UIImage(data: d), let jpg = img.jpegData(compressionQuality: 0.95) {
                        let j = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
                        try? jpg.write(to: j)
                        await studio.importaNelPool(j, video: false, nome: nome)
                        try? FileManager.default.removeItem(at: j)
                    }
                    self.importati.insert(e.id)
                }
            } }
        }
    }

    func importa(_ e: Elemento, in studio: Studio, fatto: ((UUID?) -> Void)? = nil) {
        guard !importando else { return }
        importando = true
        let risorse = PHAssetResource.assetResources(for: e.asset)
        let tipo: PHAssetResourceType = e.video ? .video : .photo
        guard let r = risorse.first(where: { $0.type == tipo }) ?? risorse.first else {
            importando = false; studio.messaggio = "Can't read this item."; return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + r.originalFilename)
        let o = PHAssetResourceRequestOptions()
        o.isNetworkAccessAllowed = true
        PHAssetResourceManager.default().writeData(for: r, toFile: url, options: o) { errore in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                Task { @MainActor in
                    defer { try? FileManager.default.removeItem(at: url); self.importando = false }
                    if let errore { studio.messaggio = "Can't import: \(errore.localizedDescription)"; return }
                    let prima = Set(studio.progetto.clips.map(\.id))
                    if e.video { await studio.importaVideo(url) }
                    else if let d = try? Data(contentsOf: url), let img = UIImage(data: d), let jpg = img.jpegData(compressionQuality: 0.95) {
                        await studio.importaFoto(jpg, nome: "Photo \(studio.progetto.clips.count + 1)")
                    }
                    self.importati.insert(e.id)
                    fatto?(studio.progetto.clips.first { !prima.contains($0.id) }?.id)
                }
            } }
        }
    }
}

// MARK: - Consegna sul monitor

/// Export dal monitor: video corretto nel Rullino e versioni per i social (le LUT si salvano dal telefono).
private struct ConsegnaMonitor: View {
    @ObservedObject var studio: Studio
    @State private var formato: FormatoVideo = .prores
    @State private var social: FormatoSocial = .reel
    @State private var riempi = true
    @State private var montaggioIntero = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let l = studio.lavoro {
                HStack { ProgressView().tint(Tema.accento); Text(l).font(.system(size: 13, weight: .semibold)).foregroundStyle(Tema.accento) }
            }
            Text("Video render").font(.system(size: 13, weight: .bold))
            HStack(spacing: 8) {
                ForEach(FormatoVideo.allCases) { f in scelta(f.rawValue, f == formato) { formato = f } }
            }
            pulsante("Export the video to the Camera Roll", "square.and.arrow.down") { Task { await studio.esportaVideo(formato) } }
            Divider().overlay(Color(white: 0.2))
            Text("For social media").font(.system(size: 13, weight: .bold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(FormatoSocial.allCases) { f in scelta(f.rawValue, f == social) { social = f } }
            }
            HStack(spacing: 8) {
                scelta("Fill (crops the edges)", riempi) { riempi = true }
                scelta("Fit (black bars)", !riempi) { riempi = false }
            }
            HStack(spacing: 8) {
                scelta("This clip", !montaggioIntero) { montaggioIntero = false }
                scelta("Whole edit (\(studio.progetto.clips.count) clips)", montaggioIntero) { montaggioIntero = true }
            }
            pulsante("Export for \(social.rawValue)", "paperplane") {
                Task {
                    if montaggioIntero { await studio.esportaMontaggio(social, riempi: social == .originale ? false : riempi) }
                    else { await studio.esportaSocial(social, riempi: riempi) }
                }
            }
            Text("The file ends up in the phone's Camera Roll. LUTs and CDLs are saved from the phone's Deliver page.")
                .font(.system(size: 11)).foregroundStyle(Tema.testo2)
        }
    }

    private func scelta(_ t: String, _ attiva: Bool, _ azione: @escaping () -> Void) -> some View {
        Button(action: azione) {
            Text(t).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                .padding(.horizontal, 12).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(attiva ? Tema.accento.opacity(0.2) : Tema.campo))
                .foregroundStyle(attiva ? Tema.accento : Color(white: 0.85))
        }
    }

    private func pulsante(_ t: String, _ simbolo: String, _ azione: @escaping () -> Void) -> some View {
        Button(action: azione) {
            Label(t, systemImage: simbolo).font(.system(size: 13, weight: .bold))
                .padding(.horizontal, 16).frame(height: 38)
                .background(RoundedRectangle(cornerRadius: 9).fill(Tema.accento))
                .foregroundStyle(.black)
        }
        .disabled(studio.lavoro != nil)
    }
}

// MARK: - Anteprima di prova

/// Solo per le prove nel simulatore (avvio con -anteprimaMonitor): l'interfaccia del monitor sul telefono, in orizzontale.
struct AnteprimaMonitor: View {
    @ObservedObject var studio: Studio

    var body: some View {
        GeometryReader { g in
            let k = g.size.width / 1920
            VistaMonitor(studio: studio)
                .environment(\.tattile, true)
                .frame(width: 1920, height: g.size.height / k)
                .scaleEffect(k, anchor: .topLeading)
        }
        .background(Color.black)
        .ignoresSafeArea()
        .statusBarHidden()
        .onAppear {
            ModalitaDesktop.ruota(orizzontale: true)
            if CommandLine.arguments.contains("-provaBenvenuto") { studio.benvenutoMonitor = true }
            if CommandLine.arguments.contains("-provaZone") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 12) { MainActor.assumeIsolated {
                    for (id, z) in ZoneMonitor.condivise.zone where id.hasPrefix("ruota.") || id.hasPrefix("master.") || id.hasPrefix("valore.Temp") {
                        GestoreMonitor.scrivi("zone \(id) \(Int(z.riquadro.minX)),\(Int(z.riquadro.minY)) \(Int(z.riquadro.width))x\(Int(z.riquadro.height))")
                    }
                } }
            }
            // prova del trascinamento col "mouse": -provaTrascina x,y,dx,dy (punti del monitor)
            if let i = CommandLine.arguments.firstIndex(of: "-provaTrascina"), i + 1 < CommandLine.arguments.count {
                let n = CommandLine.arguments[i + 1].split(separator: ",").compactMap { Double($0) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 9) { MainActor.assumeIsolated {
                    let s = Studio.condiviso
                    if CommandLine.arguments.contains("-paginaEdit") { s.richiestaPagina = .edit } else { s.richiestaPalette = .warper }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { MainActor.assumeIsolated {
                        let p = CGPoint(x: n[0], y: n[1])
                        s.puntatore = p
                        guard let (id, _) = ZoneMonitor.condivise.zona(in: p, dove: { $0.trascina != nil }) else { GestoreMonitor.scrivi("test: no zone"); return }
                        GestoreMonitor.scrivi("test: zone \(id)")
                        s.iniziaTrascinamento(id, da: p)
                        for _ in 0..<5 { s.trascinaMonitor(CGSize(width: n[2] / 5, height: n[3] / 5), zona: id) }
                    } }
                } }
            }
            // prova: serie di clic nella pagina Edit (-provaSerie "x,y;x,y;…"), uno ogni 0,7 s
            if let i = CommandLine.arguments.firstIndex(of: "-provaSerie"), i + 1 < CommandLine.arguments.count {
                let voci = CommandLine.arguments[i + 1].split(separator: ";").map(String.init)
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { MainActor.assumeIsolated {
                    Studio.condiviso.richiestaPagina = CommandLine.arguments.contains("-paginaColor") ? .color : .edit
                } }
                for (k, v) in voci.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 10 + Double(k) * 0.7) { MainActor.assumeIsolated {
                        let s = Studio.condiviso
                        // "#id" = clic al centro della zona con quel nome; "x,y" = clic in quel punto
                        var q: [Double] = v.split(separator: ",").compactMap { Double($0) }
                        if v.hasPrefix("#"), let z = ZoneMonitor.condivise.zone[String(v.dropFirst())] { q = [z.riquadro.midX, z.riquadro.midY] }
                        guard q.count == 2 else { GestoreMonitor.scrivi("series test: zone \(v) not found"); return }
                        s.puntatore = CGPoint(x: q[0], y: q[1]); s.clicMonitor()
                        GestoreMonitor.scrivi("series test: click on \(ZoneMonitor.condivise.zona(in: CGPoint(x: q[0], y: q[1]))?.id ?? "nothing")")
                    } }
                }
            }
            // prova: rotella sulla timeline prima dei clic (-provaScorri n)
            if let i = CommandLine.arguments.firstIndex(of: "-provaScorri"), i + 1 < CommandLine.arguments.count, let n = Double(CommandLine.arguments[i + 1]) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 9.5) { MainActor.assumeIsolated {
                    let s = Studio.condiviso
                    s.puntatore = CGPoint(x: 1000, y: 700)
                    s.scorriMonitor(0, CGFloat(-n))
                } }
            }
            // prova di due clic col "mouse" nella pagina Edit: -provaClicEdit x1,y1,x2,y2 (punti del monitor)
            if let i = CommandLine.arguments.firstIndex(of: "-provaClicEdit"), i + 1 < CommandLine.arguments.count {
                let n = CommandLine.arguments[i + 1].split(separator: ",").compactMap { Double($0) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { MainActor.assumeIsolated {
                    let s = Studio.condiviso
                    s.richiestaPagina = .edit
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { MainActor.assumeIsolated {
                        s.puntatore = CGPoint(x: n[0], y: n[1]); s.clicMonitor()
                        GestoreMonitor.scrivi("edit test: click 1 on \(ZoneMonitor.condivise.zona(in: CGPoint(x: n[0], y: n[1]))?.id ?? "nothing")")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated {
                            s.puntatore = CGPoint(x: n[2], y: n[3]); s.clicMonitor()
                            GestoreMonitor.scrivi("edit test: click 2 on \(ZoneMonitor.condivise.zona(in: CGPoint(x: n[2], y: n[3]))?.id ?? "nothing"), clips \(s.progetto.clips.count)")
                        } }
                    } }
                } }
            }
            // prova: scrive nel registro dove sono le zone cliccabili
            DispatchQueue.main.asyncAfter(deadline: .now() + 7) { MainActor.assumeIsolated {
                for (id, z) in ZoneMonitor.condivise.zone.sorted(by: { $0.key < $1.key }) {
                    GestoreMonitor.scrivi("zone \(id) \(Int(z.riquadro.minX)),\(Int(z.riquadro.minY)) \(Int(z.riquadro.width))x\(Int(z.riquadro.height))")
                }
            } }
        }
    }
}

/// Mette un pannello tutto nello spazio disponibile: se è più alto lo rimpicciolisce (niente scorrimento).
private struct AdattaAltezza<Contenuto: View>: View {
    @ViewBuilder var contenuto: Contenuto
    @State private var altezza: CGFloat = 1

    var body: some View {
        GeometryReader { g in
            let k = min(1, g.size.height / max(1, altezza))
            contenuto
                .frame(width: g.size.width)
                .fixedSize(horizontal: false, vertical: true)
                // altezza "naturale" del pannello (la riduzione non cambia l'impaginazione)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                    if abs(h - altezza) > 2 { altezza = h }
                }
                .scaleEffect(k, anchor: .top)
                .frame(width: g.size.width, height: g.size.height, alignment: .top)
        }
        .clipped()
    }
}

// MARK: - Pagina Edit (timeline)

/// Le clip del progetto, come il Media Pool di DaVinci: clic = va alla clip nel montaggio, destro = menu.
private struct MediaPoolMonitor: View {
    @ObservedObject var studio: Studio
    @State private var libreriaAperta = false
    @State private var progettiAperti = false

    var body: some View {
        VStack(spacing: 0) {
            // schede come in DaVinci: Media Pool (clip) e Musica (Sound Library)
            HStack(spacing: 4) {
                scheda("Media Pool", "photo.on.rectangle", !studio.poolMusica && !libreriaAperta && !progettiAperti) { studio.poolMusica = false; libreriaAperta = false; progettiAperti = false }
                scheda("Import", "plus.rectangle.on.folder", libreriaAperta && !studio.poolMusica && !progettiAperti) { studio.poolMusica = false; libreriaAperta = true; progettiAperti = false }
                scheda("Music", "music.note", studio.poolMusica && !progettiAperti) { studio.poolMusica = true; progettiAperti = false }
                scheda("Projects", "folder", progettiAperti) { progettiAperti = true }
                Spacer()
            }
            .padding(.horizontal, 8).frame(height: 34)
            .background(Color(white: 0.12))
            if progettiAperti { ProgettiMonitor(studio: studio) }
            else if studio.poolMusica { MusicaMonitor(studio: studio) }
            else if libreriaAperta { ImportaEditMonitor(studio: studio) }
            else { clip }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Tema.pannello)
    }

    private func scheda(_ t: String, _ simbolo: String, _ attiva: Bool, _ azione: @escaping () -> Void) -> some View {
        Label(t, systemImage: simbolo).font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(attiva ? Tema.accento.opacity(0.18) : .clear))
            .foregroundStyle(attiva ? Tema.accento : Color(white: 0.75))
            .zonaMonitor("pool.scheda." + t, clic: { _ in azione() })
    }

    /// I media importati (come il Media Pool di DaVinci): tieni premuto e trascina sulla timeline per usarli,
    /// oppure tasto destro › Aggiungi alla timeline.
    @ViewBuilder private var clip: some View {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], spacing: 10) {
                    ForEach(studio.progetto.pool) { e in
                        let usato = studio.progetto.clips.contains { $0.file == e.file }
                        VStack(alignment: .leading, spacing: 3) {
                            ZStack(alignment: .bottomTrailing) {
                                if let img = Archivio.immagine("Miniature", e.miniatura) { Image(uiImage: img).resizable().scaledToFill() }
                                else { Rectangle().fill(Tema.campo) }
                                HStack(spacing: 3) {
                                    if usato { Image(systemName: "film").font(.system(size: 8)) }
                                    if e.video, let d = studio.durateFile[e.file] { Text(VistaMonitor.durata(d)).font(.system(size: 9, weight: .semibold, design: .monospaced)) }
                                }
                                .padding(.horizontal, 4).background(Color.black.opacity(0.6)).padding(3)
                            }
                            .frame(height: 72).frame(maxWidth: .infinity).clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            Text(e.nome).font(.system(size: 10)).lineLimit(1).foregroundStyle(Color(white: 0.8))
                        }
                        .zonaMonitor("pool." + e.id.uuidString,
                                     trascina: { _, _ in TrascinoMedia.condiviso.muovi(.pool(e.id), miniatura: Archivio.immagine("Miniature", e.miniatura)) },
                                     destro: {
                                         MenuMonitor.condiviso.apri([
                                             VoceMenuMonitor(titolo: "Add to timeline", icona: "plus.rectangle.on.rectangle") { Task { await studio.usaDalPool(e.id) } },
                                             VoceMenuMonitor(titolo: "Remove from Media Pool", icona: "trash", distruttiva: true) { studio.togliDalPool(e.id) },
                                         ])
                                     })
                    }
                }
                .padding(10)
            }
            .scrollBounceBehavior(.basedOnSize)
            .onAppear { studio.riempiPoolDaClips() }
            if studio.progetto.pool.isEmpty {
                Text("Media Pool empty: open «Import» and click the videos or photos to bring here.").font(.system(size: 12)).foregroundStyle(Tema.testo2).padding()
            }
            Text("Press and hold and drag a media item onto the timeline to use it · right-click for the menu")
                .font(.system(size: 10)).foregroundStyle(Tema.testo2).padding(.horizontal, 10).padding(.bottom, 6)
    }
}

/// Scheda Musica del Media Pool: le tracce del montaggio e l'audio da prendere dai video della Libreria o da un file.
private struct MusicaMonitor: View {
    @ObservedObject var studio: Studio
    @StateObject private var libreria = LibreriaMonitor()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("In the edit").font(.system(size: 11, weight: .semibold)).foregroundStyle(Tema.testo2).padding(.horizontal, 10).padding(.top, 8)
            if studio.progetto.musiche.isEmpty {
                Text("No music: add it below.").font(.system(size: 12)).foregroundStyle(Tema.testo2).padding(.horizontal, 10)
            }
            ForEach(studio.progetto.musiche) { m in
                HStack(spacing: 8) {
                    Image(systemName: "music.note").foregroundStyle(Color(red: 0.4, green: 0.8, blue: 0.5))
                    Text(m.nome).font(.system(size: 12)).lineLimit(1)
                    Spacer()
                    Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(Color(red: 1, green: 0.42, blue: 0.4))
                        .frame(width: 26, height: 22)
                        .zonaMonitor("musica.togli." + m.id.uuidString, clic: { _ in studio.togliMusica(m.id) })
                }
                .padding(.horizontal, 10).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color(white: 0.15)))
                .padding(.horizontal, 8)
            }
            // brani dell'app Musica e file audio messi nella cartella Colors (app File): si scelgono da qui
            BraniMonitor(studio: studio)
            Text("From files and linked drives · click to add").font(.system(size: 11, weight: .semibold)).foregroundStyle(Tema.testo2).padding(.horizontal, 10)
            EsploraFileMonitor(studio: studio, tipi: [.audio, .video]) { c, u, tipo in
                guard let base = CartelleCollegate.condivise.apri(c) else { return }
                Task {
                    defer { base.stopAccessingSecurityScopedResource() }
                    if let p = await FormatoFile.problema(u, video: false) { studio.messaggio = p; return }
                    if tipo == .audio { await studio.aggiungiMusica(u); await studio.aggiornaDurate() }
                    else if !(await studio.aggiungiAudio(daVideo: u, nome: u.deletingPathExtension().lastPathComponent)) { studio.messaggio = "This video has no audio." }
                }
            }
            .frame(height: 170)
            Text("Other files: put them in the Files app › On My iPhone › Colors and they show up here.")
                .font(.system(size: 10)).foregroundStyle(Tema.testo2)
                .padding(.horizontal, 10)
            HStack {
                Text("Audio from Library videos · click to add it").font(.system(size: 11, weight: .semibold)).foregroundStyle(Tema.testo2)
                Spacer()
                if libreria.importando { Text("Importing…").font(.system(size: 11)).foregroundStyle(Tema.accento) }
            }
            .padding(.horizontal, 10)
            switch libreria.stato {
            case .negato:
                Text("Allow access to photos in Settings › Colors › Photos.").font(.system(size: 12)).foregroundStyle(Tema.testo2).padding(10)
            case .attesa:
                Text("Answer on the phone: Colors is asking to see the Photo library.").font(.system(size: 12)).foregroundStyle(Tema.testo2).padding(10)
            case .pronta:
                GeometryReader { g in
                    let colonne = max(2, Int(g.size.width / 120))
                    let lato = (g.size.width - CGFloat(colonne + 1) * 8) / CGFloat(colonne)
                    let righe = max(1, Int((g.size.height - 8) / (lato + 8)))
                    let pagina = colonne * righe
                    let inizio = min(libreria.inizio, max(0, libreria.elementi.count - pagina))
                    let visibili = Array(libreria.elementi.dropFirst(inizio).prefix(pagina))
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(0..<righe, id: \.self) { r in
                            HStack(spacing: 8) {
                                ForEach(0..<colonne, id: \.self) { c in
                                    let i = r * colonne + c
                                    if i < visibili.count {
                                        Miniatura(elemento: visibili[i], libreria: libreria, lato: lato)
                                            .zonaMonitor("musica.lib." + visibili[i].id, clic: { _ in libreria.importaAudio(visibili[i], in: studio) })
                                    }
                                }
                            }
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .zonaMonitor("media.griglia", trascina: { d, _ in libreria.scorri(d.height + d.width, pagina: colonne) })
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { libreria.filtro = .video; libreria.carica() }
    }
}

/// Timeline del montaggio come la pagina Edit di DaVinci: strumenti, righello, traccia video V1 e audio A1, testina rossa.
private struct TimelineMonitor: View {
    @ObservedObject var studio: Studio
    /// Pixel per secondo (− e + per lo zoom).
    @State private var zoom: CGFloat = 60
    @State private var x: CGFloat = 0
    @State private var trascinata: UUID?
    @State private var spostamento: CGFloat = 0
    @State private var fine: Task<Void, Never>?
    /// Strumento attivo, come in DaVinci: freccia (scegli e sposta) o lama (un clic taglia la clip in quel punto).
    @State private var lama = false
    /// Tracce bloccate (lucchetto): non si spostano, tagliano o cancellano.
    @State private var videoBloccato = false
    @State private var audioBloccato = false
    @State private var posizione = ScrollPosition(edge: .leading)
    /// Bordo che si sta tirando (id clip, inizio?) e di quanto (s), per il numerino come in DaVinci.
    @State private var bordo: (UUID, Bool)?
    @State private var bordoDelta: Double = 0
    @State private var fineBordo: Task<Void, Never>?
    private let testata: CGFloat = 150

    static func vaiAllaClip(_ id: UUID) {
        let s = Studio.condiviso
        Task {
            await s.apriClip(id)
            if let i = s.progetto.clips.firstIndex(where: { $0.id == id }), i < s.iniziClip.count { s.vaiSequenza(s.iniziClip[i] + 0.01) }
        }
    }

    static func menuClip(_ id: UUID) {
        let s = Studio.condiviso
        vaiAllaClip(id)
        MenuMonitor.condiviso.apri([
            VoceMenuMonitor(titolo: "Split at playhead", icona: "scissors") { s.dividiAllaTestina() },
            VoceMenuMonitor(titolo: "Duplicate", icona: "plus.square.on.square") { s.duplicaClip(id); s.aggiornaSequenza() },
            VoceMenuMonitor(titolo: "Move left", icona: "arrow.left") { s.spostaClip(id, di: -1); s.aggiornaSequenza() },
            VoceMenuMonitor(titolo: "Move right", icona: "arrow.right") { s.spostaClip(id, di: 1); s.aggiornaSequenza() },
            VoceMenuMonitor(titolo: "Open in the Color page", icona: "circle.lefthalf.filled") {
                Task { await s.apriClip(id) }; s.richiestaPagina = .color
            },
            VoceMenuMonitor(titolo: "Delete from the edit", icona: "trash", distruttiva: true) {
                Task { await s.eliminaClip(id); s.aggiornaSequenza(ritardo: 0) }
            },
        ])
    }

    var body: some View {
        VStack(spacing: 0) {
            strumenti
            GeometryReader { g in
                let durata = max(1, studio.durataMontaggio)
                let larghezza = max(g.size.width - testata, CGFloat(durata) * zoom + 60)
                HStack(spacing: 0) {
                    // intestazioni delle tracce, come in DaVinci
                    VStack(spacing: 0) {
                        Text(VistaMonitor.timecode(studio.tempoSequenza)).font(.system(size: 18, weight: .semibold, design: .monospaced))
                            .frame(height: 38).frame(maxWidth: .infinity)
                        intestazione("V1", "Video 1", colore: Color(red: 0.25, green: 0.45, blue: 0.7), bloccata: $videoBloccato).frame(height: 84)
                        intestazione("A1", "Audio 1", colore: Color(red: 0.25, green: 0.6, blue: 0.4), bloccata: $audioBloccato).frame(height: 56)
                        Spacer()
                    }
                    .frame(width: testata)
                    .background(Color(white: 0.12))
                    .overlay(alignment: .trailing) { Rectangle().fill(Color(white: 0.2)).frame(width: 1) }
                    ScrollView(.horizontal) {
                        ZStack(alignment: .topLeading) {
                            VStack(alignment: .leading, spacing: 0) {
                                righello(durata: durata, larghezza: larghezza)
                                tracciaVideo.frame(height: 84)
                                    // area dove si lasciano le clip trascinate dal Media Pool
                                    .zonaMonitor("timeline.area", clic: { _ in if lama { tagliaAlPuntatore() } })
                                tracciaAudio.frame(height: 56)
                                Spacer(minLength: 0)
                            }
                            // lama: linea gialla dove avverrà il taglio
                            if lama { LineaLama(zoom: zoom, posizioni: posizioniPerId) }
                            // testina: triangolino rosso sul righello e linea
                            VStack(spacing: 0) {
                                Triangolo().fill(Color.red).frame(width: 14, height: 10)
                                Rectangle().fill(Color.red).frame(width: 1.5)
                            }
                            .offset(x: CGFloat(studio.tempoSequenza) * zoom - 7)
                            .allowsHitTesting(false)
                        }
                        .frame(width: larghezza, height: g.size.height, alignment: .topLeading)
                    }
                    .scrollPosition($posizione)
                    .scrollBounceBehavior(.basedOnSize)
                    .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, v in TimelineMonitor.scorrimento = v; x = v }
                    // rotella: scorre la timeline
                    .zonaMonitor("timeline.scorri", clic: { _ in
                        // con la lama: taglia dove c'è il puntatore; con la freccia: sceglie la clip sotto il puntatore
                        if lama { tagliaAlPuntatore() }
                        else if let t = TimelineMonitor.tempoAlPuntatore(zoom: zoom),
                                let i = studio.posizioniClip.firstIndex(where: { t > $0.inizio && t < $0.inizio + $0.durata }) {
                            TimelineMonitor.vaiAllaClip(studio.progetto.clips[i].id)
                        }
                    }, trascina: { d, _ in
                        x = min(max(0, larghezza - (g.size.width - testata)), max(0, x - d.height - d.width))
                        posizione.scrollTo(x: x)
                    })
                }
            }
            .background(Color(white: 0.09))
        }
        .onAppear { Task { await studio.aggiornaDurate() } }
    }

    /// Quanto è scorsa la timeline (punti): serve a sapere a che tempo corrisponde il puntatore.
    static var scorrimento: CGFloat = 0

    /// Il tempo della timeline sotto il puntatore: dalla posizione del puntatore e da quanto è scorsa la timeline
    /// (non dalla grandezza della clip, che con lo zoom alto diventa enorme e sballava il calcolo).
    static func tempoAlPuntatore(zoom: CGFloat) -> Double? {
        guard let p = Studio.condiviso.puntatore, let z = ZoneMonitor.condivise.zone["timeline.scorri"], z.riquadro.contains(p) else { return nil }
        return max(0, Double((p.x - z.riquadro.minX + scorrimento) / zoom))
    }

    private func tagliaAlPuntatore() {
        guard !videoBloccato else { GestoreMonitor.scrivi("trim: track locked"); return }
        guard let t = TimelineMonitor.tempoAlPuntatore(zoom: zoom),
              let i = studio.posizioniClip.firstIndex(where: { t > $0.inizio && t < $0.inizio + $0.durata }) else { return }
        studio.vaiSequenza(t)
        studio.dividi(studio.progetto.clips[i].id, aTempo: t)
    }

    private var posizioniPerId: [UUID: (Double, Double)] {
        var r: [UUID: (Double, Double)] = [:]
        for (c, p) in zip(studio.progetto.clips, studio.posizioniClip) { r[c.id] = (p.inizio, p.durata) }
        return r
    }

    static func delta(_ s: Double) -> String {
        let f = Int((abs(s) * 25).rounded())
        return String(format: "%@%02d:%02d", s < 0 ? "-" : "+", f / 25, f % 25)
    }

    private func tempoBordo(_ id: UUID, inizio: Bool) -> Double {
        guard let (a, d) = posizioniPerId[id] else { return 0 }
        return inizio ? a : a + d
    }

    /// Tira il bordo di una clip: la clip si accorcia o si allunga (come trascinare il bordo in DaVinci).
    private func tiraBordo(_ id: UUID, inizio: Bool, _ dx: CGFloat) {
        guard !videoBloccato else { return }
        if bordo?.0 != id || bordo?.1 != inizio { bordo = (id, inizio); bordoDelta = 0 }
        let s = Double(dx / zoom)
        bordoDelta += s
        studio.rifila(id, inizio: inizio, di: s)
        fineBordo?.cancel()
        fineBordo = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            bordo = nil; bordoDelta = 0
        }
    }

    // MARK: strumenti

    private var strumenti: some View {
        HStack(spacing: 4) {
            StrumentoTimeline(simbolo: "cursorarrow", nome: "Selection (arrow)", acceso: !lama) { lama = false }
            StrumentoTimeline(simbolo: "scissors", nome: "Blade: click a clip to cut it", acceso: lama, rosso: true) { lama = true }
            separatore
            StrumentoTimeline(simbolo: "rectangle.split.2x1", nome: "Split at playhead") { if !videoBloccato { studio.dividiAllaTestina() } }
            StrumentoTimeline(simbolo: "arrow.right.to.line", nome: "Trim start to playhead") { if !videoBloccato { studio.rifilaAllaTestina(inizio: true) } }
            StrumentoTimeline(simbolo: "arrow.left.to.line", nome: "Trim end to playhead") { if !videoBloccato { studio.rifilaAllaTestina(inizio: false) } }
            StrumentoTimeline(simbolo: "plus.square.on.square", nome: "Duplicate clip") {
                if !videoBloccato, let id = studio.clipAttiva { studio.duplicaClip(id); studio.aggiornaSequenza() }
            }
            StrumentoTimeline(simbolo: "trash", nome: "Delete clip") {
                if !videoBloccato, let id = studio.clipAttiva { Task { await studio.eliminaClip(id); studio.aggiornaSequenza(ritardo: 0) } }
            }
            separatore
            StrumentoTimeline(simbolo: "wand.and.stars", nome: "Split by scenes (AI)") { if !videoBloccato { Task { await studio.dividiPerScene() } } }
            separatore
            StrumentoTimeline(simbolo: "music.note.list", nome: "Add music", acceso: studio.poolMusica) { studio.poolMusica.toggle() }
            Spacer()
            StrumentoTimeline(simbolo: "minus.magnifyingglass", nome: "Zoom out") { zoom = max(8, zoom / 1.5) }
            // barretta dello zoom come in DaVinci
            GeometryReader { g in
                let t = (log(zoom) - log(8)) / (log(400) - log(8))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(white: 0.25)).frame(height: 3)
                    Circle().fill(Color(white: 0.8)).frame(width: 11, height: 11).offset(x: t * (g.size.width - 11))
                }
                .frame(maxHeight: .infinity)
                .zonaMonitor("timeline.zoom", clic: { p in zoom = 8 * pow(50, p.x) }, trascina: { _, p in zoom = 8 * pow(50, min(1, max(0, p.x))) })
            }
            .frame(width: 110, height: 30)
            StrumentoTimeline(simbolo: "plus.magnifyingglass", nome: "Zoom in") { zoom = min(400, zoom * 1.5) }
        }
        .padding(.horizontal, 12).frame(height: 40)
        .background(Tema.pannello)
        .overlay(alignment: .bottom) { Rectangle().fill(Color(white: 0.17)).frame(height: 1) }
    }

    private var separatore: some View { Rectangle().fill(Color(white: 0.22)).frame(width: 1, height: 22).padding(.horizontal, 6) }

    private func intestazione(_ sigla: String, _ nome: String, colore: Color, bloccata: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            Text(sigla).font(.system(size: 11, weight: .bold))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color(red: 0.85, green: 0.25, blue: 0.25), lineWidth: 1))
            Text(nome).font(.system(size: 11)).foregroundStyle(Color(white: 0.8))
            Spacer()
            Image(systemName: bloccata.wrappedValue ? "lock.fill" : "lock.open")
                .font(.system(size: 11))
                .foregroundStyle(bloccata.wrappedValue ? Tema.accento : Tema.testo2)
                .frame(width: 24, height: 22)
                .zonaMonitor("blocco." + sigla, clic: { _ in bloccata.wrappedValue.toggle() })
        }
        .padding(.horizontal, 8)
        .overlay(alignment: .leading) { Rectangle().fill(colore).frame(width: 3) }
        .overlay(alignment: .bottom) { Rectangle().fill(Color(white: 0.18)).frame(height: 1) }
    }

    /// Righello col timecode: clic o trascina = sposta la testina.
    private func righello(durata: Double, larghezza: CGFloat) -> some View {
        let passo: Double = zoom > 120 ? 1 : zoom > 40 ? 2 : zoom > 15 ? 5 : 10
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(Color(white: 0.13))
            ForEach(Array(stride(from: 0.0, through: durata, by: passo / 4)), id: \.self) { t in
                let grande = Int((t / passo).rounded()) * 4 == Int((t / (passo / 4)).rounded())
                Rectangle().fill(Color(white: grande ? 0.5 : 0.3)).frame(width: 1, height: grande ? 12 : 6)
                    .offset(x: CGFloat(t) * zoom, y: 38 - (grande ? 12 : 6))
            }
            ForEach(Array(stride(from: 0.0, through: durata, by: passo)), id: \.self) { t in
                Text(VistaMonitor.timecode(t)).font(.system(size: 9, design: .monospaced)).foregroundStyle(Tema.testo2)
                    .offset(x: CGFloat(t) * zoom + 3, y: 4)
            }
        }
        .frame(width: larghezza, height: 38)
        .zonaMonitor("timeline.righello", clic: { p in studio.vaiSequenza(Double(p.x * larghezza / zoom)) },
                     trascina: { _, p in studio.vaiSequenza(Double(p.x * larghezza / zoom)) })
    }

    // MARK: tracce

    private var tracciaVideo: some View {
        let clips = studio.progetto.clips, pos = studio.posizioniClip
        return ZStack(alignment: .topLeading) {
            Color.clear
            // spazi vuoti (grigi, come in DaVinci): tasto destro › Elimina spazio
            ForEach(Array(clips.enumerated()), id: \.element.id) { i, c in
                let v = c.taglio.vuotoPrima
                if i < pos.count, v > 0.01 {
                    Rectangle().fill(Color(white: 0.22))
                        .overlay(Rectangle().stroke(Color(white: 0.32), lineWidth: 1))
                        .frame(width: max(2, CGFloat(v) * zoom), height: 74)
                        .zonaMonitor("vuoto." + c.id.uuidString,
                                     clic: { _ in MenuMonitor.condiviso.apri([
                                        VoceMenuMonitor(titolo: "Delete gap (following clips move back)", icona: "arrow.left.to.line") { studio.chiudiSpazio(prima: c.id) },
                                     ]) },
                                     destro: { MenuMonitor.condiviso.apri([
                                        VoceMenuMonitor(titolo: "Delete gap (following clips move back)", icona: "arrow.left.to.line") { studio.chiudiSpazio(prima: c.id) },
                                        VoceMenuMonitor(titolo: "Delete all gaps", icona: "arrow.left.and.line.vertical.and.arrow.right") { studio.chiudiTuttiGliSpazi() },
                                     ]) })
                        .offset(x: CGFloat(pos[i].inizio - v) * zoom, y: 5)
                }
            }
            ForEach(Array(clips.enumerated()), id: \.element.id) { i, c in
                if i < pos.count {
                    let attiva = c.id == studio.clipAttiva
                    let w = max(8, CGFloat(pos[i].durata) * zoom - 2)
                    VStack(spacing: 0) {
                        // striscia di fotogrammi
                        HStack(spacing: 1) {
                            if let img = Archivio.immagine("Miniature", c.miniatura) {
                                ForEach(0..<min(160, max(1, Int(w / 64) + 1)), id: \.self) { _ in
                                    Image(uiImage: img).resizable().scaledToFill().frame(width: 63, height: 52).clipped()
                                }
                            } else {
                                Rectangle().fill(Color(white: 0.2))
                            }
                        }
                        .frame(width: w, height: 52, alignment: .leading).clipped()
                        // barra col nome, come in DaVinci
                        HStack(spacing: 4) {
                            Image(systemName: "link").font(.system(size: 8))
                            Text(c.nome).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 5).frame(width: w, height: 22)
                        .background(Color(red: 0.24, green: 0.42, blue: 0.62))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(attiva ? Color(red: 1, green: 0.3, blue: 0.25) : Color(white: 0.3), lineWidth: attiva ? 2 : 1))
                    // bordi: tienili premuti e trascina per accorciare/allungare (verdi mentre li tiri)
                    .overlay(alignment: .leading) { maniglia(c.id, inizio: true, w: w) }
                    .overlay(alignment: .trailing) { maniglia(c.id, inizio: false, w: w) }
                    // freccia: clic = scegli, tieni premuto e trascina = sposta; lama: clic = taglia lì; destro = menu
                    .zonaMonitor("v1." + c.id.uuidString,
                                 clic: { p in
                                     if lama {
                                         tagliaAlPuntatore()
                                     } else { TimelineMonitor.vaiAllaClip(c.id) }
                                 },
                                 trascina: lama ? nil : { d, _ in if !videoBloccato { trascina(c.id, d.width, larghezzaClip: w) } },
                                 destro: { TimelineMonitor.menuClip(c.id) })
                    // lo spostamento va dopo la zona: così la zona cliccabile sta dove si vede la clip
                    .offset(x: CGFloat(pos[i].inizio) * zoom + (trascinata == c.id ? spostamento : 0), y: 5)
                    .zIndex(trascinata == c.id ? 1 : 0)
                }
            }
        }
    }

    @ViewBuilder
    private func maniglia(_ id: UUID, inizio: Bool, w: CGFloat) -> some View {
        if !videoBloccato {
            let attivo = bordo?.0 == id && bordo?.1 == inizio
            ManigliaTrim(id: "bordo.\(inizio ? "in" : "out")." + id.uuidString, inizio: inizio, trascinando: attivo,
                         etichetta: attivo ? (TimelineMonitor.delta(bordoDelta), VistaMonitor.timecode(tempoBordo(id, inizio: inizio))) : nil) { dx in
                tiraBordo(id, inizio: inizio, dx)
            }
            .frame(width: min(12, w / 3))
        }
    }

    private var tracciaAudio: some View {
        var inizio = 0.0
        let blocchi: [(Musica, Double, Double)] = studio.progetto.musiche.map { m in
            let d = m.durata(file: studio.durateFile[m.file] ?? 0)
            defer { inizio += d }
            return (m, inizio, d)
        }
        return ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(blocchi, id: \.0.id) { m, i, d in
                let w = max(8, CGFloat(d) * zoom - 2)
                VStack(spacing: 0) {
                    FormaOnda(file: m.file, inizio: m.inizio, durata: d)
                        .frame(width: w, height: 28)
                    HStack(spacing: 4) {
                        Image(systemName: "music.note").font(.system(size: 8))
                        Text(m.nome).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 5).frame(width: w, height: 18)
                    .background(Color(red: 0.2, green: 0.5, blue: 0.32))
                }
                .background(Color(red: 0.16, green: 0.36, blue: 0.24))
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color(white: 0.3), lineWidth: 1))
                .zonaMonitor("a1." + m.id.uuidString, destro: {
                    MenuMonitor.condiviso.apri([
                        VoceMenuMonitor(titolo: "Add more music", icona: "music.note.list") { studio.poolMusica = true },
                        VoceMenuMonitor(titolo: "Remove this music", icona: "trash", distruttiva: true) { if !audioBloccato { studio.togliMusica(m.id) } },
                    ])
                })
                .offset(x: CGFloat(i) * zoom, y: 5)
            }
        }
    }

    private func trascina(_ id: UUID, _ dx: CGFloat, larghezzaClip: CGFloat) {
        if trascinata != id { trascinata = id; spostamento = 0 }
        spostamento += dx
        let passo = max(40, larghezzaClip)
        if abs(spostamento) > passo / 2 {
            let d = spostamento > 0 ? 1 : -1
            studio.spostaClip(id, di: d)
            spostamento -= CGFloat(d) * passo
        }
        fine?.cancel()
        fine = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.15)) { trascinata = nil; spostamento = 0 }
            studio.aggiornaSequenza()
        }
    }
}

/// Un tasto a icona della barra della timeline: grigio, acceso se attivo; il nome compare passandoci sopra.
private struct StrumentoTimeline: View {
    let simbolo: String
    let nome: String
    var acceso = false
    var rosso = false
    let azione: () -> Void
    @ObservedObject private var sotto = ZonaSottoMonitor.condivisa

    var body: some View {
        let id = "strumento." + nome
        Image(systemName: simbolo)
            .font(.system(size: 15, weight: .regular))
            .foregroundStyle(acceso ? (rosso ? Color(red: 1, green: 0.32, blue: 0.28) : Tema.accento) : Color(white: sotto.id == id ? 0.95 : 0.65))
            .frame(width: 36, height: 30)
            .background(RoundedRectangle(cornerRadius: 5).fill(acceso ? Color(white: 0.2) : .clear))
            .overlay(alignment: .bottom) {
                if sotto.id == id {
                    Text(nome).font(.system(size: 11, weight: .semibold)).fixedSize()
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.2)))
                        .offset(y: 28)
                        .allowsHitTesting(false)
                }
            }
            .zIndex(sotto.id == id ? 1 : 0)
            .zonaMonitor(id, clic: { _ in azione() })
    }
}

private struct Triangolo: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// Forma d'onda della musica (letta una volta dal file e ricordata), come le tracce audio verdi di DaVinci.
private struct FormaOnda: View {
    let file: String
    let inizio: Double
    let durata: Double
    @State private var picchi: [Float] = []

    var body: some View {
        Canvas { ctx, size in
            guard !picchi.isEmpty else { return }
            let mezzo = size.height / 2
            var p = Path()
            let n = Int(size.width)
            for x in 0..<max(1, n) {
                let t = Double(x) / Double(max(1, n))
                let k = min(picchi.count - 1, Int(t * Double(picchi.count)))
                let a = CGFloat(picchi[k]) * mezzo * 0.95
                p.move(to: CGPoint(x: CGFloat(x), y: mezzo - a)); p.addLine(to: CGPoint(x: CGFloat(x), y: mezzo + a))
            }
            ctx.stroke(p, with: .color(Color(red: 0.75, green: 0.95, blue: 0.8).opacity(0.85)), lineWidth: 1)
        }
        .task(id: file + "\(inizio)\(durata)") { picchi = await FormaOnda.leggi(file, inizio: inizio, durata: durata) }
    }

    @MainActor private static var cache: [String: [Float]] = [:]

    /// 600 picchi del tratto usato del file (0…1).
    static func leggi(_ file: String, inizio: Double, durata: Double) async -> [Float] {
        let chiave = file + "|\(inizio)|\(durata)"
        if let c = cache[chiave] { return c }
        let url = Archivio.url("Media", file)
        let r: [Float] = await Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)
            guard let traccia = try? await asset.loadTracks(withMediaType: .audio).first,
                  let lettore = try? AVAssetReader(asset: asset) else { return [] }
            lettore.timeRange = CMTimeRange(start: CMTime(seconds: inizio, preferredTimescale: 600), duration: CMTime(seconds: max(0.1, durata), preferredTimescale: 600))
            let uscita = AVAssetReaderTrackOutput(track: traccia, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false, AVNumberOfChannelsKey: 1, AVSampleRateKey: 8000])
            lettore.add(uscita)
            guard lettore.startReading() else { return [] }
            var campioni: [Int16] = []
            while let b = uscita.copyNextSampleBuffer(), let blocco = CMSampleBufferGetDataBuffer(b) {
                let n = CMBlockBufferGetDataLength(blocco)
                var dati = [Int16](repeating: 0, count: n / 2)
                CMBlockBufferCopyDataBytes(blocco, atOffset: 0, dataLength: n, destination: &dati)
                campioni.append(contentsOf: dati)
            }
            guard !campioni.isEmpty else { return [] }
            let gruppi = 600, passo = max(1, campioni.count / gruppi)
            var p: [Float] = []
            var i = 0
            while i < campioni.count {
                let fine = min(campioni.count, i + passo)
                var m: Int32 = 0
                for k in i..<fine { m = max(m, abs(Int32(campioni[k]))) }
                p.append(Float(m) / 32768)
                i = fine
            }
            let massimo = max(0.05, p.max() ?? 1)
            return p.map { $0 / massimo }
        }.value
        cache[chiave] = r
        return r
    }
}

/// Un'icona della fila delle palette: grigia, arancione se aperta; passandoci sopra col puntatore compare il nome.
private struct IconaPalette: View {
    let palette: Palette
    let attiva: Bool
    @ObservedObject private var sotto = ZonaSottoMonitor.condivisa

    var body: some View {
        let id = "palette." + palette.rawValue
        Image(systemName: palette.icona)
            .font(.system(size: 17, weight: .light))
            .foregroundStyle(attiva ? Tema.accento : Color(white: sotto.id == id ? 0.95 : 0.62))
            .frame(maxWidth: .infinity).frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 5).fill(attiva ? Tema.accento.opacity(0.14) : .clear))
            .overlay(alignment: .bottom) { if attiva { Rectangle().fill(Tema.accento).frame(height: 2) } }
            .overlay(alignment: .top) {
                if sotto.id == id {
                    Text(palette.rawValue).font(.system(size: 11, weight: .semibold)).fixedSize()
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.2)))
                        .offset(y: -26)
                        .allowsHitTesting(false)
                }
            }
            .zIndex(sotto.id == id ? 1 : 0)
            .zonaMonitor(id, clic: { _ in Studio.condiviso.richiestaPalette = palette })
    }
}

// MARK: - Lama, trascinamento dal Media Pool, importazione nella pagina Edit

/// Linea gialla verticale dove la lama taglierà, sotto il puntatore, col timecode.
private struct LineaLama: View {
    let zoom: CGFloat
    let posizioni: [UUID: (Double, Double)]
    @ObservedObject private var punto = PuntoMonitor.condiviso

    var body: some View {
        let _ = punto.punto
        if let t = TimelineMonitor.tempoAlPuntatore(zoom: zoom), posizioni.values.contains(where: { t > $0.0 && t < $0.0 + $0.1 }) {
            VStack(spacing: 2) {
                Text(VistaMonitor.timecode(t)).font(.system(size: 10, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.85)))
                    .foregroundStyle(Color.yellow)
                    .fixedSize()
                Rectangle().fill(Color.yellow).frame(width: 2)
            }
            .frame(width: 80)
            .offset(x: CGFloat(t) * zoom - 40, y: 14)
            .allowsHitTesting(false)
        }
    }
}

/// Cosa si sta trascinando dal Media Pool o dalla libreria verso la timeline.
@MainActor
final class TrascinoMedia: ObservableObject {
    static let condiviso = TrascinoMedia()
    enum Cosa: Equatable { case clip(UUID), libreria(String), pool(UUID) }
    @Published private(set) var cosa: Cosa?
    @Published private(set) var miniatura: UIImage?
    private var fine: Task<Void, Never>?
    /// Quando si lascia un elemento della libreria: lo importa (lo fa chi l'ha trascinato).
    var lasciaLibreria: ((Int) -> Void)?

    func muovi(_ c: Cosa, miniatura m: UIImage?) {
        if cosa != c { cosa = c; miniatura = m }
        fine?.cancel()
        fine = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            lascia()
        }
    }

    /// Lasciato il tasto: se il puntatore è sulla timeline, la clip va in quel punto.
    private func lascia() {
        defer { cosa = nil; miniatura = nil; lasciaLibreria = nil }
        let s = Studio.condiviso
        guard let c = cosa, let p = s.puntatore, let area = ZoneMonitor.condivise.zone["timeline.area"], area.riquadro.contains(p) else { return }
        // punto della timeline → posto nel montaggio (prima della clip il cui centro è dopo il puntatore)
        let zone = ZoneMonitor.condivise.zone
        var posto = s.progetto.clips.count
        for (i, clip) in s.progetto.clips.enumerated() {
            if let z = zone["v1." + clip.id.uuidString] ?? zone["clip." + clip.id.uuidString], p.x < z.riquadro.midX { posto = i; break }
        }
        switch c {
        case .clip(let id):
            let attuale = s.progetto.clips.firstIndex { $0.id == id } ?? 0
            s.spostaClip(id, a: posto > attuale ? posto - 1 : posto)
        case .libreria:
            lasciaLibreria?(posto)
        case .pool(let id):
            Task { await s.usaDalPool(id, posto: posto) }
        }
    }
}

/// La miniatura che segue il puntatore mentre si trascina verso la timeline.
private struct FantasmaTrascino: View {
    @ObservedObject private var t = TrascinoMedia.condiviso
    @ObservedObject private var p = PuntoMonitor.condiviso

    var body: some View {
        if t.cosa != nil, let q = p.punto {
            Group {
                if let m = t.miniatura { Image(uiImage: m).resizable().scaledToFill() } else { Rectangle().fill(Tema.campo) }
            }
            .frame(width: 110, height: 62).clipped()
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Tema.accento, lineWidth: 2))
            .opacity(0.85)
            .offset(x: q.x + 10, y: q.y + 10)
            .allowsHitTesting(false)
        }
    }
}

/// Scheda "Importa" del Media Pool nella pagina Edit: la libreria Foto; clic = in fondo al montaggio,
/// tieni premuto e trascina sulla timeline = in quel punto.
private struct ImportaEditMonitor: View {
    @ObservedObject var studio: Studio
    @StateObject private var libreria = LibreriaMonitor()
    @State private var daFile = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                interruttoreSorgente("Photo Library", "photo.on.rectangle", !daFile) { daFile = false }
                interruttoreSorgente("Files and drives", "externaldrive", daFile) { daFile = true }
                Spacer()
            }
            .padding(.horizontal, 8).padding(.top, 6)
            if daFile {
                Text("Click a video or photo = into the Media Pool").font(.system(size: 10)).foregroundStyle(Tema.testo2)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.top, 4)
                EsploraFileMonitor(studio: studio, tipi: [.video, .foto]) { c, u, tipo in
                    guard let base = CartelleCollegate.condivise.apri(c) else { return }
                    Task {
                        defer { base.stopAccessingSecurityScopedResource() }
                        studio.messaggio = nil
                        if tipo == .video, let p = await FormatoFile.problema(u, video: true) { studio.messaggio = p; return }
                        await studio.importaNelPool(u, video: tipo == .video, nome: u.deletingPathExtension().lastPathComponent)
                    }
                }
            } else {
                libreriaFoto
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func interruttoreSorgente(_ t: String, _ s: String, _ attivo: Bool, _ azione: @escaping () -> Void) -> some View {
        Label(t, systemImage: s).font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 9).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 5).fill(attivo ? Tema.accento.opacity(0.2) : Tema.campo))
            .foregroundStyle(attivo ? Tema.accento : Color(white: 0.8))
            .zonaMonitor("sorgente." + t, clic: { _ in azione() })
    }

    private var libreriaFoto: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(LibreriaMonitor.Filtro.allCases, id: \.self) { f in
                    Text(f.rawValue).font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 9).frame(height: 22)
                        .background(Capsule().fill(libreria.filtro == f ? Tema.accento.opacity(0.2) : Tema.campo))
                        .foregroundStyle(libreria.filtro == f ? Tema.accento : Color(white: 0.8))
                        .zonaMonitor("edit.filtro." + f.rawValue, clic: { _ in libreria.filtro = f })
                }
                Spacer()
                if libreria.importando { Text("Importing…").font(.system(size: 11)).foregroundStyle(Tema.accento) }
            }
            .padding(.horizontal, 8).frame(height: 32)
            Text("Click = bring into the Media Pool (then drag it from there onto the timeline)")
                .font(.system(size: 10)).foregroundStyle(Tema.testo2).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10)
            switch libreria.stato {
            case .negato:
                Text("Allow access to photos in Settings › Colors › Photos.").font(.system(size: 12)).foregroundStyle(Tema.testo2).padding(10)
            case .attesa:
                Text("Answer on the phone: Colors is asking to see the Photo library.").font(.system(size: 12)).foregroundStyle(Tema.testo2).padding(10)
            case .pronta:
                GeometryReader { g in
                    let colonne = max(2, Int(g.size.width / 120))
                    let lato = (g.size.width - CGFloat(colonne + 1) * 8) / CGFloat(colonne)
                    let righe = max(1, Int((g.size.height - 8) / (lato + 8)))
                    let pagina = colonne * righe
                    let inizio = min(libreria.inizio, max(0, libreria.elementi.count - pagina))
                    let visibili = Array(libreria.elementi.dropFirst(inizio).prefix(pagina))
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(0..<righe, id: \.self) { r in
                            HStack(spacing: 8) {
                                ForEach(0..<colonne, id: \.self) { c in
                                    let i = r * colonne + c
                                    if i < visibili.count {
                                        let e = visibili[i]
                                        Miniatura(elemento: e, libreria: libreria, lato: lato)
                                            .zonaMonitor("edit.lib." + e.id, clic: { _ in libreria.importaNelPool(e, in: studio) })
                                    }
                                }
                            }
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .zonaMonitor("media.griglia", trascina: { d, _ in libreria.scorri(d.height + d.width, pagina: colonne) })
                }
            }
        }
        .onAppear { libreria.carica() }
    }
}

/// Scheda Progetti: quelli salvati, nuovo progetto, apri.
private struct ProgettiMonitor: View {
    @ObservedObject var studio: Studio
    @State private var elenco: [Progetto] = []

    /// Tasto destro su un progetto salvato: apri, rinomina, elimina (con conferma).
    private func menu(_ p: Progetto) {
        MenuMonitor.condiviso.apri([
            VoceMenuMonitor(titolo: "Open", icona: "folder") { Task { await studio.apriProgetto(p.id); elenco = Archivio.elencoArchiviati() } },
            VoceMenuMonitor(titolo: "Rename", icona: "pencil") {
                studio.testoMonitor = TestoMonitor(titolo: "Rename project", testo: p.nome) { studio.rinominaProgetto(p.id, $0); elenco = Archivio.elencoArchiviati() }
            },
            VoceMenuMonitor(titolo: "Delete…", icona: "trash", distruttiva: true) {
                // secondo menu per confermare: eliminare non si può annullare
                MenuMonitor.condiviso.apri([
                    VoceMenuMonitor(titolo: "Yes, delete «\(p.nome)» forever", icona: "trash.fill", distruttiva: true) {
                        studio.eliminaProgetto(p.id); elenco = Archivio.elencoArchiviati()
                    },
                    VoceMenuMonitor(titolo: "No, keep it", icona: "xmark") {},
                ])
            },
        ])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("New project", systemImage: "doc.badge.plus").font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 10).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 6).fill(Tema.accento.opacity(0.2)))
                .foregroundStyle(Tema.accento)
                .zonaMonitor("progetti.nuovo", clic: { _ in
                    Task { await studio.nuovoProgetto(nome: "Project \(Archivio.elencoArchiviati().count + 2)"); elenco = Archivio.elencoArchiviati() }
                })
            Text("Open: \(studio.progetto.nome) · \(studio.progetto.clips.count) clips").font(.system(size: 11)).foregroundStyle(Tema.testo2)
                .zonaMonitor("progetto.aperto", destro: {
                    MenuMonitor.condiviso.apri([
                        VoceMenuMonitor(titolo: "Rename", icona: "pencil") {
                            studio.testoMonitor = TestoMonitor(titolo: "Rename project", testo: studio.progetto.nome) { studio.rinominaProgetto(studio.progetto.id, $0) }
                        },
                    ])
                })
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(elenco, id: \.id) { p in
                        HStack(spacing: 8) {
                            Image(systemName: "film.stack").foregroundStyle(Tema.accento)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.nome).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                Text("\(p.clips.count) clips · \(p.modificato.formatted(date: .abbreviated, time: .shortened))").font(.system(size: 10)).foregroundStyle(Tema.testo2)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 8).frame(height: 38)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color(white: 0.13)))
                        .zonaMonitor("progetto." + p.id.uuidString, clic: { _ in
                            Task { await studio.apriProgetto(p.id); elenco = Archivio.elencoArchiviati() }
                        }, destro: { menu(p) })
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { elenco = Archivio.elencoArchiviati() }
        .onChange(of: studio.progettiSalvati.count) { _, _ in elenco = Archivio.elencoArchiviati() }
        .onChange(of: studio.progettiSalvati.map(\.nome)) { _, _ in elenco = Archivio.elencoArchiviati() }
    }
}

/// Musica sceglibile dal monitor: brani dell'app Musica (quelli scaricati, senza protezione) e file audio
/// nella cartella di Colors (app File › Sul mio iPhone › Colors).
private struct BraniMonitor: View {
    @ObservedObject var studio: Studio
    @State private var brani: [(nome: String, url: URL, cartella: Bool)] = []
    @State private var stato = "Looking for music…"
    @State private var importo = false
    @State private var scorri = ScrollPosition(edge: .top)
    @State private var y: CGFloat = 0
    @State private var massimo: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Your music · click to add it").font(.system(size: 11, weight: .semibold)).foregroundStyle(Tema.testo2).padding(.horizontal, 10)
            if brani.isEmpty {
                Text(stato).font(.system(size: 11)).foregroundStyle(Tema.testo2).padding(.horizontal, 10)
            }
            ScrollView {
                VStack(spacing: 4) {
            ForEach(Array(brani.prefix(40).enumerated()), id: \.offset) { i, b in
                HStack(spacing: 8) {
                    Image(systemName: b.cartella ? "doc.richtext" : "music.quarternote.3").foregroundStyle(Tema.accento)
                    Text(b.nome).font(.system(size: 12)).lineLimit(1)
                    Spacer()
                    Image(systemName: "plus.circle").foregroundStyle(Color(white: 0.7))
                }
                .padding(.horizontal, 10).frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color(white: 0.13)))
                .padding(.horizontal, 8)
                .zonaMonitor("brano.\(i)." + b.nome, clic: { _ in aggiungi(b) })
            }
                }
            }
            .frame(maxHeight: 190)
            .scrollBounceBehavior(.basedOnSize)
            .scrollPosition($scorri)
            .onScrollGeometryChange(for: CGFloat.self) { max(0, $0.contentSize.height - $0.containerSize.height) } action: { _, m in massimo = m }
            .zonaMonitor("brani.scorri", trascina: { d, _ in y = min(massimo, max(0, y - d.height)); scorri.scrollTo(y: y) })
            if importo { Text("Adding…").font(.system(size: 11)).foregroundStyle(Tema.accento).padding(.horizontal, 10) }
        }
        .task { await cerca() }
    }

    private func cerca() async {
        var r: [(String, URL, Bool)] = []
        // file audio nella cartella Documents di Colors
        let doc = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let audio: Set<String> = ["mp3", "m4a", "wav", "aif", "aiff", "aac", "caf", "flac"]
        // anche nelle sottocartelle (non quelle interne dell'app)
        if let giro = FileManager.default.enumerator(at: doc, includingPropertiesForKeys: nil) {
            while let u = giro.nextObject() as? URL {
                if ["Colorista", "ProvaTracker"].contains(u.lastPathComponent) { giro.skipDescendants(); continue }
                if audio.contains(u.pathExtension.lowercased()) { r.append((u.deletingPathExtension().lastPathComponent, u, true)) }
            }
        }
        // brani dell'app Musica
        let ok: Bool = await withCheckedContinuation { c in
            MPMediaLibrary.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        if ok, let elementi = MPMediaQuery.songs().items {
            for e in elementi { if let u = e.assetURL, !e.hasProtectedAsset { r.append((e.title ?? "Track", u, false)) } }
        }
        brani = r.map { (nome: $0.0, url: $0.1, cartella: $0.2) }
        stato = r.isEmpty ? (ok ? "No songs downloaded in the Music app and no audio files in the Colors folder (Files app)." : "To see your songs allow access to Music in Settings › Colors.") : ""
    }

    private func aggiungi(_ b: (nome: String, url: URL, cartella: Bool)) {
        guard !importo else { return }
        importo = true
        Task { @MainActor in
            defer { importo = false }
            if b.cartella { await studio.aggiungiMusica(b.url); await studio.aggiornaDurate(); return }
            // i brani dell'app Musica si copiano in un file .m4a
            let uscita = FileManager.default.temporaryDirectory.appendingPathComponent(b.nome.replacingOccurrences(of: "/", with: "-") + ".m4a")
            try? FileManager.default.removeItem(at: uscita)
            guard let e = AVAssetExportSession(asset: AVURLAsset(url: b.url), presetName: AVAssetExportPresetAppleM4A) else {
                studio.messaggio = "Can't read this song."; return
            }
            do {
                try await e.export(to: uscita, as: .m4a)
                await studio.aggiungiMusica(uscita)
                await studio.aggiornaDurate()
                try? FileManager.default.removeItem(at: uscita)
            } catch {
                studio.messaggio = "Can't copy this song: \(error.localizedDescription)"
            }
        }
    }
}

/// Bordo di una clip nella timeline: passandoci sopra diventa una parentesi gialla (come il trim di DaVinci),
/// mentre lo trascini è verde con l'etichetta di quanto togli/aggiungi e del timecode.
private struct ManigliaTrim: View {
    let id: String
    let inizio: Bool
    let trascinando: Bool
    let etichetta: (String, String)?
    let trascina: (CGFloat) -> Void
    @ObservedObject private var sotto = ZonaSottoMonitor.condivisa

    var body: some View {
        let acceso = sotto.id == id || trascinando
        let colore = trascinando ? Color(red: 0.3, green: 0.9, blue: 0.4) : Color.yellow
        ZStack(alignment: inizio ? .leading : .trailing) {
            Color.white.opacity(0.001)
            if acceso {
                // parentesi quadra come il cursore di trim di DaVinci
                Path { p in
                    let x: CGFloat = inizio ? 1.5 : 10.5, b: CGFloat = inizio ? 7 : -7
                    p.move(to: CGPoint(x: x + b, y: 1.5)); p.addLine(to: CGPoint(x: x, y: 1.5))
                    p.addLine(to: CGPoint(x: x, y: 72.5)); p.addLine(to: CGPoint(x: x + b, y: 72.5))
                }
                .stroke(colore, lineWidth: 3)
                .frame(width: 12, height: 74)
            } else {
                Rectangle().fill(Color.white.opacity(0.3)).frame(width: 1.5)
            }
        }
        .frame(maxHeight: .infinity)
        .overlay(alignment: .top) {
            if let (d, tc) = etichetta {
                VStack(spacing: 1) {
                    Text(d).font(.system(size: 11, weight: .semibold, design: .monospaced))
                    Text(tc).font(.system(size: 10, design: .monospaced)).foregroundStyle(Color(white: 0.7))
                }
                .fixedSize()
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.9)))
                .offset(y: -38)
            }
        }
        .contentShape(Rectangle())
        .zonaMonitor(id, trascina: { d, _ in trascina(d.width) })
    }
}

// MARK: - Bentornato sul monitor

/// All'avvio col monitor collegato: continuare il progetto o iniziarne uno nuovo (salvando o no quello di prima).
private struct BenvenutoMonitor: View {
    @ObservedObject var studio: Studio
    @State private var chiediSalvataggio = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
            VStack(alignment: .leading, spacing: 14) {
                if !chiediSalvataggio {
                    Text("Welcome back").font(.system(size: 22, weight: .bold))
                    Text("Do you want to continue where you left off (\(studio.progetto.clips.count) clips) or start a new project?")
                        .font(.system(size: 14)).foregroundStyle(Color(white: 0.8))
                    HStack(spacing: 10) {
                        tasto("Continue «\(studio.progetto.nome)»", primario: true, id: "continua") { studio.benvenutoMonitor = false }
                        tasto("New project", primario: false, id: "nuovo") { chiediSalvataggio = true }
                    }
                } else {
                    Text("Save «\(studio.progetto.nome)»?").font(.system(size: 22, weight: .bold))
                    Text("Yes: it stays in Projects and you can reopen it whenever you want.\nNo: it is deleted along with the clips copied into the app (the photos and videos in the Library are not touched).")
                        .font(.system(size: 13)).foregroundStyle(Color(white: 0.8))
                    HStack(spacing: 10) {
                        tasto("Yes, save", primario: true, id: "si") {
                            studio.benvenutoMonitor = false
                            Task { await studio.nuovoProgetto(nome: "Project \(Archivio.elencoArchiviati().count + 2)"); studio.richiestaPagina = .media }
                        }
                        tasto("No", primario: false, rosso: true, id: "no") {
                            studio.benvenutoMonitor = false
                            Task { await studio.nuovoProgetto(nome: "", salvaPrecedente: false); studio.richiestaPagina = .media }
                        }
                        tasto("Cancel", primario: false, id: "annulla") { chiediSalvataggio = false }
                    }
                }
            }
            .padding(26)
            .frame(width: 560, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(white: 0.14)))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color(white: 0.3), lineWidth: 1))
            .shadow(color: .black.opacity(0.6), radius: 24, y: 8)
        }
        .ignoresSafeArea()
    }

    private func tasto(_ t: String, primario: Bool, rosso: Bool = false, id: String, _ azione: @escaping () -> Void) -> some View {
        Text(t).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            .padding(.horizontal, 16).frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 9).fill(primario ? Tema.accento : Color(white: 0.24)))
            .foregroundStyle(primario ? Color.black : (rosso ? Color(red: 1, green: 0.42, blue: 0.4) : Color(white: 0.9)))
            .zonaMonitor("menu.benvenuto." + id, clic: { _ in azione() })
    }
}

// MARK: - Scrivere un testo dal monitor

/// Finestra sul monitor per scrivere un nome: le lettere arrivano dalla tastiera del telefono (o da una tastiera collegata).
private struct DialogoTestoMonitor: View {
    @ObservedObject var studio: Studio

    var body: some View {
        if let t = studio.testoMonitor {
            ZStack {
                Color.black.opacity(0.55)
                VStack(alignment: .leading, spacing: 14) {
                    Text(t.titolo).font(.system(size: 20, weight: .bold))
                    HStack(spacing: 0) {
                        Text(t.testo).font(.system(size: 16))
                        // cursore che lampeggia
                        TimelineView(.periodic(from: .now, by: 0.5)) { c in
                            Rectangle().fill(Tema.accento).frame(width: 2, height: 20)
                                .opacity(Int(c.date.timeIntervalSince1970 * 2) % 2 == 0 ? 1 : 0)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 12).frame(height: 40)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.07)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Tema.accento, lineWidth: 1.5))
                    Text("Type with the phone's keyboard (or a connected keyboard) · Return = OK")
                        .font(.system(size: 12)).foregroundStyle(Tema.testo2)
                    HStack(spacing: 10) {
                        Spacer()
                        tasto("Cancel", primario: false) { studio.testoMonitor = nil }
                        tasto("OK", primario: true) { DialogoTestoMonitor.conferma(studio) }
                    }
                }
                .padding(24)
                .frame(width: 560, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color(white: 0.14)))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color(white: 0.3), lineWidth: 1))
                .shadow(color: .black.opacity(0.6), radius: 24, y: 8)
            }
            .ignoresSafeArea()
        }
    }

    static func conferma(_ studio: Studio) {
        guard let t = studio.testoMonitor else { return }
        studio.testoMonitor = nil
        t.conferma(t.testo)
    }

    private func tasto(_ t: String, primario: Bool, _ azione: @escaping () -> Void) -> some View {
        Text(t).font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, 18).frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 9).fill(primario ? Tema.accento : Color(white: 0.24)))
            .foregroundStyle(primario ? Color.black : Color(white: 0.9))
            .zonaMonitor("menu.testo." + t, clic: { _ in azione() })
    }
}

extension Studio {
    /// Per il trackpad: conferma il testo scritto.
    func confermaTestoMonitor() { DialogoTestoMonitor.conferma(self) }
}

/// Sul monitor: mouse collegato ma AssistiveTouch spento.
private struct AvvisoAssistiveTouchMonitor: View {
    @ObservedObject private var mouse = MouseMonitor.condiviso
    var body: some View {
        if mouse.mostraAvvisoAssistiveTouch, !CommandLine.arguments.contains("-anteprimaMonitor") {
            VStack(alignment: .leading, spacing: 4) {
                Label("Mouse connected: turn on AssistiveTouch", systemImage: "hand.point.up.left.fill").font(.system(size: 14, weight: .bold))
                Text("Press the phone's side button 3 times (or Settings › Accessibility › Touch › AssistiveTouch).")
                    .font(.system(size: 12))
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Tema.accento))
            .foregroundStyle(.black)
            .padding(.trailing, 20).padding(.bottom, 60)
            .allowsHitTesting(false)
        }
    }
}

// MARK: - Finestre sul video del monitor

/// Le finestre del nodo disegnate sul video, con le maniglie da usare col mouse:
/// centro = trascina per spostare (o clic sul video per portarla lì), bordo del cerchio = grandezza,
/// maniglia della linea = rotazione. Clic su un'altra finestra = la sceglie.
private struct FinestreSulMonitor: View {
    @ObservedObject var studio: Studio

    var body: some View {
        if studio.paletteMonitor == .finestre, studio.nodo.tipo == .correzione, !studio.inEdit, let img = studio.risultato {
            GeometryReader { g in
                let r = FinestreSulMonitor.rettangolo(img.size, g.size)
                let lato = max(r.width, r.height)
                let tutte = studio.finestreVisibili
                ZStack(alignment: .topLeading) {
                    // tutto il video: trascina = sposta la finestra scelta dove va il puntatore; clic = sceglie la più vicina
                    Color.clear
                        .frame(width: r.width, height: r.height)
                        .zonaMonitor("finestre.video",
                                     clic: { p in scegliVicina(SIMD2(Float(p.x), Float(p.y)), tutte) },
                                     trascina: { _, p in
                                         guard studio.finestraCorrente.tipo != .nessuna, !studio.tracciando else { return }
                                         studio.spostaFinestra(SIMD2(Float(min(1, max(0, p.x))), Float(min(1, max(0, p.y)))))
                                     })
                        .offset(x: r.minX, y: r.minY)
                    ForEach(Array(tutte.enumerated()), id: \.offset) { i, f in
                        if f.tipo != .nessuna { disegno(f, r, lato, scelta: i == studio.finestraScelta) }
                    }
                    if let f = tutte.indices.contains(studio.finestraScelta) ? tutte[studio.finestraScelta] : nil, f.tipo != .nessuna {
                        maniglie(f, r, lato)
                    }
                }
            }
        }
    }

    static func rettangolo(_ img: CGSize, _ box: CGSize) -> CGRect {
        let k = min(box.width / max(1, img.width), box.height / max(1, img.height))
        let w = img.width * k, h = img.height * k
        return CGRect(x: (box.width - w) / 2, y: (box.height - h) / 2, width: w, height: h)
    }

    private func punto(_ c: SIMD2<Float>, _ r: CGRect) -> CGPoint {
        CGPoint(x: r.minX + CGFloat(c.x) * r.width, y: r.minY + CGFloat(c.y) * r.height)
    }

    private func scegliVicina(_ p: SIMD2<Float>, _ tutte: [Finestra]) {
        var best: (Int, Float)?
        for (i, f) in tutte.enumerated() where f.tipo != .nessuna {
            let d = simd_length(f.centro - p)
            if d < (best?.1 ?? .infinity) { best = (i, d) }
        }
        if let (i, d) = best, d < 0.12 { studio.finestraScelta = i }
    }

    @ViewBuilder
    private func disegno(_ f: Finestra, _ r: CGRect, _ lato: CGFloat, scelta: Bool) -> some View {
        let c = punto(f.centro, r)
        let opaco = scelta ? 0.95 : 0.45
        if f.tipo == .cerchio {
            let raggio = CGFloat(f.raggio) * lato
            Circle().stroke(Color.white.opacity(opaco), lineWidth: scelta ? 2 : 1)
                .frame(width: raggio * 2, height: raggio * 2).position(c).allowsHitTesting(false)
            if scelta {
                Circle().stroke(Color.white.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
                    .frame(width: raggio * 2 * CGFloat(1 + f.morbidezza), height: raggio * 2 * CGFloat(1 + f.morbidezza))
                    .position(c).allowsHitTesting(false)
            }
        } else {
            Path { p in
                let a = CGFloat(f.angolo) * .pi / 180
                let d = CGPoint(x: -sin(a), y: -cos(a))
                p.move(to: CGPoint(x: c.x - d.x * lato, y: c.y - d.y * lato))
                p.addLine(to: CGPoint(x: c.x + d.x * lato, y: c.y + d.y * lato))
            }
            .stroke(Color.white.opacity(opaco), lineWidth: scelta ? 2 : 1)
            .allowsHitTesting(false)
        }
    }

    /// Maniglie della finestra scelta.
    @ViewBuilder
    private func maniglie(_ f: Finestra, _ r: CGRect, _ lato: CGFloat) -> some View {
        let c = punto(f.centro, r)
        // centro: trascina = sposta
        Circle().fill(Tema.accento).frame(width: 14, height: 14)
            .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 1))
            .frame(width: 30, height: 30).contentShape(Rectangle())
            .position(c)
            .zonaMonitor("finestre.centro", trascina: { d, _ in
                guard !studio.tracciando else { return }
                let n = studio.finestraCorrente.a(studio.eVideo ? studio.tempo : nil).centro
                studio.spostaFinestra(SIMD2(min(1, max(0, n.x + Float(d.width / r.width))), min(1, max(0, n.y + Float(d.height / r.height)))))
            })
        if f.tipo == .cerchio {
            // bordo a destra: trascina = più grande o più piccolo
            let raggio = CGFloat(f.raggio) * lato
            Rectangle().fill(Color.white).frame(width: 12, height: 12)
                .overlay(Rectangle().stroke(Color.black.opacity(0.6), lineWidth: 1))
                .frame(width: 28, height: 28).contentShape(Rectangle())
                .position(x: c.x + raggio, y: c.y)
                .zonaMonitor("finestre.raggio", trascina: { d, _ in
                    var n = studio.finestraCorrente
                    n.raggio = min(1.5, max(0.02, n.raggio + Float(d.width / lato)))
                    studio.finestraCorrente = n
                })
            // bordo morbido (tratteggio): trascina = più o meno sfumata
            let morbido = raggio * CGFloat(1 + f.morbidezza)
            Circle().fill(Color.white.opacity(0.8)).frame(width: 10, height: 10)
                .frame(width: 26, height: 26).contentShape(Rectangle())
                .position(x: c.x, y: c.y - morbido)
                .zonaMonitor("finestre.morbidezza", trascina: { d, _ in
                    var n = studio.finestraCorrente
                    n.morbidezza = min(1, max(0.01, n.morbidezza - Float(d.height / max(20, raggio))))
                    studio.finestraCorrente = n
                })
        } else {
            // maniglia sulla linea: trascina in giro = ruota la linea
            let a = CGFloat(f.angolo) * .pi / 180
            let m = CGPoint(x: c.x - sin(a) * 90, y: c.y - cos(a) * 90)
            Circle().fill(Color.white).frame(width: 12, height: 12)
                .overlay(Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 7, weight: .bold)).foregroundStyle(.black))
                .frame(width: 28, height: 28).contentShape(Rectangle())
                .position(m)
                .zonaMonitor("finestre.ruota", trascina: { _, _ in
                    guard let p = Studio.condiviso.puntatore, let z = ZoneMonitor.condivise.zone["finestre.video"] else { return }
                    let cx = z.riquadro.minX + CGFloat(studio.finestraCorrente.centro.x) * z.riquadro.width
                    let cy = z.riquadro.minY + CGFloat(studio.finestraCorrente.centro.y) * z.riquadro.height
                    var n = studio.finestraCorrente
                    n.angolo = Float(atan2(-(p.x - cx), -(p.y - cy)) * 180 / .pi)
                    studio.finestraCorrente = n
                })
        }
    }
}

// MARK: - Contagocce sul video del monitor

private struct ContagocceSulMonitor: View {
    @ObservedObject var studio: Studio

    var body: some View {
        if studio.contagocce != .nessuno, let img = studio.risultato {
            GeometryReader { g in
                let r = FinestreSulMonitor.rettangolo(img.size, g.size)
                ZStack(alignment: .topLeading) {
                    Color.white.opacity(0.001)
                        .frame(width: r.width, height: r.height)
                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(Tema.accento.opacity(0.8), lineWidth: 2))
                        .zonaMonitor("menu.contagocce", clic: { p in
                            guard (0...1).contains(p.x), (0...1).contains(p.y) else { return }
                            studio.tocco(p)
                        }, destro: { studio.contagocce = .nessuno })
                        // lo spostamento dopo la zona: così la zona sta sopra il video (prima era nel posto sbagliato)
                        .offset(x: r.minX, y: r.minY)
                    Label("Eyedropper: click the color to pick · right-click = cancel", systemImage: "eyedropper")
                        .font(.system(size: 12, weight: .bold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(Tema.accento)).foregroundStyle(.black)
                        .frame(width: g.size.width, alignment: .center)
                        .offset(y: r.minY + 8)
                        .allowsHitTesting(false)
                }
            }
        }
    }
}

/// Mostra per qualche secondo il colore preso col contagocce.
private struct ColorePresoMonitor: View {
    @ObservedObject var studio: Studio

    var body: some View {
        if let (c, uso) = studio.colorePreso {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(red: Double(min(1, max(0, c.x))), green: Double(min(1, max(0, c.y))), blue: Double(min(1, max(0, c.z)))))
                    .frame(width: 38, height: 38)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.8), lineWidth: 1))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Color picked · \(uso)").font(.system(size: 12, weight: .bold))
                    Text("R \(Int(c.x * 255))  G \(Int(c.y * 255))  B \(Int(c.z * 255))")
                        .font(.system(size: 12, design: .monospaced))
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.8)))
            .foregroundStyle(.white)
            .padding(14)
            .allowsHitTesting(false)
            .task(id: "\(c)") {
                try? await Task.sleep(for: .seconds(5))
                studio.colorePreso = nil
            }
        }
    }
}
