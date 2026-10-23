import Foundation
import simd

private extension Float {
    var clampato: Float { Swift.min(1, Swift.max(0, self)) }
}

/// Una ruota colore: spostamento di tinta (x, y nel cerchio) + cursore "master" sotto la ruota.
struct Wheel: Codable, Hashable {
    var x: Float = 0
    var y: Float = 0
    var master: Float = 0

    /// Angolo del rosso sulla ruota, come in un vettorscopio (circa 103°).
    static let angoloRosso: Float = 103 * .pi / 180

    /// Direzione di colore (somma dei tre canali = 0) per un angolo della ruota.
    static func direzione(_ angolo: Float) -> SIMD3<Float> {
        let a = angolo - angoloRosso
        return SIMD3(cos(a), cos(a - 2 * .pi / 3), cos(a + 2 * .pi / 3))
    }

    /// Spinta di colore per canale: intensità = distanza del puntino dal centro.
    var colore: SIMD3<Float> {
        let m = min(1, (x * x + y * y).squareRoot())
        guard m > 0.0001 else { return .zero }
        return Wheel.direzione(atan2(y, x)) * m
    }

    var neutra: Bool { x == 0 && y == 0 && master == 0 }

    /// Vista a barre (Color Bars di DaVinci): sposta un solo canale (0 = R, 1 = G, 2 = B) di `d`.
    /// La parte uguale per tutti va nella rotella master, il resto diventa il puntino della ruota.
    mutating func spostaCanale(_ canale: Int, di d: Float) {
        var c = colore
        var spinta = SIMD3<Float>(repeating: -d / 3)
        spinta[canale] = d * 2 / 3
        c += spinta
        // il master pesa il doppio del colore (vedi Lift/Gamma/Gain in GradePronto): metà della parte comune
        master += d / 6
        // dal colore (somma 0) al puntino della ruota
        let m = (simd_length(c) / 1.2247449).clampato
        guard m > 0.0001 else { x = 0; y = 0; return }
        let cosA = c.x / m
        let sinA = (c.y / m + 0.5 * cosA) / 0.8660254
        let t = atan2(sinA, cosA) + Wheel.angoloRosso
        x = m * cos(t); y = m * sin(t)
    }

    static func mescola(_ a: Wheel, _ b: Wheel, _ t: Float) -> Wheel {
        Wheel(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t, master: a.master + (b.master - a.master) * t)
    }
}

/// Curva con punti di controllo (x, y in 0…1, o y in -1…1 per le curve di tinta).
struct Curva: Codable, Hashable {
    var punti: [SIMD2<Float>]

    static let diagonale = Curva(punti: [SIMD2(0, 0), SIMD2(1, 1)])
    static let piatta = Curva(punti: [])

    var eDiagonale: Bool { punti == Curva.diagonale.punti }
    var ePiatta: Bool { punti.isEmpty || punti.allSatisfy { abs($0.y) < 0.0005 } }

    static func mescola(_ a: Curva, _ b: Curva, _ t: Float) -> Curva {
        guard a.punti.count == b.punti.count else { return t < 0.5 ? a : b }
        return Curva(punti: zip(a.punti, b.punti).map { $0 + ($1 - $0) * t })
    }
}

/// Un vettore del Color Slice: tinta, saturazione e densità di una fascia di colore.
struct Fetta: Codable, Hashable {
    var tinta: Float = 0       // -1…1 (spostamento)
    var saturazione: Float = 0 // -1…1
    var densita: Float = 0     // -1…1 (positivo = più scuro e "pieno")
}

/// Tutta la correzione colore di un nodo. `pronto()` prepara le tabelle, poi `applica` lavora su un colore RGB 0…1.
struct Grade: Codable, Hashable {
    // primarie
    var lift = Wheel()
    var gamma = Wheel()
    var gain = Wheel()
    var offset = Wheel()
    // ruote log (spostamenti per zona di luminanza)
    var logOmbre = Wheel()
    var logMedi = Wheel()
    var logLuci = Wheel()
    var logBasso: Float = 0.3
    var logAlto: Float = 0.7
    // ruote HDR a zone: nero, scuri, ombre, luce, alte luci, speculari (master in stop)
    var zone: [Wheel] = Array(repeating: Wheel(), count: 6)

