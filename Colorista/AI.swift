import CoreImage
import Vision

/// Auto colore: gli auto-aggiustamenti di Core Image (analizzano volti, esposizione e dominante) tradotti in una correzione modificabile.
enum AutoColore {
    static func grade(per img: CIImage, contesto: CIContext, spazio: CGColorSpace) -> Grade {
        var g = Grade()
        let filtri = img.autoAdjustmentFilters(options: [.redEye: false, .enhance: true, .level: false])
        var bilanciamento: [CIFilter] = []
        for f in filtri {
            switch f.name {
            case "CIToneCurve":
                // la curva dei toni proposta diventa la curva Y (5 punti, gli stessi del filtro)
                let punti = (0..<5).compactMap { (f.value(forKey: "inputPoint\($0)") as? CIVector).map { SIMD2(Float($0.x), Float($0.y)) } }
                if punti.count == 5, punti.contains(where: { abs($0.x - $0.y) > 0.003 }) { g.curvaY = Curva(punti: punti) }
            case "CIVibrance":
                g.colorBoost = max(-1, min(1, (f.value(forKey: "inputAmount") as? NSNumber)?.floatValue ?? 0))
            case "CIHighlightShadowAdjust":
                let ombre = (f.value(forKey: "inputShadowAmount") as? NSNumber)?.floatValue ?? 0
                let luci = (f.value(forKey: "inputHighlightAmount") as? NSNumber)?.floatValue ?? 1
                g.ombre = max(-1, min(1, ombre * 0.8))
                g.luci = max(-1, min(1, luci - 1))
            case "CITemperatureAndTint", "CIFaceBalance":
                bilanciamento.append(f)
            default:
                break
            }
        }
        // bilanciamento del bianco: si misura cosa fanno i filtri a un grigio medio e lo si rifà con i guadagni per canale
        if !bilanciamento.isEmpty {
            let grigio = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
            var x = grigio
            for f in bilanciamento { f.setValue(x, forKey: kCIInputImageKey); if let o = f.outputImage { x = o } }
            var px = [Float](repeating: 0, count: 4)
            contesto.render(x.cropped(to: CGRect(x: 1, y: 1, width: 1, height: 1)), toBitmap: &px, rowBytes: 16,
                            bounds: CGRect(x: 1, y: 1, width: 1, height: 1), format: .RGBAf, colorSpace: spazio)
            let k = SIMD3(px[0], px[1], px[2]) / 0.5
            if k.min() > 0.2 {
                // normalizzato sulla luminanza: cambia il colore, non l'esposizione
                let l = (k * Grade.lumaRec709).sum()
                g.bilanciamento = limita(k / max(l, 0.0001), SIMD3(repeating: 0.5), SIMD3(repeating: 2))
            }
        }
        return g
    }

    /// Quante cose ha cambiato (per dire all'utente se l'immagine era già a posto).
    static func modifiche(_ g: Grade) -> Int {
        var n = 0
        if !g.curvaY.eDiagonale { n += 1 }
        if g.colorBoost != 0 { n += 1 }
        if g.ombre != 0 || g.luci != 0 { n += 1 }
        if g.bilanciamento != SIMD3(1, 1, 1) { n += 1 }
        return n
    }
}
