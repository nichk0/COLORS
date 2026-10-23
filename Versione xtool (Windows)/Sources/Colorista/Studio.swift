import SwiftUI
import CoreImage
import UIKit
import AVFoundation
import Photos
import PhotosUI
import _PhotosUI_SwiftUI
import UniformTypeIdentifiers

/// Ciò che serve al video per correggere i fotogrammi mentre l'utente regola (letto da un altro thread).
final class StatoVideo: @unchecked Sendable {
    private let lock = NSLock()
    private var _nodi: [Nodo] = []
    private var _spazio = CGColorSpace(name: CGColorSpace.itur_709)!
    func imposta(_ n: [Nodo], _ s: CGColorSpace) { lock.lock(); _nodi = n; _spazio = s; lock.unlock() }
    func leggi() -> ([Nodo], CGColorSpace) { lock.lock(); defer { lock.unlock() }; return (_nodi, _spazio) }

    /// Con `uscita` il fotogramma corretto viene portato a quella misura (formati social): riempiendo (ritaglio centrato) o con bande nere.
    func composizione(_ a: AVAsset, size: Int, uscita: CGSize? = nil, riempi: Bool = true) async throws -> AVVideoComposition {
        let comp = try await AVMutableVideoComposition.videoComposition(with: a, applyingCIFiltersWithHandler: { [self] req in
            let (n, s) = leggi()
            let c = Fabbrica.condivisa.catena(nodi: n, tempo: req.compositionTime.seconds, size: size, spazio: s)
            var img = c.applica(req.sourceImage)
            if let uscita { img = FormatoSocial.adatta(img, a: uscita, riempi: riempi) }
            req.finish(with: img, context: nil)
        })
        if let uscita { comp.renderSize = uscita }
        return comp
    }
}

enum Contagocce { case nessuno, bianco, qualificatore, curva }
enum FormatoVideo: String, CaseIterable, Identifiable { case hevc = "HEVC 10 bit", prores = "ProRes 422 HQ"; var id: String { rawValue } }

/// Stato dell'app: progetto, clip attiva, nodi, anteprima, scope, galleria ed esportazioni.
@MainActor
final class Studio: ObservableObject {
    /// Uno solo per tutta l'app: lo usano il telefono e il monitor esterno.
    static let condiviso = Studio()
    /// Monitor esterno collegato (mostra l'interfaccia desktop).
    @Published var monitorCollegato = false
    /// Il telefono è sulla pagina Edit: il monitor mostra il montaggio invece della clip.
    @Published var inEdit = false
    /// Pagina e palette aperte sul telefono (il monitor le evidenzia).
    @Published var paginaMonitor: Pagina = .color
    @Published var paletteMonitor: Palette = .primarie
    /// Come si presenta il monitor esterno (scelto dal pulsante Monitor, ricordato tra un avvio e l'altro).
    @Published var monitor = ImpostazioniMonitor.carica() { didSet { monitor.salva() } }
    /// Trackpad: puntatore sul monitor (in punti del monitor; nil = nascosto) e zona sotto il puntatore.
    /// Stanno fuori da Studio: muovere il puntatore non deve ridisegnare tutta l'app (andava a scatti).
    var puntatore: CGPoint? {
        get { PuntoMonitor.condiviso.punto }
        set { PuntoMonitor.condiviso.punto = newValue }
    }
    var zonaSotto: String? {
        get { ZonaSottoMonitor.condivisa.id }
        set { if ZonaSottoMonitor.condivisa.id != newValue { ZonaSottoMonitor.condivisa.id = newValue } }
    }
    /// Un clic sul monitor chiede al telefono di cambiare pagina o palette.
    @Published var richiestaPagina: Pagina?
    @Published var richiestaPalette: Palette?
    /// Lo schermo del telefono viene duplicato su un monitor o via AirPlay (o registrato).
    @Published var duplicazione = false

    // progetto
    @Published private(set) var progetto = Progetto()
    @Published private(set) var clipAttiva: UUID?
    @Published var appunti: [Nodo]?

    // nodi della clip attiva
    @Published var nodi: [Nodo] = [Nodo(tipo: .correzione)] { didSet { registra(oldValue); cambiato() } }
    @Published var selezionato: UUID { didSet { if selezionato != oldValue { finestraScelta = 0 } } }

    // viewer
    @Published private(set) var originale: UIImage?
    @Published private(set) var risultato: UIImage?
    @Published var scope: TipoScope = .parade { didSet { aggiornaScope() } }
    @Published private(set) var immagineScope: UIImage?
    @Published var mostraMaschera = false { didSet { aggiorna() } }
    /// Monitor esterno: il filmato a tutto schermo.
    @Published var schermoInteroMonitor = false
    // pagina Deliver: impostazioni di render e coda dei lavori (Render.swift)
    @Published var impostazioniRender = ImpostazioniRender()
    @Published var codaRender: [LavoroRender] = []
    @Published var renderInCorso = false
    /// Monitor, pagina Edit: il Media Pool mostra la musica invece delle clip.
    @Published var poolMusica = false
    /// Il monitor chiede al telefono di aprire la scelta di un file musicale (File di iOS).
    @Published var richiestaFileMusica = false
    /// Il monitor chiede al telefono di collegare una cartella o una chiavetta (la sceglie iOS, una volta).
    @Published var richiestaCartella = false
    /// Il monitor chiede di rinominare un progetto: il nome si scrive sul telefono.
    @Published var richiestaRinomina: UUID?
    /// All'avvio col monitor collegato la domanda "Bentornato" compare sul monitor (si risponde col mouse).
    @Published var benvenutoMonitor = false
    /// Testo da scrivere dal monitor (rinomina, nome del file…): la finestra è sul monitor, si scrive con la tastiera del telefono.
    @Published var testoMonitor: TestoMonitor?
    /// iOS sta mostrando sul telefono una sua finestra (scelta dei file): il monitor lo dice.
    @Published var sceltaSulTelefono: String?
    /// Vista della maschera: false = trasparente (immagine corretta, fuori grigio), true = solo bianco e nero.
    @Published var mascheraBN = UserDefaults.standard.bool(forKey: "mascheraBN") {
        didSet { UserDefaults.standard.set(mascheraBN, forKey: "mascheraBN"); aggiorna() }
    }
    @Published var falsoColore = false { didSet { aggiorna() } }
    /// Ultimo colore preso col contagocce (per mostrarlo): colore 0…1 e cosa ci si è fatto.
    @Published var colorePreso: (colore: SIMD3<Float>, uso: String)?
    @Published var contagocce: Contagocce = .nessuno { didSet { if contagocce != oldValue { GestoreMonitor.scrivi("contagocce: \(contagocce)") } } }
    /// Curva su cui lavora il contagocce delle curve.
    var curvaContagocce: TipoCurva?
    @Published var confronto: Still?
    @Published var tendina: CGFloat = 0.5
    @Published var messaggio: String?
    @Published private(set) var nomeClip = "Immagine di prova"
    @Published private(set) var dimensioni = ""
    @Published private(set) var lavoro: String?     // operazione lunga in corso (export, tracker…)

    // video
    @Published private(set) var eVideo = false
    @Published var tempo: Double = 0
    @Published private(set) var durata: Double = 0
    @Published private(set) var inRiproduzione = false
    let player = AVPlayer()
    private var asset: AVURLAsset?
    private(set) var fpsClip: Double = 25
    private var generatore: AVAssetImageGenerator?
    private var osservatoreTempo: Any?
    let statoVideo = StatoVideo()

