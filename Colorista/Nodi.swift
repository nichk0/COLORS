import Foundation
import CoreImage
import Vision

struct KeyframeGrade: Codable, Hashable {
    var tempo: Double
    var grade: Grade
}

struct PuntoTraccia: Codable, Hashable {
    var tempo: Double
    var centro: SIMD2<Float>
    var scala: Float = 1          // dimensione rispetto alla finestra disegnata
    var rotazione: Float = 0      // gradi, antiorario
}

extension PuntoTraccia {
    /// Decodifica tollerante: le tracce vecchie avevano solo tempo e centro.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tempo = try c.decode(Double.self, forKey: .tempo)
        centro = try c.decode(SIMD2<Float>.self, forKey: .centro)
        scala = (try? c.decodeIfPresent(Float.self, forKey: .scala)) ?? 1
        rotazione = (try? c.decodeIfPresent(Float.self, forKey: .rotazione)) ?? 0
    }
}

enum MagicMask: String, Codable, CaseIterable, Identifiable {
    case nessuna = "Nessuna", persona = "Persona", sfondo = "Sfondo (tutto tranne la persona)"
    case soggetto = "Soggetto (AI)", fuoriSoggetto = "Tutto tranne il soggetto (AI)"
    var id: String { rawValue }
    /// Nome corto per i selettori (il rawValue resta uguale per i progetti salvati).
    var nome: String {
        switch self {
        case .nessuna: return "Nessuna"
        case .persona: return "Persona"
        case .sfondo: return "Sfondo"
        case .soggetto: return "Soggetto"
        case .fuoriSoggetto: return "Fuori sogg."
        }
    }
    var invertita: Bool { self == .sfondo || self == .fuoriSoggetto }
}

/// Effetti spaziali del nodo (come le ResolveFX): non possono stare in una LUT.
struct Effetti: Codable, Hashable {
    var nitidezza: Float = 0
    var dettaglio: Float = 0        // Midtone Detail (-1…1)
    var sfocatura: Float = 0
    var rumore: Float = 0           // riduzione rumore spaziale
    var grana: Float = 0
    var granaGrossa: Float = 0.4
    var halation: Float = 0
    var glow: Float = 0
    var soglia: Float = 0.75        // da dove partono glow e halation
    var attivi: Bool { self != Effetti() }
}

/// Come si collega un nodo al precedente: in serie, in parallelo (stesso ingresso, uscite mescolate)
/// o a layer (stesso ingresso, questo nodo sopra a quello sotto dove la sua maschera lo permette).
enum ModoNodo: String, Codable, CaseIterable, Identifiable {
    case serie = "Serie", parallelo = "Parallelo", layer = "Layer"
    var id: String { rawValue }
    var icona: String {
        switch self {
        case .serie: return "arrow.right"
        case .parallelo: return "equal"
        case .layer: return "square.3.layers.3d"
        }
    }
}

/// Un nodo della catena, come in DaVinci: correttore, Color Space Transform o LUT.
struct Nodo: Identifiable, Codable, Hashable {
    enum Tipo: String, Codable { case correzione = "Correttore", cst = "CST", lut = "LUT" }

    var id = UUID()
    var tipo: Tipo
    var attivo = true
    var grade = Grade()
    var cst = CST()
    var lut: CubeLUT?
    var nomeLUT = ""
    var qualificatore = Qualificatore()
    var finestra = Finestra()
    /// Finestre in più dello stesso nodo (la maschera è l'unione di tutte). Ogni finestra ha la sua traccia.
    var finestreExtra: [Finestra] = []
    var sfocaturaMaschera: Float = 0
    var magic: MagicMask = .nessuna
    var effetti = Effetti()
    var keyframes: [KeyframeGrade] = []
    var nome = ""                    // etichetta scelta (look, Color Match…)
    var modo: ModoNodo = .serie

    init(tipo: Tipo) { self.tipo = tipo }

