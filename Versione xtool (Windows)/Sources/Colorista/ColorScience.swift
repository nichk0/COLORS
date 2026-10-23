import Foundation

// MARK: - spline per le curve

enum Spline {
    /// Curva monotona (Fritsch–Carlson) campionata in `n` valori su x = 0…1. Fuori dai punti resta piatta.
    static func tabellaMonotona(_ p0: [SIMD2<Float>], _ n: Int) -> [Float] {
        let p = p0.sorted { $0.x < $1.x }
        if p.isEmpty { return [Float](repeating: 0, count: n) }
        if p.count == 1 { return [Float](repeating: p[0].y, count: n) }
        let k = p.count
        var d = [Float](repeating: 0, count: k - 1)
        for i in 0..<(k - 1) { d[i] = (p[i + 1].y - p[i].y) / max(p[i + 1].x - p[i].x, 1e-5) }
        var m = [Float](repeating: 0, count: k)
        m[0] = d[0]; m[k - 1] = d[k - 2]
        if k > 2 { for i in 1..<(k - 1) { m[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2 } }
        for i in 0..<(k - 1) {
            if abs(d[i]) < 1e-6 { m[i] = 0; m[i + 1] = 0; continue }
            let a = m[i] / d[i], b = m[i + 1] / d[i], h = a * a + b * b
            if h > 9 { let t = 3 / h.squareRoot(); m[i] = t * a * d[i]; m[i + 1] = t * b * d[i] }
        }
        var out = [Float](repeating: 0, count: n)
        var seg = 0
        for j in 0..<n {
            let x = Float(j) / Float(n - 1)
            if x <= p[0].x { out[j] = p[0].y; continue }
            if x >= p[k - 1].x { out[j] = p[k - 1].y; continue }
            while seg < k - 2 && x > p[seg + 1].x { seg += 1 }
            let h = max(p[seg + 1].x - p[seg].x, 1e-5), t = (x - p[seg].x) / h
            let t2 = t * t, t3 = t2 * t
            out[j] = (2 * t3 - 3 * t2 + 1) * p[seg].y + (t3 - 2 * t2 + t) * h * m[seg]
                + (-2 * t3 + 3 * t2) * p[seg + 1].y + (t3 - t2) * h * m[seg + 1]
        }
        return out
    }

    /// Curva chiusa ad anello (per la tinta: 0 e 1 sono lo stesso rosso), Catmull-Rom.
    static func tabellaPeriodica(_ p0: [SIMD2<Float>], _ n: Int) -> [Float] {
        let p = p0.sorted { $0.x < $1.x }
        if p.isEmpty { return [Float](repeating: 0, count: n) }
        if p.count == 1 { return [Float](repeating: p[0].y, count: n) }
        let k = p.count
        func pt(_ i: Int) -> SIMD2<Float> {
            let q = ((i % k) + k) % k
            let giri = Float((i - q) / k)
            return SIMD2(p[q].x + giri, p[q].y)
        }
        var out = [Float](repeating: 0, count: n)
        for j in 0..<n {
            var x = Float(j) / Float(n)
            if x < p[0].x { x += 1 }
            var i = 0
            while i < k && !(x >= pt(i).x && x < pt(i + 1).x) { i += 1 }
            let a = pt(i - 1), b = pt(i), c = pt(i + 1), d = pt(i + 2)
            let h = max(c.x - b.x, 1e-5), t = (x - b.x) / h
            // tangenti limitate: dove la curva è piatta o cambia verso non "sborda" (niente effetti su tinte lontane)
            let sab = (b.y - a.y) / max(b.x - a.x, 1e-5), sbc = (c.y - b.y) / h, scd = (d.y - c.y) / max(d.x - c.x, 1e-5)
            let m1 = (sab * sbc <= 0 ? 0 : (sab + sbc) / 2) * h
            let m2 = (sbc * scd <= 0 ? 0 : (sbc + scd) / 2) * h
            let t2 = t * t, t3 = t2 * t
            out[j] = (2 * t3 - 3 * t2 + 1) * b.y + (t3 - 2 * t2 + t) * m1 + (-2 * t3 + 3 * t2) * c.y + (t3 - t2) * m2
        }
        return out
    }

    @inline(__always) static func leggi(_ t: [Float], _ x: Float) -> Float {
        let n = t.count - 1
        let u = min(max(x, 0), 1) * Float(n)
        let i = min(Int(u), n - 1), f = u - Float(i)
        return t[i] + (t[i + 1] - t[i]) * f
    }

    @inline(__always) static func leggiCiclica(_ t: [Float], _ x: Float) -> Float {
        let n = t.count
        var u = x.truncatingRemainder(dividingBy: 1); if u < 0 { u += 1 }
        let v = u * Float(n)
        let i = Int(v) % n, f = v - Float(Int(v))
        return t[i] + (t[(i + 1) % n] - t[i]) * f
    }
}

// MARK: - spazi colore

enum Colore {
    /// RGB → (tinta 0…1, saturazione, valore). Tinta 0 = rosso.
    static func hsv(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let mx = max(c.x, c.y, c.z), mn = min(c.x, c.y, c.z), d = mx - mn
        var h: Float = 0
        if d > 1e-6 {
            if mx == c.x { h = (c.y - c.z) / d }
            else if mx == c.y { h = 2 + (c.z - c.x) / d }
            else { h = 4 + (c.x - c.y) / d }
            h /= 6; if h < 0 { h += 1 }
        }
        return SIMD3(h, mx > 1e-6 ? d / mx : 0, mx)
    }