    private var sorgente: CIImage?
    private var ultimaUscita: CIImage?
    private var completa: UIImage?
    private var spazio = CGColorSpace(name: CGColorSpace.sRGB)!
    private let contesto = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .cacheIntermediates: false])
    private var salvataggio: Task<Void, Never>?
    private var caricando = false

    // annulla / ripeti
    @Published private(set) var passato: [[Nodo]] = []
    @Published private(set) var futuro: [[Nodo]] = []
    private var ultimaModifica = Date.distantPast
    private var annullando = false

    nonisolated static let lutAnteprima = 33
    /// Dimensione per foto e video finali (Core Image regge fino a 64).
    nonisolated static let lutFinale = 64

    init() {
        let primo = Nodo(tipo: .correzione)
        selezionato = primo.id
        // prima il progetto da disco, e la preparazione dei nodi non deve far partire un salvataggio
        // (prima salvava il progetto ancora vuoto sopra quello vero)
        progetto = Archivio.carica()
        caricando = true
        nodi = [primo]
        caricando = false
        if let id = progetto.clipAttiva ?? progetto.clips.first?.id {
            Task { await apriClip(id) }
        } else {
            mostraFoto(TestChart.immagine(), nome: "Immagine di prova")
        }
        azzeraCronologia()   // l'impostazione iniziale dei nodi non è un passo da annullare
        aggiornaElencoProgetti()
    }

    // MARK: nodi

    var indice: Int { nodi.firstIndex { $0.id == selezionato } ?? 0 }

    /// Nodo selezionato. Se ha keyframe, ogni modifica crea o aggiorna il keyframe al tempo corrente.
    var nodo: Nodo {
        get { nodi[indice] }
        set {
            var n = newValue
            if eVideo, !n.keyframes.isEmpty, n.grade != nodi[indice].grade {
                if let k = n.keyframes.firstIndex(where: { abs($0.tempo - tempo) < 0.04 }) { n.keyframes[k].grade = n.grade }
                else { n.keyframes.append(KeyframeGrade(tempo: tempo, grade: n.grade)); n.keyframes.sort { $0.tempo < $1.tempo } }
            }
            nodi[indice] = n
        }
    }

    // MARK: finestre del nodo

    /// Finestra che si sta modificando: 0 = la prima (quella col tracker), poi le extra.
    @Published var finestraScelta = 0

    var numeroFinestre: Int { 1 + nodo.finestreExtra.count }
    private var sceltaValida: Int { min(max(finestraScelta, 0), numeroFinestre - 1) }

    var finestraCorrente: Finestra {
        get { sceltaValida == 0 ? nodo.finestra : nodo.finestreExtra[sceltaValida - 1] }
        set {
            let i = sceltaValida
            if i == 0 { nodo.finestra = newValue } else { nodo.finestreExtra[i - 1] = newValue }
        }
    }

    /// Nuova finestra (cerchio al centro) e la si seleziona.
    func aggiungiFinestra() {
        var f = Finestra()
        f.tipo = .cerchio
        if nodo.finestra.tipo == .nessuna { nodo.finestra = f; finestraScelta = 0; return }
        nodo.finestreExtra.append(f)
        finestraScelta = numeroFinestre - 1
    }

    func togliFinestra() {
        let i = sceltaValida
        if i == 0 {
            // la seconda finestra (con la sua traccia) prende il posto della prima
            if nodo.finestreExtra.isEmpty { nodo.finestra = Finestra() }
            else { nodo.finestra = nodo.finestreExtra.removeFirst() }
        } else {
            nodo.finestreExtra.remove(at: i - 1)
        }
        finestraScelta = max(0, i - 1)
    }

    func aggiungi(_ tipo: Nodo.Tipo, lut: CubeLUT? = nil, nome: String = "") {
        var n = Nodo(tipo: tipo)
        n.lut = lut; n.nomeLUT = nome
        // un CST va all'inizio della catena, come si fa in DaVinci con il footage Log
        if tipo == .cst { nodi.insert(n, at: 0) } else { nodi.insert(n, at: indice + 1) }
        selezionato = n.id
    }

    func elimina(_ id: UUID) {
        guard let i = nodi.firstIndex(where: { $0.id == id }) else { return }
        // la catena non resta mai vuota: se era l'ultimo nodo, al suo posto nasce un correttore pulito
        if nodi.count == 1 { nodi = [Nodo(tipo: .correzione)]; selezionato = nodi[0].id; return }
        nodi.remove(at: i)
        selezionato = nodi[min(i, nodi.count - 1)].id
    }

    /// Seleziona un nodo correttore (il primo dopo quello attuale, altrimenti il più vicino prima);
    /// se non ce ne sono ne aggiunge uno. Serve quando dal CST o da una LUT si passa a Primarie, Curve…
    func vaiACorrettore() {
        guard nodo.tipo != .correzione else { return }
        let i = indice
        if let n = nodi[(i + 1)...].first(where: { $0.tipo == .correzione }) ?? nodi[..<i].last(where: { $0.tipo == .correzione }) {
            selezionato = n.id
        } else {
            aggiungi(.correzione)
        }
    }

    func sposta(_ id: UUID, di passo: Int) {
        guard let i = nodi.firstIndex(where: { $0.id == id }) else { return }
        let j = i + passo
        guard j >= 0, j < nodi.count else { return }
        nodi.swapAt(i, j)
    }

    func azzeraNodo() {
        var n = Nodo(tipo: nodo.tipo)
        n.id = nodo.id; n.lut = nodo.lut; n.nomeLUT = nodo.nomeLUT
        nodi[indice] = n
    }

    // MARK: keyframe

    var tempiKeyframe: [Double] { nodo.keyframes.map(\.tempo) }
    var keyframeQui: Bool { nodo.keyframes.contains { abs($0.tempo - tempo) < 0.04 } }

    func alternaKeyframe() {
        var n = nodi[indice]
        if let k = n.keyframes.firstIndex(where: { abs($0.tempo - tempo) < 0.04 }) {
            n.keyframes.remove(at: k)
        } else {
            n.keyframes.append(KeyframeGrade(tempo: tempo, grade: n.grade))
            n.keyframes.sort { $0.tempo < $1.tempo }
        }
        nodi[indice] = n
    }

    func vaiAlKeyframe(_ avanti: Bool) async {
        let t = avanti ? tempiKeyframe.first { $0 > tempo + 0.04 } : tempiKeyframe.last { $0 < tempo - 0.04 }
        if let t { await fotogramma(t) }
    }

    // MARK: catena e anteprima

    func catena(size: Int = Studio.lutAnteprima, tempo t: Double? = nil, keyframe: Bool = true) -> Catena {
        Fabbrica.condivisa.catena(nodi: nodi, tempo: t, keyframe: keyframe, size: size, spazio: spazio)
    }

    private var passoSelezionato: Int? {
        guard nodo.attivo else { return nil }
        return nodi.prefix(indice).filter(\.attivo).count
    }

    // MARK: annulla / ripeti

    /// Salva lo stato precedente. Le modifiche ravvicinate (un trascinamento di ruota o cursore)
    /// diventano un solo passo: se ne registra uno nuovo solo dopo una pausa.
    private func registra(_ vecchi: [Nodo]) {
        guard !annullando, !caricando, vecchi != nodi else { return }
        if Date().timeIntervalSince(ultimaModifica) > 0.6 {
            passato.append(vecchi)
            if passato.count > 80 { passato.removeFirst() }
            futuro.removeAll()
        }
        ultimaModifica = Date()
    }

    func annulla() {
        guard let p = passato.popLast() else { return }
        futuro.append(nodi)
        ripristina(p)
    }

    func ripeti() {
        guard let f = futuro.popLast() else { return }
        passato.append(nodi)
        ripristina(f)
    }

    private func ripristina(_ n: [Nodo]) {
        annullando = true
        nodi = n
        annullando = false
        ultimaModifica = .distantPast
        if !nodi.contains(where: { $0.id == selezionato }) { selezionato = nodi[0].id }
    }

    /// Nuova clip: la cronologia della precedente non vale più.
    private func azzeraCronologia() { passato = []; futuro = []; ultimaModifica = .distantPast }

    private func cambiato() {
        aggiorna()
        programmaSalvataggio()
    }

    func aggiorna() {
        statoVideo.imposta(nodi, spazio)
        guard !inRiproduzione, let src = sorgente else { return }
        // le finestre tracciate si vedono dove sono in questo fotogramma
        let c = catena(tempo: eVideo ? tempo : nil, keyframe: false)
        let m = mostraMaschera && nodo.haMaschera ? passoSelezionato : nil
        var out = c.applica(src, mascheraDi: m, trasparente: !mascheraBN)
        ultimaUscita = out
        if falsoColore && m == nil { out = Catena(passi: [], spazio: spazio).cubo(out, FalsoColore.cubo, FalsoColore.size) }
        risultato = immagine(out)
        aggiornaScope()
    }

    private func immagine(_ ci: CIImage) -> UIImage? {
        guard let cg = contesto.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: spazio) else { return nil }
        return UIImage(cgImage: cg)
    }

    func aggiornaScope() {
        guard scope != .nessuno, let out = ultimaUscita else { immagineScope = nil; return }
        let (px, w, h) = pixel(out, larghezza: 256)
        immagineScope = Scope.disegna(scope, pixel: px, larghezza: w, altezza: h)
    }

    private func pixel(_ img: CIImage, larghezza w: Int) -> ([UInt8], Int, Int) {
        let e = img.extent, k = CGFloat(w) / e.width
        let piccola = img.transformed(by: CGAffineTransform(scaleX: k, y: k))
        let h = max(1, Int((e.height * k).rounded()))
        var px = [UInt8](repeating: 0, count: w * h * 4)
        contesto.render(piccola, toBitmap: &px, rowBytes: w * 4, bounds: CGRect(x: piccola.extent.minX, y: piccola.extent.minY, width: CGFloat(w), height: CGFloat(h)), format: .RGBA8, colorSpace: spazio)
        return (px, w, h)
    }

    // MARK: contagocce e automatismi

    /// Tocco sull'anteprima (coordinate 0…1, y verso il basso).
    func tocco(_ p: CGPoint) {
        GestoreMonitor.scrivi("contagocce \(contagocce) in \(String(format: "%.2f,%.2f", p.x, p.y)), immagine \(sorgente == nil ? "assente" : "ok")")
        guard contagocce != .nessuno, let src = sorgente else { return }
        let ingresso = catena().applica(src, finoA: nodi.prefix(indice).filter(\.attivo).count)
        guard let c = media(ingresso, p) else { GestoreMonitor.scrivi("contagocce: colore non letto"); return }
        let usi: [Contagocce: String] = [.bianco: "bilanciamento del bianco", .qualificatore: "qualificatore", .curva: "curva"]
        colorePreso = (c, usi[contagocce] ?? "")
        GestoreMonitor.scrivi("contagocce: preso R \(Int(c.x * 255)) G \(Int(c.y * 255)) B \(Int(c.z * 255))")
        switch contagocce {
        case .bianco:
            let l = (c * Grade.lumaRec709).sum()
            let k = SIMD3<Float>(repeating: l) / SIMD3(max(c.x, 0.002), max(c.y, 0.002), max(c.z, 0.002))
            nodo.grade.bilanciamento = limita(k, SIMD3(repeating: 0.25), SIMD3(repeating: 4))
        case .qualificatore:
            nodo.qualificatore.centra(su: c)
        case .curva:
            // contagocce delle curve: tre punti sul colore toccato (tinta, luminanza o saturazione)
            if let tipo = curvaContagocce, let kp = tipo.curva {
                let hsv = Colore.hsv(limita(c, .zero, SIMD3(repeating: 1)))
                let x: Float
                switch tipo.asse {
                case .tinta: x = hsv.x
                case .luminanza: x = min(max((c * Grade.lumaRec709).sum(), 0), 1)
                case .saturazione: x = hsv.y
                }
                nodo.grade[keyPath: kp].aggiungiTre(x, periodica: tipo.diTinta)
            }
        case .nessuno: break
        }
        contagocce = .nessuno
    }

    private func media(_ img: CIImage, _ p: CGPoint) -> SIMD3<Float>? {
        let e = img.extent
        let x = (e.minX + p.x * e.width - 2).rounded(.down), y = (e.minY + (1 - p.y) * e.height - 2).rounded(.down)
        var px = [Float](repeating: 0, count: 5 * 5 * 4)
        contesto.render(img, toBitmap: &px, rowBytes: 5 * 16, bounds: CGRect(x: x, y: y, width: 5, height: 5), format: .RGBAf, colorSpace: spazio)
        var s = SIMD3<Float>.zero
        for i in 0..<25 { s += SIMD3(px[i * 4], px[i * 4 + 1], px[i * 4 + 2]) }
        return s / 25
    }

    /// Bilanciamento automatico (pulsante "A"): nero e bianco di ogni canale portati agli estremi.
    func autoBilancia() {
        guard let src = sorgente else { return }
        let ingresso = catena().applica(src, finoA: nodi.prefix(indice).filter(\.attivo).count)
        let (px, w, h) = pixel(ingresso, larghezza: 160)
        var canali = [[UInt8]](repeating: [], count: 3)
        for i in 0..<(w * h) { for k in 0..<3 { canali[k].append(px[i * 4 + k]) } }
        var nero = SIMD3<Float>.zero, bianco = SIMD3<Float>(repeating: 1)
        for k in 0..<3 {
            let s = canali[k].sorted()
            guard !s.isEmpty else { continue }
            nero[k] = Float(s[Int(Float(s.count - 1) * 0.005)]) / 255
            bianco[k] = Float(s[Int(Float(s.count - 1) * 0.995)]) / 255
        }
        let gamma = bianco - nero
        guard gamma.min() > 0.05 else { messaggio = "Immagine troppo uniforme per il bilanciamento automatico."; return }
        nodo.grade.nero = nero
        nodo.grade.bilanciamento = SIMD3(repeating: 1) / gamma
    }

    // MARK: AI

    /// Auto colore AI: analizza l'immagine all'uscita del nodo selezionato e aggiunge dopo un nodo "Auto AI".
    func autoColoreAI() {
        guard let src = sorgente else { return }
        // se il nodo selezionato è già "Auto AI" lo si ricalcola (sull'immagine che gli arriva) invece di aggiungerne un altro
        let rifai = nodo.tipo == .correzione && nodo.nome == "Auto AI"
        let ingresso = catena().applica(src, finoA: nodi.prefix(rifai ? indice : indice + 1).filter(\.attivo).count)
        let k = 640 / max(ingresso.extent.width, ingresso.extent.height)
        let piccola = ingresso.transformed(by: CGAffineTransform(scaleX: min(k, 1), y: min(k, 1)))
        let g = AutoColore.grade(per: piccola, contesto: contesto, spazio: spazio)
        guard AutoColore.modifiche(g) > 0 else { messaggio = "L'AI non trova niente da correggere: l'immagine è già bilanciata."; return }
        if rifai { nodi[indice].grade = g; return }
        var n = Nodo(tipo: .correzione)
        n.nome = "Auto AI"
        n.grade = g
        nodi.insert(n, at: min(indice + 1, nodi.count))
        selezionato = n.id
    }

    /// Look descritto a parole (Apple Intelligence): aggiunge il nodo dopo quello selezionato.
    func lookDaParole(_ testo: String) async {
        let t = testo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        lavoro = "L'AI sta creando il look…"
        defer { lavoro = nil }
        do {
            var n = try await LookAParole.nodo(per: t)
            n.id = UUID()
            nodi.insert(n, at: min(indice + 1, nodi.count))
            selezionato = n.id
        } catch {
            messaggio = "Non riesco a creare il look: \(error.localizedDescription)"
        }
    }

    // MARK: look pronti

    /// Aggiunge il look come nodo dopo quello selezionato.
    func applicaLook(_ l: Look) {
        var n = l.nodo
        n.id = UUID()
        nodi.insert(n, at: min(indice + 1, nodi.count))
        selezionato = n.id
    }

    /// Anteprima piccola del look sull'immagine attuale (per i riquadri della palette).
    func anteprimaLook(_ l: Look) -> UIImage? {
        guard let src = sorgente else { return nil }
        let k = 160 / max(src.extent.width, src.extent.height)
        let piccola = src.transformed(by: CGAffineTransform(scaleX: k, y: k))
        let base = Fabbrica.condivisa.catena(nodi: nodi, tempo: nil, size: 17, spazio: spazio).applica(piccola)
        let conLook = Fabbrica.condivisa.catena(nodi: [l.nodo], tempo: nil, size: 17, spazio: spazio).applica(base)
        return immagine(conLook)
    }

    // MARK: Color Match

    /// Media e deviazione di ogni canale (su un'immagine rimpicciolita).
    private func statistiche(_ img: CIImage) -> (media: SIMD3<Float>, dev: SIMD3<Float>) {
        let (px, w, h) = pixel(img, larghezza: 160)
        let n = Float(w * h)
        var somma = SIMD3<Float>.zero, quad = SIMD3<Float>.zero
        for i in 0..<(w * h) {
            let c = SIMD3(Float(px[i * 4]), Float(px[i * 4 + 1]), Float(px[i * 4 + 2])) / 255
            somma += c; quad += c * c
        }
        let m = somma / n
        let v = quad / n - m * m
        return (m, SIMD3(sqrt(max(v.x, 1e-6)), sqrt(max(v.y, 1e-6)), sqrt(max(v.z, 1e-6))))
    }

    /// Porta i colori dell'immagine attuale verso quelli di `riferimento` con un nodo "Color Match" (livelli e bilanciamento per canale).
    func colorMatch(verso riferimento: CIImage, nome: String) {
        guard let src = sorgente else { return }
        let ingresso = catena().applica(src, finoA: nodi.prefix(indice + 1).filter(\.attivo).count)
        let a = statistiche(ingresso), b = statistiche(riferimento)
        // y = (x − nero) · k  con  k = dev_rif / dev_att  e  nero = media_att − media_rif / k
        let k = limita(b.dev / a.dev, SIMD3(repeating: 0.4), SIMD3(repeating: 2.5))
        let nero = a.media - b.media / k
        var n = Nodo(tipo: .correzione)
        n.nome = "Color Match"
        n.grade.bilanciamento = k
        n.grade.nero = nero
        nodi.insert(n, at: min(indice + 1, nodi.count))
        selezionato = n.id
        messaggio = "Colori abbinati a \(nome). Il nodo \"Color Match\" si può spegnere o ritoccare."
    }

    func colorMatch(still s: Still) {
        guard let ui = Archivio.immagine("Stills", s.file), let cg = ui.cgImage else { return }
        colorMatch(verso: CIImage(cgImage: cg), nome: "«\(s.nome)»")
    }

    /// Usa come riferimento un'altra clip del progetto, con la sua correzione.
    func colorMatch(clip id: UUID) async {
        salvaNodiNellaClip()
        guard let c = progetto.clips.first(where: { $0.id == id }) else { return }
        let url = Archivio.url("Media", c.file)
        var img: CIImage?
        var tempoRif: Double?
        var spazioRif = CGColorSpace(name: CGColorSpace.sRGB)!
        if c.video {
            let g = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            g.appliesPreferredTrackTransform = true
            g.maximumSize = CGSize(width: 480, height: 480)
            let m = c.taglio
            let t = m.inizio + ((m.fine ?? (m.inizio + 2)) - m.inizio) / 2
            if let (cg, _) = try? await g.image(at: CMTime(seconds: t, preferredTimescale: 600)) { img = CIImage(cgImage: cg) }
            tempoRif = t
            spazioRif = CGColorSpace(name: CGColorSpace.itur_709)!
        } else if let ui = UIImage(contentsOfFile: url.path)?.ridotta(lato: 480), let cg = ui.cgImage {
            img = CIImage(cgImage: cg)
        }
        guard let img else { messaggio = "Non riesco a leggere la clip di riferimento."; return }
        let corretta = Fabbrica.condivisa.catena(nodi: c.nodi, tempo: tempoRif, size: 33, spazio: spazioRif).applica(img)
        colorMatch(verso: corretta, nome: "«\(c.nome)»")
    }

    // MARK: clip

    var clipCorrente: Clip? { progetto.clips.first { $0.id == clipAttiva } }

    private func salvaNodiNellaClip() {
        guard let id = clipAttiva, let i = progetto.clips.firstIndex(where: { $0.id == id }) else { return }
        progetto.clips[i].nodi = nodi
    }

    private func programmaSalvataggio() {
        guard !caricando else { return }
        salvaNodiNellaClip()
        salvataggio?.cancel()
        salvataggio = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, let self else { return }
            self.salvaNodiNellaClip()
            Archivio.salva(self.progetto)   // il progetto di adesso, non una copia di 0,7 s prima
        }
    }

    func apriClip(_ id: UUID) async {
        salvaNodiNellaClip()
        guard let c = progetto.clips.first(where: { $0.id == id }) else { return }
        clipAttiva = id
        progetto.clipAttiva = id
        caricando = true
        nodi = c.nodi.isEmpty ? [Nodo(tipo: .correzione)] : c.nodi
        selezionato = nodi[0].id
        caricando = false
        azzeraCronologia()
        confronto = nil
        let url = Archivio.url("Media", c.file)
        if c.video {
            await caricaVideo(url, nome: c.nome)
        } else if let ui = UIImage(contentsOfFile: url.path) {
            mostraFoto(ui, nome: c.nome)
        }
        Archivio.salva(progetto)
    }

    /// Aggiunge al progetto una clip (file già copiato in Media).
    private func aggiungiClip(file: String, nome: String, video: Bool) async {
        var c = Clip(nome: nome, file: file, video: video)
        c.miniatura = await miniatura(Archivio.url("Media", file), video: video)
        progetto.clips.append(c)
        await apriClip(c.id)
    }

    /// Importa un file nel Media Pool (non nella timeline).
    func importaNelPool(_ url: URL, video: Bool, nome: String) async {
        do {
            let f = video ? try Archivio.importa(url) : try Archivio.importa(dati: (try Data(contentsOf: url)), estensione: url.pathExtension.isEmpty ? "jpg" : url.pathExtension)
            let m = await miniatura(Archivio.url("Media", f), video: video)
            progetto.pool.append(ElementoPool(nome: nome, file: f, video: video, miniatura: m))
            Archivio.salva(progetto)
            await aggiornaDurate()
        } catch {
            messaggio = "Non riesco a importare: \(error.localizedDescription)"
        }
    }

    /// Mette un media del pool nella timeline, al posto `posto` (nil = in fondo).
    func usaDalPool(_ id: UUID, posto: Int? = nil) async {
        guard let e = progetto.pool.first(where: { $0.id == id }) else { return }
        salvaNodiNellaClip()
        var c = Clip(nome: e.nome, file: e.file, video: e.video)
        c.miniatura = e.miniatura
        progetto.clips.insert(c, at: min(posto ?? progetto.clips.count, progetto.clips.count))
        Archivio.salva(progetto)
        await aggiornaDurate()
        aggiornaSequenza(ritardo: 0)
        if progetto.clips.count == 1 { await apriClip(c.id) }
    }

    /// Progetti di prima del Media Pool: i media già nella timeline compaiono anche nel pool.
    func riempiPoolDaClips() {
        var aggiunti = false
        for c in progetto.clips where !progetto.pool.contains(where: { $0.file == c.file }) {
            progetto.pool.append(ElementoPool(nome: c.nome, file: c.file, video: c.video, miniatura: c.miniatura))
            aggiunti = true
        }
        if aggiunti { Archivio.salva(progetto) }
    }

    func togliDalPool(_ id: UUID) {
        guard let i = progetto.pool.firstIndex(where: { $0.id == id }) else { return }
        let e = progetto.pool.remove(at: i)
        if !progetto.fileUsati.contains(e.file) && !Archivio.fileUsatoAltrove(e.file, progetto: progetto) { Archivio.elimina("Media", e.file) }
        Archivio.salva(progetto)
    }

    private func miniatura(_ url: URL, video: Bool) async -> String? {
        if video {
            let g = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            g.appliesPreferredTrackTransform = true
            g.maximumSize = CGSize(width: 240, height: 240)
            guard let (cg, _) = try? await g.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)) else { return nil }
            return Archivio.salvaImmagine(UIImage(cgImage: cg), cartella: "Miniature", lato: 240)
        }
        guard let ui = UIImage(contentsOfFile: url.path) else { return nil }
        return Archivio.salvaImmagine(ui, cartella: "Miniature", lato: 240)
    }

    /// Importa foto e video scelti dalla Libreria, uno alla volta, mostrando a che punto è.
    func importaDaLibreria(_ items: [PhotosPickerItem]) async {
        var falliti = 0
        for (i, item) in items.enumerated() {
            lavoro = items.count > 1 ? "Importo \(i + 1) di \(items.count)…" : "Importo dalla Libreria…"
            if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                do {
                    guard let v = try await item.loadTransferable(type: FileVideo.self) else { falliti += 1; continue }
                    await importaVideo(v.url)
                    try? FileManager.default.removeItem(at: v.url)
                } catch {
                    falliti += 1
                }
            } else if let d = try? await item.loadTransferable(type: Data.self) {
                await importaFoto(d, nome: "Foto \(progetto.clips.count + 1)")
            } else {
                falliti += 1
            }
        }
        lavoro = nil
        if falliti > 0 {
            messaggio = falliti == items.count ? "Non riesco a importare quello che hai scelto. Se è su iCloud, aprilo prima in Foto per scaricarlo."
                : "\(falliti) elementi non sono stati importati (forse sono su iCloud e non ancora scaricati)."
        }
    }

    func importaVideo(_ url: URL) async {
        do { await aggiungiClip(file: try Archivio.importa(url), nome: url.lastPathComponent, video: true) }
        catch { messaggio = "Non riesco a importare il video: \(error.localizedDescription)" }
    }

    func importaFoto(_ dati: Data, nome: String) async {
        guard UIImage(data: dati) != nil else { messaggio = "Non riesco ad aprire questa foto."; return }
        do { await aggiungiClip(file: try Archivio.importa(dati: dati, estensione: "jpg"), nome: nome, video: false) }
        catch { messaggio = error.localizedDescription }
    }

    /// Toglie più clip insieme (selezione nella pagina Media).
    func eliminaClips(_ ids: Set<UUID>) async {
        let attivaTolta = clipAttiva.map(ids.contains) ?? false
        for id in ids where id != clipAttiva { await eliminaClip(id) }
        if attivaTolta, let id = clipAttiva { await eliminaClip(id) }
        aggiornaSequenza(ritardo: 0)
    }

    func eliminaClip(_ id: UUID) async {
        guard let i = progetto.clips.firstIndex(where: { $0.id == id }) else { return }
        let c = progetto.clips.remove(at: i)
        // i duplicati condividono file e miniatura: si cancellano solo se nessun'altra clip li usa
        if !progetto.fileUsati.contains(c.file) && !Archivio.fileUsatoAltrove(c.file, progetto: progetto) { Archivio.elimina("Media", c.file) }
        if let m = c.miniatura, !progetto.fileUsati.contains(m) && !Archivio.fileUsatoAltrove(m, progetto: progetto) { Archivio.elimina("Miniature", m) }
        if clipAttiva == id {
            clipAttiva = nil
            if let primo = progetto.clips.first { await apriClip(primo.id) }
            else { caricando = true; nodi = [Nodo(tipo: .correzione)]; selezionato = nodi[0].id; caricando = false; mostraFoto(TestChart.immagine(), nome: "Immagine di prova") }
        }
        Archivio.salva(progetto)
    }

    // MARK: sequenza (pagina Edit)

    let playerSequenza = AVPlayer()
    @Published private(set) var durataSequenza: Double = 0
    @Published var tempoSequenza: Double = 0
    @Published private(set) var sequenzaInRiproduzione = false
    @Published private(set) var preparandoSequenza = false
    /// Durata dei file (video e audio), letta una volta sola: serve a disegnare subito la timeline.
    @Published private(set) var durateFile: [String: Double] = [:]

    /// Dove inizia e quanto dura ogni clip nella timeline, calcolato dal progetto (non aspetta la costruzione del montaggio).
    var posizioniClip: [(inizio: Double, durata: Double)] {
        var r: [(Double, Double)] = []
        var cursore = 0.0, transPrec = 0.0
        for (i, c) in progetto.clips.enumerated() {
            let m = c.taglio
            let d = Sequenza.durata(m, video: c.video, durataFile: durateFile[c.file] ?? 3)
            transPrec = min(transPrec, d / 2)       // come in Sequenza: mai tre clip sovrapposte
            let inizio = m.vuotoPrima > 0.001 ? cursore + m.vuotoPrima : max(0, cursore - transPrec)
            r.append((inizio, d))
            cursore = inizio + d
            transPrec = (m.transizione == .nessuna || i == progetto.clips.count - 1) ? 0 : min(m.durataTransizione, d / 2)
        }
        return r
    }
    var iniziClip: [Double] { posizioniClip.map(\.inizio) }
    var durateClip: [Double] { posizioniClip.map(\.durata) }
    var durataMontaggio: Double { posizioniClip.last.map { $0.inizio + $0.durata } ?? 0 }

    /// Legge le durate dei file che mancano.
    func aggiornaDurate() async {
        let file = progetto.clips.filter(\.video).map(\.file) + progetto.pool.filter(\.video).map(\.file) + progetto.musiche.map(\.file)
        for f in Set(file) where durateFile[f] == nil {
            if let d = try? await AVURLAsset(url: Archivio.url("Media", f)).load(.duration).seconds, d.isFinite { durateFile[f] = d }
        }
    }
    private var aggiornamentoSequenza: Task<Void, Never>?
    private var osservatoreSequenza: Any?
    private var avvisoMusica = false

    /// Ricostruisce la sequenza (dopo un cambio di montaggio o di correzione). Le richieste ravvicinate diventano una sola.
    func aggiornaSequenza(ritardo: Double = 0.25) {
        salvaNodiNellaClip()
        aggiornamentoSequenza?.cancel()
        aggiornamentoSequenza = Task { [weak self] in
            await self?.aggiornaDurate()
            if ritardo > 0 { try? await Task.sleep(for: .seconds(ritardo)) }
            guard let self, !Task.isCancelled else { return }
            self.preparandoSequenza = true
            defer { self.preparandoSequenza = false }
            do {
                let piano = try await Sequenza.costruisci(self.progetto, misura: self.anteprimaVerticale ? CGSize(width: 540, height: 960) : nil,
                                                          riempi: self.anteprimaVerticale)
                guard !Task.isCancelled else { return }
                let item = AVPlayerItem(asset: piano.composizione)
                item.videoComposition = piano.video
                item.audioMix = piano.audio
                item.audioTimePitchAlgorithm = .spectral      // velocità diverse senza voce "da cartone animato"
                let t = min(self.tempoSequenza, max(0, piano.durata - 0.05))
                let suonava = self.sequenzaInRiproduzione
                self.playerSequenza.replaceCurrentItem(with: item)
                self.durataSequenza = piano.durata
                if piano.musicaNonValida, !self.avvisoMusica { self.avvisoMusica = true; self.messaggio = "Non riesco ad aprire la musica: il montaggio è senza musica. Prova a sceglierne un'altra." }
                self.osservaSequenza()
                await self.playerSequenza.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                if suonava { self.playerSequenza.play() }
            } catch {
                let e = error as NSError
                self.messaggio = "Non riesco a preparare il montaggio: \(error.localizedDescription) (\(e.domain) \(e.code))"
            }
        }
    }

    private func osservaSequenza() {
        guard osservatoreSequenza == nil else { return }
        osservatoreSequenza = playerSequenza.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.tempoSequenza = t.seconds
                if self.sequenzaInRiproduzione, t.seconds >= self.durataSequenza - 0.03 { self.pausaSequenza() }
            }
        }
    }

    func playSequenza() {
        fermaVideo()
        if tempoSequenza >= durataSequenza - 0.05 { vaiSequenza(0) }
        playerSequenza.play()
        sequenzaInRiproduzione = true
    }

    func pausaSequenza() {
        playerSequenza.pause()
        sequenzaInRiproduzione = false
    }

    func vaiSequenza(_ t: Double) {
        tempoSequenza = min(max(0, t), durataSequenza)
        playerSequenza.seek(to: CMTime(seconds: tempoSequenza, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Montaggio della clip attiva: ogni modifica si salva e aggiorna la sequenza.
    var montaggioCorrente: Montaggio {
        get { clipCorrente?.taglio ?? Montaggio() }
        set {
            guard let i = progetto.clips.firstIndex(where: { $0.id == clipAttiva }) else { return }
            progetto.clips[i].taglio = newValue
            programmaSalvataggio()
            aggiornaSequenza()
        }
    }

    /// Accorcia o allunga una clip dal bordo (timeline del monitor): `secondi` in tempo della timeline,
    /// positivo = il bordo va a destra. Inizio: sposta l'entrata nel file; fine: sposta l'uscita.
    func rifila(_ id: UUID, inizio: Bool, di secondi: Double) {
        guard let i = progetto.clips.firstIndex(where: { $0.id == id }) else { return }
        let c = progetto.clips[i]
        var m = c.taglio
        let df = c.video ? (durateFile[c.file] ?? (m.fine ?? 10)) : 0
        let prima = Sequenza.durata(m, video: c.video, durataFile: df)
        var s = secondi
        // le altre clip non si spostano: si allunga solo dentro lo spazio vuoto che c'è
        if inizio { s = max(s, -m.vuotoPrima) }
        else if i + 1 < progetto.clips.count { s = min(s, progetto.clips[i + 1].taglio.vuotoPrima) }
        if c.video {
            let d = s * max(m.velocita, 0.1)
            let fine = min(m.fine ?? df, df)
            if inizio { m.inizio = min(max(0, m.inizio + d), fine - 0.2) }
            else { let f = min(max(m.inizio + 0.2, fine + d), df); m.fine = f >= df - 0.01 ? nil : f }
        } else {
            m.durataFoto = max(0.3, m.durataFoto + (inizio ? -s : s))
        }
        let cambio = Sequenza.durata(m, video: c.video, durataFile: df) - prima   // + = più lunga
        if inizio { m.vuotoPrima = max(0, m.vuotoPrima - cambio) }
        else if i + 1 < progetto.clips.count { progetto.clips[i + 1].taglio.vuotoPrima = max(0, progetto.clips[i + 1].taglio.vuotoPrima - cambio) }
        progetto.clips[i].taglio = m
        programmaSalvataggio()
        aggiornaSequenza()
    }

    /// Toglie lo spazio vuoto prima di una clip: lei e quelle dopo scorrono indietro (come "Ripple delete" di DaVinci).
    func chiudiSpazio(prima id: UUID) {
        guard let i = progetto.clips.firstIndex(where: { $0.id == id }) else { return }
        progetto.clips[i].taglio.vuotoPrima = 0
        programmaSalvataggio()
        aggiornaSequenza(ritardo: 0)
    }

    func chiudiTuttiGliSpazi() {
        for i in progetto.clips.indices { progetto.clips[i].taglio.vuotoPrima = 0 }
        programmaSalvataggio()
        aggiornaSequenza(ritardo: 0)
    }

    /// Taglia la clip attiva in due alla testina: la seconda parte diventa una clip nuova subito dopo.
    func dividiAllaTestina() {
        guard let id = clipAttiva else { return }
        dividi(id, aTempo: tempoSequenza)
    }

    /// Taglia una clip precisa nel punto `tempo` della timeline (la lama del monitor taglia quella cliccata).
    func dividi(_ id: UUID, aTempo tempo: Double) {
        salvaNodiNellaClip()
        guard let i = progetto.clips.firstIndex(where: { $0.id == id }), progetto.clips[i].video,
              i < iniziClip.count else { GestoreMonitor.scrivi("taglio: clip non trovata o non video"); return }
        let m = progetto.clips[i].taglio
        let t = tempo - iniziClip[i]
        GestoreMonitor.scrivi("taglio: clip \(i + 1) a \(String(format: "%.2f", tempo)) s (dentro la clip \(String(format: "%.2f", t)) di \(String(format: "%.2f", durateClip[i])) s, file \(durateFile[progetto.clips[i].file].map { String(format: "%.1f", $0) } ?? "durata non letta"))")
        guard t > 0.1, t < durateClip[i] - 0.1 else { messaggio = "Porta la testina dentro la clip selezionata per dividerla."; return }
        let taglio = m.inizio + t * m.velocita
        var prima = progetto.clips[i], seconda = progetto.clips[i]
        seconda.id = UUID()
        seconda.nodi = seconda.nodi.map(\.copia)
        seconda.versioni = []
        prima.taglio.fine = taglio
        prima.taglio.transizione = .nessuna
        prima.taglio.audioUscita = 0
        seconda.taglio.inizio = taglio
        seconda.taglio.audioEntrata = 0
        seconda.taglio.vuotoPrima = 0          // il buco resta solo prima del primo pezzo
        progetto.clips[i] = prima
        progetto.clips.insert(seconda, at: i + 1)
        Archivio.salva(progetto)
        aggiornaSequenza(ritardo: 0)
    }

    /// Divide la clip attiva nei punti dove cambia la scena (AI): ogni scena diventa una clip con la stessa correzione.
    func dividiPerScene() async {
        salvaNodiNellaClip()
        guard let i = progetto.clips.firstIndex(where: { $0.id == clipAttiva }), progetto.clips[i].video else { return }
        pausaSequenza()
        lavoro = "Cerco i cambi di scena…"
        defer { lavoro = nil }
        let c = progetto.clips[i]
        let m = c.taglio
        let url = Archivio.url("Media", c.file)
        do {
            let d = try await AVURLAsset(url: url).load(.duration).seconds
            let fine = min(m.fine ?? d, d)
            let tagli = try await CambiScena.tagli(url: url, da: m.inizio, a: fine) { [weak self] p in
                Task { @MainActor in self?.lavoro = "Scene… \(Int(p * 100))%" }
            }
            guard !tagli.isEmpty else { messaggio = "Non ho trovato cambi di scena in questa clip."; return }
            let confini = [m.inizio] + tagli + [fine]
            var nuove: [Clip] = []
            for (k, (a, b)) in zip(confini, confini.dropFirst()).enumerated() {
                var n = c
                if k > 0 { n.id = UUID(); n.nodi = c.nodi.map(\.copia); n.versioni = [] }
                n.nome = "\(c.nome) · \(k + 1)"
                n.taglio.inizio = a
                n.taglio.fine = b >= d - 0.01 ? nil : b
                if k < confini.count - 2 { n.taglio.transizione = .nessuna; n.taglio.audioUscita = 0 }
                if k > 0 { n.taglio.audioEntrata = 0 }
                nuove.append(n)
            }
            progetto.clips.replaceSubrange(i...i, with: nuove)
            Archivio.salva(progetto)
            aggiornaSequenza(ritardo: 0)
            messaggio = "Clip divisa in \(nuove.count) scene."
        } catch {
            messaggio = "Divisione non riuscita: \(error.localizedDescription)"
        }
    }

    /// Durata del file della clip attiva (per i cursori del taglio).
    @Published private(set) var durataFileCorrente: Double = 0

    // MARK: tracce audio di sottofondo

    /// Aggiunge un file audio (da File) in fondo alle tracce.
    func aggiungiMusica(_ url: URL) async {
        let accesso = url.startAccessingSecurityScopedResource()
        defer { if accesso { url.stopAccessingSecurityScopedResource() } }
        if let p = await FormatoFile.problema(url, video: false) { messaggio = p; return }
        do {
            let f = try Archivio.importa(url)
            progetto.musiche.append(Musica(file: f, nome: url.deletingPathExtension().lastPathComponent))
            Archivio.salva(progetto)
            aggiornaSequenza(ritardo: 0)
        } catch {
            messaggio = "Non riesco a importare l'audio: \(error.localizedDescription)"
        }
    }

    /// Usa come tracce audio i video scelti dalla Libreria (se ne prende l'audio).
    func aggiungiAudioDaLibreria(_ items: [PhotosPickerItem]) async {
        var falliti = 0
        for (i, item) in items.enumerated() {
            lavoro = "Prendo l'audio \(i + 1) di \(items.count)…"
            guard let v = try? await item.loadTransferable(type: FileVideo.self) else { falliti += 1; continue }
            defer { try? FileManager.default.removeItem(at: v.url) }
            let a = AVURLAsset(url: v.url)
            guard let tracce = try? await a.loadTracks(withMediaType: .audio), !tracce.isEmpty else { falliti += 1; continue }
            if let f = try? Archivio.importa(v.url) {
                progetto.musiche.append(Musica(file: f, nome: "Audio video \(progetto.musiche.count + 1)"))
            } else { falliti += 1 }
        }
        lavoro = nil
        Archivio.salva(progetto)
        aggiornaSequenza(ritardo: 0)
        if falliti > 0 { messaggio = falliti == items.count ? "Nei video scelti non c'è audio (o non riesco a leggerli)." : "\(falliti) video senza audio sono stati saltati." }
    }

    /// Audio da un file video già sul telefono (Libreria scelta dal monitor): diventa una traccia musicale.
    func aggiungiAudio(daVideo url: URL, nome: String) async -> Bool {
        let a = AVURLAsset(url: url)
        guard let tracce = try? await a.loadTracks(withMediaType: .audio), !tracce.isEmpty,
              let f = try? Archivio.importa(url) else { return false }
        progetto.musiche.append(Musica(file: f, nome: nome))
        Archivio.salva(progetto)
        aggiornaSequenza(ritardo: 0)
        await aggiornaDurate()
        return true
    }

    func togliMusica(_ id: UUID) {
        guard let i = progetto.musiche.firstIndex(where: { $0.id == id }) else { return }
        let m = progetto.musiche.remove(at: i)
        if !progetto.fileUsati.contains(m.file) && !Archivio.fileUsatoAltrove(m.file, progetto: progetto) {
            Archivio.elimina("Media", m.file)
        }
        Archivio.salva(progetto)
        aggiornaSequenza(ritardo: 0)
    }

    /// Sposta una traccia audio al posto `j` (trascinamento nella timeline).
    func spostaMusica(_ id: UUID, a j: Int) {
        guard let i = progetto.musiche.firstIndex(where: { $0.id == id }), i != j else { return }
        let m = progetto.musiche.remove(at: i)
        progetto.musiche.insert(m, at: min(max(0, j), progetto.musiche.count))
        Archivio.salva(progetto)
        aggiornaSequenza(ritardo: 0)
    }

    func volumeMusica(_ id: UUID) -> Float { progetto.musiche.first { $0.id == id }?.volume ?? 0.6 }
    func impostaVolumeMusica(_ id: UUID, _ v: Float) {
        guard let i = progetto.musiche.firstIndex(where: { $0.id == id }) else { return }
        progetto.musiche[i].volume = v
        programmaSalvataggio()
        aggiornaSequenza()
    }

    var dissolvenzaMusica: Double {
        get { progetto.dissolvenzaMusica }
        set { progetto.dissolvenzaMusica = newValue; programmaSalvataggio(); aggiornaSequenza() }
    }
    var ripetiMusica: Bool {
        get { progetto.ripetiMusica }
        set { progetto.ripetiMusica = newValue; programmaSalvataggio(); aggiornaSequenza() }
    }

    /// Posizione di ogni traccia audio nella timeline (una dopo l'altra).
    var posizioniMusica: [(inizio: Double, durata: Double)] {
        var t = 0.0
        return progetto.musiche.map { m in
            let d = m.durata(file: durateFile[m.file] ?? 10)
            defer { t += d }
            return (t, d)
        }
    }

    /// Traccia audio scelta (toccandola nella timeline): nel pannello Audio si apre con taglio e dissolvenze.
    @Published var musicaScelta: UUID?

    func musica(_ id: UUID) -> Musica? { progetto.musiche.first { $0.id == id } }

    func modificaMusica(_ id: UUID, _ cambia: (inout Musica) -> Void) {
        guard let i = progetto.musiche.firstIndex(where: { $0.id == id }) else { return }
        cambia(&progetto.musiche[i])
        programmaSalvataggio()
        aggiornaSequenza()
    }

    /// Spezza la traccia audio in due dove sta la testina (la seconda parte diventa una traccia nuova subito dopo).
    func dividiMusicaAllaTestina(_ id: UUID) {
        guard let i = progetto.musiche.firstIndex(where: { $0.id == id }), i < posizioniMusica.count else { return }
        let pos = posizioniMusica[i]
        let t = tempoSequenza - pos.inizio
        guard t > 0.1, t < pos.durata - 0.1 else { messaggio = "Porta la testina dentro questa traccia audio per dividerla."; return }
        var prima = progetto.musiche[i], seconda = progetto.musiche[i]
        let taglio = prima.inizio + t
        seconda.id = UUID()
        prima.fine = taglio
        prima.uscita = 0
        seconda.inizio = taglio
        seconda.entrata = 0
        progetto.musiche[i] = prima
        progetto.musiche.insert(seconda, at: i + 1)
        musicaScelta = seconda.id
        Archivio.salva(progetto)
        aggiornaSequenza(ritardo: 0)
    }

    // MARK: reframe automatico

    /// In Edit il montaggio si vede in verticale 9:16 (per controllare il reframe).
    @Published var anteprimaVerticale = false { didSet { if anteprimaVerticale != oldValue { aggiornaSequenza(ritardo: 0) } } }

    func analizzaReframe() async {
        guard let c = clipCorrente, c.video else { return }
        pausaSequenza()
        lavoro = "Cerco il soggetto…"
        defer { lavoro = nil }
        let m = c.taglio
        let url = Archivio.url("Media", c.file)
        do {
            let d = try await AVURLAsset(url: url).load(.duration).seconds
            let punti = try await Reframe.analizza(url: url, da: m.inizio, a: min(m.fine ?? d, d)) { [weak self] p in
                Task { @MainActor in self?.lavoro = "Reframe… \(Int(p * 100))%" }
            }
            guard !punti.isEmpty else { messaggio = "Non riesco ad analizzare la clip."; return }
            var n = montaggioCorrente
            n.reframe = punti
            n.seguiSoggetto = true
            montaggioCorrente = n
            anteprimaVerticale = true
        } catch {
            messaggio = "Reframe non riuscito: \(error.localizedDescription)"
        }
    }

    // MARK: sottotitoli automatici

    /// Lingua del parlato (preimpostata su quella dell'iPhone, se c'è nell'elenco).
    @Published var linguaSottotitoli: String = {
        let c = Locale.current.language.languageCode?.identifier ?? "it"
        return Trascrizione.lingue.first { $0.codice.hasPrefix(c) }?.codice ?? "it-IT"
    }()

    func generaSottotitoli() async {
        guard let c = clipCorrente, c.video else { return }
        pausaSequenza()
        lavoro = "Ascolto il parlato…"
        defer { lavoro = nil }
        let m = c.taglio
        let url = Archivio.url("Media", c.file)
        do {
            let d = try await AVURLAsset(url: url).load(.duration).seconds
            let (righe, sulTelefono) = try await Trascrizione.trascrivi(url: url, da: m.inizio, a: min(m.fine ?? d, d), lingua: linguaSottotitoli)
            var n = montaggioCorrente
            n.sottotitoli = righe
            n.mostraSottotitoli = true
            montaggioCorrente = n
            messaggio = "\(righe.count) righe di sottotitoli create" + (sulTelefono ? "." : " (con il server di Apple: questa lingua non è disponibile offline su questo iPhone).")
        } catch {
            messaggio = "Sottotitoli non riusciti: \(error.localizedDescription)"
        }
    }

    /// Analizza la clip attiva e attiva la stabilizzazione.
    func stabilizzaClip() async {
        guard let c = clipCorrente, c.video else { return }
        pausaSequenza()
        lavoro = "Analizzo il movimento…"
        defer { lavoro = nil }
        let m = c.taglio
        let url = Archivio.url("Media", c.file)
        do {
            let d = try await AVURLAsset(url: url).load(.duration).seconds
            // si salva il percorso della camera (forza e treppiede si applicano dopo, senza rifare l'analisi)
            let percorso = try await Stabilizzatore.percorso(url: url, da: m.inizio, a: min(m.fine ?? d, d)) { [weak self] p in
                Task { @MainActor in self?.lavoro = "Stabilizzo… \(Int(p * 100))%" }
            }
            guard percorso.count > 2 else { messaggio = "Clip troppo corta da stabilizzare."; return }
            var nuovo = montaggioCorrente
            nuovo.percorsoStab = percorso
            nuovo.stabilizza = true
            montaggioCorrente = nuovo
        } catch {
            messaggio = "Stabilizzazione non riuscita: \(error.localizedDescription)"
        }
    }

    /// Esporta tutto il montaggio (transizioni, titoli, audio e musica compresi) nel Rullino.
    func esportaMontaggio(_ f: FormatoSocial, riempi: Bool) async {
        guard !progetto.clips.isEmpty else { return }
        pausaSequenza()
        fermaVideo()
        salvaNodiNellaClip()
        lavoro = "Preparo il montaggio…"
        defer { lavoro = nil }
        do {
            let piano = try await Sequenza.costruisci(progetto, misura: f.misura, riempi: riempi, lut: Studio.lutFinale)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Colorista-montaggio-\(Int(Date().timeIntervalSince1970)).mp4")
            let preset = f.hevc ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
            guard let s = AVAssetExportSession(asset: piano.composizione, presetName: preset) else { messaggio = "Esportazione non disponibile."; return }
            s.videoComposition = piano.video
            s.audioMix = piano.audio
            s.audioTimePitchAlgorithm = .spectral
            lavoro = "Esporto il montaggio (\(f.rawValue))…"
            try await s.export(to: url, as: .mp4)
            lavoro = "Salvo nel Rullino…"
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }
            try? FileManager.default.removeItem(at: url)
            let m = piano.contesto.misura
            messaggio = "Montaggio salvato nel Rullino (\(Int(m.width))×\(Int(m.height)), \(String(format: "%.1f", piano.durata)) s)."
        } catch {
            messaggio = "Esportazione del montaggio non riuscita: \(error.localizedDescription)"
        }
    }

    // MARK: progetti

    @Published private(set) var progettiSalvati: [Progetto] = []

    func aggiornaElencoProgetti() { progettiSalvati = Archivio.elencoArchiviati() }

    /// Chiude il progetto aperto (lo salva nell'elenco, se non è vuoto e se `salvaPrecedente`) e apre `nuovo`.
    private func passaA(_ nuovo: Progetto, salvaPrecedente: Bool = true) async {
        salvaNodiNellaClip()
        salvataggio?.cancel()
        pausaSequenza()
        fermaVideo()
        let vecchio = progetto
        if !progetto.vuoto && salvaPrecedente { Archivio.archivia(progetto) }
        progetto = nuovo
        Archivio.salva(progetto)
        clipAttiva = nil
        confronto = nil
        caricando = true
        nodi = [Nodo(tipo: .correzione)]
        selezionato = nodi[0].id
        caricando = false
        if let id = progetto.clipAttiva ?? progetto.clips.first?.id { await apriClip(id) }
        else { mostraFoto(TestChart.immagine(), nome: "Immagine di prova") }
        azzeraCronologia()
        tempoSequenza = 0
        if !salvaPrecedente {
            // progetto non salvato: i suoi file nell'app (copie di foto e video) si cancellano,
            // tranne quelli usati dal progetto nuovo o da un progetto salvato
            let altri = Archivio.elencoArchiviati()
            for f in vecchio.fileUsati where !progetto.fileUsati.contains(f) && !altri.contains(where: { $0.fileUsati.contains(f) }) {
                for cartella in ["Media", "Miniature", "Stills"] { Archivio.elimina(cartella, f) }
            }
        }
        aggiornaElencoProgetti()
        aggiornaSequenza(ritardo: 0)
    }

    /// Nuovo progetto vuoto. Con `salvaPrecedente: false` quello aperto non va nei Progetti e i suoi file si cancellano.
    func nuovoProgetto(nome: String, salvaPrecedente: Bool = true) async {
        var p = Progetto()
        let n = nome.trimmingCharacters(in: .whitespaces)
        p.nome = n.isEmpty ? "Progetto \(progettiSalvati.count + (progetto.vuoto || !salvaPrecedente ? 1 : 2))" : n
        await passaA(p, salvaPrecedente: salvaPrecedente)
    }

    func apriProgetto(_ id: UUID) async {
        guard let p = Archivio.caricaArchiviato(id) else { messaggio = "Non riesco ad aprire il progetto."; return }
        Archivio.rimuoviArchiviato(id)
        await passaA(p)
    }

    func rinominaProgetto(_ nome: String) {
        let n = nome.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        progetto.nome = n
        Archivio.salva(progetto)
    }

    /// Rinomina un progetto: quello aperto o uno salvato.
    func rinominaProgetto(_ id: UUID, _ nome: String) {
        let n = nome.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        if id == progetto.id { rinominaProgetto(n); return }
        guard var p = Archivio.caricaArchiviato(id) else { return }
        p.nome = n
        Archivio.archivia(p)
        aggiornaElencoProgetti()
    }

    /// Elimina un progetto salvato e i suoi file che nessun altro progetto usa.
    func eliminaProgetto(_ id: UUID) {
        guard let p = Archivio.caricaArchiviato(id) else { return }
        Archivio.rimuoviArchiviato(id)
        let altri = Archivio.elencoArchiviati()
        for f in p.fileUsati where !progetto.fileUsati.contains(f) && !altri.contains(where: { $0.fileUsati.contains(f) }) {
            for cartella in ["Media", "Miniature", "Stills"] { Archivio.elimina(cartella, f) }
        }
        aggiornaElencoProgetti()
    }

    // MARK: montaggio (pagina Edit)

    /// Sposta una clip nella sequenza (l'ordine delle clip è l'ordine del montaggio).
    func spostaClip(_ id: UUID, di passo: Int) {
        guard let i = progetto.clips.firstIndex(where: { $0.id == id }) else { return }
        let j = i + passo
        guard j >= 0, j < progetto.clips.count else { return }
        progetto.clips.swapAt(i, j)
        Archivio.salva(progetto)
    }

    /// Sposta una clip al posto `j` (trascinamento nella timeline).
    func spostaClip(_ id: UUID, a j: Int) {
        guard let i = progetto.clips.firstIndex(where: { $0.id == id }), i != j else { return }
        let c = progetto.clips.remove(at: i)
        progetto.clips.insert(c, at: min(max(0, j), progetto.clips.count))
        Archivio.salva(progetto)
        aggiornaSequenza(ritardo: 0)
    }

    /// Duplica una clip subito dopo l'originale: stesso file, correzione copiata.
    func duplicaClip(_ id: UUID) {
        salvaNodiNellaClip()
        guard let i = progetto.clips.firstIndex(where: { $0.id == id }) else { return }
        var c = progetto.clips[i]
        c.id = UUID()
        c.nome += " (copia)"
        c.nodi = c.nodi.map(\.copia)
        c.versioni = []
        progetto.clips.insert(c, at: i + 1)
        Archivio.salva(progetto)
    }

    func rinominaClip(_ id: UUID, _ nome: String) {
        guard let i = progetto.clips.firstIndex(where: { $0.id == id }), !nome.isEmpty else { return }
        progetto.clips[i].nome = nome
        if id == clipAttiva { nomeClip = nome }
        Archivio.salva(progetto)
    }

    func copiaCorrezione(_ id: UUID) {
        salvaNodiNellaClip()
        appunti = progetto.clips.first { $0.id == id }?.nodi ?? nodi
    }

    func incollaCorrezione(su id: UUID) async {
        guard let a = appunti, let i = progetto.clips.firstIndex(where: { $0.id == id }) else { return }
        progetto.clips[i].nodi = a.map(\.copia)
        if id == clipAttiva { caricando = true; nodi = progetto.clips[i].nodi; selezionato = nodi[0].id; caricando = false; aggiorna() }
        Archivio.salva(progetto)
    }

    func incollaSuTutte() {
        guard let a = appunti else { return }
        for i in progetto.clips.indices { progetto.clips[i].nodi = a.map(\.copia) }
        if let i = progetto.clips.firstIndex(where: { $0.id == clipAttiva }) { caricando = true; nodi = progetto.clips[i].nodi; selezionato = nodi[0].id; caricando = false; aggiorna() }
        Archivio.salva(progetto)
        messaggio = "Correzione applicata a \(progetto.clips.count) clip."
    }

    // MARK: versioni

    func salvaVersione() {
        guard let i = progetto.clips.firstIndex(where: { $0.id == clipAttiva }) else { messaggio = "Le versioni si salvano su una clip del progetto: importa prima una foto o un video."; return }
        progetto.clips[i].versioni.append(Versione(nome: "Versione \(progetto.clips[i].versioni.count + 1)", nodi: nodi))
        Archivio.salva(progetto)
    }

    func caricaVersione(_ v: Versione) {
        nodi = v.nodi
        selezionato = nodi.first?.id ?? selezionato
    }

    func eliminaVersione(_ v: Versione) {
        guard let i = progetto.clips.firstIndex(where: { $0.id == clipAttiva }) else { return }
        progetto.clips[i].versioni.removeAll { $0.id == v.id }
        Archivio.salva(progetto)
    }

    // MARK: galleria

    func catturaStill() {
        guard let img = risultato, let f = Archivio.salvaImmagine(img, cartella: "Stills", lato: 1600) else { return }
        progetto.stills.insert(Still(nome: "\(nomeClip) · \(progetto.stills.count + 1)", file: f, nodi: nodi), at: 0)
        Archivio.salva(progetto)
    }

    func applicaStill(_ s: Still) {
        nodi = s.nodi.map(\.copia)
        selezionato = nodi.first?.id ?? selezionato
    }

    func eliminaStill(_ s: Still) {
        progetto.stills.removeAll { $0.id == s.id }
        Archivio.elimina("Stills", s.file)
        if confronto?.id == s.id { confronto = nil }
        Archivio.salva(progetto)
    }

    // MARK: foto e video

    private func mostraFoto(_ ui: UIImage, nome: String) {
        fermaVideo()
        eVideo = false; asset = nil; generatore = nil
        spazio = CGColorSpace(name: CGColorSpace.sRGB)!
        durataFileCorrente = 0
        completa = ui.ridotta(lato: 4096)
        let p = ui.ridotta(lato: 1600)
        originale = p
        sorgente = p.cgImage.map { CIImage(cgImage: $0) }
        nomeClip = nome
        dimensioni = "\(Int(ui.size.width * ui.scale))×\(Int(ui.size.height * ui.scale))"
        aggiorna()
    }

    private func caricaVideo(_ url: URL, nome: String) async {
        fermaVideo()
        let a = AVURLAsset(url: url)
        do {
            let d = try await a.load(.duration)
            guard let traccia = try await a.loadTracks(withMediaType: .video).first else { messaggio = "Nel file non c'è video."; return }
            let size = try await traccia.load(.naturalSize)
            let fps = try await traccia.load(.nominalFrameRate)
            asset = a
            fpsClip = Double(fps > 0 ? fps : 25)
            durata = d.seconds
            durataFileCorrente = d.seconds
            tempo = 0
            let g = AVAssetImageGenerator(asset: a)
            g.appliesPreferredTrackTransform = true
            g.requestedTimeToleranceBefore = .zero
            g.requestedTimeToleranceAfter = .zero
            g.maximumSize = CGSize(width: 1600, height: 1600)
            generatore = g
            // il video ha valori codificati Rec.709: la LUT lavora su quei valori (così il Log resta Log)
            spazio = CGColorSpace(name: CGColorSpace.itur_709)!
            eVideo = true
            nomeClip = nome
            dimensioni = "\(Int(abs(size.width)))×\(Int(abs(size.height))) · \(String(format: "%.0f", fps)) fps · \(String(format: "%.1f", durata)) s"
            await fotogramma(0)
        } catch {
            messaggio = "Non riesco ad aprire il video: \(error.localizedDescription)"
        }
    }

    func fotogramma(_ t: Double) async {
        guard let g = generatore else { return }
        tempo = t
        // i nodi con keyframe mostrano la correzione di questo istante
        if nodi.contains(where: { !$0.keyframes.isEmpty }) {
            caricando = true
            for i in nodi.indices where !nodi[i].keyframes.isEmpty { nodi[i].grade = nodi[i].grade(a: t) }
            caricando = false
        }
        do {
            let (cg, _) = try await g.image(at: CMTime(seconds: t, preferredTimescale: 600))
            sorgente = CIImage(cgImage: cg)
            originale = UIImage(cgImage: cg)
            aggiorna()
        } catch {
            // succede quando si salta veloce nel video (la richiesta precedente viene annullata): si resta
            // sul fotogramma di prima senza avvisi (l'avviso chiudeva anche il trackpad col monitor)
        }
    }

    func play() async {
        guard let a = asset else { return }
        do {
            statoVideo.imposta(nodi, spazio)
            let item = AVPlayerItem(asset: a)
            let comp = try await statoVideo.composizione(a, size: Studio.lutAnteprima)
            // in riproduzione come in pausa: Rec.709 SDR. Con i video HDR dell'iPhone l'uscita restava HDR
            // e su un monitor normale il play si vedeva più scuro del fotogramma fermo
            if let m = comp as? AVMutableVideoComposition {
                m.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
                m.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
                m.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
            }
            item.videoComposition = comp
            player.replaceCurrentItem(with: item)
            await player.seek(to: CMTime(seconds: tempo, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            osservatoreTempo = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] t in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.tempo = t.seconds
                    if self.tempo >= self.durata - 0.05 { Task { await self.pausa() } }
                }
            }
            inRiproduzione = true
            player.play()
        } catch {
            messaggio = "Riproduzione non riuscita: \(error.localizedDescription)"
        }
    }

    func pausa() async {
        guard inRiproduzione else { return }
        fermaVideo()
        await fotogramma(min(tempo, max(0, durata - 0.04)))
    }

    private func fermaVideo() {
        player.pause()
        if let o = osservatoreTempo { player.removeTimeObserver(o); osservatoreTempo = nil }
        player.replaceCurrentItem(with: nil)
        inRiproduzione = false
    }

    // MARK: tracker

    enum ModoTracking { case indietro, fotogrammaIndietro, entrambi, fotogrammaAvanti, avanti }

    /// Cosa segue il tracker oltre alla posizione (come le caselle Pan/Tilt/Zoom/Rotate di DaVinci).
    @Published var tracciaDimensione = true
    @Published var tracciaRotazione = true
    @Published private(set) var tracciando = false
    private var interruttore: Tracker.Interruttore?

    /// Tracking della finestra scelta a partire dalla testina. Se la finestra è già tracciata
    /// riparte da dove si trova lì, e sostituisce la traccia da qui in avanti (o all'indietro).
    func traccia(_ modo: ModoTracking) async {
        guard let a = asset, finestraCorrente.tipo != .nessuna, !tracciando else { return }
        fermaVideo()
        let idNodo = nodo.id, quale = sceltaValida, t0 = tempo
        let inter = Tracker.Interruttore()
        interruttore = inter
        tracciando = true
        defer { tracciando = false; interruttore = nil; lavoro = nil }
        var opzioni = Tracker.Opzioni(dimensione: tracciaDimensione, rotazione: tracciaRotazione)
        let unoSolo = modo == .fotogrammaAvanti || modo == .fotogrammaIndietro
        if unoSolo { opzioni.massimoFotogrammi = 1 }
        let versi: [Tracker.Verso]
        switch modo {
        case .indietro, .fotogrammaIndietro: versi = [.indietro]
        case .avanti, .fotogrammaAvanti: versi = [.avanti]
        case .entrambi: versi = [.indietro, .avanti]
        }
        var arrivo = t0, fotogrammi = 0, perso = false
        do {
            for verso in versi {
                guard let k = nodi.firstIndex(where: { $0.id == idNodo }) else { return }
                let f = quale == 0 ? nodi[k].finestra : nodi[k].finestreExtra[quale - 1]
                let p0 = Finestra.punto(f.traccia, t0) ?? PuntoTraccia(tempo: t0, centro: f.centro)
                let nomeVerso = verso == .avanti ? "in avanti" : "all'indietro"
                lavoro = "Tracking \(nomeVerso)…"
                let r = try await Tracker.traccia(asset: a, da: t0, verso: verso, centro: p0.centro,
                                                  raggio: f.tipo == .cerchio ? f.raggio * p0.scala : 0.12,
                                                  opzioni: opzioni, interruttore: inter) { [weak self] p in
                    Task { @MainActor in if self?.tracciando == true { self?.lavoro = "Tracking \(nomeVerso)… \(Int(p * 100))%" } }
                }
                guard r.campioni.count > 1, let k2 = nodi.firstIndex(where: { $0.id == idNodo }) else { perso = perso || r.perso; continue }
                let nuovi = r.campioni.map {
                    PuntoTraccia(tempo: $0.tempo, centro: $0.centro, scala: p0.scala * $0.scala, rotazione: p0.rotazione + $0.rotazione)
                }
                // un fotogramma alla volta sostituisce solo quel fotogramma; il tracking continuo
                // sostituisce tutto dal punto di partenza in quella direzione
                let margine = 0.5 / fpsClip
                let ordinati = verso == .avanti ? nuovi : nuovi.reversed()
                let da = ordinati.first!.tempo - margine, a = ordinati.last!.tempo + margine
                var g = quale == 0 ? nodi[k2].finestra : nodi[k2].finestreExtra[quale - 1]
                let prima = g.traccia.filter { $0.tempo < da }, dopo = g.traccia.filter { $0.tempo > a }
                switch (unoSolo, verso) {
                case (true, _): g.traccia = prima + ordinati + dopo
                case (false, .avanti): g.traccia = prima + ordinati
                case (false, .indietro): g.traccia = ordinati + dopo
                }
                if quale == 0 { nodi[k2].finestra = g } else { nodi[k2].finestreExtra[quale - 1] = g }
                arrivo = r.campioni.last!.tempo
                fotogrammi += r.campioni.count - 1
                perso = perso || r.perso
            }
        } catch {
            messaggio = "Tracking non riuscito: \(error.localizedDescription)"
        }
        // la testina va dove si è fermato il tracker: si vede subito se la finestra è rimasta sull'oggetto
        if arrivo != t0 { await fotogramma(arrivo) } else { aggiorna() }
        if inter.fermo {
            messaggio = "Tracking fermato: \(fotogrammi) fotogrammi tracciati."
        } else if perso {
            messaggio = "Il tracker ha perso l'oggetto dopo \(fotogrammi) fotogrammi. Rimetti la finestra sull'oggetto e riparti da lì."
        } else if !unoSolo && fotogrammi > 0 {
            messaggio = "Tracciati \(fotogrammi) fotogrammi."
        } else if fotogrammi == 0 {
            messaggio = "Il tracker non ha trovato niente da seguire."
        }
    }

    /// Segui volto (AI): trova la faccia nel fotogramma della testina, ci mette sopra la finestra (grande come la faccia)
    /// e la segue in tutta la clip, all'indietro e in avanti. Senza finestre ne crea una.
    func seguiVolto() async {
        guard let a = asset, !tracciando else { return }
        fermaVideo()
        // con una finestra già messa si prende la faccia più vicina a lei, altrimenti la più grande
        var vicino: SIMD2<Float>?
        let creata = !(nodo.haFinestre && finestraCorrente.tipo != .nessuna)
        if creata { aggiungiFinestra() } else { vicino = finestraCorrente.a(tempo).centro }
        let idNodo = nodo.id, quale = sceltaValida, t0 = tempo
        let inter = Tracker.Interruttore()
        interruttore = inter
        tracciando = true
        defer { tracciando = false; interruttore = nil; lavoro = nil }
        var opzioni = Tracker.Opzioni(dimensione: tracciaDimensione, rotazione: tracciaRotazione)
        opzioni.volto = true
        opzioni.voltoVicino = vicino
        var parti: [Tracker.Verso: [Tracker.Campione]] = [:]
        var partenza: (centro: SIMD2<Float>, lato: Float)?
        var perso = false
        do {
            for verso in [Tracker.Verso.indietro, .avanti] where !inter.fermo {
                let nome = verso == .avanti ? "in avanti" : "all'indietro"
                lavoro = "Cerco la faccia…"
                let r = try await Tracker.traccia(asset: a, da: t0, verso: verso, centro: vicino ?? SIMD2(0.5, 0.5), raggio: 0.1,
                                                  opzioni: opzioni, interruttore: inter) { [weak self] p in
                    Task { @MainActor in if self?.tracciando == true { self?.lavoro = "Seguo la faccia \(nome)… \(Int(p * 100))%" } }
                }
                guard let v = r.volto else {
                    if creata, nodi.firstIndex(where: { $0.id == idNodo }) == indice { togliFinestra() }
                    messaggio = "Non trovo una faccia in questo fotogramma. Porta la testina dove la faccia si vede bene (di fronte) e riprova."
                    return
                }
                partenza = v
                parti[verso] = r.campioni
                perso = perso || r.perso
            }
        } catch {
            messaggio = "Segui volto non riuscito: \(error.localizedDescription)"
            return
        }
        guard let v = partenza, let k = nodi.firstIndex(where: { $0.id == idNodo }) else { return }
        let punti = { (c: [Tracker.Campione]) in c.map { PuntoTraccia(tempo: $0.tempo, centro: $0.centro, scala: $0.scala, rotazione: $0.rotazione) } }
        var f = quale == 0 ? nodi[k].finestra : nodi[k].finestreExtra[quale - 1]
        // la finestra va sulla faccia, un po' più grande così la prende tutta
        f.tipo = .cerchio
        f.centro = v.centro
        f.raggio = max(0.03, v.lato * 0.7)
        f.traccia = punti(parti[.indietro] ?? []).reversed() + punti(Array((parti[.avanti] ?? []).dropFirst()))
        if quale == 0 { nodi[k].finestra = f } else { nodi[k].finestreExtra[quale - 1] = f }
        aggiorna()
        if let primo = f.traccia.first, let ultimo = f.traccia.last {
            let durata = String(format: "%.1f", ultimo.tempo - primo.tempo)
            if inter.fermo { messaggio = "Fermato: faccia seguita per \(durata) s." }
            else if perso { messaggio = "Faccia seguita per \(durata) s, poi si è persa. Porta la testina dove si rivede e premi di nuovo Segui volto, oppure usa i pulsanti del tracker." }
            else { messaggio = "Faccia seguita per \(durata) s (\(f.traccia.count) fotogrammi)." }
        }
    }

    func fermaTracking() { interruttore?.ferma() }

    /// Toglie la traccia della finestra scelta (resta dove si trova adesso).
    func cancellaTraccia() {
        var f = finestraCorrente.a(eVideo ? tempo : nil)
        f.traccia = []
        finestraCorrente = f
    }

    /// Spostamento della finestra col dito. Se è tracciata si sposta tutta la traccia (come "Clip" in DaVinci).
    func spostaFinestra(_ p: SIMD2<Float>) {
        var f = finestraCorrente
        if eVideo, !f.traccia.isEmpty {
            let d = p - f.a(tempo).centro
            for j in f.traccia.indices { f.traccia[j].centro += d }
        }
        f.centro = p
        finestraCorrente = f
    }

    /// Finestre del nodo come si vedono adesso nel viewer (con il tracker al tempo della testina).
    var finestreVisibili: [Finestra] { nodo.finestre(a: eVideo ? tempo : nil) }

    // MARK: esportazioni

    /// LUT dell'intera catena. I nodi con maschere o effetti non entrano (una LUT non sa "dove" è un pixel).
    func documentoLUT(size: Int, titolo: String) -> (CubeDocument, saltati: Int) {
        let attivi = nodi.filter(\.attivo)
        let f = nodi.funzioneLUT()
        var lut = CubeLUT.costruisci(size: size, f)
        lut.titolo = titolo
        return (CubeDocument(testo: lut.testoCube()), attivi.filter(\.spaziale).count)
    }

    /// Una LUT per ogni clip del progetto, chiamata come la clip (per DaVinci: una LUT da mettere su ogni clip).
    func lutTutteLeClip(size: Int) -> (documenti: [CubeDocument], saltati: Int) {
        salvaNodiNellaClip()
        var docs: [CubeDocument] = [], saltati = 0
        for c in progetto.clips {
            let attivi = c.nodi.filter(\.attivo)
            saltati += attivi.filter(\.spaziale).count
            let f = c.nodi.funzioneLUT()
            let nome = (c.nome as NSString).deletingPathExtension
            var lut = CubeLUT.costruisci(size: size, f)
            lut.titolo = nome
            docs.append(CubeDocument(testo: lut.testoCube(), nome: nome + ".cube"))
        }
        return (docs, saltati)
    }

    /// CDL equivalente alla catena (solo primarie: per la Galleria di DaVinci).
    func documentoCDL(nome: String) -> (CDLDocument, errore: Float) {
        let (cdl, err) = CDL.stima(nodi.funzioneLUT())
        return (CDLDocument(testo: cdl.xml(id: nome, descrizione: "Colors · \(nomeClip)"), nome: nome + ".cdl"), err)
    }

    func importaCDL(_ url: URL) {
        let accesso = url.startAccessingSecurityScopedResource()
        defer { if accesso { url.stopAccessingSecurityScopedResource() } }
        do {
            let cdl = try CDL.leggi(try String(contentsOf: url, encoding: .utf8))
            var lut = CubeLUT.costruisci(size: 33) { limita(cdl.applica($0), .zero, SIMD3(repeating: 1)) }
            lut.titolo = "CDL " + url.deletingPathExtension().lastPathComponent
            aggiungi(.lut, lut: lut, nome: lut.titolo)
        } catch {
            messaggio = error.localizedDescription
        }
    }

    func fotoCorretta() -> UIImage? {
        guard let c = completa?.cgImage else { return nil }
        return immagine(catena(size: Studio.lutFinale).applica(CIImage(cgImage: c)))
    }

    /// La clip attiva come piccolo montaggio a sé: correzione colore + tutto quello che si è fatto in Edit
    /// (taglio, velocità, stabilizzazione, inquadratura, titolo), senza la musica di sottofondo.
    private func pianoSoloClip(misura: CGSize?, riempi: Bool) async throws -> Sequenza.Piano? {
        salvaNodiNellaClip()
        guard let c = progetto.clips.first(where: { $0.id == clipAttiva }) else { return nil }
        var p = progetto
        p.clips = [c]
        p.musiche = []
        return try await Sequenza.costruisci(p, misura: misura, riempi: riempi, lut: Studio.lutFinale)
    }

    func esportaVideo(_ formato: FormatoVideo) async {
        guard asset != nil else { return }
        fermaVideo()
        pausaSequenza()
        lavoro = "Preparo il video…"
        defer { lavoro = nil }
        do {
            guard let piano = try await pianoSoloClip(misura: nil, riempi: false) else { return }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Colorista-\(Int(Date().timeIntervalSince1970)).mov")
            switch formato {
            case .hevc:
                guard let s = AVAssetExportSession(asset: piano.composizione, presetName: AVAssetExportPresetHEVCHighestQuality) else {
                    messaggio = "Esportazione HEVC non disponibile."; return
                }
                s.videoComposition = piano.video
                s.audioMix = piano.audio
                lavoro = "Esporto in HEVC…"
                try await s.export(to: url, as: .mov)
            case .prores:
                try await Esportazione.prores(asset: piano.composizione, composizione: piano.video, verso: url) { [weak self] p in
                    Task { @MainActor in self?.lavoro = "Esporto in ProRes… \(Int(p * 100))%" }
                }
            }
            lavoro = "Salvo nel Rullino…"
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }
            try? FileManager.default.removeItem(at: url)
            messaggio = "Video salvato nel Rullino (\(formato.rawValue))."
        } catch {
            messaggio = "Esportazione non riuscita: \(error.localizedDescription)"
        }
        await fotogramma(tempo)
    }

    /// Video corretto nel formato di un social (misura, rapporto e codec giusti), salvato nel Rullino.
    func esportaSocial(_ f: FormatoSocial, riempi: Bool) async {
        guard asset != nil else { return }
        fermaVideo()
        pausaSequenza()
        lavoro = "Preparo il video per \(f.rawValue)…"
        defer { lavoro = nil }
        do {
            guard let piano = try await pianoSoloClip(misura: f.misura, riempi: f == .originale ? false : riempi) else { return }
            let uscita = piano.contesto.misura
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Colorista-\(f.id)-\(Int(Date().timeIntervalSince1970)).mp4")
            let preset = f.hevc ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
            guard let s = AVAssetExportSession(asset: piano.composizione, presetName: preset) else { messaggio = "Esportazione non disponibile."; return }
            s.videoComposition = piano.video
            s.audioMix = piano.audio
            lavoro = "Esporto per \(f.rawValue)…"
            try await s.export(to: url, as: .mp4)
            lavoro = "Salvo nel Rullino…"
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }
            try? FileManager.default.removeItem(at: url)
            messaggio = "Video per \(f.rawValue) salvato nel Rullino (\(Int(uscita.width))×\(Int(uscita.height)))."
        } catch {
            messaggio = "Esportazione non riuscita: \(error.localizedDescription)"
        }
        await fotogramma(tempo)
    }

    /// Foto corretta a piena risoluzione portata al formato del social scelto.
    func fotoSocial(_ f: FormatoSocial, riempi: Bool) -> UIImage? {
        guard let c = completa?.cgImage else { return nil }
        var img = catena(size: Studio.lutFinale).applica(CIImage(cgImage: c))
        if let u = f.dimensioneFoto(sorgente: img.extent.size) { img = FormatoSocial.adatta(img, a: u, riempi: riempi) }
        return immagine(img)
    }

    func importaLUT(_ url: URL) {
        let accesso = url.startAccessingSecurityScopedResource()
        defer { if accesso { url.stopAccessingSecurityScopedResource() } }
        do {
            let testo = try String(contentsOf: url, encoding: .utf8)
            var lut = try CubeLUT.leggi(testo)
            if lut.titolo == "LUT" { lut.titolo = url.deletingPathExtension().lastPathComponent }
            aggiungi(.lut, lut: lut, nome: lut.titolo)
        } catch {
            messaggio = error.localizedDescription
        }
    }

    /// File scelto da "File": video, foto o LUT.
    func apriFile(_ url: URL) async {
        let est = url.pathExtension.lowercased()
        if est == "cube" { importaLUT(url); return }
        if ["cdl", "cc", "ccc"].contains(est) { importaCDL(url); return }
        let accesso = url.startAccessingSecurityScopedResource()
        defer { if accesso { url.stopAccessingSecurityScopedResource() } }
        let tipo = UTType(filenameExtension: url.pathExtension)
        if tipo?.conforms(to: .movie) == true || tipo?.conforms(to: .video) == true {
            await importaVideo(url)
        } else if let d = try? Data(contentsOf: url) {
            await importaFoto(d, nome: url.lastPathComponent)
        }
    }
}

