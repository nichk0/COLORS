import SwiftUI
import AVFoundation
import PhotosUI
import _PhotosUI_SwiftUI

struct ContentView: View {
    @ObservedObject private var studio = Studio.condiviso
    @State private var pagina: Pagina = .color
    @State private var palette: Palette = .primarie
    @State private var mediaScelti: [PhotosPickerItem] = []
    @State private var bypass = false
    @State private var mostraFile = false
    /// Scelta di un file musicale chiesta dal monitor (pagina Edit).
    @State private var mostraMusicaFile = false
    /// Scelta di una cartella o chiavetta da collegare (chiesta dal monitor).
    @State private var mostraCartella = false
    @State private var mostraLibreria = false
    @State private var importaSoloLUT = false
    @State private var mostraEsporta = false
    @State private var dimensioneLUT = 33
    @State private var nomeLUT = "Colors"
    @State private var documento: CubeDocument?
    @State private var documenti: [CubeDocument] = []
    @State private var mostraEsportaTutte = false
    @State private var documentoCDL: CDLDocument?
    @State private var mostraEsportaCDL = false
    @State private var scopeGrande = false
    /// Altezza del viewer scelta con la maniglia (0 = automatica). Resta memorizzata.
    @AppStorage("altezzaViewer") private var altezzaViewer: Double = 0
    @State private var altezzaInizio: CGFloat?
    @State private var schermoIntero = false
    /// Vista compatta: nasconde clip e nodi (Color) o la timeline (Edit) per lasciare spazio al video.
    @AppStorage("compatto") private var compatto = false
    @State private var benvenuto = false
    @State private var avviato = false
    @State private var nomeNuovoProgetto = ""
    @State private var chiediNomeProgetto = false
    @State private var chiediSalvataggio = false
    @State private var mostraMonitor = false
    @State private var mostraTrackpad = false

