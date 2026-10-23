import Foundation

/// LUT nel formato .cube (Resolve/Adobe): 3D (`size`³ colori, rosso che varia più in fretta), 1D, o 1D "shaper" + 3D come quelle di DaVinci.
struct CubeLUT: Codable, Hashable {
    var size: Int                       // 0 = nessuna parte 3D (LUT solo 1D)
    var dati: [SIMD3<Float>]
    var titolo = "Colors"
    var dominioMin = SIMD3<Float>(0, 0, 0)
    var dominioMax = SIMD3<Float>(1, 1, 1)
    // parte 1D (LUT 1D, oppure "shaper" che prepara l'ingresso della 3D)
    var shaper: [SIMD3<Float>]?
    var shaperMin: SIMD3<Float>?
    var shaperMax: SIMD3<Float>?

    init(size: Int, dati: [SIMD3<Float>], titolo: String = "Colors",
         dominioMin: SIMD3<Float> = SIMD3(0, 0, 0), dominioMax: SIMD3<Float> = SIMD3(1, 1, 1)) {
        self.size = size; self.dati = dati; self.titolo = titolo; self.dominioMin = dominioMin; self.dominioMax = dominioMax
    }

    enum Errore: LocalizedError {
        case senzaDimensione, datiMancanti(trovati: Int, attesi: Int), rigaNonValida(String)
        var errorDescription: String? {
            switch self {
            case .senzaDimensione: return "Manca LUT_3D_SIZE o LUT_1D_SIZE nel file."
            case let .datiMancanti(t, a): return "La LUT ha \(t) colori invece di \(a)."
            case let .rigaNonValida(r): return "Riga non valida: \(r)"
            }
        }
    }

    /// Descrizione breve, es. "3D 33³" o "1D 4096 + 3D 65³".
    var descrizione: String {
        var p: [String] = []
        if let s = shaper { p.append("1D \(s.count)") }
        if size >= 2 { p.append("3D \(size)³") }
        return p.joined(separator: " + ")
    }

    static func costruisci(grade: Grade, poi importata: CubeLUT?, size: Int) -> CubeLUT {
        let g = grade.pronto()
        return costruisci(size: size) { c in
            let x = g.applica(c)
            return importata?.campiona(x) ?? x
        }
    }

    /// LUT che campiona una qualsiasi funzione colore → colore.
    static func costruisci(size: Int, _ f: (SIMD3<Float>) -> SIMD3<Float>) -> CubeLUT {
        var dati = [SIMD3<Float>](repeating: .zero, count: size * size * size)
        let passo = 1 / Float(size - 1)
        dati.withUnsafeMutableBufferPointer { buf in
            var i = 0
            for b in 0..<size {
                for g in 0..<size {
                    for r in 0..<size {
                        buf[i] = f(SIMD3(Float(r) * passo, Float(g) * passo, Float(b) * passo))
                        i += 1
                    }
                }
            }
        }
        return CubeLUT(size: size, dati: dati)
    }

    /// Applica la LUT: prima la parte 1D (se c'è), poi la 3D con interpolazione trilineare.
    func campiona(_ c: SIMD3<Float>) -> SIMD3<Float> {
        var x = c
        if let s = shaper, s.count >= 2 {
            let lo = shaperMin ?? SIMD3(0, 0, 0), hi = shaperMax ?? SIMD3(1, 1, 1)
            let n = Float(s.count - 1)
            let u = limita((x - lo) / (hi - lo), .zero, SIMD3(repeating: 1)) * n
            func canale(_ v: Float, _ k: Int) -> Float {
                let i = min(Int(v), s.count - 2), f = v - Float(i)
                return s[i][k] + (s[i + 1][k] - s[i][k]) * f
            }
            x = SIMD3(canale(u.x, 0), canale(u.y, 1), canale(u.z, 2))
        }
        guard size >= 2 else { return x }
        let n = Float(size - 1)
        let u = limita((x - dominioMin) / (dominioMax - dominioMin), .zero, SIMD3(repeating: 1)) * n
        let r0 = min(Int(u.x), size - 2), g0 = min(Int(u.y), size - 2), b0 = min(Int(u.z), size - 2)
        let fr = u.x - Float(r0), fg = u.y - Float(g0), fb = u.z - Float(b0)
        func at(_ r: Int, _ g: Int, _ b: Int) -> SIMD3<Float> { dati[r + size * (g + size * b)] }
        let c00 = at(r0, g0, b0) * (1 - fr) + at(r0 + 1, g0, b0) * fr
        let c10 = at(r0, g0 + 1, b0) * (1 - fr) + at(r0 + 1, g0 + 1, b0) * fr
        let c01 = at(r0, g0, b0 + 1) * (1 - fr) + at(r0 + 1, g0, b0 + 1) * fr
        let c11 = at(r0, g0 + 1, b0 + 1) * (1 - fr) + at(r0 + 1, g0 + 1, b0 + 1) * fr
        let c0 = c00 * (1 - fg) + c10 * fg
        let c1 = c01 * (1 - fg) + c11 * fg
        return c0 * (1 - fb) + c1 * fb
    }