/// False Color: colora l'immagine per fasce di esposizione (grigio = ok; verde = grigio medio; rosa = pelle; giallo/rosso = luci bruciate).
enum FalsoColore {
    static let size = 33
    static let cubo: Data = CubeLUT.costruisci(size: size) { c in
        let l = (c * Grade.lumaRec709).sum()
        switch l {
        case ..<0.025: return SIMD3(0.5, 0, 0.6)       // nero chiuso
        case ..<0.04: return SIMD3(0, 0.25, 1)         // appena sopra il nero
        case 0.38..<0.42: return SIMD3(0.2, 0.75, 0.2) // grigio medio
        case 0.52..<0.56: return SIMD3(1, 0.55, 0.7)   // un diaframma sopra: pelle chiara
        case 0.97..<0.99: return SIMD3(1, 0.95, 0)     // quasi bruciato
        case 0.99...: return SIMD3(1, 0, 0)            // bruciato
        default: return SIMD3(repeating: l * 0.85)
        }
    }.datiCoreImage()
}

/// Video scelto dalla Libreria foto: viene copiato in una cartella temporanea dell'app.
struct FileVideo: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        // .movie copre .mov, .mp4, HEVC e ProRes dell'iPhone; il file viene copiato perché quello ricevuto sparisce subito
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { r in
            let dst = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + r.file.lastPathComponent)
            try FileManager.default.copyItem(at: r.file, to: dst)
            return FileVideo(url: dst)
        }
    }
}