    var esposizione: Float = 0      // stop
    var temperatura: Float = 0      // -1 freddo … +1 caldo
    var tinta: Float = 0            // -1 verde … +1 magenta
    var nero = SIMD3<Float>(0, 0, 0)            // livello del nero per canale (auto-bilanciamento)
    var bilanciamento = SIMD3<Float>(1, 1, 1)   // dal contagocce del bianco / auto
    var contrasto: Float = 1
    var pivot: Float = 0.435
    var ombre: Float = 0
    var luci: Float = 0
    var saturazione: Float = 1
    var colorBoost: Float = 0
    var rotazioneTinta: Float = 0   // gradi
    /// Lum Mix (come DaVinci): quanto contano le rotelle Y (master) di Lift/Gamma/Gain/Offset. 1 = tutto, 0 = spente.
    var lumMix: Float = 1

    // RGB Mixer (righe: uscita R, G, B)
    var mixer: [Float] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
    var mixerPreservaLuma = false
    var mixerMono = false

    // curve
    var curvaY = Curva.diagonale
    var curvaR = Curva.diagonale
    var curvaG = Curva.diagonale
    var curvaB = Curva.diagonale
    var hueVsHue = Curva.piatta
    var hueVsSat = Curva.piatta
    var hueVsLum = Curva.piatta
    var lumVsSat = Curva.piatta
    var satVsSat = Curva.piatta
    var satVsLum = Curva.piatta
    /// Intensità delle curve Custom (Y, R, G, B): 1 = piena, 0 = curva spenta.
    var intensitaCurve = SIMD4<Float>(1, 1, 1, 1)
    /// Soft Clip: livelli di taglio di neri e luci e quanto è morbido il ginocchio.
    var clipBasso: Float = 0
    var clipAlto: Float = 1
    var morbidoBasso: Float = 0
    var morbidoAlto: Float = 0

    // Color Slice: rosso, giallo, verde, ciano, blu, magenta
    var fette: [Fetta] = Array(repeating: Fetta(), count: 6)
    // Color Warper: spostamenti (Δtinta, Δsat) su una griglia 12 tinte × 3 anelli di saturazione
    var warper: [SIMD2<Float>] = Array(repeating: .zero, count: Grade.warperTinte * Grade.warperAnelli)
    static let warperTinte = 12, warperAnelli = 3

    // HDR (come la palette HDR di DaVinci): per ogni fascia saturazione e ampiezza, una ruota globale e i controlli generali
    var zoneSat: [Float] = Array(repeating: 1, count: 6)          // saturazione della fascia (1 = invariata)
    var zoneAmpiezza: [Float] = Array(repeating: 1, count: 6)     // quanto la fascia si allarga sulle vicine
    var hdrGlobale = Wheel()                                      // esposizione (stop) e colore su tutta l'immagine
    var hdrTemp: Float = 0, hdrTint: Float = 0, hdrHue: Float = 0 // hue in gradi
    var hdrContrasto: Float = 1, hdrPivot: Float = 0.435
    var hdrNeroOffset: Float = 0                                  // B/Ofs: sposta il nero

    static let lumaRec709 = SIMD3<Float>(0.2126, 0.7152, 0.0722)
    static let nomiZone = ["Black", "Dark", "Shadows", "Light", "Highlight", "Specular"]
    static let centriZone: [Float] = [0.03, 0.14, 0.3, 0.52, 0.76, 0.95]
    static let nomiFette = ["Red", "Yellow", "Green", "Cyan", "Blue", "Magenta"]

    init() {}

