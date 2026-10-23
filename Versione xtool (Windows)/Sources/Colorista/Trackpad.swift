import SwiftUI
import UIKit
import GameController

/// Il telefono come trackpad e tastiera del monitor esterno (che con l'iPhone non si tocca):
/// sul monitor c'è un puntatore disegnato dall'app; le parti cliccabili del monitor si registrano qui
/// con il loro riquadro, e un clic (o un trascinamento) va a quella sotto il puntatore.
@MainActor
final class ZoneMonitor {
    static let condivise = ZoneMonitor()

    struct Zona {
        var riquadro: CGRect
        /// Punto del clic dentro la zona, 0…1.
        var clic: ((CGPoint) -> Void)?
        /// Spostamento del dito (punti del monitor) e punto attuale dentro la zona, 0…1.
        var trascina: ((CGSize, CGPoint) -> Void)?
        /// Tasto destro: di solito rimette il valore di partenza (come il doppio clic di DaVinci).
        var destro: (() -> Void)?
        /// Quale vista l'ha registrata: una vista che sparisce toglie solo la sua (non quella nuova con lo stesso nome).
        var proprietario = UUID()
    }

    private(set) var zone: [String: Zona] = [:]
    var ultimoClic = Date.distantPast
    var ultimoDestro = Date.distantPast
    /// Grandezza del monitor in punti.
    var dimensione = CGSize(width: 1920, height: 1080)

    func registra(_ id: String, _ z: Zona) { zone[id] = z }
    func togli(_ id: String) { zone[id] = nil }
    func togli(_ id: String, di proprietario: UUID) { if zone[id]?.proprietario == proprietario { zone[id] = nil } }

    /// La zona più piccola che contiene il punto (quella "più in alto": un nodo dentro il pannello dei nodi).
    func zona(in p: CGPoint, dove: (Zona) -> Bool = { _ in true }) -> (id: String, zona: Zona)? {
        // un menu aperto sta sopra a tutto
        if let m = zone.first(where: { $0.key.hasPrefix("menu.") && $0.value.riquadro.contains(p) && dove($0.value) }) { return (m.key, m.value) }
        return zone.filter { $0.value.riquadro.contains(p) && dove($0.value) }
            .min { $0.value.riquadro.width * $0.value.riquadro.height < $1.value.riquadro.width * $1.value.riquadro.height }
            .map { ($0.key, $0.value) }
    }
}

/// Posizione del puntatore sul monitor: la guarda solo la freccia disegnata.
@MainActor
final class PuntoMonitor: ObservableObject {
    static let condiviso = PuntoMonitor()
    @Published var punto: CGPoint?
}

/// La zona sotto il puntatore (cambia di rado): la guardano le zone per il bordo bianco.
@MainActor
final class ZonaSottoMonitor: ObservableObject {
    static let condivisa = ZonaSottoMonitor()
    @Published var id: String?
}

/// La freccia del puntatore sul monitor.
struct CursoreMonitor: View {
    @ObservedObject private var p = PuntoMonitor.condiviso

    var body: some View {
        if let p = p.punto {
            Image(systemName: "cursorarrow")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.8), radius: 2)
                .offset(x: p.x - 6, y: p.y - 4)
                .allowsHitTesting(false)
        }
    }
}

/// Rende cliccabile (e trascinabile) una parte del monitor, con il bordo bianco quando il puntatore ci passa sopra.
private struct ZonaMonitor: ViewModifier {
    let id: String
    let clic: ((CGPoint) -> Void)?
    let trascina: ((CGSize, CGPoint) -> Void)?
    let destro: (() -> Void)?
    /// Modalità desktop sul telefono: la zona risponde direttamente al dito.
    @Environment(\.tattile) private var tattile
    /// Solo le viste disegnate sul monitor diventano zone (le palette del telefono no).
    @Environment(\.suMonitor) private var suMonitor
    @State private var proprietario = UUID()

    private func registra(_ r: CGRect) {
        guard suMonitor || tattile else { return }
        ZoneMonitor.condivise.registra(id, .init(riquadro: r, clic: clic, trascina: trascina, destro: destro, proprietario: proprietario))
    }
    @State private var ultima = CGSize.zero

    func body(content: Content) -> some View {
        content
            .overlay {
                if tattile {
                    GeometryReader { g in
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { p in
                                guard let clic else { return }
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                clic(CGPoint(x: p.x / max(1, g.size.width), y: p.y / max(1, g.size.height)))
                            }
                            .gesture(trascina == nil ? nil : DragGesture(minimumDistance: 2)
                                .onChanged { v in
                                    let d = CGSize(width: v.translation.width - ultima.width, height: v.translation.height - ultima.height)
                                    ultima = v.translation
                                    trascina?(d, CGPoint(x: v.location.x / max(1, g.size.width), y: v.location.y / max(1, g.size.height)))
                                }
                                .onEnded { _ in ultima = .zero })
                    }
                }
            }
            .background(GeometryReader { g in
                // si registra a ogni aggiornamento della vista: così il clic fa sempre quello che si vede adesso
                // (una miniatura della libreria che cambia, un tasto play/pausa…)
                let r = g.frame(in: .named("monitor"))
                let _ = registra(r)
                Color.clear
            })
            // e ogni volta che la vista si sposta senza ridisegnarsi (timeline o liste fatte scorrere)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("monitor")) } action: { registra($0) }
            .onChange(of: id) { vecchio, _ in ZoneMonitor.condivise.togli(vecchio, di: proprietario) }
            .onDisappear { ZoneMonitor.condivise.togli(id, di: proprietario) }
    }
}

extension EnvironmentValues {
    /// Vero nella modalità desktop sul telefono: le zone del monitor si toccano col dito.
    @Entry var tattile = false
    /// Vero dentro l'interfaccia del monitor esterno.
    @Entry var suMonitor = false
}

// MARK: - Tasti e interruttori cliccabili dal monitor

/// Come lo stile "plain", ma sul monitor ogni tasto diventa cliccabile col puntatore (senza collegarli uno per uno).
struct StilePulsante: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View { PulsanteMonitor(configuration: configuration) }
}

private struct PulsanteMonitor: View {
    let configuration: PrimitiveButtonStyleConfiguration
    @State private var id = "tasto." + UUID().uuidString

    var body: some View {
        configuration.label
            .contentShape(Rectangle())
            .onTapGesture { configuration.trigger() }
            .zonaMonitor(id, clic: { _ in configuration.trigger() })
    }
}

/// Interruttore come quello di iOS, cliccabile anche dal monitor.
struct StileInterruttore: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View { InterruttoreMonitor(configuration: configuration) }
}