extension UTType {
    static let cube = UTType(filenameExtension: "cube", conformingTo: .data) ?? .data
    static let cdl = UTType(filenameExtension: "cdl", conformingTo: .xml) ?? .xml
    static let cc = UTType(filenameExtension: "cc", conformingTo: .xml) ?? .xml
    static let ccc = UTType(filenameExtension: "ccc", conformingTo: .xml) ?? .xml
}

/// Documento .cube per il salvataggio in File.
struct CubeDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.cube] }
    var testo: String
    var nome = "Colors.cube"
    init(testo: String, nome: String = "Colors.cube") { self.testo = testo; self.nome = nome }
    init(configuration: ReadConfiguration) throws {
        testo = configuration.file.regularFileContents.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let w = FileWrapper(regularFileWithContents: Data(testo.utf8))
        w.preferredFilename = nome
        return w
    }
}

/// Documento .cdl (ASC Color Decision List).
struct CDLDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.cdl] }
    var testo: String
    var nome = "Colors.cdl"
    init(testo: String, nome: String) { self.testo = testo; self.nome = nome }
    init(configuration: ReadConfiguration) throws {
        testo = configuration.file.regularFileContents.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let w = FileWrapper(regularFileWithContents: Data(testo.utf8))
        w.preferredFilename = nome
        return w
    }
}