    // decodifica tollerante: i progetti salvati con versioni precedenti restano apribili
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ d: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? d }
        lift = v(.lift, lift); gamma = v(.gamma, gamma); gain = v(.gain, gain); offset = v(.offset, offset)
        logOmbre = v(.logOmbre, logOmbre); logMedi = v(.logMedi, logMedi); logLuci = v(.logLuci, logLuci)
        logBasso = v(.logBasso, logBasso); logAlto = v(.logAlto, logAlto); zone = v(.zone, zone)
        esposizione = v(.esposizione, esposizione); temperatura = v(.temperatura, temperatura); tinta = v(.tinta, tinta)
        nero = v(.nero, nero); bilanciamento = v(.bilanciamento, bilanciamento)
        contrasto = v(.contrasto, contrasto); pivot = v(.pivot, pivot); ombre = v(.ombre, ombre); luci = v(.luci, luci)
        saturazione = v(.saturazione, saturazione); colorBoost = v(.colorBoost, colorBoost); rotazioneTinta = v(.rotazioneTinta, rotazioneTinta)
        lumMix = v(.lumMix, lumMix)
        mixer = v(.mixer, mixer); mixerPreservaLuma = v(.mixerPreservaLuma, mixerPreservaLuma); mixerMono = v(.mixerMono, mixerMono)
        curvaY = v(.curvaY, curvaY); curvaR = v(.curvaR, curvaR); curvaG = v(.curvaG, curvaG); curvaB = v(.curvaB, curvaB)
        hueVsHue = v(.hueVsHue, hueVsHue); hueVsSat = v(.hueVsSat, hueVsSat); hueVsLum = v(.hueVsLum, hueVsLum)
        lumVsSat = v(.lumVsSat, lumVsSat); satVsSat = v(.satVsSat, satVsSat); satVsLum = v(.satVsLum, satVsLum)
        intensitaCurve = v(.intensitaCurve, intensitaCurve)
        clipBasso = v(.clipBasso, clipBasso); clipAlto = v(.clipAlto, clipAlto); morbidoBasso = v(.morbidoBasso, morbidoBasso); morbidoAlto = v(.morbidoAlto, morbidoAlto)
        fette = v(.fette, fette); warper = v(.warper, warper)
        zoneSat = v(.zoneSat, zoneSat); zoneAmpiezza = v(.zoneAmpiezza, zoneAmpiezza); hdrGlobale = v(.hdrGlobale, hdrGlobale)
        hdrTemp = v(.hdrTemp, hdrTemp); hdrTint = v(.hdrTint, hdrTint); hdrHue = v(.hdrHue, hdrHue)
        hdrContrasto = v(.hdrContrasto, hdrContrasto); hdrPivot = v(.hdrPivot, hdrPivot); hdrNeroOffset = v(.hdrNeroOffset, hdrNeroOffset)
    }

    /// Qualcosa della palette HDR è diverso dal normale.
    var hdrModificato: Bool {
        zone.contains { !$0.neutra } || zoneSat.contains { $0 != 1 } || zoneAmpiezza.contains { $0 != 1 } || !hdrGlobale.neutra
            || hdrTemp != 0 || hdrTint != 0 || hdrHue != 0 || hdrContrasto != 1 || hdrPivot != 0.435 || hdrNeroOffset != 0
    }

    mutating func azzeraHDR() {
        let b = Grade()
        zone = b.zone; zoneSat = b.zoneSat; zoneAmpiezza = b.zoneAmpiezza; hdrGlobale = b.hdrGlobale
        hdrTemp = 0; hdrTint = 0; hdrHue = 0; hdrContrasto = 1; hdrPivot = 0.435; hdrNeroOffset = 0
    }

    func pronto() -> GradePronto { GradePronto(self) }
    func applica(_ c: SIMD3<Float>) -> SIMD3<Float> { pronto().applica(c) }

    /// Interpolazione tra due correzioni (per i keyframe).
    static func mescola(_ a: Grade, _ b: Grade, _ t: Float) -> Grade {
        if t <= 0 { return a }
        if t >= 1 { return b }
        func f(_ x: Float, _ y: Float) -> Float { x + (y - x) * t }
        func w(_ x: Wheel, _ y: Wheel) -> Wheel { Wheel.mescola(x, y, t) }
        func c(_ x: Curva, _ y: Curva) -> Curva { Curva.mescola(x, y, t) }
        var g = a
        g.lift = w(a.lift, b.lift); g.gamma = w(a.gamma, b.gamma); g.gain = w(a.gain, b.gain); g.offset = w(a.offset, b.offset)
        g.logOmbre = w(a.logOmbre, b.logOmbre); g.logMedi = w(a.logMedi, b.logMedi); g.logLuci = w(a.logLuci, b.logLuci)
        g.logBasso = f(a.logBasso, b.logBasso); g.logAlto = f(a.logAlto, b.logAlto)
        g.zone = zip(a.zone, b.zone).map { w($0, $1) }
        g.esposizione = f(a.esposizione, b.esposizione); g.temperatura = f(a.temperatura, b.temperatura); g.tinta = f(a.tinta, b.tinta)
        g.nero = a.nero + (b.nero - a.nero) * t; g.bilanciamento = a.bilanciamento + (b.bilanciamento - a.bilanciamento) * t
        g.contrasto = f(a.contrasto, b.contrasto); g.pivot = f(a.pivot, b.pivot); g.ombre = f(a.ombre, b.ombre); g.luci = f(a.luci, b.luci)
        g.saturazione = f(a.saturazione, b.saturazione); g.colorBoost = f(a.colorBoost, b.colorBoost); g.rotazioneTinta = f(a.rotazioneTinta, b.rotazioneTinta); g.lumMix = f(a.lumMix, b.lumMix)
        g.mixer = zip(a.mixer, b.mixer).map { f($0, $1) }
        g.curvaY = c(a.curvaY, b.curvaY); g.curvaR = c(a.curvaR, b.curvaR); g.curvaG = c(a.curvaG, b.curvaG); g.curvaB = c(a.curvaB, b.curvaB)
        g.hueVsHue = c(a.hueVsHue, b.hueVsHue); g.hueVsSat = c(a.hueVsSat, b.hueVsSat); g.hueVsLum = c(a.hueVsLum, b.hueVsLum)
        g.lumVsSat = c(a.lumVsSat, b.lumVsSat); g.satVsSat = c(a.satVsSat, b.satVsSat); g.satVsLum = c(a.satVsLum, b.satVsLum)
        g.intensitaCurve = a.intensitaCurve + (b.intensitaCurve - a.intensitaCurve) * t
        g.clipBasso = f(a.clipBasso, b.clipBasso); g.clipAlto = f(a.clipAlto, b.clipAlto)
        g.morbidoBasso = f(a.morbidoBasso, b.morbidoBasso); g.morbidoAlto = f(a.morbidoAlto, b.morbidoAlto)
        g.fette = zip(a.fette, b.fette).map { Fetta(tinta: f($0.tinta, $1.tinta), saturazione: f($0.saturazione, $1.saturazione), densita: f($0.densita, $1.densita)) }
        g.warper = zip(a.warper, b.warper).map { $0 + ($1 - $0) * t }
        g.zoneSat = zip(a.zoneSat, b.zoneSat).map { f($0, $1) }; g.zoneAmpiezza = zip(a.zoneAmpiezza, b.zoneAmpiezza).map { f($0, $1) }
        g.hdrGlobale = w(a.hdrGlobale, b.hdrGlobale)
        g.hdrTemp = f(a.hdrTemp, b.hdrTemp); g.hdrTint = f(a.hdrTint, b.hdrTint); g.hdrHue = f(a.hdrHue, b.hdrHue)
        g.hdrContrasto = f(a.hdrContrasto, b.hdrContrasto); g.hdrPivot = f(a.hdrPivot, b.hdrPivot); g.hdrNeroOffset = f(a.hdrNeroOffset, b.hdrNeroOffset)
        return g
    }
}