private struct InterruttoreMonitor: View {
    let configuration: ToggleStyleConfiguration
    @State private var id = "interruttore." + UUID().uuidString

    var body: some View {
        HStack {
            configuration.label
            Spacer(minLength: 8)
            Capsule()
                .fill(configuration.isOn ? Tema.accento : Color(white: 0.3))
                .frame(width: 46, height: 28)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle().fill(.white).padding(2.5)
                }
                .animation(.easeOut(duration: 0.15), value: configuration.isOn)
        }
        .contentShape(Rectangle())
        .onTapGesture { configuration.isOn.toggle() }
        .zonaMonitor(id, clic: { _ in configuration.isOn.toggle() })
    }
}

extension View {
    /// Editor a punti (curve, warper) col puntatore: tieni premuto e muovi per spostare un punto,
    /// clic per sceglierlo o aggiungerlo, tasto destro per toglierlo. I punti sono in coordinate della vista.
    func zonaEditor(clic: ((CGPoint) -> Void)? = nil, inizia: @escaping (CGPoint) -> Void,
                    muovi: @escaping (CGPoint) -> Void, destro: ((CGPoint) -> Void)? = nil) -> some View {
        modifier(ZonaEditor(clic: clic, inizia: inizia, muovi: muovi, destro: destro))
    }

    /// Menu a tendina cliccabile dal monitor: il clic apre l'elenco delle scelte sotto il puntatore.
    func menuMonitor<T: Hashable>(_ selezione: Binding<T>, _ opzioni: [T], nome: @escaping (T) -> String) -> some View {
        modifier(MenuSceltaMonitor(selezione: selezione, opzioni: opzioni, nome: nome))
    }

    /// Scelta a segmenti cliccabile dal monitor: il clic sceglie l'opzione sotto il puntatore (da sinistra a destra).
    func sceltaMonitor<T: Hashable>(_ selezione: Binding<T>, _ opzioni: [T]) -> some View {
        modifier(SceltaMonitor(selezione: selezione, opzioni: opzioni))
    }
}

private struct ZonaEditor: ViewModifier {
    let clic: ((CGPoint) -> Void)?
    let inizia: (CGPoint) -> Void
    let muovi: (CGPoint) -> Void
    let destro: ((CGPoint) -> Void)?
    @State private var id = "editor." + UUID().uuidString
    /// Un trascinamento nuovo comincia se il precedente è fermo da un attimo.
    private final class Stato { var ultimo = Date.distantPast }
    @State private var stato = Stato()

    func body(content: Content) -> some View {
        GeometryReader { g in
            let s = g.size
            content.zonaMonitor(id,
                clic: { p in clic?(CGPoint(x: p.x * s.width, y: p.y * s.height)) },
                trascina: { _, p in
                    let q = CGPoint(x: p.x * s.width, y: p.y * s.height)
                    if Date().timeIntervalSince(stato.ultimo) > 0.25 { inizia(q) }
                    stato.ultimo = Date()
                    muovi(q)
                },
                destro: destro.map { d in {
                    guard let z = ZoneMonitor.condivise.zone[id], let p = Studio.condiviso.puntatore else { return }
                    d(CGPoint(x: (p.x - z.riquadro.minX) / max(1, z.riquadro.width) * s.width,
                              y: (p.y - z.riquadro.minY) / max(1, z.riquadro.height) * s.height))
                } })
        }
    }
}

private struct MenuSceltaMonitor<T: Hashable>: ViewModifier {
    let selezione: Binding<T>
    let opzioni: [T]
    let nome: (T) -> String
    @State private var id = "menuScelta." + UUID().uuidString

    func body(content: Content) -> some View {
        content.zonaMonitor(id, clic: { _ in
            MenuMonitor.condiviso.apri(opzioni.map { o in
                VoceMenuMonitor(titolo: nome(o), icona: o == selezione.wrappedValue ? "checkmark" : "") { selezione.wrappedValue = o }
            })
        })
    }
}

private struct SceltaMonitor<T: Hashable>: ViewModifier {
    let selezione: Binding<T>
    let opzioni: [T]
    @State private var id = "scelta." + UUID().uuidString

    func body(content: Content) -> some View {
        content.zonaMonitor(id, clic: { p in
            guard !opzioni.isEmpty else { return }
            selezione.wrappedValue = opzioni[min(opzioni.count - 1, max(0, Int(p.x * CGFloat(opzioni.count))))]
        })
    }
}

extension View {
    func zonaMonitor(_ id: String, clic: ((CGPoint) -> Void)? = nil, trascina: ((CGSize, CGPoint) -> Void)? = nil, destro: (() -> Void)? = nil) -> some View {
        modifier(ZonaMonitor(id: id, clic: clic, trascina: trascina, destro: destro))
    }
}

// MARK: - Comandi dal trackpad

extension Studio {
    func mostraPuntatore() {
        let d = ZoneMonitor.condivise.dimensione
        puntatore = CGPoint(x: d.width / 2, y: d.height / 2)
        aggiornaZonaSotto()
    }

    func muoviPuntatore(_ d: CGSize) {
        guard var p = puntatore else { return }
        let m = ZoneMonitor.condivise.dimensione
        p.x = min(m.width - 2, max(0, p.x + d.width))
        p.y = min(m.height - 2, max(0, p.y + d.height))
        puntatore = p
        aggiornaZonaSotto()
    }

    private func aggiornaZonaSotto() {
        let id = puntatore.flatMap { ZoneMonitor.condivise.zona(in: $0)?.id }
        if id != zonaSotto { zonaSotto = id }
    }

    private func dentro(_ z: ZoneMonitor.Zona, _ p: CGPoint) -> CGPoint {
        let r = z.riquadro
        return CGPoint(x: (p.x - r.minX) / max(1, r.width), y: (p.y - r.minY) / max(1, r.height))
    }

    func clicMonitor() {
        // lo stesso clic può arrivare due volte (dal mouse e dal tocco sul telefono): conta una volta sola
        guard Date().timeIntervalSince(ZoneMonitor.condivise.ultimoClic) > 0.25 else { return }
        ZoneMonitor.condivise.ultimoClic = Date()
        guard let p = puntatore else { return }
        let trovata = ZoneMonitor.condivise.zona(in: p)
        // clic fuori dal menu aperto: il menu si chiude e basta (come sul Mac)
        if !MenuMonitor.condiviso.voci.isEmpty, !(trovata?.id.hasPrefix("menu.") ?? false) { MenuMonitor.condiviso.chiudi(); return }
        // finestra Bentornato aperta: si clicca solo lì
        if benvenutoMonitor, !(trovata?.id.hasPrefix("menu.benvenuto") ?? false) { return }
        if testoMonitor != nil, !(trovata?.id.hasPrefix("menu.testo") ?? false) { return }
        guard let (idTrovata, z) = trovata else { GestoreMonitor.scrivi("click on nothing at \(Int(p.x)),\(Int(p.y))"); return }
        if contagocce != .nessuno || idTrovata.contains("contagocce") { GestoreMonitor.scrivi("click on \(idTrovata)") }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        z.clic?(dentro(z, p))
    }