    /// Campi dei progetti vecchi: la traccia stava nel nodo (solo per la prima finestra).
    private enum Vecchi: String, CodingKey { case traccia }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ d: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? d }
        id = v(.id, UUID()); tipo = v(.tipo, .correzione); attivo = v(.attivo, true)
        grade = v(.grade, Grade()); cst = v(.cst, CST()); lut = try? c.decodeIfPresent(CubeLUT.self, forKey: .lut)
        nomeLUT = v(.nomeLUT, ""); qualificatore = v(.qualificatore, Qualificatore()); finestra = v(.finestra, Finestra()); finestreExtra = v(.finestreExtra, [])
        sfocaturaMaschera = v(.sfocaturaMaschera, 0); magic = v(.magic, .nessuna); effetti = v(.effetti, Effetti())
        keyframes = v(.keyframes, [])
        nome = v(.nome, ""); modo = v(.modo, .serie)
        if finestra.traccia.isEmpty, let vecchi = try? decoder.container(keyedBy: Vecchi.self),
           let t = try? vecchi.decodeIfPresent([PuntoTraccia].self, forKey: .traccia), !t.isEmpty {
            finestra.traccia = t
        }
    }

    var haMaschera: Bool { tipo == .correzione && (qualificatore.attivo || haFinestre || magic != .nessuna) }
    var haFinestre: Bool { finestra.tipo != .nessuna || finestreExtra.contains { $0.tipo != .nessuna } }
    /// Il nodo fa cose che una LUT non può contenere.
    var spaziale: Bool { haMaschera || (tipo == .correzione && effetti.attivi) }

    var etichetta: String {
        switch tipo {
        case .correzione:
            if !nome.isEmpty { return nome }
            if magic != .nessuna { return "Magic Mask" }
            if haMaschera { return "Secondaria" }
            return effetti.attivi ? "Effetti" : "Correttore"
        case .cst: return "CST"
        case .lut: return nomeLUT.isEmpty ? "LUT" : nomeLUT
        }
    }

    /// Correzione al tempo `t` (interpola tra i keyframe, con partenza e arrivo morbidi).
    func grade(a t: Double?) -> Grade {
        guard let t, let primo = keyframes.first else { return grade }
        if keyframes.count == 1 || t <= primo.tempo { return primo.grade }
        guard let ultimo = keyframes.last, t < ultimo.tempo else { return keyframes.last!.grade }
        let i = keyframes.lastIndex { $0.tempo <= t } ?? 0
        let a = keyframes[i], b = keyframes[i + 1]
        var u = Float((t - a.tempo) / max(b.tempo - a.tempo, 0.0001))
        u = u * u * (3 - 2 * u)
        return Grade.mescola(a.grade, b.grade, u)
    }

    /// Tutte le finestre del nodo al tempo `t` (ognuna segue la sua traccia, se c'è).
    func finestre(a t: Double?) -> [Finestra] { ([finestra] + finestreExtra).map { $0.a(t) } }

    /// Trasformazione colore del nodo (quella che finisce nella LUT).
    func funzione(grade g: Grade? = nil) -> (SIMD3<Float>) -> SIMD3<Float> {
        switch tipo {
        case .correzione: let p = (g ?? grade).pronto(); return { p.applica($0) }
        case .cst: let c = cst.pronto(); return { c.applica($0) }
        case .lut: let l = lut; return { l?.campiona($0) ?? $0 }
        }
    }

    /// Copia con identificativo nuovo (per incollare correzioni).
    var copia: Nodo { var n = self; n.id = UUID(); return n }
}

/// Costruisce le catene e tiene in cache le LUT già calcolate. Si usa dal thread principale e da quello del video.
final class Fabbrica: @unchecked Sendable {
    static let condivisa = Fabbrica()
    private let lock = NSLock()
    private var cubi: [Chiave: Data] = [:]
    private var chiavi: [Qualificatore: Data] = [:]

    enum Chiave: Hashable { case grade(Grade, Int), cst(CST, Int), lut(UUID, Int) }