/// Correzione con costanti e tabelle già calcolate: si usa per riempire le LUT (decine di migliaia di colori).
struct GradePronto {
    let g: Grade
    let moltiplica: SIMD3<Float>
    let L: SIMD3<Float>, G: SIMD3<Float>, esp: SIMD3<Float>, off: SIMD3<Float>
    let logS: SIMD3<Float>, logM: SIMD3<Float>, logH: SIMD3<Float>
    let tY: [Float]?, tR: [Float]?, tG: [Float]?, tB: [Float]?
    let hh: [Float]?, hs: [Float]?, hl: [Float]?, ls: [Float]?, ss: [Float]?, sl: [Float]?
    let conSoftClip: Bool
    let rot: Matrice3?
    let conLog: Bool
    let zoneAttive: Bool
    let mix: Matrice3?
    let conFette: Bool
    let conWarper: Bool
    let rotHDR: Matrice3?
    let moltHDR: SIMD3<Float>

    init(_ g: Grade) {
        self.g = g
        let uno = SIMD3<Float>(repeating: 1)
        moltiplica = SIMD3<Float>(repeating: exp2(g.esposizione)) * g.bilanciamento
            * SIMD3(1 + 0.22 * g.temperatura, 1 - 0.18 * g.tinta, 1 - 0.22 * g.temperatura)
        let y = g.lumMix
        L = SIMD3(repeating: g.lift.master * 0.5 * y) + g.lift.colore * 0.25
        G = SIMD3(repeating: exp2(g.gain.master * y)) * (uno + g.gain.colore * 0.5)
        let e = g.gamma.colore * 0.45 + SIMD3(repeating: g.gamma.master * 0.9 * y)
        esp = SIMD3(exp(-e.x), exp(-e.y), exp(-e.z))
        off = SIMD3(repeating: g.offset.master * 0.3) + g.offset.colore * 0.12
        logS = SIMD3(repeating: g.logOmbre.master * 0.25) + g.logOmbre.colore * 0.12
        logM = SIMD3(repeating: g.logMedi.master * 0.25) + g.logMedi.colore * 0.12
        logH = SIMD3(repeating: g.logLuci.master * 0.25) + g.logLuci.colore * 0.12
        conLog = !(g.logOmbre.neutra && g.logMedi.neutra && g.logLuci.neutra)
        zoneAttive = g.hdrModificato
        rotHDR = g.hdrHue == 0 ? nil : Matrice3.rotazioneTinta(gradi: g.hdrHue)
        moltHDR = SIMD3(1 + 0.22 * g.hdrTemp, 1 - 0.18 * g.hdrTint, 1 - 0.22 * g.hdrTemp)
        tY = g.curvaY.eDiagonale ? nil : Spline.tabellaMonotona(g.curvaY.punti, 1024)
        tR = g.curvaR.eDiagonale ? nil : Spline.tabellaMonotona(g.curvaR.punti, 1024)
        tG = g.curvaG.eDiagonale ? nil : Spline.tabellaMonotona(g.curvaG.punti, 1024)
        tB = g.curvaB.eDiagonale ? nil : Spline.tabellaMonotona(g.curvaB.punti, 1024)
        hh = g.hueVsHue.ePiatta ? nil : Spline.tabellaPeriodica(g.hueVsHue.punti, 720)
        hs = g.hueVsSat.ePiatta ? nil : Spline.tabellaPeriodica(g.hueVsSat.punti, 720)
        hl = g.hueVsLum.ePiatta ? nil : Spline.tabellaPeriodica(g.hueVsLum.punti, 720)
        ls = g.lumVsSat.ePiatta ? nil : Spline.tabellaMonotona(g.lumVsSat.punti, 512)
        ss = g.satVsSat.ePiatta ? nil : Spline.tabellaMonotona(g.satVsSat.punti, 512)
        sl = g.satVsLum.ePiatta ? nil : Spline.tabellaMonotona(g.satVsLum.punti, 512)
        conSoftClip = g.clipBasso > 0.0005 || g.clipAlto < 0.9995 || g.morbidoBasso > 0.0005 || g.morbidoAlto > 0.0005
        rot = g.rotazioneTinta == 0 ? nil : Matrice3.rotazioneTinta(gradi: g.rotazioneTinta)
        let m = g.mixer
        let identita: [Float] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        mix = (m == identita && !g.mixerMono) || m.count != 9 ? nil
            : Matrice3(r0: SIMD3(m[0], m[1], m[2]), r1: SIMD3(m[3], m[4], m[5]), r2: SIMD3(m[6], m[7], m[8]))
        conFette = g.fette.contains { $0 != Fetta() }
        conWarper = g.warper.contains { $0 != .zero }
    }