    /// Tasto destro sulla zona sotto il puntatore (la più piccola che ha qualcosa da fare col destro).
    func destroMonitor() {
        guard Date().timeIntervalSince(ZoneMonitor.condivise.ultimoDestro) > 0.25 else { return }
        ZoneMonitor.condivise.ultimoDestro = Date()
        guard let p = puntatore, let (_, z) = ZoneMonitor.condivise.zona(in: p, dove: { $0.destro != nil }) else { return }
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        z.destro?()
    }

    /// Rotellina: fa solo scorrere (palette, libreria Media, striscia delle clip). Non cambia mai i valori:
    /// passando sopra a ruote e cursori non deve modificare niente per sbaglio.
    func scorriMonitor(_ dx: CGFloat, _ dy: CGFloat) {
        guard let p = puntatore else { return }
        let contenitori = ["file.scorri", "brani.scorri", "palette.scorri", "media.griglia", "clip.scorri", "timeline.scorri"]
        guard let id = contenitori.first(where: { ZoneMonitor.condivise.zone[$0]?.riquadro.contains(p) ?? false }),
              let z = ZoneMonitor.condivise.zone[id] else { return }
        z.trascina?(CGSize(width: dx, height: dy), .zero)
    }

    /// Primo passo di un trascinamento: la zona riceve il punto dove è stato premuto (un editor a punti afferra quello).
    func iniziaTrascinamento(_ id: String, da p: CGPoint) {
        guard let z = ZoneMonitor.condivise.zone[id] else { return }
        z.trascina?(.zero, dentro(z, p))
    }

    /// Trascinamento: la zona è quella sotto il puntatore quando è cominciato.
    func trascinaMonitor(_ d: CGSize, zona id: String) {
        guard let z = ZoneMonitor.condivise.zone[id], let p = puntatore else { muoviPuntatore(d); return }
        muoviPuntatore(d)
        z.trascina?(d, dentro(z, puntatore ?? p))
    }

    // MARK: azioni usate dalle zone e dalla tastiera

    func playPausa() {
        // pagina Edit: si riproduce il montaggio
        if inEdit { if sequenzaInRiproduzione { pausaSequenza() } else { playSequenza() }; return }
        guard eVideo else { return }
        Task { if inRiproduzione { await pausa() } else { await play() } }
    }

    func passo(_ n: Int) {
        if inEdit { if !sequenzaInRiproduzione { vaiSequenza(tempoSequenza + Double(n) / 25) }; return }
        guard eVideo, !inRiproduzione else { return }
        Task { await fotogramma(min(durata, max(0, tempo + Double(n) / fpsClip))) }
    }

    func vaiA(_ parte: Double) {
        if inEdit { vaiSequenza(parte * durataMontaggio); return }
        guard eVideo, !inRiproduzione else { return }
        Task { await fotogramma(min(durata, max(0, parte * durata))) }
    }

    func clipVicina(_ d: Int) {
        let c = progetto.clips
        guard !c.isEmpty else { return }
        let i = c.firstIndex { $0.id == clipAttiva } ?? 0
        let j = min(c.count - 1, max(0, i + d))
        guard j != i else { return }
        Task { await apriClip(c[j].id) }
    }

    /// Ruota delle primarie trascinata col trackpad (come il dito sulla ruota del telefono, metà della corsa).
    func spostaRuota(_ kp: WritableKeyPath<Grade, Wheel>, _ d: CGSize, raggio: CGFloat) {
        if nodo.tipo != .correzione { vaiACorrettore() }
        var w = nodo.grade[keyPath: kp]
        var nx = w.x + Float(d.width / raggio) * 0.5
        var ny = w.y - Float(d.height / raggio) * 0.5
        let m = (nx * nx + ny * ny).squareRoot()
        if m > 1 { nx /= m; ny /= m }
        w.x = nx; w.y = ny
        nodo.grade[keyPath: kp] = w
    }

    func spostaMaster(_ kp: WritableKeyPath<Grade, Wheel>, _ d: CGSize, larghezza: CGFloat) {
        if nodo.tipo != .correzione { vaiACorrettore() }
        nodo.grade[keyPath: kp].master = min(1, max(-1, nodo.grade[keyPath: kp].master + Float(d.width / larghezza) * 0.8))
    }

    /// Tasto destro su una ruota: rimette al centro il colore o la rotella master.
    func azzeraRuota(_ kp: WritableKeyPath<Grade, Wheel>, colore: Bool) {
        if nodo.tipo != .correzione { vaiACorrettore() }
        if colore { nodo.grade[keyPath: kp].x = 0; nodo.grade[keyPath: kp].y = 0 } else { nodo.grade[keyPath: kp].master = 0 }
    }

    /// Valore numerico trascinato (contrasto, saturazione…): 300 punti di corsa = tutto l'intervallo.
    func spostaValore(_ kp: WritableKeyPath<Grade, Float>, _ dx: CGFloat, _ intervallo: ClosedRange<Float>) {
        if nodo.tipo != .correzione { vaiACorrettore() }
        let passo = Float(dx / 300) * (intervallo.upperBound - intervallo.lowerBound)
        nodo.grade[keyPath: kp] = min(intervallo.upperBound, max(intervallo.lowerBound, nodo.grade[keyPath: kp] + passo))
    }

    /// Scorciatoie da tastiera, come in DaVinci dove si può.
    func scorciatoia(_ c: Character) {
        switch String(c).lowercased() {
        case " ", "k": playPausa()
        case "j": passo(-1)
        case "l": passo(1)
        case "d": nodo.attivo.toggle()
        case "s": aggiungi(.correzione)
        case "z": annulla()
        case "y": ripeti()
        default: break
        }
    }
}

// MARK: - Schermata trackpad del telefono

