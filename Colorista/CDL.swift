import Foundation

/// ASC CDL (Slope, Offset, Power + Saturation): lo standard che la Galleria di DaVinci importa da file .cdl / .cc / .ccc.
struct CDL: Equatable {
    var slope = SIMD3<Float>(1, 1, 1)
    var offset = SIMD3<Float>(0, 0, 0)
    var power = SIMD3<Float>(1, 1, 1)
    var saturazione: Float = 1

    /// Formula ASC CDL v1.2: SOP per canale, poi saturazione con luma Rec.709.
    func applica(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let v = c * slope + offset
        let p = SIMD3(pow(max(v.x, 0), power.x), pow(max(v.y, 0), power.y), pow(max(v.z, 0), power.z))
        let l = (p * Grade.lumaRec709).sum()
        return SIMD3(repeating: l) + (p - SIMD3(repeating: l)) * saturazione
    }

    func xml(id: String, descrizione: String) -> String {
        func t(_ v: SIMD3<Float>) -> String { String(format: "%.6f %.6f %.6f", v.x, v.y, v.z) }
        let idPulito = id.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "&", with: "e")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <ColorDecisionList xmlns="urn:ASC:CDL:v1.01">
            <ColorDecision>
                <ColorCorrection id="\(idPulito)">
                    <SOPNode>
                        <Description>\(descrizione.replacingOccurrences(of: "<", with: "").replacingOccurrences(of: "&", with: "e"))</Description>
                        <Slope>\(t(slope))</Slope>
                        <Offset>\(t(offset))</Offset>
                        <Power>\(t(power))</Power>
                    </SOPNode>
                    <SatNode>
                        <Saturation>\(String(format: "%.6f", saturazione))</Saturation>
                    </SatNode>
                </ColorCorrection>
            </ColorDecision>
        </ColorDecisionList>