    static func rgb(_ hsv: SIMD3<Float>) -> SIMD3<Float> {
        let h = hsv.x * 6, s = hsv.y, v = hsv.z
        let i = Int(floor(h)) % 6, f = h - floor(h)
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        switch (i + 6) % 6 {
        case 0: return SIMD3(v, t, p)
        case 1: return SIMD3(q, v, p)
        case 2: return SIMD3(p, v, t)
        case 3: return SIMD3(p, q, v)
        case 4: return SIMD3(t, p, v)
        default: return SIMD3(v, p, q)
        }
    }
}

/// Matrice 3×3 (righe).
struct Matrice3: Equatable {
    var r0: SIMD3<Float>, r1: SIMD3<Float>, r2: SIMD3<Float>

    static func * (m: Matrice3, v: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3((m.r0 * v).sum(), (m.r1 * v).sum(), (m.r2 * v).sum())
    }
    static func * (a: Matrice3, b: Matrice3) -> Matrice3 {
        let c0 = SIMD3(b.r0.x, b.r1.x, b.r2.x), c1 = SIMD3(b.r0.y, b.r1.y, b.r2.y), c2 = SIMD3(b.r0.z, b.r1.z, b.r2.z)
        func riga(_ r: SIMD3<Float>) -> SIMD3<Float> { SIMD3((r * c0).sum(), (r * c1).sum(), (r * c2).sum()) }
        return Matrice3(r0: riga(a.r0), r1: riga(a.r1), r2: riga(a.r2))
    }
    var inversa: Matrice3 {
        let a = r0, b = r1, c = r2
        let x = SIMD3(b.y * c.z - b.z * c.y, b.z * c.x - b.x * c.z, b.x * c.y - b.y * c.x)
        let det = (a * x).sum()
        let i0 = SIMD3(b.y * c.z - b.z * c.y, a.z * c.y - a.y * c.z, a.y * b.z - a.z * b.y)
        let i1 = SIMD3(b.z * c.x - b.x * c.z, a.x * c.z - a.z * c.x, a.z * b.x - a.x * b.z)
        let i2 = SIMD3(b.x * c.y - b.y * c.x, a.y * c.x - a.x * c.y, a.x * b.y - a.y * b.x)
        return Matrice3(r0: i0 / det, r1: i1 / det, r2: i2 / det)
    }