struct TrackpadMonitor: View {
    @ObservedObject var studio: Studio
    @Environment(\.dismiss) private var chiudi
    /// Chiusura quando è presentato da PresentatoreTrackpad.
    var esci: (() -> Void)? = nil
    @State private var testo = ""
    @FocusState private var tastiera: Bool
    @State private var inizio: Date?
    @State private var ultima = CGSize.zero
    @State private var mosso = false
    @State private var trascinando: String?
    @State private var attesa: Task<Void, Never>?
    @ObservedObject private var mouse = MouseMonitor.condiviso
    @State private var sinistroGiu = false
    @State private var trascinatoColSinistro = false
    @State private var ultimaRotella: CGFloat = 0
    @State private var scorrimento: CGFloat = 0
    @State private var ultimoHover: CGPoint?
    @State private var tastoMouse = false
    @State private var misuraSuperficie = CGSize(width: 402, height: 874)

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Trackpad").font(.headline)
                Spacer()
                Button {
                    tastiera.toggle()
                } label: {
                    Label("Keyboard", systemImage: "keyboard")
                        .padding(.horizontal, 12).frame(height: 34)
                        .background(Capsule().fill(tastiera ? Tema.accento.opacity(0.2) : Tema.campo))
                        .foregroundStyle(tastiera ? Tema.accento : .white)
                }
                Button("Done") { if let esci { esci() } else { chiudi() } }.font(.headline).foregroundStyle(Tema.accento).padding(.leading, 8)
            }
            if !studio.monitorCollegato {
                Text("No monitor connected: connect a monitor or a TV to see the pointer.")
                    .font(.footnote).foregroundStyle(Tema.accento)
            }
            if mouse.collegato {
                Text("Mouse connected: move it to move the pointer on the monitor. Click = click · hold and move = drag · wheel = adjust wheels and values.")
                    .font(.footnote).foregroundStyle(Tema.testo2)
            }
            HStack(spacing: 8) {
                superficie
                rotellina
            }
            tastiMouse
            tasti
            if tastiera {
                Text("Space or K: play/pause · J/L or ←/→: one frame · ↑/↓: clip · D: node on/off · S: new node · Z: undo · Y: redo")
                    .font(.caption2).foregroundStyle(Tema.testo2)
            }
            // campo invisibile: riceve i tasti (della tastiera del telefono o di una tastiera vera)
            TextField("", text: $testo)
                .focused($tastiera)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .frame(width: 1, height: 1).opacity(0.01)
                .onChange(of: testo) { _, t in
                    guard !t.isEmpty else { return }
                    for c in t { studio.scorciatoia(c) }
                    testo = ""
                }
                .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { k in
                    switch k.key {
                    case .leftArrow: studio.passo(-1)
                    case .rightArrow: studio.passo(1)
                    case .upArrow: studio.clipVicina(-1)
                    default: studio.clipVicina(1)
                    }
                    return .handled
                }
        }
        .padding(16)
        .background(Tema.sfondo.ignoresSafeArea())
        // mouse collegato: il puntatore di iOS gira per tutto lo schermo del telefono, quindi tutto lo schermo
        // diventa la superficie del mouse (così un clic non finisce mai su un tasto del telefono)
        .overlay { if mouse.collegato { superficieMouse } }
        // testo da scrivere per il monitor: la tastiera del telefono scrive nella finestra del monitor
        .overlay { if studio.testoMonitor != nil { TastieraTestoMonitor(studio: studio) } }
        // avvisi dell'app mentre c'è il trackpad: compaiono qui sopra (un avviso normale chiuderebbe il trackpad)
        .overlay(alignment: .top) {
            if let m = studio.messaggio {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Tema.accento)
                    Text(m).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
                    Button("OK") { studio.messaggio = nil }.font(.footnote.weight(.bold)).foregroundStyle(Tema.accento)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.18)))
                .padding(.horizontal, 12).padding(.top, 8)
                .task(id: m) { try? await Task.sleep(for: .seconds(6)); if studio.messaggio == m { studio.messaggio = nil } }
            }
        }
        .preferredColorScheme(.dark)
        // niente barra dell'ora in alto e barretta in basso: si prendevano i clic del mouse quando il puntatore ci finiva sopra
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .all)
        .onAppear { studio.mostraPuntatore() }
        .onDisappear { studio.puntatore = nil; studio.zonaSotto = nil }
    }

    /// Un dito: sposta il puntatore. Tocco: clic. Tieni premuto e poi muovi: trascina quello che c'è sotto.
    private var superficie: some View {
        RoundedRectangle(cornerRadius: 18)
            .fill(Tema.pannello)
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(trascinando != nil ? Tema.accento : Tema.bordo, lineWidth: trascinando != nil ? 2 : 1))
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "hand.point.up.left").font(.system(size: 30)).foregroundStyle(Tema.testo2)
                    Text("Move your finger to move the pointer").font(.subheadline)
                    Text("Tap or Left = click · hold Left and move = drag · Right = default value").font(.caption).foregroundStyle(Tema.testo2)
                }
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            // mouse collegato al telefono (con AssistiveTouch attivo iOS mostra il suo puntatore):
            // passandoci sopra si muove il puntatore del monitor, la rotella scorre o regola
            .onContinuousHover { fase in
                switch fase {
                case .active(let p):
                    MouseMonitor.condiviso.segna("pointer on the phone")
                    if let u = ultimoHover, !MouseMonitor.condiviso.muoveDaSolo { studio.muoviPuntatore(CGSize(width: (p.x - u.x) * 2.2, height: (p.y - u.y) * 2.2)) }
                    ultimoHover = p
                case .ended: ultimoHover = nil
                }
            }
            .gesture(RotellaMouse { dx, dy in MouseMonitor.condiviso.segna("wheel on the phone"); studio.scorriMonitor(dx, dy) })
            // tasto destro del mouse sul trackpad (iOS lo manda alla schermata del telefono, non al mouse dell'app)
            .gesture(TastoDestroMouse { studio.destroMonitor() })
            .gesture(SpiaTocchi())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    // mouse in uso: il "tocco" è il tasto sinistro; il puntatore lo muove il mouse
                    if mouse.collegato, inizio == nil, !tastoMouse, MouseMonitor.condiviso.inUso {
                        tastoMouse = true
                        MouseMonitor.condiviso.segna("left from touch")
                        MouseMonitor.condiviso.tasto(true)
                    }
                    if tastoMouse { return }
                    if inizio == nil {
                        inizio = Date(); ultima = .zero; mosso = false
                        // fermo per un attimo: comincia il trascinamento della zona sotto il puntatore
                        attesa = Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(350))
                            guard !Task.isCancelled, !mosso, let p = studio.puntatore,
                                  let (id, _) = ZoneMonitor.condivise.zona(in: p, dove: { $0.trascina != nil }) else { return }
                            trascinando = id
                            studio.iniziaTrascinamento(id, da: p)
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        }
                    }
                    let d = CGSize(width: v.translation.width - ultima.width, height: v.translation.height - ultima.height)
                    ultima = v.translation
                    if (v.translation.width * v.translation.width + v.translation.height * v.translation.height).squareRoot() > 10 { mosso = true }
                    let velocita = (d.width * d.width + d.height * d.height).squareRoot()
                    if sinistroGiu, trascinando == nil, let p = studio.puntatore,
                       let (id, _) = ZoneMonitor.condivise.zona(in: p, dove: { $0.trascina != nil }) {
                        trascinando = id; trascinatoColSinistro = true; attesa?.cancel()
                        studio.iniziaTrascinamento(id, da: p)
                    } else if sinistroGiu { trascinatoColSinistro = true }
                    if let id = trascinando {
                        studio.trascinaMonitor(CGSize(width: d.width * 2, height: d.height * 2), zona: id)
                    } else if mosso {
                        // più veloce muovi il dito, più strada fa il puntatore (come un trackpad vero)
                        let k = 1.8 + min(3.5, velocita / 5)
                        studio.muoviPuntatore(CGSize(width: d.width * k, height: d.height * k))
                    }
                }
                .onEnded { _ in
                    if tastoMouse { tastoMouse = false; MouseMonitor.condiviso.tasto(false); return }
                    attesa?.cancel()
                    if trascinando == nil, !mosso, !sinistroGiu, let i = inizio, Date().timeIntervalSince(i) < 0.45 {
                        MouseMonitor.condiviso.segna("click on the trackpad")
                        studio.clicMonitor()
                    } else if mosso { MouseMonitor.condiviso.segna("drag on the trackpad") }
                    inizio = nil
                    if !sinistroGiu { trascinando = nil }
                })
    }

    /// Con il mouse: tutto lo schermo. Il clic sinistro arriva come tocco, il destro e la rotella come mouse.
    private var superficieMouse: some View {
        ZStack {
            Tema.sfondo
            VStack(spacing: 10) {
                Image(systemName: "computermouse").font(.system(size: 40)).foregroundStyle(Tema.accento)
                Text("Mouse connected").font(.headline)
                if mouse.mostraAvvisoAssistiveTouch {
                    AvvisoAssistiveTouch().allowsHitTesting(true)
                }
                Text("Use the mouse on the monitor: left = click (hold and move = drag) · right = menu or default value · wheel = scroll or adjust.")
                    .font(.footnote).foregroundStyle(Tema.testo2).multilineTextAlignment(.center)
                Text("To use the phone's buttons disconnect the mouse.")
                    .font(.caption).foregroundStyle(Tema.testo2)
            }
            .padding(30)
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        // il puntatore del monitor segue quello del telefono, ma solo dentro una zona lontana dai bordi del telefono:
        // così si arriva ai bordi e agli angoli del monitor senza che il puntatore del telefono finisca sulla barretta
        // o sull'isola (dove iOS si prende i clic)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { misuraSuperficie = $0 }
        .onContinuousHover { fase in
            switch fase {
            case .active(let p):
                MouseMonitor.condiviso.segna("pointer on the phone")
                MouseMonitor.condiviso.portaA(normalizza(p))
            case .ended: break
            }
        }
        .gesture(RotellaMouse { dx, dy in MouseMonitor.condiviso.segna("wheel on the phone"); studio.scorriMonitor(dx, dy) })
        .gesture(TastoDestroMouse { studio.destroMonitor() })
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { v in
                if tastoMouse { MouseMonitor.condiviso.portaA(normalizza(v.location)) }
                if !tastoMouse {
                    tastoMouse = true
                    GestoreMonitor.scrivi("left click on the phone at \(Int(v.startLocation.x)),\(Int(v.startLocation.y)) · monitor pointer \(studio.puntatore.map { "\(Int($0.x)),\(Int($0.y))" } ?? "-")")
                    MouseMonitor.condiviso.segna("left from touch")
                    MouseMonitor.condiviso.tasto(true)
                }
            }
            .onEnded { _ in
                tastoMouse = false
                MouseMonitor.condiviso.tasto(false)
            })
    }

    /// Posizione del puntatore del telefono → 0…1, dentro la zona sicura (lontano da isola, barretta e bordi).
    private func normalizza(_ p: CGPoint) -> CGPoint {
        let w = max(1, misuraSuperficie.width), h = max(1, misuraSuperficie.height)
        let sx: CGFloat = 40, sopra: CGFloat = 90, sotto: CGFloat = 80
        return CGPoint(x: min(1, max(0, (p.x - sx) / (w - 2 * sx))),
                       y: min(1, max(0, (p.y - sopra) / (h - sopra - sotto))))
    }

    /// Tasto sinistro (tienilo premuto e muovi il dito sul trackpad per trascinare) e tasto destro.
    private var tastiMouse: some View {
        HStack(spacing: 8) {
            Text("Left")
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity).frame(height: 50)
                .background(RoundedRectangle(cornerRadius: 12).fill(sinistroGiu ? Tema.accento.opacity(0.35) : Tema.campo))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !sinistroGiu { sinistroGiu = true; trascinatoColSinistro = false; UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                    }
                    .onEnded { _ in
                        if !trascinatoColSinistro { studio.clicMonitor() }
                        sinistroGiu = false; trascinando = nil
                    })
                .accessibilityLabel("Left button")
            Text("Right")
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity).frame(height: 50)
                .background(RoundedRectangle(cornerRadius: 12).fill(Tema.campo))
                .contentShape(Rectangle())
                .onTapGesture { studio.destroMonitor() }
                .accessibilityLabel("Right button")
        }
    }

    /// Rotellina: trascina su e giù per scorrere o regolare quello che c'è sotto il puntatore.
    private var rotellina: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(Tema.campo)
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "chevron.up")
                    ForEach(0..<7, id: \.self) { i in
                        Capsule().fill(Color.white.opacity(0.25)).frame(width: 16, height: 2)
                            .offset(y: CGFloat((Int(scorrimento) / 6 + i) % 3) - 1)
                    }
                    Image(systemName: "chevron.down")
                }
                .font(.system(size: 11, weight: .bold)).foregroundStyle(Tema.testo2)
                .allowsHitTesting(false)
            }
            .frame(width: 46)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let dy = v.translation.height - ultimaRotella
                    ultimaRotella = v.translation.height
                    scorrimento += dy
                    studio.scorriMonitor(0, dy * 1.5)
                }
                .onEnded { _ in ultimaRotella = 0 })
            .accessibilityLabel("Scroll wheel")
    }

    private var tasti: some View {
        HStack(spacing: 8) {
            tasto("backward.frame", "Backward") { studio.passo(-1) }
            tasto(studio.inRiproduzione ? "pause.fill" : "play.fill", "Play") { studio.playPausa() }
            tasto("forward.frame", "Forward") { studio.passo(1) }
            tasto("plus.square.on.square", "Node") { studio.aggiungi(.correzione) }
            tasto("power", "On/Off") { studio.nodo.attivo.toggle() }
            tasto("arrow.uturn.backward", "Cancel") { studio.annulla() }
        }
    }

    private func tasto(_ icona: String, _ nome: String, _ azione: @escaping () -> Void) -> some View {
        Button(action: azione) {
            VStack(spacing: 3) {
                Image(systemName: icona).font(.system(size: 17, weight: .semibold))
                Text(nome).font(.system(size: 10))
            }
            .frame(maxWidth: .infinity).frame(height: 54)
            .background(RoundedRectangle(cornerRadius: 10).fill(Tema.campo))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(nome)
    }
}