    func cubo(_ n: Nodo, grade: Grade, size: Int) -> Data {
        let k: Chiave
        switch n.tipo {
        case .correzione: k = .grade(grade, size)
        case .cst: k = .cst(n.cst, size)
        case .lut: k = .lut(n.id, size)
        }
        lock.lock(); let c = cubi[k]; lock.unlock()
        if let c { return c }
        let d = CubeLUT.costruisci(size: size, n.funzione(grade: grade)).datiCoreImage()
        lock.lock(); if cubi.count > 160 { cubi.removeAll() }; cubi[k] = d; lock.unlock()
        return d
    }

    func chiave(_ q: Qualificatore) -> Data {
        lock.lock(); let c = chiavi[q]; lock.unlock()
        if let c { return c }
        let d = CubeLUT.costruisci(size: Catena.lutChiave) { c in SIMD3(repeating: q.chiave(c)) }.datiCoreImage()
        lock.lock(); if chiavi.count > 40 { chiavi.removeAll() }; chiavi[q] = d; lock.unlock()
        return d
    }

    /// Catena per i nodi dati; con `tempo` usa i tracker e (se `keyframe`) i keyframe.
    /// L'anteprima usa `keyframe: false` perché la correzione mostrata è quella che si sta modificando.
    func catena(nodi: [Nodo], tempo: Double?, keyframe: Bool = true, size: Int, spazio: CGColorSpace) -> Catena {
        var passi: [Catena.Passo] = []
        for n in nodi where n.attivo {
            let g = keyframe ? n.grade(a: tempo) : n.grade
            let cor = n.tipo == .correzione
            let finestre = cor ? n.finestre(a: tempo).filter { $0.tipo != .nessuna } : []
            passi.append(.init(cubo: cubo(n, grade: g, size: size), size: size,
                               chiave: cor && n.qualificatore.attivo ? chiave(n.qualificatore) : nil,
                               finestre: finestre,
                               magic: cor ? n.magic : .nessuna,
                               sfocatura: n.haMaschera ? n.sfocaturaMaschera : 0,
                               effetti: cor && n.effetti.attivi ? n.effetti : nil,
                               modo: passi.isEmpty ? .serie : n.modo))
        }
        return Catena(passi: passi, spazio: spazio)
    }
}

/// Catena di nodi già "cotta" in LUT: si applica a foto e fotogrammi video con Core Image (GPU).
final class Catena: @unchecked Sendable {
    static let lutChiave = 33

    struct Passo {
        let cubo: Data
        let size: Int
        let chiave: Data?       // LUT che produce la maschera del qualificatore
        let finestre: [Finestra]
        let magic: MagicMask
        let sfocatura: Float
        let effetti: Effetti?
        let modo: ModoNodo
        var conMaschera: Bool { chiave != nil || !finestre.isEmpty || magic != .nessuna }
    }
    let passi: [Passo]
    let spazio: CGColorSpace

    init(passi: [Passo], spazio: CGColorSpace) { self.passi = passi; self.spazio = spazio }