    /// Rotazione attorno all'asse dei grigi (gira le tinte, i grigi restano grigi).
    static func rotazioneTinta(gradi: Float) -> Matrice3 {
        let t = gradi * .pi / 180, c = cos(t), s = sin(t) / Float(3).squareRoot(), k = (1 - c) / 3
        let a = c + k, b = k - s, d = k + s
        return Matrice3(r0: SIMD3(a, b, d), r1: SIMD3(d, a, b), r2: SIMD3(b, d, a))
    }

    /// Da RGB lineare a XYZ, dati i primari (xy) e il bianco.
    static func versoXYZ(r: SIMD2<Float>, g: SIMD2<Float>, b: SIMD2<Float>, bianco w: SIMD2<Float>) -> Matrice3 {
        func xyz(_ p: SIMD2<Float>) -> SIMD3<Float> { SIMD3(p.x / p.y, 1, (1 - p.x - p.y) / p.y) }
        let R = xyz(r), G = xyz(g), B = xyz(b), W = xyz(w)
        let P = Matrice3(r0: SIMD3(R.x, G.x, B.x), r1: SIMD3(R.y, G.y, B.y), r2: SIMD3(R.z, G.z, B.z))
        let S = P.inversa * W
        return Matrice3(r0: P.r0 * S, r1: P.r1 * S, r2: P.r2 * S)
    }
}

// MARK: - Color Space Transform (camera Log → Rec.709)

struct CST: Codable, Hashable {
    enum Camera: String, Codable, CaseIterable, Identifiable {
        case bmdGen5 = "Blackmagic Film Gen 5"
        case appleLog = "Apple Log (iPhone)"
        case slog3 = "Sony S-Log3 / S-Gamut3.Cine"
        case logc3 = "ARRI LogC3 / Wide Gamut 3"
        case vlog = "Panasonic V-Log / V-Gamut"
        var id: String { rawValue }
    }
    var camera: Camera = .bmdGen5
    var esposizione: Float = 0
    var toneMapping = true
    var compressioneGamut = true

    init() {}
    init(camera: Camera) { self.camera = camera }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        camera = (try? c.decode(Camera.self, forKey: .camera)) ?? .bmdGen5
        esposizione = (try? c.decode(Float.self, forKey: .esposizione)) ?? 0
        toneMapping = (try? c.decode(Bool.self, forKey: .toneMapping)) ?? true
        compressioneGamut = (try? c.decode(Bool.self, forKey: .compressioneGamut)) ?? true
    }

    static let d65 = SIMD2<Float>(0.3127, 0.3290)
    static let da709: Matrice3 = Matrice3.versoXYZ(r: SIMD2(0.64, 0.33), g: SIMD2(0.30, 0.60), b: SIMD2(0.15, 0.06), bianco: d65).inversa

    static func matrice(_ c: Camera) -> Matrice3 {
        let m: Matrice3
        switch c {
        case .bmdGen5: m = Matrice3.versoXYZ(r: SIMD2(0.7177, 0.3171), g: SIMD2(0.2280, 0.8616), b: SIMD2(0.1006, -0.0820), bianco: d65)   // Blackmagic Wide Gamut
        case .appleLog: m = Matrice3.versoXYZ(r: SIMD2(0.708, 0.292), g: SIMD2(0.170, 0.797), b: SIMD2(0.131, 0.046), bianco: d65)   // Rec.2020
        case .slog3: m = Matrice3.versoXYZ(r: SIMD2(0.766, 0.275), g: SIMD2(0.225, 0.800), b: SIMD2(0.089, -0.087), bianco: d65)
        case .logc3: m = Matrice3.versoXYZ(r: SIMD2(0.6840, 0.3130), g: SIMD2(0.2210, 0.8480), b: SIMD2(0.0861, -0.1020), bianco: d65)
        case .vlog: m = Matrice3.versoXYZ(r: SIMD2(0.730, 0.280), g: SIMD2(0.165, 0.840), b: SIMD2(0.100, -0.030), bianco: d65)
        }
        return da709 * m
    }