// MARK: - Modalità desktop sul telefono

/// Su iPhone le app non possono avere una schermata tutta loro sul monitor (iOS fa solo la duplicazione):
/// così il telefono stesso mostra l'interfaccia desktop in orizzontale e il monitor (cavo o AirPlay) la duplica.
/// Si tocca direttamente sul telefono: tocco = clic, tieni premuto e muovi = trascina (ruote, rotelle, barra del tempo).
struct ModalitaDesktop: View {
    @ObservedObject var studio: Studio
    var chiudi: () -> Void = {}
    @State private var trascinando: String?
    @State private var ultima = CGSize.zero
    @State private var inizio: Date?
    @State private var attesa: Task<Void, Never>?

    var body: some View {
        GeometryReader { g in
            // l'interfaccia è disegnata a 1440 punti di larghezza e rimpicciolita sullo schermo del telefono
            let larga: CGFloat = 1440
            let k = g.size.width / larga
            let alta = g.size.height / max(k, 0.01)
            ZStack(alignment: .topLeading) {
                // un piccolo "Mac": finestre spostabili e ridimensionabili, barra in alto e Dock
                DesktopFinestre(studio: studio, esci: chiudi)
            }
            .frame(width: larga, height: alta)
            .scaleEffect(k, anchor: .topLeading)
        }
        .ignoresSafeArea()
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .background(Color.black)
        .onAppear {
            // dopo che il foglio Monitor si è chiuso del tutto (finché c'è, iOS resta in verticale)
            Task { @MainActor in
                for attesa in [0.1, 0.6, 1.2] { try? await Task.sleep(for: .seconds(attesa)); Self.ruota(orizzontale: true) }
            }
        }
        .onDisappear { Self.ruota(orizzontale: false) }
    }