extension UIImage {
    /// Copia ridotta (lato lungo al massimo `lato` pixel), già ruotata nel verso giusto.
    func ridotta(lato: CGFloat) -> UIImage {
        let w = size.width * scale, h = size.height * scale
        let k = min(1, lato / max(w, h))
        let nuova = CGSize(width: (w * k).rounded(), height: (h * k).rounded())
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: nuova, format: fmt).image { _ in
            draw(in: CGRect(origin: .zero, size: nuova))
        }
    }
}

/// Immagine di prova mostrata quando il progetto è vuoto: tinte, scala di grigi e toni pelle.
enum TestChart {
    static func immagine() -> UIImage {
        let s = CGSize(width: 1200, height: 800)
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: s, format: fmt).image { ctx in
            let c = ctx.cgContext
            for x in 0..<240 {
                for y in 0..<20 {
                    let hue = CGFloat(x) / 240, sat = 1 - CGFloat(y) / 22
                    UIColor(hue: hue, saturation: sat, brightness: 1, alpha: 1).setFill()
                    c.fill(CGRect(x: CGFloat(x) * 5, y: CGFloat(y) * 20, width: 5, height: 20))
                }
            }
            for x in 0..<240 {
                UIColor(white: CGFloat(x) / 239, alpha: 1).setFill()
                c.fill(CGRect(x: CGFloat(x) * 5, y: 400, width: 5, height: 160))
            }
            for i in 0..<10 {
                UIColor(white: CGFloat(i) / 9, alpha: 1).setFill()
                c.fill(CGRect(x: CGFloat(i) * 120, y: 560, width: 120, height: 120))
            }
            let pelle: [UInt32] = [0x8d5524, 0xc68642, 0xe0ac69, 0xf1c27d, 0xffdbac, 0x5c3a21, 0xa1665e, 0xd9a07b, 0xeac0a0, 0x3b2219]
            for (i, h) in pelle.enumerated() {
                UIColor(red: CGFloat((h >> 16) & 255) / 255, green: CGFloat((h >> 8) & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: 1).setFill()
                c.fill(CGRect(x: CGFloat(i) * 120, y: 680, width: 120, height: 120))
            }
        }
    }
}