    /// Dati per il filtro CIColorCube di Core Image (RGBA float).
    func datiCoreImage() -> Data {
        var f = [Float](); f.reserveCapacity(dati.count * 4)
        for c in dati { f.append(c.x); f.append(c.y); f.append(c.z); f.append(1) }
        return f.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Testo del file .cube, con le sole parole chiave che legge anche DaVinci Resolve (niente DOMAIN_MIN/MAX).
    func testoCube() -> String {
        let pulito = titolo.replacingOccurrences(of: "\"", with: "'")
        var s = "TITLE \"\(pulito)\"\n# Creata con Colors\n\nLUT_3D_SIZE \(size)\n\n"
        s.reserveCapacity(s.count + dati.count * 28)
        for c in dati {
            s += String(format: "%.6f %.6f %.6f\n", c.x, c.y, c.z)
        }
        return s
    }

    /// Legge un file .cube: 3D, 1D o 1D shaper + 3D, con gli intervalli d'ingresso di DaVinci e di Adobe.
    static func leggi(_ testo: String) throws -> CubeLUT {
        var size3 = 0, size1 = 0, titolo = "LUT"
        var valori = [SIMD3<Float>]()
        var min3 = SIMD3<Float>(0, 0, 0), max3 = SIMD3<Float>(1, 1, 1)
        var min1 = SIMD3<Float>(0, 0, 0), max1 = SIMD3<Float>(1, 1, 1)
        for rigaGrezza in testo.split(whereSeparator: \.isNewline) {
            let riga = rigaGrezza.trimmingCharacters(in: .whitespaces)
            if riga.isEmpty || riga.hasPrefix("#") { continue }
            let parti = riga.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let primo = parti.first else { continue }
            let numeri = parti.dropFirst().compactMap { Float($0) }
            switch primo.uppercased() {
            case "TITLE":
                titolo = riga.dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: " \t\""))
            case "LUT_1D_SIZE":
                size1 = numeri.first.map { Int($0) } ?? 0
            case "LUT_3D_SIZE":
                size3 = numeri.first.map { Int($0) } ?? 0
            case "LUT_1D_INPUT_RANGE":
                if numeri.count == 2 { min1 = SIMD3(repeating: numeri[0]); max1 = SIMD3(repeating: numeri[1]) }
            case "LUT_3D_INPUT_RANGE":
                if numeri.count == 2 { min3 = SIMD3(repeating: numeri[0]); max3 = SIMD3(repeating: numeri[1]) }
            case "LUT_3D_INPUT_RANGE_R", "LUT_3D_INPUT_RANGE_G", "LUT_3D_INPUT_RANGE_B":
                if numeri.count == 2 {
                    let k = ["R": 0, "G": 1, "B": 2][String(primo.uppercased().suffix(1))] ?? 0
                    min3[k] = numeri[0]; max3[k] = numeri[1]
                }
            case "DOMAIN_MIN", "DOMAIN_MAX":
                // Adobe: vale per l'unica tabella presente
                if numeri.count == 3 {
                    let v = SIMD3(numeri[0], numeri[1], numeri[2])
                    if primo.uppercased() == "DOMAIN_MIN" { min3 = v; min1 = v } else { max3 = v; max1 = v }
                }
            default:
                let v = parti.compactMap { Float($0) }
                guard v.count == 3 else {
                    if Float(primo) != nil { throw Errore.rigaNonValida(riga) }
                    continue   // parola chiave sconosciuta: si ignora
                }
                valori.append(SIMD3(v[0], v[1], v[2]))
            }
        }
        guard size1 >= 2 || size3 >= 2 else { throw Errore.senzaDimensione }
        let attesi = (size1 >= 2 ? size1 : 0) + (size3 >= 2 ? size3 * size3 * size3 : 0)
        guard valori.count == attesi else { throw Errore.datiMancanti(trovati: valori.count, attesi: attesi) }
        // nei file DaVinci la tabella 1D viene prima della 3D
        var lut = CubeLUT(size: size3 >= 2 ? size3 : 0, dati: size3 >= 2 ? Array(valori.suffix(size3 * size3 * size3)) : [],
                          titolo: titolo, dominioMin: min3, dominioMax: max3)
        if size1 >= 2 {
            lut.shaper = Array(valori.prefix(size1))
            lut.shaperMin = min1; lut.shaperMax = max1
        }
        return lut
    }
}