    var body: some View {
        GeometryReader { geo in
        let tot = geo.size.height
        let video: CGFloat = studio.eVideo ? 40 : 0
        VStack(spacing: 0) {
            switch pagina {
            case .media:
                barra
                PaginaMedia(studio: studio, apriLibreria: { mostraLibreria = true },
                            apriFile: { importaSoloLUT = false; mostraFile = true },
                            apriInColor: { pagina = .color })
            case .edit:
                barra
                // in Edit il viewer mostra il montaggio intero (con transizioni, titoli e musica)
                viewerRegolabile(tot, occupato: compatto ? 42 + 40 + 44 : 42 + 40 + 44 + 124 + 44 + 120, extra: compatto ? 9999 : 0) {
                    ZStack {
                        Color.black
                        VistaPlayer(player: studio.playerSequenza)
                        if studio.progetto.clips.isEmpty {
                            Text("Import clips from the Media page").font(.caption).foregroundStyle(Tema.testo2)
                        }
                        if let l = studio.lavoro {
                            VStack(spacing: 8) { ProgressView(); Text(l).font(.caption) }
                                .padding(14).background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.75)))
                        }
                    }
                }
                TrasportoSequenza(studio: studio)
                if !compatto { TimelineEdit(studio: studio) } else { Spacer(minLength: 0) }
            case .fusion:
                barra
                viewerRegolabile(tot, occupato: 42 + video + 38 + 140)
                if studio.eVideo { trasporto }
                barraNodo
                ScrollView { PannelloEffetti(studio: studio).padding(10) }
                    .frame(maxHeight: .infinity)
                    .background(Tema.sfondo)
            case .color:
                paginaColor
            case .deliver:
                barra
                viewerRegolabile(tot, occupato: 42 + video + 140)
                if studio.eVideo { trasporto }
                ScrollView { pannelloConsegna.padding(10) }
                    .frame(maxHeight: .infinity)
                    .background(Tema.sfondo)
            }
            BarraPagine(scelta: $pagina)
        }
        }
        .fullScreenCover(isPresented: $schermoIntero) { SchermoIntero(studio: studio, bypass: $bypass) }
        .sheet(isPresented: $mostraMonitor) {
            FoglioMonitor(studio: studio, apriTrackpad: {
                mostraMonitor = false
                Task { try? await Task.sleep(for: .milliseconds(450)); mostraTrackpad = true }
            })
        }
        // il trackpad si apre con un controller UIKit che blocca il puntatore di iOS (niente barretta bianca, clic diretti)
        .onChange(of: mostraTrackpad) { _, on in
            if on { PresentatoreTrackpad.mostra(studio) { mostraTrackpad = false } } else { PresentatoreTrackpad.nascondi() }
        }
        .overlay { if CommandLine.arguments.contains("-anteprimaMonitor") { AnteprimaMonitor(studio: studio) } }
        // monitor collegato (schermo esterno vero): l'interfaccia desktop è sul monitor e il telefono diventa trackpad e tastiera;
        // quando si stacca il telefono torna normale
        .onChange(of: studio.monitorCollegato) { _, on in
            if on { mostraMonitor = false; apriTrackpadAppena() } else { mostraTrackpad = false }
        }
        // con il monitor attaccato già all'avvio c'è la domanda "Bentornato": il trackpad si apre quando si chiude
        .onChange(of: benvenuto) { _, _ in apriTrackpadAppena() }
        .onChange(of: chiediSalvataggio) { _, _ in apriTrackpadAppena() }
        .onChange(of: chiediNomeProgetto) { _, _ in apriTrackpadAppena() }
        .modifier(RichiesteMonitor(studio: studio, mostraTrackpad: $mostraTrackpad, mostraMusicaFile: $mostraMusicaFile,
                                   mostraCartella: $mostraCartella, riapri: apriTrackpadAppena))
        .background(Color.clear.fileImporter(isPresented: $mostraMusicaFile, allowedContentTypes: [.audio, .mp3, .mpeg4Audio, .wav, .aiff, .movie, .item], allowsMultipleSelection: true) { r in
            if case let .success(urls) = r { Task { for u in urls { await studio.aggiungiMusica(u) }; await studio.aggiornaDurate() } }
        })
        // clic dal monitor esterno (trackpad): cambiano pagina e palette del telefono
        .onChange(of: studio.richiestaPagina) { _, p in if let p { pagina = p; studio.richiestaPagina = nil } }
        .onChange(of: studio.richiestaPalette) { _, p in if let p { pagina = .color; palette = p; studio.richiestaPalette = nil } }
        // all'apertura: continuare il progetto lasciato o iniziarne uno nuovo
        .task {
            GestoreMonitor.avvia()
            guard !avviato else { return }
            avviato = true
            studio.paginaMonitor = pagina
            studio.paletteMonitor = palette
            if !studio.progetto.vuoto, !CommandLine.arguments.contains("-anteprimaMonitor") {
                // il monitor si collega un attimo dopo l'avvio: se c'è, la domanda va sul monitor (e il telefono fa da trackpad)
                try? await Task.sleep(for: .milliseconds(1500))
                if studio.monitorCollegato { studio.benvenutoMonitor = true } else { benvenuto = true }
            }
        }
        .alert("Welcome back", isPresented: $benvenuto) {
            Button("Continue «\(studio.progetto.nome)»") {}
            Button("New project") { chiediSalvataggio = true }
        } message: {
            Text("Do you want to continue where you left off (\(studio.progetto.clips.count) clips) or start a new project?")
        }
        .alert("Save «\(studio.progetto.nome)»?", isPresented: $chiediSalvataggio) {
            Button("Yes, save") { nomeNuovoProgetto = ""; chiediNomeProgetto = true }
            Button("No", role: .destructive) { Task { await studio.nuovoProgetto(nome: "", salvaPrecedente: false); pagina = .media } }
            Button("Cancel", role: .cancel) { benvenuto = true }
        } message: {
            Text("Yes: it stays in Projects and you can reopen it whenever you want.\nNo: it is deleted along with the clips copied into the app and a new empty project opens (the photos and videos in your Library are not touched).")
        }
        .alert("New project", isPresented: $chiediNomeProgetto) {
            TextField("Name", text: $nomeNuovoProgetto)
            Button("Cancel", role: .cancel) {}
            Button("Create") { let n = nomeNuovoProgetto; Task { await studio.nuovoProgetto(nome: n); pagina = .media } }
        }
        // il monitor esterno evidenzia la palette aperta sul telefono
        .onChange(of: palette) { _, p in studio.paletteMonitor = p }
        .onChange(of: pagina) { vecchia, p in
            studio.inEdit = p == .edit
            studio.paginaMonitor = p
            // Fusion lavora sugli effetti di un nodo correttore
            if p == .fusion { studio.vaiACorrettore() }
            // Edit: la sequenza si ricostruisce con le correzioni fatte nel frattempo
            if p == .edit { studio.aggiornaSequenza(ritardo: 0) }
            if vecchia == .edit { studio.pausaSequenza() }
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .tint(Tema.accento)
        .photosPicker(isPresented: $mostraLibreria, selection: $mediaScelti, maxSelectionCount: 50,
                      matching: .any(of: [.images, .videos]), preferredItemEncoding: .current)
        .onChange(of: mediaScelti) { _, items in
            guard !items.isEmpty else { return }
            Task { await apri(items); mediaScelti = [] }
        }
        .onChange(of: studio.selezionato) { _, _ in
            switch studio.nodo.tipo {
            case .cst: palette = .cst
            case .lut: break
            case .correzione: if palette == .cst { palette = .primarie }
            }
        }
        .fileImporter(isPresented: $mostraFile, allowedContentTypes: importaSoloLUT ? [.cube, .cdl, .cc, .ccc, .data] : [.movie, .video, .image, .cube, .cdl, .cc, .ccc, .data],
                      allowsMultipleSelection: !importaSoloLUT) { r in
            if case let .success(urls) = r { Task { for u in urls { await studio.apriFile(u) } } }
        }
        .fileExporter(isPresented: $mostraEsporta, document: documento, contentType: .cube, defaultFilename: nomeLUT + ".cube") { r in
            if case let .failure(e) = r { studio.messaggio = e.localizedDescription }
        }
        .fileExporter(isPresented: $mostraEsportaTutte, documents: documenti, contentType: .cube) { r in
            if case let .failure(e) = r { studio.messaggio = e.localizedDescription }
        }
        .fileExporter(isPresented: $mostraEsportaCDL, document: documentoCDL, contentType: .cdl, defaultFilename: nomeLUT + ".cdl") { r in
            if case let .failure(e) = r { studio.messaggio = e.localizedDescription }
        }
        .alert(studio.messaggio ?? "", isPresented: Binding(get: { studio.messaggio != nil && !mostraTrackpad }, set: { if !$0 { studio.messaggio = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    /// Pagina Color: viewer, clip, nodi e palette (il layout di prima).
    private var paginaColor: some View {
        GeometryReader { g in
            if g.size.width > g.size.height {
                // orizzontale: come DaVinci, viewer, clip e nodi a sinistra, palette a destra
                HStack(spacing: 1) {
                    VStack(spacing: 1) {
                        barra
                        viewer
                        if studio.eVideo { trasporto }
                        if !compatto {
                            stripClip.frame(height: 58)
                            rigaNodi.frame(height: 84)
                        }
                        barraNodo
                    }
                    .frame(width: g.size.width * 0.58)
                    VStack(spacing: 1) {
                        BarraPalette(scelta: $palette, tocco: sceltaPalette)
                        pannello
                    }
                }
            } else {
                VStack(spacing: 1) {
                    barra
                    viewerRegolabile(g.size.height, occupato: 42 + (studio.eVideo ? 40 : 0) + (compatto ? 0 : 58 + 84) + 38 + 46 + 110, extra: compatto ? 142 : 0)
                    if studio.eVideo { trasporto }
                    if !compatto {
                        stripClip.frame(height: 58)
                        rigaNodi.frame(height: 84)
                    }
                    barraNodo
                    BarraPalette(scelta: $palette, tocco: sceltaPalette)
                    // il pannello prende lo spazio che il viewer lascia libero
                    pannello.frame(minHeight: 100, maxHeight: .infinity)
                }
            }
        }
    }

    // MARK: viewer regolabile

    /// Viewer ad altezza scelta dall'utente, con la maniglia sotto per allargarlo o stringerlo.
    /// `occupato` è lo spazio che serve al resto della pagina, così i comandi restano sempre visibili.
    private func viewerRegolabile(_ tot: CGFloat, occupato: CGFloat, extra: CGFloat = 0) -> some View {
        viewerRegolabile(tot, occupato: occupato, extra: extra) { viewer }
    }

    /// `extra`: spazio liberato dalla vista compatta, che va al video.
    private func viewerRegolabile<V: View>(_ tot: CGFloat, occupato: CGFloat, extra: CGFloat = 0, @ViewBuilder contenuto: () -> V) -> some View {
        let massimo = max(140, tot - occupato - 24)
        let automatica = min(max(tot * 0.3, 140), massimo)
        let base = altezzaViewer > 0 ? min(max(CGFloat(altezzaViewer), 120), massimo) : automatica
        let h = min(base + extra, massimo)
        return VStack(spacing: 0) {
            contenuto().frame(height: h).clipped()
            // maniglia: trascina per cambiare la grandezza, doppio tocco per tornare all'automatica
            ZStack {
                Tema.pannello
                Capsule().fill(altezzaInizio != nil ? Tema.accento : Color.white.opacity(0.35)).frame(width: 44, height: 5)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { altezzaViewer = 0 }
                    .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)   // globale: la maniglia si muove col dito
                        .onChanged { v in
                            if altezzaInizio == nil { altezzaInizio = h - extra }
                            altezzaViewer = Double(min(max((altezzaInizio ?? h) + v.translation.height, 120), massimo))
                        }
                        .onEnded { _ in altezzaInizio = nil })
                    .accessibilityLabel("Viewer size")
                // comprimi / espandi: nasconde clip e nodi (o la timeline) per vedere meglio il video
                HStack {
                    Spacer()
                    Button { withAnimation(.easeInOut(duration: 0.2)) { compatto.toggle() } } label: {
                        Label(compatto ? "Show" : "Collapse", systemImage: compatto ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 8).frame(height: 22)
                            .background(Capsule().fill(compatto ? Tema.accento : Tema.campo))
                            .foregroundStyle(compatto ? .black : .white)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 8)
                }
            }
            .frame(height: 24)
        }
    }

    /// Monitor collegato: apre il trackpad appena non c'è una domanda aperta (iOS non lo apre sopra un avviso).
    private func apriTrackpadAppena() {
        guard studio.monitorCollegato, !mostraTrackpad else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard studio.monitorCollegato, !mostraTrackpad, !benvenuto, !chiediSalvataggio, !chiediNomeProgetto, !mostraMonitor, !mostraMusicaFile, !mostraCartella else { return }
            mostraTrackpad = true
        }
    }

    private func apri(_ items: [PhotosPickerItem]) async {
        await studio.importaDaLibreria(items)
    }

    /// Dal CST o da una LUT, toccando Primarie, Curve… si passa a un nodo correttore (prima restava bloccato sul CST).
    private func sceltaPalette(_ p: Palette) {
        if ![.cst, .galleria, .consegna].contains(p) { studio.vaiACorrettore() }
    }

    // MARK: barra in alto

    private var barra: some View {
        HStack(spacing: 12) {
            Menu {
                // niente PhotosPicker dentro il Menu: su iOS spesso non si apre. Si apre dal modificatore .photosPicker
                Button { mostraLibreria = true } label: { Label("From Photo Library", systemImage: "photo.on.rectangle") }
                Button { importaSoloLUT = false; mostraFile = true } label: { Label("From Files (external SSD too)", systemImage: "folder") }
            } label: {
                Image(systemName: "photo.badge.plus").font(.system(size: 17))
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(studio.nomeClip).font(.caption.weight(.semibold)).lineLimit(1)
                Text(studio.dimensioni).font(.system(size: 9)).foregroundStyle(Tema.testo2).lineLimit(1)
            }
            Spacer()
            // annulla / ripeti
            Button { studio.annulla() } label: {
                Image(systemName: "arrow.uturn.backward").font(.system(size: 17, weight: .semibold))
            }
            .disabled(studio.passato.isEmpty)
            .accessibilityLabel("Cancel")
            Button { studio.ripeti() } label: {
                Image(systemName: "arrow.uturn.forward").font(.system(size: 17, weight: .semibold))
            }
            .disabled(studio.futuro.isEmpty)
            .accessibilityLabel("Redo")
            Menu {
                Picker("Scope", selection: $studio.scope) {
                    ForEach(TipoScope.allCases) { Text($0.rawValue).tag($0) }
                }
            } label: {
                Image(systemName: "waveform.path.ecg.rectangle").font(.system(size: 17))
            }
            // monitor esterno: arancione quando è collegato
            Button { mostraMonitor = true } label: {
                Image(systemName: "display").font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(studio.monitorCollegato ? Tema.accento : .white)
            }
            .accessibilityLabel("External monitor")
            etichetta("FC", attiva: studio.falsoColore) { studio.falsoColore.toggle() }
            etichetta("BYPASS", attiva: bypass) { bypass.toggle() }
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(Tema.pannello)
    }

    private func etichetta(_ t: String, attiva: Bool, _ azione: @escaping () -> Void) -> some View {
        Button(action: azione) {
            Text(t).font(.system(size: 10, weight: .bold))
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 4).fill(attiva ? Tema.accento : Tema.campo))
                .foregroundStyle(attiva ? .black : .white)
        }
    }

    // MARK: viewer

    private var viewer: some View {
        GeometryReader { g in
            ZStack {
                Color.black
                if studio.inRiproduzione {
                    VistaPlayer(player: studio.player)
                } else if let img = bypass ? studio.originale : studio.risultato {
                    Image(uiImage: img).resizable().scaledToFit()
                    if let s = studio.confronto, let still = Archivio.immagine("Stills", s.file) {
                        splitScreen(still, img.size, g.size)
                    }
                    sovrapposizioni(img.size, g.size)
                }
                if scopeGrande, let s = studio.immagineScope {
                    Image(uiImage: s).resizable().interpolation(.medium).scaledToFit()
                        .padding(8).background(Color.black.opacity(0.85))
                        .onTapGesture { scopeGrande = false }
                }
                if let l = studio.lavoro {
                    VStack(spacing: 8) { ProgressView(); Text(l).font(.caption) }
                        .padding(14).background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.75)))
                }
            }
            .contentShape(Rectangle())
            .overlay(alignment: .bottomTrailing) {
                Button { schermoIntero = true } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                        .foregroundStyle(.white)
                }
                .padding(8)
                .accessibilityLabel("Full screen")
            }
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                guard let img = studio.risultato else { return }
                let r = rettangolo(img.size, g.size)
                let p = CGPoint(x: (v.location.x - r.minX) / r.width, y: (v.location.y - r.minY) / r.height)
                guard (0...1).contains(p.x), (0...1).contains(p.y) else { return }
                if studio.contagocce != .nessuno {
                    studio.tocco(p)
                } else if palette == .finestre, studio.finestraCorrente.tipo != .nessuna, !studio.tracciando {
                    studio.spostaFinestra(SIMD2(Float(p.x), Float(p.y)))
                } else if studio.confronto != nil {
                    studio.tendina = p.x
                }
            })
        }
        .clipped()
    }

    private func rettangolo(_ img: CGSize, _ box: CGSize) -> CGRect {
        let k = min(box.width / img.width, box.height / img.height)
        let w = img.width * k, h = img.height * k
        return CGRect(x: (box.width - w) / 2, y: (box.height - h) / 2, width: w, height: h)
    }

    /// Split-screen con lo still: a sinistra della tendina lo still, a destra la clip attuale.
    private func splitScreen(_ still: UIImage, _ img: CGSize, _ box: CGSize) -> some View {
        let r = rettangolo(img, box)
        let x = r.minX + r.width * studio.tendina
        return ZStack {
            Image(uiImage: still).resizable().scaledToFill()
                .frame(width: r.width, height: r.height).clipped()
                .position(x: r.midX, y: r.midY)
                .mask(Rectangle().frame(width: max(0, x - r.minX), height: r.height).position(x: r.minX + (x - r.minX) / 2, y: r.midY))
            Rectangle().fill(Color.white).frame(width: 1.5, height: r.height).position(x: x, y: r.midY)
            Text("STILL").font(.system(size: 9, weight: .bold)).padding(3).background(Color.black.opacity(0.6))
                .position(x: r.minX + 24, y: r.minY + 12)
        }
        .allowsHitTesting(false)
    }

    /// Contorni delle finestre, come le maniglie della Power Window: la scelta in evidenza, le altre più tenui.
    @ViewBuilder
    private func sovrapposizioni(_ img: CGSize, _ box: CGSize) -> some View {
        if palette == .finestre, studio.nodo.tipo == .correzione {
            let r = rettangolo(img, box)
            // dove si trovano adesso (con il tracker) e il percorso fatto
            let tutte = studio.finestreVisibili
            ForEach(Array(tutte.enumerated()), id: \.offset) { i, f in
                if f.tipo != .nessuna {
                    if f.traccia.count > 1 { percorso(f.traccia, r, scelta: i == studio.finestraScelta) }
                    contorno(f, r, scelta: i == studio.finestraScelta, numero: i + 1)
                }
            }
        }
        if studio.contagocce != .nessuno {
            Text("Eyedropper active").font(.caption2.bold())
                .padding(4).background(Capsule().fill(Tema.accento)).foregroundStyle(.black)
                .frame(maxHeight: .infinity, alignment: .top).padding(.top, 6)
        }
    }

    /// Percorso del tracker: la linea che segue il centro della finestra, con un punto per l'inizio, la fine e il fotogramma attuale.
    private func percorso(_ traccia: [PuntoTraccia], _ r: CGRect, scelta: Bool) -> some View {
        func punto(_ c: SIMD2<Float>) -> CGPoint { CGPoint(x: r.minX + CGFloat(c.x) * r.width, y: r.minY + CGFloat(c.y) * r.height) }
        // con tracce lunghe basta un punto ogni tanto per disegnare la linea
        let salto = max(1, traccia.count / 400)
        let colore = scelta ? Tema.accento : Color.white
        return ZStack {
            Path { p in
                p.move(to: punto(traccia[0].centro))
                for i in stride(from: salto, to: traccia.count, by: salto) { p.addLine(to: punto(traccia[i].centro)) }
                p.addLine(to: punto(traccia[traccia.count - 1].centro))
            }
            .stroke(colore.opacity(scelta ? 0.85 : 0.35), style: StrokeStyle(lineWidth: scelta ? 1.5 : 1, lineCap: .round, lineJoin: .round))
            Circle().stroke(colore.opacity(0.8), lineWidth: 1).frame(width: 7, height: 7).position(punto(traccia[0].centro))
            Rectangle().stroke(colore.opacity(0.8), lineWidth: 1).frame(width: 7, height: 7).position(punto(traccia[traccia.count - 1].centro))
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func contorno(_ f: Finestra, _ r: CGRect, scelta: Bool, numero: Int) -> some View {
        let c = CGPoint(x: r.minX + CGFloat(f.centro.x) * r.width, y: r.minY + CGFloat(f.centro.y) * r.height)
        let lato = max(r.width, r.height)
        let opaco = scelta ? 0.9 : 0.4
        if f.tipo == .cerchio {
            let raggio = CGFloat(f.raggio) * lato
            Circle().stroke(Color.white.opacity(opaco), lineWidth: scelta ? 1.4 : 1)
                .frame(width: raggio * 2, height: raggio * 2).position(c)
            if scelta {
                Circle().stroke(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .frame(width: raggio * 2 * CGFloat(1 + f.morbidezza), height: raggio * 2 * CGFloat(1 + f.morbidezza)).position(c)
            }
        } else {
            Path { p in
                let a = CGFloat(f.angolo) * .pi / 180
                let d = CGPoint(x: -sin(a), y: -cos(a))
                p.move(to: CGPoint(x: c.x - d.x * lato, y: c.y - d.y * lato))
                p.addLine(to: CGPoint(x: c.x + d.x * lato, y: c.y + d.y * lato))
            }
            .stroke(Color.white.opacity(opaco), lineWidth: scelta ? 1.4 : 1)
        }
        Circle().fill(scelta ? Tema.accento : Color.white.opacity(0.5)).frame(width: 10, height: 10).position(c)
        Text("\(numero)").font(.system(size: 9, weight: .bold)).foregroundStyle(scelta ? Tema.accento : .white.opacity(0.7))
            .position(x: c.x + 10, y: c.y - 10)
    }

    // MARK: trasporto video con keyframe

    private var trasporto: some View {
        HStack(spacing: 8) {
            Button {
                Task { if studio.inRiproduzione { await studio.pausa() } else { await studio.play() } }
            } label: {
                Image(systemName: studio.inRiproduzione ? "pause.fill" : "play.fill").frame(width: 22)
            }
            Button { Task { await studio.vaiAlKeyframe(false) } } label: { Image(systemName: "chevron.left").font(.caption) }
                .disabled(studio.tempiKeyframe.isEmpty)
            Button { studio.alternaKeyframe() } label: {
                Image(systemName: studio.keyframeQui ? "diamond.fill" : "diamond").foregroundStyle(studio.keyframeQui ? Tema.accento : .white)
            }
            .accessibilityLabel("Node keyframes")
            Button { Task { await studio.vaiAlKeyframe(true) } } label: { Image(systemName: "chevron.right").font(.caption) }
                .disabled(studio.tempiKeyframe.isEmpty)
            ZStack {
                Slider(value: Binding(get: { studio.tempo }, set: { studio.tempo = $0 }), in: 0...max(studio.durata, 0.1)) { modifica in
                    if !modifica && !studio.inRiproduzione { Task { await studio.fotogramma(studio.tempo) } }
                }
                .disabled(studio.inRiproduzione)
                GeometryReader { g in
                    ForEach(studio.tempiKeyframe, id: \.self) { t in
                        Image(systemName: "diamond.fill").font(.system(size: 7)).foregroundStyle(Tema.accento)
                            .position(x: 12 + (g.size.width - 24) * CGFloat(t / max(studio.durata, 0.1)), y: 3)
                    }
                }
                .allowsHitTesting(false)
            }
            Text(timecode(studio.tempo)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Tema.testo2)
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(Tema.pannello)
    }

    private func timecode(_ t: Double) -> String {
        let f = Int((t * 25).rounded())
        return String(format: "%02d:%02d:%02d:%02d", f / 90000, f / 1500 % 60, f / 25 % 60, f % 25)
    }

    // MARK: clip (timeline)

    private var stripClip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(studio.progetto.clips.enumerated()), id: \.element.id) { i, c in
                    let attiva = c.id == studio.clipAttiva
                    VStack(spacing: 1) {
                        ZStack(alignment: .bottomTrailing) {
                            if let img = Archivio.immagine("Miniature", c.miniatura) {
                                Image(uiImage: img).resizable().scaledToFill()
                            } else {
                                Rectangle().fill(Tema.campo)
                            }
                            if c.video { Image(systemName: "video.fill").font(.system(size: 8)).padding(2) }
                        }
                        .frame(width: 70, height: 38).clipped()
                        Text(String(format: "%02d", i + 1)).font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(attiva ? Tema.accento : Tema.testo2)
                    }
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(attiva ? Tema.accento : .clear, lineWidth: 2))
                    .onTapGesture { Task { await studio.apriClip(c.id) } }
                    .contextMenu {
                        Button { studio.copiaCorrezione(c.id) } label: { Label("Copy grade", systemImage: "doc.on.doc") }
                        if studio.appunti != nil {
                            Button { Task { await studio.incollaCorrezione(su: c.id) } } label: { Label("Paste grade", systemImage: "doc.on.clipboard") }
                            Button { studio.incollaSuTutte() } label: { Label("Paste to all clips", systemImage: "square.on.square") }
                        }
                        Button(role: .destructive) { Task { await studio.eliminaClip(c.id) } } label: { Label("Remove from project", systemImage: "trash") }
                    }
                }
                if studio.progetto.clips.isEmpty {
                    Text("No clips: import photos or videos with the button at the top left.")
                        .font(.caption2).foregroundStyle(Tema.testo2)
                }
            }
            .padding(.horizontal, 8)
            .frame(maxHeight: .infinity)
        }
        .background(Tema.sfondo)
    }

    // MARK: nodi e scope

    private var rigaNodi: some View {
        HStack(spacing: 1) {
            GrafoNodi(studio: studio) { importaSoloLUT = true; mostraFile = true }
            if studio.scope != .nessuno, let s = studio.immagineScope {
                Image(uiImage: s).resizable().interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
                    .padding(4)
                    .background(Color.black)
                    .frame(maxWidth: studio.scope == .vettorscopio || studio.scope == .cie ? 90 : 170)
                    .onTapGesture { scopeGrande.toggle() }
            }
        }
    }

    /// Comandi del nodo selezionato sempre a vista (prima erano solo nel menu "tieni premuto").
    private var barraNodo: some View {
        let n = studio.nodo
        let i = studio.indice
        return HStack(spacing: 4) {
            Text(String(format: "%02d", i + 1)).font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(Tema.accento)
            Text(n.etichetta).font(.caption).lineLimit(1)
            Spacer(minLength: 4)
            bottoneNodo(n.attivo ? "eye" : "eye.slash", nil, attivo: !n.attivo) {   // solo icona: la barra resta su una riga
                studio.nodi[i].attivo.toggle()
            }
            if i > 0 {
                // collegamento al nodo prima: serie, parallelo o layer
                Menu {
                    ForEach(ModoNodo.allCases) { m in
                        Button { studio.nodi[i].modo = m } label: { Label(m.rawValue, systemImage: m.icona) }
                    }
                } label: {
                    Image(systemName: n.modo.icona).font(.system(size: 14))
                        .frame(minWidth: 36, minHeight: 30)
                        .background(RoundedRectangle(cornerRadius: 6).fill(n.modo == .serie ? Tema.campo : Tema.accento.opacity(0.25)))
                        .foregroundStyle(n.modo == .serie ? .white : Tema.accento)
                }
                .accessibilityLabel("Node connection")
            }
            bottoneNodo("arrow.left", nil) { studio.sposta(n.id, di: -1) }.disabled(i == 0)
            bottoneNodo("arrow.right", nil) { studio.sposta(n.id, di: 1) }.disabled(i == studio.nodi.count - 1)
            bottoneNodo("arrow.counterclockwise", nil) { studio.azzeraNodo() }
            bottoneNodo("trash", nil, distruttivo: true) { studio.elimina(n.id) }
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(Tema.pannello)
    }

    private func bottoneNodo(_ icona: String, _ testo: String?, attivo: Bool = false, distruttivo: Bool = false, _ azione: @escaping () -> Void) -> some View {
        Button(action: azione) {
            HStack(spacing: 4) {
                Image(systemName: icona).font(.system(size: 14))
                if let testo { Text(testo).font(.caption2.weight(.semibold)) }
            }
            .padding(.horizontal, 9).frame(minWidth: 36, minHeight: 30)
            .background(RoundedRectangle(cornerRadius: 6).fill(attivo ? Tema.accento.opacity(0.25) : Tema.campo))
            .foregroundStyle(distruttivo ? Color.red : attivo ? Tema.accento : .white)
        }
        .buttonStyle(.plain)
    }

    private var pannelloConsegna: some View {
        PannelloConsegna(studio: studio, nomeLUT: $nomeLUT, dimensioneLUT: $dimensioneLUT,
                         salvaLUT: {
                             let (doc, saltati) = studio.documentoLUT(size: dimensioneLUT, titolo: nomeLUT)
                             documento = doc
                             mostraEsporta = true
                             if saltati > 0 { studio.messaggio = "\(saltati) node(s) with masks or effects are not in the LUT." }
                         },
                         importaLUT: { importaSoloLUT = true; mostraFile = true },
                         salvaTutte: {
                             let (docs, saltati) = studio.lutTutteLeClip(size: dimensioneLUT)
                             documenti = docs
                             mostraEsportaTutte = true
                             if saltati > 0 { studio.messaggio = "\(saltati) node(s) with masks or effects are not in the LUTs." }
                         },
                         salvaCDL: {
                             let (doc, err) = studio.documentoCDL(nome: nomeLUT)
                             documentoCDL = doc
                             mostraEsportaCDL = true
                             if err > 0.02 { studio.messaggio = String(format: "The CDL is an approximation (average error %.1f%%): curves, Warper or secondaries can't be expressed in a CDL. Use the LUT for the exact grade.", err * 100) }
                         })
    }

    // MARK: pannello della palette

    private var pannello: some View {
        ScrollView {
            Group {
                if studio.nodo.tipo == .lut && ![.consegna, .galleria].contains(palette) {
                    PannelloLUTNodo(studio: studio)
                } else if studio.nodo.tipo == .cst && ![.consegna, .galleria].contains(palette) {
                    PannelloCST(studio: studio)
                } else {
                    switch palette {
                    case .primarie: PannelloPrimarie(studio: studio)
                    case .ai: PannelloAI(studio: studio)
                    case .hdr: PannelloHDR(studio: studio)
                    case .curve: PannelloCurve(studio: studio)
                    case .warper: PannelloWarper(studio: studio)
                    case .mixer: PannelloMixer(studio: studio)
                    case .qualificatore: PannelloQualificatore(studio: studio)
                    case .finestre: PannelloFinestre(studio: studio)
                    case .effetti: PannelloEffetti(studio: studio)
                    case .regolazioni: PannelloRegolazioni(studio: studio)
                    case .cst: PannelloCST(studio: studio)
                    case .galleria: PannelloGalleria(studio: studio)
                    case .consegna: pannelloConsegna
                    }
                }
            }
            .padding(10)
        }
        .background(Tema.sfondo)
    }
}