    func cubo(_ img: CIImage, _ dati: Data, _ size: Int) -> CIImage {
        img.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": size, "inputCubeData": dati, "inputColorSpace": spazio,
        ])
    }

    /// Applica i passi; con `mascheraDi` mostra la maschera di quel passo (come "evidenzia" in DaVinci):
    /// con `trasparente` si vede l'immagine finale corretta e fuori dalla maschera diventa grigia e scura,
    /// altrimenti si vede solo la maschera in bianco e nero.
    /// I nodi in parallelo o a layer formano un gruppo con il nodo prima: tutti ricevono lo stesso ingresso.
    func applica(_ src: CIImage, finoA: Int? = nil, mascheraDi: Int? = nil, trasparente: Bool = false) -> CIImage {
        var img = src
        let e = src.extent
        let limite = min(finoA ?? passi.count, passi.count)
        var vista: CIImage?     // maschera da mostrare, calcolata una volta sola (la Magic Mask AI è lenta)
        var i = 0
        while i < limite {
            var j = i
            while j + 1 < limite, passi[j + 1].modo != .serie { j += 1 }
            let ingresso = img
            if let m = mascheraDi, (i...j).contains(m), passi[m].conMaschera {
                let mk = maschera(passi[m], ingresso: ingresso, area: e)
                guard trasparente else { return mk }
                vista = mk
            }
            let pronta = { (k: Int) -> CIImage? in k == mascheraDi ? vista : nil }
            if j == i {
                img = passo(passi[i], ingresso: ingresso, sfondo: ingresso, area: e, mascheraPronta: pronta(i))
            } else if passi[i + 1].modo == .layer {
                // layer: ogni nodo si appoggia sopra il risultato dei precedenti, dentro la sua maschera
                var r = passo(passi[i], ingresso: ingresso, sfondo: ingresso, area: e, mascheraPronta: pronta(i))
                for k in (i + 1)...j { r = passo(passi[k], ingresso: ingresso, sfondo: r, area: e, mascheraPronta: pronta(k)) }
                img = r
            } else {
                // parallelo: le uscite si mescolano in parti uguali
                let n = CGFloat(j - i + 1)
                let parti = (i...j).map { Catena.scalaTutto(passo(passi[$0], ingresso: ingresso, sfondo: ingresso, area: e, mascheraPronta: pronta($0)), 1 / n) }
                img = parti.dropFirst().reduce(parti[0]) { $1.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: $0]) }
            }
            i = j + 1
        }
        if let v = vista { return Catena.evidenzia(img.cropped(to: e), maschera: v).cropped(to: e) }
        return img.cropped(to: e)
    }

    /// Vista "evidenzia" trasparente: dentro la maschera l'immagine resta com'è (con le correzioni), fuori diventa grigia e scura.
    private static func evidenzia(_ img: CIImage, maschera m: CIImage) -> CIImage {
        let fuori = scala(img.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0]), 0.3)
        return img.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: fuori, kCIInputMaskImageKey: m])
    }

    /// Un nodo: correzione dell'ingresso, effetti, poi (se ha maschere) appoggiata sullo sfondo dentro la maschera.
    private func passo(_ p: Passo, ingresso: CIImage, sfondo: CIImage, area e: CGRect, mascheraPronta: CIImage? = nil) -> CIImage {
        var corretta = cubo(ingresso, p.cubo, p.size)
        if let fx = p.effetti { corretta = Catena.effetti(fx, corretta, area: e) }
        guard p.conMaschera else { return corretta }
        let m = mascheraPronta ?? maschera(p, ingresso: ingresso, area: e)
        return corretta.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: sfondo, kCIInputMaskImageKey: m])
    }

    /// Moltiplica anche l'alfa (immagini premoltiplicate): così la somma di n parti da 1/n torna opaca.
    private static func scalaTutto(_ img: CIImage, _ k: CGFloat) -> CIImage {
        img.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: k),
        ])
    }

    private func maschera(_ p: Passo, ingresso: CIImage, area e: CGRect) -> CIImage {
        var m: CIImage?
        func moltiplica(_ a: CIImage) { m = m.map { $0.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: a]) } ?? a }
        if let k = p.chiave { moltiplica(cubo(ingresso, k, Catena.lutChiave)) }
        if !p.finestre.isEmpty {
            // più finestre: vale dentro una qualsiasi (unione = massimo delle maschere)
            let unione = p.finestre.dropFirst().reduce(Finestra.immagine(p.finestre[0], area: e)) { m, f in
                Finestra.immagine(f, area: e).applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: m])
            }
            moltiplica(unione.cropped(to: e))
        }
        if p.magic != .nessuna {
            let base: CIImage?
            switch p.magic {
            case .persona, .sfondo: base = Catena.persona(ingresso, area: e)
            case .soggetto, .fuoriSoggetto: base = Catena.soggetto(ingresso, area: e)
            case .nessuna: base = nil
            }
            if var pm = base {
                if p.magic.invertita { pm = pm.applyingFilter("CIColorInvert") }
                moltiplica(pm)
            } else {
                // analisi non riuscita (per esempio nel simulatore): il nodo non corregge niente, invece di tutta l'immagine
                moltiplica(CIImage(color: .black).cropped(to: e))
            }
        }
        var out = m ?? CIImage(color: .white).cropped(to: e)
        if p.sfocatura > 0 {
            out = out.clampedToExtent().applyingGaussianBlur(sigma: Double(p.sfocatura) * Double(max(e.width, e.height)) * 0.02).cropped(to: e)
        }
        return out.cropped(to: e)
    }

    /// Magic Mask: segmentazione della persona con Vision (maschera grigia 0…1 grande come l'immagine).
    static func persona(_ img: CIImage, area e: CGRect) -> CIImage? {
        let req = VNGeneratePersonSegmentationRequest()
        req.qualityLevel = .balanced
        req.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let h = VNImageRequestHandler(ciImage: img, options: [:])
        guard (try? h.perform([req])) != nil, let pb = req.results?.first?.pixelBuffer else { return nil }
        let m = CIImage(cvPixelBuffer: pb)
        let sx = e.width / m.extent.width, sy = e.height / m.extent.height
        return m.transformed(by: CGAffineTransform(scaleX: sx, y: sy).concatenating(CGAffineTransform(translationX: e.minX, y: e.minY)))
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
            .cropped(to: e)
    }

    /// Magic Mask AI per qualsiasi soggetto in primo piano (animali, oggetti, auto, persone…), con Vision.
    static func soggetto(_ img: CIImage, area e: CGRect) -> CIImage? {
        let req = VNGenerateForegroundInstanceMaskRequest()
        let h = VNImageRequestHandler(ciImage: img, options: [:])
        guard (try? h.perform([req])) != nil, let r = req.results?.first,
              let pb = try? r.generateScaledMaskForImage(forInstances: r.allInstances, from: h) else { return nil }
        let m = CIImage(cvPixelBuffer: pb)
        let sx = e.width / m.extent.width, sy = e.height / m.extent.height
        // la maschera è a un canale (float): la si porta su R, G e B come le altre
        return m.transformed(by: CGAffineTransform(scaleX: sx, y: sy).concatenating(CGAffineTransform(translationX: e.minX, y: e.minY)))
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
            .cropped(to: e)
    }

    private static func scala(_ img: CIImage, _ k: CGFloat) -> CIImage {
        img.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
    }

    /// Effetti spaziali: riduzione rumore, sfocatura, Midtone Detail, nitidezza, glow, halation, grana.
    static func effetti(_ f: Effetti, _ img: CIImage, area e: CGRect) -> CIImage {
        var x = img
        let lato = Double(max(e.width, e.height))
        if f.rumore > 0 {
            x = x.applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": 0.005 + 0.06 * Double(f.rumore), "inputSharpness": 0.4])
        }
        if f.sfocatura > 0 {
            x = x.clampedToExtent().applyingGaussianBlur(sigma: Double(f.sfocatura) * lato * 0.01).cropped(to: e)
        }
        if f.dettaglio != 0 {
            x = x.clampedToExtent().applyingFilter("CIUnsharpMask", parameters: ["inputRadius": lato * 0.012, "inputIntensity": Double(f.dettaglio) * 0.7]).cropped(to: e)
        }
        if f.nitidezza > 0 {
            x = x.applyingFilter("CISharpenLuminance", parameters: ["inputSharpness": Double(f.nitidezza) * 1.5, "inputRadius": 1.6])
        }
        if f.glow > 0 || f.halation > 0 {
            // solo le parti sopra la soglia
            let s = CGFloat(min(f.soglia, 0.98)), k = 1 / (1 - s)
            let alte = x.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: -s * k, y: -s * k, z: -s * k, w: 0),
            ]).applyingFilter("CIColorClamp")
            if f.glow > 0 {
                let g = scala(alte.clampedToExtent().applyingGaussianBlur(sigma: lato * 0.02).cropped(to: e), CGFloat(f.glow) * 0.8)
                x = g.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: x])
            }
            if f.halation > 0 {
                // alone rosso-arancio attorno alle luci, come la pellicola
                let h = CGFloat(f.halation)
                let rosso = alte.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0.3 * h, y: 0.6 * h, z: 0.1 * h, w: 0), "inputGVector": CIVector(x: 0.06 * h, y: 0.12 * h, z: 0.02 * h, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                ]).clampedToExtent().applyingGaussianBlur(sigma: lato * 0.006).cropped(to: e)
                x = rosso.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: x])
            }
        }
        if f.grana > 0 {
            let grosso = 1 + CGFloat(f.granaGrossa) * 3
            let dx = CGFloat.random(in: 0...500), dy = CGFloat.random(in: 0...500)
            let rumore = CIFilter(name: "CIRandomGenerator")!.outputImage!
                .transformed(by: CGAffineTransform(translationX: dx, y: dy).concatenating(CGAffineTransform(scaleX: grosso, y: grosso)))
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                    "inputBiasVector": CIVector(x: -0.5, y: -0.5, z: -0.5, w: 0),
                ])
            let g = scala(rumore, CGFloat(f.grana) * 0.12).cropped(to: e)
            x = g.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: x])
        }
        return x.cropped(to: e)
    }
}