// MARK: - Coda di render (pagina Deliver)

extension Studio {
    /// Durata di quello che si esporterebbe adesso (timeline intera o clip attiva).
    var durataRender: Double {
        if impostazioniRender.cosa == .clip, let i = progetto.clips.firstIndex(where: { $0.id == clipAttiva }), i < posizioniClip.count {
            return posizioniClip[i].durata
        }
        return durataMontaggio
    }

    /// Misura della clip aperta, letta da "1920×1080 · …".
    var misuraSorgente: CGSize? {
        let n = dimensioni.split(whereSeparator: { !$0.isNumber }).compactMap { Double($0) }
        return n.count >= 2 ? CGSize(width: n[0], height: n[1]) : nil
    }

    func aggiungiAllaCoda() {
        salvaNodiNellaClip()
        let s = impostazioniRender
        var numero = (codaRender.map(\.numero).max() ?? 0) + 1
        func aggiungi(_ nome: String, _ clip: UUID?, _ durata: Double) {
            codaRender.append(LavoroRender(numero: numero, nome: nome, impostazioni: s, clip: clip, durata: durata))
            numero += 1
        }
        let pos = posizioniClip
        switch (s.cosa, s.modo) {
        case (.clip, _):
            guard let id = clipAttiva, let i = progetto.clips.firstIndex(where: { $0.id == id }) else { messaggio = "Nessuna clip aperta."; return }
            aggiungi(s.nomeFile, id, i < pos.count ? pos[i].durata : 0)
        case (.montaggio, .individuali):
            for (i, c) in progetto.clips.enumerated() {
                aggiungi("\(s.nomeFile)_\((c.nome as NSString).deletingPathExtension)", c.id, i < pos.count ? pos[i].durata : 0)
            }
        case (.montaggio, .singolo):
            guard !progetto.clips.isEmpty else { messaggio = "La timeline è vuota."; return }
            aggiungi(s.nomeFile, nil, durataMontaggio)
        }
    }