    private var tocchi: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if inizio == nil {
                    inizio = Date(); ultima = .zero
                    let p = v.startLocation
                    // fermo per un attimo sopra una ruota, una rotella o la barra del tempo: comincia a trascinare
                    attesa = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(250))
                        guard !Task.isCancelled, let (id, z) = ZoneMonitor.condivise.zona(in: p), z.trascina != nil else { return }
                        trascinando = id
                        studio.puntatore = p
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    }
                }
                let d = CGSize(width: v.translation.width - ultima.width, height: v.translation.height - ultima.height)
                ultima = v.translation
                if let id = trascinando {
                    studio.puntatore = v.location
                    studio.trascinaMonitor(d, zona: id)
                } else if (v.translation.width * v.translation.width + v.translation.height * v.translation.height).squareRoot() > 10 {
                    attesa?.cancel()
                }
            }
            .onEnded { v in
                attesa?.cancel()
                let fermo = (v.translation.width * v.translation.width + v.translation.height * v.translation.height).squareRoot() < 10
                if trascinando == nil, fermo, let (_, z) = ZoneMonitor.condivise.zona(in: v.location) {
                    let r = z.riquadro
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    z.clic?(CGPoint(x: (v.location.x - r.minX) / max(1, r.width), y: (v.location.y - r.minY) / max(1, r.height)))
                }
                inizio = nil; trascinando = nil; studio.puntatore = nil
            }
    }

    static func ruota(orizzontale: Bool) {
        guard let s = UIApplication.shared.connectedScenes.first(where: { $0.session.role == .windowApplication }) as? UIWindowScene else { return }
        for w in s.windows { w.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations(); w.rootViewController?.presentedViewController?.setNeedsUpdateOfSupportedInterfaceOrientations() }
        s.requestGeometryUpdate(.iOS(interfaceOrientations: orizzontale ? .landscapeRight : .portrait)) { e in print("MONITOR: rotation failed: \(e.localizedDescription)") }
    }
}


// MARK: - Mouse vero (Bluetooth)

/// Un mouse o trackpad Bluetooth collegato all'iPhone muove il puntatore del monitor (come fa ProDocktive).
/// Tasto sinistro = clic (tieni premuto e muovi = trascina ruote, rotelle, valori, barra del tempo);
/// tasto destro = rimette il valore di partenza; rotella = scorre o regola quello che c'è sotto.
@MainActor
final class MouseMonitor: ObservableObject {
    static let condiviso = MouseMonitor()
    @Published private(set) var collegato = false
    /// AssistiveTouch acceso (serve il puntatore di iOS sul telefono). Un'app non può accenderlo: Colors lo fa notare.
    @Published private(set) var assistiveTouch = UIAccessibility.isAssistiveTouchRunning
    /// Il puntatore di iOS è arrivato sul telefono: AssistiveTouch funziona (anche se iOS non lo dice).
    @Published private(set) var puntatoreVisto = false
    var mostraAvvisoAssistiveTouch: Bool { collegato && !assistiveTouch && !puntatoreVisto }

    private var premuto = false
    private var puntoPremuto: CGPoint?
    private var mosso: CGFloat = 0
    private var ultimoMovimento = Date.distantPast
    /// Il mouse manda già i suoi spostamenti all'app: il puntatore di iOS sul telefono non deve muovere anche lui.
    var muoveDaSolo: Bool { Date().timeIntervalSince(ultimoMovimento) < 0.3 }
    private var trascinando: String?