    /// Curva Log della camera → luce lineare della scena (0.18 = grigio medio).
    static func lineare(_ v: Float, _ c: Camera) -> Float {
        switch c {
        case .bmdGen5:
            let a: Float = 8.283605932402494, b: Float = 0.09246575342465753, cc: Float = 0.08692876065491224
            let d: Float = 0.005494072432257808, e: Float = 0.5300133392291939
            return v < a * 0.005 + b ? (v - b) / a : exp((v - e) / cc) - d
        case .appleLog:
            let r0: Float = -0.05641088, rt: Float = 0.01, cc: Float = 47.28711236
            let beta: Float = 0.00964052, gamma: Float = 0.08550479, delta: Float = 0.69336945
            let pt = cc * (rt - r0) * (rt - r0)
            if v >= pt { return exp2((v - delta) / gamma) - beta }
            return v >= 0 ? (v / cc).squareRoot() + r0 : r0
        case .slog3:
            if v >= 171.2102946929 / 1023 { return pow(10, (v * 1023 - 420) / 261.5) * 0.19 - 0.01 }
            return (v * 1023 - 95) * 0.01125 / (171.2102946929 - 95)
        case .logc3:
            let cut: Float = 0.010591, a: Float = 5.555556, b: Float = 0.052272, cc: Float = 0.247190
            let d: Float = 0.385537, e: Float = 5.367655, f: Float = 0.092809
            return v > e * cut + f ? (pow(10, (v - d) / cc) - b) / a : (v - f) / e
        case .vlog:
            return v < 0.181 ? (v - 0.125) / 5.6 : pow(10, (v - 0.598206) / 0.241514) - 0.00873
        }
    }

    func pronto() -> CSTPronto { CSTPronto(self) }
}

struct CSTPronto {
    let cst: CST
    let m: Matrice3
    let k: Float
    init(_ c: CST) { cst = c; m = CST.matrice(c.camera); k = exp2(c.esposizione) }

    /// Compressione del gamut (stile ACES): i colori fuori dal Rec.709 rientrano dolcemente invece di tagliarsi.
    static func comprimiGamut(_ x: SIMD3<Float>) -> SIMD3<Float> {
        let ach = max(x.x, x.y, x.z)
        guard ach > 0 else { return x }
        func c(_ v: Float) -> Float {
            let d = (ach - v) / ach                      // distanza dall'acromatico (1 = sul bordo del gamut)
            let soglia: Float = 0.8, limite: Float = 1.25
            guard d > soglia else { return v }
            let s = (limite - soglia) / pow(pow((1 - soglia) / (limite - soglia), -1.2) - 1, 1 / 1.2)
            let dn = soglia + s * ((d - soglia) / s) / pow(1 + pow((d - soglia) / s, 1.2), 1 / 1.2)
            return ach - dn * ach
        }
        return SIMD3(c(x.x), c(x.y), c(x.z))
    }

    func applica(_ c: SIMD3<Float>) -> SIMD3<Float> {
        var x = SIMD3(CST.lineare(c.x, cst.camera), CST.lineare(c.y, cst.camera), CST.lineare(c.z, cst.camera))
        x = m * x * k
        if cst.compressioneGamut { x = CSTPronto.comprimiGamut(x) }
        x = SIMD3(max(x.x, 0), max(x.y, 0), max(x.z, 0))
        if cst.toneMapping {
            // tone mapping morbido: le luci forti rientrano senza tagliarsi (bianco a circa 4 volte il diffuso)
            x = x * (SIMD3<Float>(repeating: 1) + x / 16) / (SIMD3<Float>(repeating: 1) + x)
        }
        // codifica per schermo Rec.709 gamma 2.4
        x = limita(x, .zero, SIMD3(repeating: 1))
        return SIMD3(pow(x.x, 1 / 2.4), pow(x.y, 1 / 2.4), pow(x.z, 1 / 2.4))
    }
}

// MARK: - qualificatore HSL e finestre

struct Qualificatore: Codable, Hashable {
    var attivo = false
    var tinta: Float = 0.08          // centro 0…1
    var larghezzaTinta: Float = 0.06
    var satMin: Float = 0.1
    var satMax: Float = 1
    var lumMin: Float = 0
    var lumMax: Float = 1
    var morbidezza: Float = 0.05
    var inverti = false