    /// Soft Clip di un canale: sotto `clipBasso` e sopra `clipAlto` si arriva al limite con una curva morbida.
    static func softClip(_ v: Float, _ g: Grade) -> Float {
        var x = v
        let alto = min(max(g.clipAlto, 0.5), 1.5)
        let ginocchioA = alto - max(g.morbidoAlto, 0.002) * 0.4
        if x > ginocchioA {
            let w = alto - ginocchioA
            x = ginocchioA + w * (1 - exp(-(x - ginocchioA) / w))
        }
        let basso = min(max(g.clipBasso, -0.2), 0.5)
        let ginocchioB = basso + max(g.morbidoBasso, 0.002) * 0.4
        if x < ginocchioB {
            let w = ginocchioB - basso
            x = ginocchioB - w * (1 - exp(-(ginocchioB - x) / w))
        }
        return x
    }

    @inline(__always) static func liscia(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    func applica(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let uno = SIMD3<Float>(repeating: 1)
        // 1. livelli del nero, esposizione, contagocce e bilanciamento del bianco
        var x = (c - g.nero) * moltiplica
        // 2. RGB Mixer
        if let m = mix {
            let l0 = luma(x)
            x = m * x
            if g.mixerMono { x = SIMD3(repeating: x.x) }
            else if g.mixerPreservaLuma { let l1 = luma(x); if l1 > 0.0001 { x *= l0 / l1 } }
        }
        // 3. Lift (ombre, il bianco resta fermo) e Gain (luci)
        x = (x + L * (uno - x)) * G
        // 4. Gamma: potenza sui mezzitoni
        x = SIMD3(GradePronto.potenza(x.x, esp.x), GradePronto.potenza(x.y, esp.y), GradePronto.potenza(x.z, esp.z))
        // 5. ruote HDR a zone: esposizione (stop) e colore per fascia di luminanza
        if zoneAttive {
            let l = luma(x)
            var pesi = [Float](repeating: 0, count: 6), tot: Float = 0
            for i in 0..<6 {
                let d = (l - Grade.centriZone[i]) / (0.11 * max(0.2, g.zoneAmpiezza[i]))
                pesi[i] = exp(-d * d); tot += pesi[i]
            }
            // esposizione e colore per fascia, più la ruota globale
            var k = SIMD3(repeating: g.hdrGlobale.master) + g.hdrGlobale.colore * 0.5
            var sat: Float = 0
            for i in 0..<6 {
                let w = pesi[i] / max(tot, 0.0001)
                if !g.zone[i].neutra { k += (SIMD3(repeating: g.zone[i].master) + g.zone[i].colore * 0.5) * w }
                sat += g.zoneSat[i] * w
            }
            x *= SIMD3(exp2(k.x), exp2(k.y), exp2(k.z))
            // saturazione per fascia (mantiene la luminanza)
            if abs(sat - 1) > 0.0001 { let l2 = luma(x); x = SIMD3(repeating: l2) + (x - SIMD3(repeating: l2)) * sat }
            // controlli generali HDR: temperatura/tinta, contrasto attorno al pivot, spostamento del nero, tinta
            x *= moltHDR
            if g.hdrContrasto != 1 { x = (x - SIMD3(repeating: g.hdrPivot)) * g.hdrContrasto + SIMD3(repeating: g.hdrPivot) }
            if g.hdrNeroOffset != 0 { x += SIMD3(repeating: g.hdrNeroOffset * 0.1) }
            if let r = rotHDR { x = r * x }
        }
        // 6. ruote log: spostamenti solo nella loro zona di luminanza
        if conLog {
            let l = luma(x)
            let wS = 1 - GradePronto.liscia(g.logBasso - 0.12, g.logBasso + 0.12, l)
            let wH = GradePronto.liscia(g.logAlto - 0.12, g.logAlto + 0.12, l)
            let wM = max(0, 1 - wS - wH)
            x += logS * wS + logM * wM + logH * wH
        }
        // 7. Offset
        x += off
        // 8. contrasto attorno al pivot
        x = (x - SIMD3(repeating: g.pivot)) * g.contrasto + SIMD3(repeating: g.pivot)
        // 9. ombre / luci (recupero dettagli)
        if g.ombre != 0 || g.luci != 0 {
            let l = luma(x)
            x += SIMD3(repeating: g.ombre * 0.22 * (1 - GradePronto.liscia(0, 0.55, l)) + g.luci * 0.22 * GradePronto.liscia(0.45, 1, l))
        }
        // 10. curve personalizzate: Y su tutti i canali, poi R, G, B
        let k = g.intensitaCurve
        if let t = tY { x += (SIMD3(Spline.leggi(t, x.x), Spline.leggi(t, x.y), Spline.leggi(t, x.z)) - x) * k.x }
        if let t = tR { x.x += (Spline.leggi(t, x.x) - x.x) * k.y }
        if let t = tG { x.y += (Spline.leggi(t, x.y) - x.y) * k.z }
        if let t = tB { x.z += (Spline.leggi(t, x.z) - x.z) * k.w }
        // Soft Clip: neri e luci arrivano al limite con un ginocchio morbido invece di tagliarsi di netto
        if conSoftClip {
            x = SIMD3(GradePronto.softClip(x.x, g), GradePronto.softClip(x.y, g), GradePronto.softClip(x.z, g))
        }
        // 11. lavorazioni in tinta/saturazione: curve di tinta, Color Slice, Color Warper
        if hh != nil || hs != nil || hl != nil || ls != nil || ss != nil || sl != nil || conFette || conWarper {
            x = limita(x, .zero, uno)
            var hsv = Colore.hsv(x)
            let h0 = hsv.x, s0 = hsv.y, l0 = luma(x)
            var dLum: Float = 0
            if let t = hh { hsv.x += Spline.leggiCiclica(t, h0) * 0.5 }
            var k: Float = 1
            if let t = hs { k *= 1 + Spline.leggiCiclica(t, h0) }
            if let t = ls { k *= 1 + Spline.leggi(t, l0) }
            if let t = ss { k *= 1 + Spline.leggi(t, s0) }
            if let t = hl { dLum += Spline.leggiCiclica(t, h0) * 1.2 }
            if let t = sl { dLum += Spline.leggi(t, s0) * 1.2 }
            if conFette {
                for i in 0..<6 where g.fette[i] != Fetta() {
                    var d = abs(h0 - Float(i) / 6); d = min(d, 1 - d)
                    let w = max(0, 1 - d * 6); let ww = w * w * (3 - 2 * w)
                    guard ww > 0 else { continue }
                    let f = g.fette[i]
                    hsv.x += f.tinta * 0.06 * ww
                    k *= 1 + f.saturazione * ww
                    dLum -= f.densita * 0.8 * ww * s0     // densità: i colori saturi si scuriscono
                    k *= 1 + max(0, f.densita) * 0.3 * ww
                }
            }
            if conWarper {
                let d = warp(h0, s0)
                hsv.x += d.x
                hsv.y = hsv.y * k + d.y
                k = 1
            }
            hsv.x = hsv.x.truncatingRemainder(dividingBy: 1); if hsv.x < 0 { hsv.x += 1 }
            hsv.y = min(1, max(0, hsv.y * k))
            x = Colore.rgb(hsv)
            // tinta e saturazione cambiano il colore ma non la luminosità (come il "Lum Mix" di DaVinci)
            let l1 = luma(x)
            if l1 > 0.0001 { x *= l0 / l1 }
            if dLum != 0 { x *= exp2(dLum) }
        }
        // 12. Color Boost: satura di più i colori poco saturi
        if g.colorBoost != 0 {
            let mx = max(x.x, x.y, x.z), mn = min(x.x, x.y, x.z)
            let s = mx > 0.0001 ? (mx - mn) / mx : 0
            let l = luma(x), k = 1 + g.colorBoost * (1 - s)
            x = SIMD3(repeating: l) + (x - SIMD3(repeating: l)) * k
        }
        // 13. saturazione mantenendo la luminanza
        let l = luma(x)
        x = SIMD3(repeating: l) + (x - SIMD3(repeating: l)) * g.saturazione
        // 14. rotazione di tinta
        if let r = rot { x = r * x }
        return limita(x, .zero, uno)
    }

    /// Spostamento del Color Warper per una tinta/saturazione: interpolazione sulla griglia (anello 0 = centro fermo).
    func warp(_ h: Float, _ s: Float) -> SIMD2<Float> {
        let nt = Grade.warperTinte, na = Grade.warperAnelli
        let u = h * Float(nt), i0 = Int(u) % nt, i1 = (i0 + 1) % nt, fu = u - Float(Int(u))
        let v = min(max(s, 0), 1) * Float(na)            // 0 = centro, 1…na = anelli
        let a0 = min(Int(v), na), a1 = min(a0 + 1, na), fv = v - Float(a0)
        func p(_ i: Int, _ a: Int) -> SIMD2<Float> { a == 0 ? .zero : g.warper[(a - 1) * nt + i] }
        let q0 = p(i0, a0) * (1 - fu) + p(i1, a0) * fu
        let q1 = p(i0, a1) * (1 - fu) + p(i1, a1) * fu
        return q0 * (1 - fv) + q1 * fv
    }

    @inline(__always) func luma(_ x: SIMD3<Float>) -> Float { (x * Grade.lumaRec709).sum() }

    /// Potenza che non esplode sui valori negativi.
    @inline(__always) static func potenza(_ v: Float, _ p: Float) -> Float { v <= 0 ? v : pow(v, p) }
}

@inline(__always) func limita(_ v: SIMD3<Float>, _ lo: SIMD3<Float>, _ hi: SIMD3<Float>) -> SIMD3<Float> {
    SIMD3(min(max(v.x, lo.x), hi.x), min(max(v.y, lo.y), hi.y), min(max(v.z, lo.z), hi.z))
}