extension Finestra {
    /// Maschera bianca dentro / nera fuori, sfumata.
    static func immagine(_ f: Finestra, area e: CGRect) -> CIImage {
        let lato = Float(max(e.width, e.height))
        let cx = CGFloat(f.centro.x) * e.width + e.minX
        let cy = (1 - CGFloat(f.centro.y)) * e.height + e.minY   // Core Image ha l'origine in basso
        let dentro = CIColor(red: 1, green: 1, blue: 1), fuori = CIColor(red: 0, green: 0, blue: 0)
        let c0 = f.inverti ? fuori : dentro, c1 = f.inverti ? dentro : fuori
        let img: CIImage?
        switch f.tipo {
        case .nessuna:
            img = CIImage(color: c0)
        case .cerchio:
            let r = f.raggio * lato, s = max(f.morbidezza, 0.01)
            img = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: cx, y: cy),
                "inputRadius0": CGFloat(r * (1 - s * 0.5)), "inputRadius1": CGFloat(r * (1 + s)),
                "inputColor0": c0, "inputColor1": c1,
            ])?.outputImage
        case .lineare:
            let a = f.angolo * .pi / 180
            let d = SIMD2<Float>(cos(a), sin(a)) * max(f.morbidezza, 0.01) * lato * 0.5
            img = CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: cx - CGFloat(d.x), y: cy - CGFloat(d.y)),
                "inputPoint1": CIVector(x: cx + CGFloat(d.x), y: cy + CGFloat(d.y)),
                "inputColor0": c0, "inputColor1": c1,
            ])?.outputImage
        }
        return (img ?? CIImage(color: c0)).cropped(to: e)
    }
}

extension Array where Element == Nodo {
    /// La catena come funzione colore→colore (per LUT e CDL): i nodi con maschere o effetti non ci entrano,
    /// i gruppi in parallelo si mescolano, nei gruppi a layer (senza maschere) vince il nodo sopra.
    func funzioneLUT() -> (SIMD3<Float>) -> SIMD3<Float> {
        let attivi = filter { $0.attivo && !$0.spaziale }
        var gruppi: [(ModoNodo, [(SIMD3<Float>) -> SIMD3<Float>])] = []
        for (i, n) in attivi.enumerated() {
            if i > 0, n.modo != .serie, !gruppi.isEmpty { gruppi[gruppi.count - 1].0 = n.modo; gruppi[gruppi.count - 1].1.append(n.funzione()) }
            else { gruppi.append((.serie, [n.funzione()])) }
        }
        return { c in
            gruppi.reduce(c) { x, g in
                switch g.0 {
                case .serie: return g.1[0](x)
                case .layer: return g.1.last!(x)
                case .parallelo: return g.1.reduce(SIMD3<Float>.zero) { $0 + $1(x) } / Float(g.1.count)
                }
            }
        }
    }
}