    func avvia() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIAccessibility.assistiveTouchStatusDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.assistiveTouch = UIAccessibility.isAssistiveTouchRunning }
        }
        nc.addObserver(forName: .GCMouseDidConnect, object: nil, queue: .main) { n in
            MainActor.assumeIsolated { if let m = n.object as? GCMouse { self.collega(m) } }
        }
        nc.addObserver(forName: .GCMouseDidDisconnect, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.collegato = GCMouse.mice().isEmpty == false }
        }
        GCMouse.mice().forEach(collega)
        GestoreMonitor.scrivi("mice seen at launch: \(GCMouse.mice().count)")
    }

    private func collega(_ m: GCMouse) {
        collegato = true
        GestoreMonitor.scrivi("mouse connected: \(m.vendorName ?? "?")")
        guard let input = m.mouseInput else { return }
        input.mouseMovedHandler = { _, dx, dy in
            DispatchQueue.main.async { MainActor.assumeIsolated { self.accumula(CGFloat(dx), CGFloat(-dy)) } }
        }
        input.leftButton.pressedChangedHandler = { _, _, giu in
            DispatchQueue.main.async { MainActor.assumeIsolated { self.segna("sinistro"); self.tasto(giu) } }
        }
        input.rightButton?.pressedChangedHandler = { _, _, giu in
            guard giu else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.segna("destro"); self.studio.destroMonitor() } }
        }
        input.scroll.yAxis.valueChangedHandler = { _, v in
            DispatchQueue.main.async { MainActor.assumeIsolated { self.segna("wheel axis") } }
        }
        input.scroll.valueChangedHandler = { _, dx, dy in
            DispatchQueue.main.async { MainActor.assumeIsolated { self.segna("rotella"); self.studio.scorriMonitor(CGFloat(dx) * 4, CGFloat(-dy) * 4) } }
        }
    }

    private var studio: Studio { Studio.condiviso }

    /// Gli spostamenti arrivano a centinaia al secondo: si sommano e si applicano una volta per giro.
    private var somma = CGSize.zero
    private var pianificato = false
    private func accumula(_ dx: CGFloat, _ dy: CGFloat) {
        segna("movimento")
        ultimoMovimento = Date()
        somma.width += dx; somma.height += dy
        guard !pianificato else { return }
        pianificato = true
        DispatchQueue.main.async { MainActor.assumeIsolated {
            let d = self.somma
            self.somma = .zero; self.pianificato = false
            // se il puntatore del telefono dà la posizione, comanda lui (gli spostamenti servirebbero il doppio)
            guard Date().timeIntervalSince(self.ultimaPosizione) > 0.5 else { return }
            self.muovi(d.width, d.height)
        } }
    }

    /// Scrive nel registro il primo evento di ogni tipo (per capire cosa iOS passa davvero all'app).
    private var visti: Set<String> = []
    func segna(_ tipo: String) {
        guard !visti.contains(tipo) else { return }
        visti.insert(tipo)
        GestoreMonitor.scrivi("mouse event: " + tipo)
    }

    /// Ultima volta che il puntatore del telefono ha dato la posizione (allora comanda lui, non gli spostamenti del mouse).
    private var ultimaPosizione = Date.distantPast

    /// Porta il puntatore del monitor al punto (0…1) che corrisponde al puntatore del telefono.
    func portaA(_ n: CGPoint) {
        if !puntatoreVisto { puntatoreVisto = true }
        guard studio.monitorCollegato else { return }
        ultimaPosizione = Date()
        let m = ZoneMonitor.condivise.dimensione
        let dest = CGPoint(x: n.x * (m.width - 2), y: n.y * (m.height - 2))
        guard let p = studio.puntatore else { studio.puntatore = dest; return }
        muovi(dest.x - p.x, dest.y - p.y, scala: 1)
    }

    private func muovi(_ dx: CGFloat, _ dy: CGFloat, scala: CGFloat = 1.4) {
        guard studio.monitorCollegato else { return }
        if studio.puntatore == nil { studio.mostraPuntatore() }
        let d = CGSize(width: dx * scala, height: dy * scala)
        if premuto {
            mosso += abs(dx) + abs(dy)
            // il trascinamento parte da dove hai premuto (non da dove è arrivato il puntatore intanto)
            if trascinando == nil, mosso > 10, let p0 = puntoPremuto ?? studio.puntatore,
               let (id, _) = ZoneMonitor.condivise.zona(in: p0, dove: { $0.trascina != nil }) {
                trascinando = id
                studio.iniziaTrascinamento(id, da: p0)
            }
        }
        if let id = trascinando { studio.trascinaMonitor(d, zona: id) } else { studio.muoviPuntatore(d) }
    }

    /// Il mouse si è mosso da poco: un tocco sul trackpad è il suo tasto sinistro (iOS lo manda come dito).
    var inUso: Bool { Date().timeIntervalSince(ultimoMovimento) < 4 }

    func tasto(_ giu: Bool) {
        guard studio.monitorCollegato else { return }
        if studio.puntatore == nil { studio.mostraPuntatore() }
        if giu { premuto = true; mosso = 0; trascinando = nil; puntoPremuto = studio.puntatore; return }
        if premuto, trascinando == nil, mosso < 14 { studio.clicMonitor() }
        premuto = false; trascinando = nil
    }

}

/// Rotella del mouse sul trackpad del telefono: iOS la manda come scorrimento senza dita.
struct RotellaMouse: UIGestureRecognizerRepresentable {
    var scorri: (CGFloat, CGFloat) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let r = UIPanGestureRecognizer()
        r.allowedScrollTypesMask = .all
        r.allowedTouchTypes = []
        return r
    }

    func handleUIGestureRecognizerAction(_ r: UIPanGestureRecognizer, context: Context) {
        let t = r.translation(in: r.view)
        r.setTranslation(.zero, in: r.view)
        if t != .zero { scorri(t.x, t.y) }
    }
}

/// Tasto destro del mouse sul trackpad del telefono.
struct TastoDestroMouse: UIGestureRecognizerRepresentable {
    var azione: () -> Void

    func makeUIGestureRecognizer(context: Context) -> UITapGestureRecognizer {
        let r = UITapGestureRecognizer()
        r.buttonMaskRequired = .secondary
        // solo il puntatore del mouse: il clic sinistro arriva come tocco di dito e non deve aprire il menu
        r.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        return r
    }

    func handleUIGestureRecognizerAction(_ r: UITapGestureRecognizer, context: Context) {
        if r.state == .ended {
            MouseMonitor.condiviso.segna("right on the phone")
            azione()
        }
    }
}

/// Solo per il registro: che tipo di tocchi arrivano sul trackpad (dito, puntatore del mouse, rotella).
struct SpiaTocchi: UIGestureRecognizerRepresentable {
    func makeUIGestureRecognizer(context: Context) -> Spia { Spia() }