    /// Quanto il colore è "dentro" la selezione (0…1).
    func chiave(_ c: SIMD3<Float>) -> Float {
        let hsv = Colore.hsv(limita(c, .zero, SIMD3(repeating: 1)))
        let l = (c * Grade.lumaRec709).sum()
        var dh = abs(hsv.x - tinta); dh = min(dh, 1 - dh)
        let s = max(morbidezza, 0.001)
        let kh = 1 - GradePronto.liscia(larghezzaTinta, larghezzaTinta + s, dh)
        let ks = GradePronto.liscia(satMin - s, satMin, hsv.y) * (1 - GradePronto.liscia(satMax, satMax + s, hsv.y))
        let kl = GradePronto.liscia(lumMin - s, lumMin, l) * (1 - GradePronto.liscia(lumMax, lumMax + s, l))
        let k = kh * ks * kl
        return inverti ? 1 - k : k
    }

    /// Imposta la selezione attorno a un colore preso col contagocce.
    mutating func centra(su c: SIMD3<Float>) {
        let hsv = Colore.hsv(limita(c, .zero, SIMD3(repeating: 1)))
        let l = (c * Grade.lumaRec709).sum()
        tinta = hsv.x
        larghezzaTinta = 0.05
        satMin = max(0, hsv.y - 0.25); satMax = min(1, hsv.y + 0.35)
        lumMin = max(0, l - 0.3); lumMax = min(1, l + 0.3)
        attivo = true
    }
}

struct Finestra: Codable, Hashable {
    enum Tipo: String, Codable, CaseIterable, Identifiable {
        case nessuna = "None", cerchio = "Circle", lineare = "Linear"
        var id: String { rawValue }
    }
    var tipo: Tipo = .nessuna
    var centro = SIMD2<Float>(0.5, 0.5)   // 0…1, y verso il basso
    var raggio: Float = 0.25               // rispetto al lato lungo
    var morbidezza: Float = 0.3
    var angolo: Float = 90                 // gradi, per la finestra lineare
    var inverti = false
    /// Tracker: dove sta la finestra in ogni fotogramma (posizione, dimensione, rotazione).
    var traccia: [PuntoTraccia] = []

    /// La finestra al tempo `t`: segue la sua traccia, se c'è.
    func a(_ t: Double?) -> Finestra {
        guard let t, let p = Finestra.punto(traccia, t) else { return self }
        var f = self
        f.centro = p.centro
        f.raggio = raggio * p.scala
        f.angolo = angolo + p.rotazione
        return f
    }

    /// Punto della traccia al tempo `t` (interpolato tra i fotogrammi; fuori dalla traccia resta al primo o all'ultimo).
    static func punto(_ tr: [PuntoTraccia], _ t: Double) -> PuntoTraccia? {
        guard let primo = tr.first, let ultimo = tr.last else { return nil }
        if t <= primo.tempo { return primo }
        if t >= ultimo.tempo { return ultimo }
        // ricerca binaria: le tracce possono avere migliaia di punti
        var lo = 0, hi = tr.count - 1
        while hi - lo > 1 { let m = (lo + hi) / 2; if tr[m].tempo <= t { lo = m } else { hi = m } }
        let a = tr[lo], b = tr[hi]
        let u = Float((t - a.tempo) / max(b.tempo - a.tempo, 0.0001))
        return PuntoTraccia(tempo: t, centro: a.centro + (b.centro - a.centro) * u,
                            scala: a.scala + (b.scala - a.scala) * u, rotazione: a.rotazione + (b.rotazione - a.rotazione) * u)
    }
}

extension Finestra {
    /// Decodifica tollerante: i progetti salvati prima del tracker restano apribili.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ d: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? d }
        tipo = v(.tipo, .nessuna); centro = v(.centro, SIMD2(0.5, 0.5)); raggio = v(.raggio, 0.25)
        morbidezza = v(.morbidezza, 0.3); angolo = v(.angolo, 90); inverti = v(.inverti, false); traccia = v(.traccia, [])
    }
}