        """
    }

    enum Errore: LocalizedError {
        case nonCDL
        var errorDescription: String? { "Il file non contiene una correzione ASC CDL (Slope/Offset/Power)." }
    }

    /// Legge la prima correzione da un .cdl, .cc o .ccc.
    static func leggi(_ testo: String) throws -> CDL {
        func tre(_ tag: String) -> SIMD3<Float>? {
            guard let a = testo.range(of: "<\(tag)>"), let b = testo.range(of: "</\(tag)>", range: a.upperBound..<testo.endIndex) else { return nil }
            let n = testo[a.upperBound..<b.lowerBound].split(whereSeparator: { $0 == " " || $0 == "\t" || $0.isNewline }).compactMap { Float($0) }
            return n.count == 3 ? SIMD3(n[0], n[1], n[2]) : nil
        }
        guard let s = tre("Slope"), let o = tre("Offset"), let p = tre("Power") else { throw Errore.nonCDL }
        var c = CDL(slope: s, offset: o, power: p)
        if let a = testo.range(of: "<Saturation>"), let b = testo.range(of: "</Saturation>", range: a.upperBound..<testo.endIndex),
           let v = Float(testo[a.upperBound..<b.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)) {
            c.saturazione = v
        }
        return c
    }

    /// Cerca il CDL che si avvicina di più a una correzione qualsiasi.
    /// Restituisce anche l'errore medio (0…1): sopra ~0.02 la correzione usa cose che un CDL non sa fare (curve, secondarie…).
    static func stima(_ f: (SIMD3<Float>) -> SIMD3<Float>) -> (CDL, errore: Float) {
        let n = 33
        let xs = (0..<n).map { Float($0) / Float(n - 1) }
        let grigi = xs.map { f(SIMD3(repeating: $0)) }
        var campioni: [SIMD3<Float>] = []
        for r in stride(from: Float(0.1), through: 0.9, by: 0.2) {
            for g in stride(from: Float(0.1), through: 0.9, by: 0.2) {
                for b in stride(from: Float(0.1), through: 0.9, by: 0.2) { campioni.append(SIMD3(r, g, b)) }
            }
        }
        let attesi = campioni.map(f)
        var cdl = CDL()
        // SOP e saturazione si influenzano (la saturazione agisce anche sui grigi se i canali hanno slope diversi):
        // si stimano a giri alterni, togliendo ogni volta la saturazione dalla scala dei grigi.
        for _ in 0..<6 {
            let s = max(cdl.saturazione, 0.05)
            let ys = grigi.map { y -> SIMD3<Float> in
                let l = (y * Grade.lumaRec709).sum()
                return SIMD3(repeating: l) + (y - SIMD3(repeating: l)) / s
            }
            cdl = sop(xs, ys, saturazione: cdl.saturazione)
            cdl.saturazione = saturazione(cdl, campioni, attesi)
        }
        cdl = rifinisci(cdl, campioni + xs.map { SIMD3(repeating: $0) }, attesi + grigi)
        var err: Float = 0
        for (c, y) in zip(campioni, attesi) { let d = limita(cdl.applica(c), .zero, SIMD3(repeating: 1)) - y; err += (abs(d.x) + abs(d.y) + abs(d.z)) / 3 }
        return (cdl, err / Float(campioni.count))
    }

    /// Slope/Offset/Power per canale dalla scala dei grigi (già senza saturazione).
    private static func sop(_ xs: [Float], _ ys: [SIMD3<Float>], saturazione: Float) -> CDL {
        var cdl = CDL(); cdl.saturazione = saturazione
        for k in 0..<3 {
            var migliore: (Float, Float, Float, Float) = (1, 0, 1, .infinity)   // slope, offset, power, errore
            for j in 0..<90 {
                let p = exp(log(0.3) + (log(3.0) - log(0.3)) * Float(j) / 89)
                // linearizza: y^(1/p) = slope·x + offset → minimi quadrati
                var sx: Float = 0, sy: Float = 0, sxx: Float = 0, sxy: Float = 0, m: Float = 0
                for (x, y) in zip(xs, ys) where y[k] > 0.0005 {
                    let z = pow(y[k], 1 / p)
                    sx += x; sy += z; sxx += x * x; sxy += x * z; m += 1
                }
                guard m >= 4 else { continue }
                let det = m * sxx - sx * sx
                guard abs(det) > 1e-8 else { continue }
                let s = (m * sxy - sx * sy) / det, o = (sy - s * sx) / m
                var e: Float = 0
                for (x, y) in zip(xs, ys) { let d = pow(max(x * s + o, 0), p) - y[k]; e += d * d }
                if e < migliore.3 { migliore = (s, o, p, e) }
            }
            cdl.slope[k] = migliore.0; cdl.offset[k] = migliore.1; cdl.power[k] = migliore.2
        }
        return cdl
    }

    /// Rifinitura: discesa per coordinate sui 10 parametri, minimizzando l'errore quadratico su tutti i colori di prova.
    private static func rifinisci(_ c0: CDL, _ ingressi: [SIMD3<Float>], _ attesi: [SIMD3<Float>]) -> CDL {
        func vettore(_ c: CDL) -> [Float] { [c.slope.x, c.slope.y, c.slope.z, c.offset.x, c.offset.y, c.offset.z, c.power.x, c.power.y, c.power.z, c.saturazione] }
        func cdl(_ v: [Float]) -> CDL { CDL(slope: SIMD3(v[0], v[1], v[2]), offset: SIMD3(v[3], v[4], v[5]), power: SIMD3(max(v[6], 0.05), max(v[7], 0.05), max(v[8], 0.05)), saturazione: max(v[9], 0)) }
        func costo(_ v: [Float]) -> Float {
            let c = cdl(v); var e: Float = 0
            for (x, y) in zip(ingressi, attesi) { let d = limita(c.applica(x), .zero, SIMD3(repeating: 1)) - y; e += (d * d).sum() }
            return e
        }
        var v = vettore(c0), migliore = costo(v)
        var passi: [Float] = [0.05, 0.05, 0.05, 0.02, 0.02, 0.02, 0.05, 0.05, 0.05, 0.05]
        for _ in 0..<80 {
            var migliorato = false
            for i in 0..<v.count {
                for segno: Float in [1, -1] {
                    var w = v; w[i] += segno * passi[i]
                    let e = costo(w)
                    if e < migliore { migliore = e; v = w; migliorato = true; break }
                }
            }
            if !migliorato {
                passi = passi.map { $0 * 0.5 }
                if passi.max()! < 1e-5 { break }
            }
        }
        return cdl(v)
    }

    /// Saturazione che avvicina di più i colori di prova, dati Slope/Offset/Power.
    private static func saturazione(_ c: CDL, _ campioni: [SIMD3<Float>], _ attesi: [SIMD3<Float>]) -> Float {
        var num: Float = 0, den: Float = 0
        let sop = CDL(slope: c.slope, offset: c.offset, power: c.power)
        for (x, y) in zip(campioni, attesi) {
            let v = sop.applica(x), l = (v * Grade.lumaRec709).sum()
            let dv = v - SIMD3(repeating: l), dy = y - SIMD3(repeating: l)
            num += (dv * dy).sum(); den += (dv * dv).sum()
        }
        return den > 1e-6 ? max(0, min(4, num / den)) : 1
    }
}