    func togliDallaCoda(_ id: UUID) {
        codaRender.removeAll { l in
            if case .inCorso = l.stato { return false }
            return l.id == id
        }
    }

    /// Toglie i lavori finiti (o tutti, se nessuno è finito).
    func svuotaCodaFatti() {
        let fatti = codaRender.filter { if case .fatto = $0.stato { return true }; return false }
        if fatti.isEmpty { codaRender.removeAll() } else { codaRender.removeAll { l in fatti.contains { $0.id == l.id } } }
    }

    /// "Render All": esegue in ordine i lavori in attesa (e quelli andati male).
    func renderTutto() async {
        guard !renderInCorso, lavoro == nil else { return }
        renderInCorso = true
        fermaVideo()
        pausaSequenza()
        salvaNodiNellaClip()
        defer { renderInCorso = false; lavoro = nil }
        let daFare = codaRender.filter { $0.stato == .attesa || CodaRenderMonitor.errore($0.stato) }.map(\.id)
        var riusciti = 0
        for id in daFare where await eseguiRender(id) { riusciti += 1 }
        messaggio = "Render completato: \(riusciti) di \(daFare.count)."
        await fotogramma(tempo)
    }

    private func statoRender(_ id: UUID, _ s: LavoroRender.Stato) {
        if let i = codaRender.firstIndex(where: { $0.id == id }) { codaRender[i].stato = s }
    }