    final class Spia: UIGestureRecognizer {
        override init(target: Any?, action: Selector?) {
            super.init(target: target, action: action)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            allowedTouchTypes = [UITouch.TouchType.direct, .indirect, .indirectPointer, .pencil].map { NSNumber(value: $0.rawValue) }
        }
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            for t in touches {
                let tipo: String
                switch t.type {
                case .direct: tipo = "dito"
                case .indirectPointer: tipo = "pointer (buttons \(event.buttonMask.rawValue))"
                case .indirect: tipo = "indiretto"
                default: tipo = "altro"
                }
                MainActor.assumeIsolated { MouseMonitor.condiviso.segna("touch: " + tipo) }
            }
            state = .failed
        }
        override func shouldReceive(_ event: UIEvent) -> Bool {
            if event.type == .scroll { MainActor.assumeIsolated { MouseMonitor.condiviso.segna("iOS scroll event") } }
            return super.shouldReceive(event)
        }
    }
}

// MARK: - Menu del tasto destro sul monitor

struct VoceMenuMonitor: Identifiable {
    let id = UUID()
    let titolo: String
    let icona: String
    var distruttiva = false
    let azione: () -> Void
}

/// Menu che si apre col tasto destro sul monitor (sotto il puntatore), come il menu contestuale del telefono.
@MainActor
final class MenuMonitor: ObservableObject {
    static let condiviso = MenuMonitor()
    @Published private(set) var voci: [VoceMenuMonitor] = []
    @Published private(set) var punto = CGPoint.zero

    func apri(_ v: [VoceMenuMonitor]) {
        punto = Studio.condiviso.puntatore ?? .zero
        voci = v
    }

    func chiudi() { voci = [] }
}

/// Il menu disegnato sul monitor.
struct VistaMenuMonitor: View {
    @ObservedObject var menu = MenuMonitor.condiviso

    var body: some View {
        GeometryReader { g in
            if !menu.voci.isEmpty {
                let larghezza: CGFloat = 340
                let altezza = CGFloat(menu.voci.count) * 32 + 10
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(menu.voci.enumerated()), id: \.element.id) { i, v in
                        HStack(spacing: 9) {
                            Image(systemName: v.icona).frame(width: 18)
                            Text(v.titolo)
                            Spacer()
                        }
                        .font(.system(size: 13))
                        .foregroundStyle(v.distruttiva ? Color(red: 1, green: 0.42, blue: 0.4) : Color(white: 0.92))
                        .padding(.horizontal, 10).frame(height: 32)
                        .contentShape(Rectangle())
                        .zonaMonitor("menu.\(i)", clic: { _ in
                            let a = v.azione
                            MenuMonitor.condiviso.chiudi()
                            a()
                        })
                    }
                }
                .padding(.vertical, 5)
                .frame(width: larghezza)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.16)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(white: 0.32), lineWidth: 1))
                .shadow(color: .black.opacity(0.6), radius: 12, y: 4)
                .offset(x: min(menu.punto.x + 4, g.size.width - larghezza - 4),
                        y: min(menu.punto.y + 4, g.size.height - altezza - 4))
            }
        }
    }
}

// MARK: - Trackpad a schermo intero con il puntatore bloccato

/// Controller del trackpad: chiede a iOS di bloccare il puntatore del mouse (così non va sulla barretta in basso
/// e tutti i clic arrivano a Colors come tasti del mouse), nasconde la barretta e rimanda i gesti di sistema.
final class ControlloreTrackpad: UIHostingController<AnyView> {
    override var prefersPointerLocked: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var prefersStatusBarHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsUpdateOfPrefersPointerLocked()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            let bloccato = self?.view.window?.windowScene?.pointerLockState?.isLocked ?? false
            MainActor.assumeIsolated { GestoreMonitor.scrivi("pointer locked: \(bloccato ? "yes" : "no")") }
        }
    }
}

@MainActor
enum PresentatoreTrackpad {
    private static weak var aperto: ControlloreTrackpad?

    static func mostra(_ studio: Studio, chiuso: @escaping () -> Void) {
        guard aperto == nil,
              let scena = UIApplication.shared.connectedScenes.first(where: { $0.session.role == .windowApplication }) as? UIWindowScene,
              var sopra = scena.keyWindow?.rootViewController ?? scena.windows.first?.rootViewController else { return }
        while let p = sopra.presentedViewController { sopra = p }
        let c = ControlloreTrackpad(rootView: AnyView(TrackpadMonitor(studio: studio, esci: { nascondi(); chiuso() })))
        // .overFullScreen: la schermata sotto resta viva, altrimenti iOS toglie lo schermo esterno (modalità desktop)
        c.modalPresentationStyle = .overFullScreen
        c.modalPresentationCapturesStatusBarAppearance = true
        c.view.backgroundColor = .black
        aperto = c
        sopra.present(c, animated: true)
    }

    static func nascondi() {
        aperto?.dismiss(animated: true)
        aperto = nil
    }
}

/// Sul telefono, mentre sul monitor c'è una finestra per scrivere: un campo con la tastiera, il testo si vede sul monitor.
struct TastieraTestoMonitor: View {
    @ObservedObject var studio: Studio
    @FocusState private var attivo: Bool

    var body: some View {
        VStack(spacing: 12) {
            Text(studio.testoMonitor?.titolo ?? "").font(.headline)
            Text("Type: the text appears on the monitor").font(.footnote).foregroundStyle(Tema.testo2)
            TextField("", text: Binding(get: { studio.testoMonitor?.testo ?? "" }, set: { studio.testoMonitor?.testo = $0 }))
                .focused($attivo)
                .submitLabel(.done)
                .onSubmit { studio.confermaTestoMonitor() }
                .padding(.horizontal, 12).frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 10).fill(Tema.campo))
            HStack {
                Button("Cancel") { studio.testoMonitor = nil }
                Spacer()
                Button("OK") { studio.confermaTestoMonitor() }.fontWeight(.bold)
            }
            .foregroundStyle(Tema.accento)
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tema.sfondo)
        .onAppear { attivo = true }
    }
}

/// AssistiveTouch spento: iOS non mostra il puntatore del mouse sul telefono e i clic non arrivano bene.
/// Un'app non può accenderlo da sola: si spiega come farlo in un attimo.
struct AvvisoAssistiveTouch: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Turn on AssistiveTouch", systemImage: "hand.point.up.left.fill").font(.subheadline.weight(.bold))
            Text("Fastest: press the side button 3 times. If nothing happens, set it up once in Settings › Accessibility › Accessibility Shortcut › AssistiveTouch.")
                .font(.caption)
            Text("Or: Settings › Accessibility › Touch › AssistiveTouch.").font(.caption)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Tema.accento.opacity(0.18)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tema.accento, lineWidth: 1))
        .foregroundStyle(Color(white: 0.95))
    }
}