/// Riproduzione del video con la correzione applicata (la applica la video composition).
struct VistaPlayer: UIViewRepresentable {
    let player: AVPlayer
    final class Vista: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
    func makeUIView(context: Context) -> Vista {
        let v = Vista()
        v.playerLayer.videoGravity = .resizeAspect
        v.playerLayer.player = player
        v.backgroundColor = .black
        return v
    }
    func updateUIView(_ v: Vista, context: Context) { v.playerLayer.player = player }
}


/// Richieste che arrivano dal monitor e si fanno sul telefono (iOS mostra le sue finestre solo qui):
/// il trackpad si chiude un attimo, si sceglie, poi torna.
private struct RichiesteMonitor: ViewModifier {
    @ObservedObject var studio: Studio
    @Binding var mostraTrackpad: Bool
    @Binding var mostraMusicaFile: Bool
    @Binding var mostraCartella: Bool
    var riapri: () -> Void
    @State private var rinomina: UUID?
    @State private var nuovoNome = ""

    func body(content: Content) -> some View {
        content
        // rinominare un progetto dal monitor: il nome si scrive qui sul telefono
        .onChange(of: studio.richiestaRinomina) { _, id in
            guard let id else { return }
            studio.richiestaRinomina = nil
            nuovoNome = id == studio.progetto.id ? studio.progetto.nome : (Archivio.caricaArchiviato(id)?.nome ?? "")
            mostraTrackpad = false
            Task { try? await Task.sleep(for: .milliseconds(500)); rinomina = id }
        }
        .alert("Rename project", isPresented: Binding(get: { rinomina != nil }, set: { if !$0 { rinomina = nil; riapri() } })) {
            TextField("Name", text: $nuovoNome)
            Button("Cancel", role: .cancel) {}
            Button("OK") { if let id = rinomina { studio.rinominaProgetto(id, nuovoNome) } }
        }
        // musica scelta dal monitor: il trackpad si chiude un attimo, si sceglie il file sul telefono, poi torna
        .onChange(of: studio.richiestaFileMusica) { _, on in
            guard on else { return }
            studio.richiestaFileMusica = false
            mostraTrackpad = false
            Task { try? await Task.sleep(for: .milliseconds(500)); mostraMusicaFile = true }
        }
        .onChange(of: mostraMusicaFile) { _, on in
            if on { GestoreMonitor.sospendiCompagno() }
            else { GestoreMonitor.riprendiCompagno(); riapri() }
        }
        .onChange(of: studio.richiestaCartella) { _, on in
            guard on else { return }
            studio.richiestaCartella = false
            mostraTrackpad = false
            Task { try? await Task.sleep(for: .milliseconds(500)); mostraCartella = true }
        }
        .onChange(of: mostraCartella) { _, on in
            // mentre si sceglie, il monitor duplica il telefono: la finestra dei file si vede anche lì
            if on { GestoreMonitor.sospendiCompagno() }
            else { GestoreMonitor.riprendiCompagno(); riapri() }
        }
        .background(Color.clear.fileImporter(isPresented: $mostraCartella, allowedContentTypes: [.folder]) { r in
            if case let .success(u) = r { CartelleCollegate.condivise.aggiungi(u) }
        })
    }
}