    private func eseguiRender(_ id: UUID) async -> Bool {
        guard let l = codaRender.first(where: { $0.id == id }) else { return false }
        let s = l.impostazioni
        statoRender(id, .inCorso(0))
        lavoro = "Render lavoro \(l.numero)…"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(l.nome)-\(Int(Date().timeIntervalSince1970)).\(s.estensione)")
        do {
            var p = progetto
            if let c = l.clip {
                guard let clip = p.clips.first(where: { $0.id == c }) else { throw CocoaError(.fileNoSuchFile) }
                p.clips = [clip]
                p.musiche = []
            }
            let piano = try await Sequenza.costruisci(p, misura: s.risoluzione.misura, riempi: s.riempi, lut: Studio.lutFinale)
            if s.fps > 0 { piano.video.frameDuration = CMTime(value: 1, timescale: CMTimeScale(s.fps)) }
            var mix = piano.audio
            if !s.audio {
                for t in piano.composizione.tracks(withMediaType: .audio) { piano.composizione.removeTrack(t) }
                mix = nil
            }
            if s.codec == .prores {
                try await Esportazione.prores(asset: piano.composizione, composizione: piano.video, audioMix: mix, verso: url) { [weak self] v in
                    Task { @MainActor in self?.statoRender(id, .inCorso(v)) }
                }
            } else {
                let preset: String
                switch (s.codec, s.qualita) {
                case (.hevc, _): preset = AVAssetExportPresetHEVCHighestQuality
                case (_, .media): preset = AVAssetExportPresetMediumQuality
                default: preset = AVAssetExportPresetHighestQuality
                }
                guard let sessione = AVAssetExportSession(asset: piano.composizione, presetName: preset) else { throw CocoaError(.featureUnsupported) }
                sessione.videoComposition = piano.video
                sessione.audioMix = mix
                sessione.audioTimePitchAlgorithm = .spectral
                // avanzamento: si legge ogni tanto mentre esporta
                let osserva = Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        self?.statoRender(id, .inCorso(Double(sessione.progress)))
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                }
                defer { osserva.cancel() }
                try await sessione.export(to: url, as: s.tipoFile)
            }
            let mb = Double((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0) / 1_000_000
            if let cid = s.cartella, let c = CartelleCollegate.condivise.tutte.first(where: { $0.id == cid }) {
                // su una chiavetta o cartella collegata
                lavoro = "Copio su \(c.nome)…"
                guard let base = CartelleCollegate.condivise.apri(c) else { throw CocoaError(.fileNoSuchFile) }
                defer { base.stopAccessingSecurityScopedResource() }
                var dest = base.appendingPathComponent("\(l.nome).\(s.estensione)")
                var n = 2
                while FileManager.default.fileExists(atPath: dest.path) { dest = base.appendingPathComponent("\(l.nome) \(n).\(s.estensione)"); n += 1 }
                try FileManager.default.copyItem(at: url, to: dest)
            } else {
                lavoro = "Salvo nel Rullino…"
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }
            }
            try? FileManager.default.removeItem(at: url)
            statoRender(id, .fatto(mb))
            return true
        } catch {
            try? FileManager.default.removeItem(at: url)
            statoRender(id, .errore(error.localizedDescription))
            return false
        }
    }
}

// MARK: - Rifila alla testina (pagina Edit)

extension Studio {
    /// "Rifila l'inizio/la fine alla testina" sulla clip sotto la testina; le clip dopo scorrono (niente buco).
    func rifilaAllaTestina(inizio: Bool) {
        let pos = posizioniClip
        let t = tempoSequenza
        guard let i = pos.firstIndex(where: { t > $0.inizio + 0.05 && t < $0.inizio + $0.durata - 0.05 }) else {
            messaggio = "Porta la testina dentro una clip per rifilarla."; return
        }
        let id = progetto.clips[i].id
        let vuoto = progetto.clips[i].taglio.vuotoPrima
        if inizio {
            rifila(id, inizio: true, di: t - pos[i].inizio)
            // il buco lasciato si chiude: torna lo spazio vuoto che c'era prima
            if let k = progetto.clips.firstIndex(where: { $0.id == id }) { progetto.clips[k].taglio.vuotoPrima = vuoto }
            aggiornaSequenza(ritardo: 0)
            vaiSequenza(pos[i].inizio)
        } else {
            let prossimo = i + 1 < progetto.clips.count ? progetto.clips[i + 1].taglio.vuotoPrima : 0
            rifila(id, inizio: false, di: t - (pos[i].inizio + pos[i].durata))
            if i + 1 < progetto.clips.count { progetto.clips[i + 1].taglio.vuotoPrima = prossimo }
            aggiornaSequenza(ritardo: 0)
        }
    }
}


/// Un testo che si scrive dal monitor.
struct TestoMonitor: Identifiable {
    let id = UUID()
    var titolo: String
    var testo: String
    var conferma: (String) -> Void
}
