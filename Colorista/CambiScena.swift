import AVFoundation
import Vision

/// Divisione per scene: Vision calcola una "impronta" di ogni fotogramma; dove l'impronta cambia di colpo c'è un cambio d'inquadratura.
enum CambiScena {
    /// Tempi (nel file) dei cambi di scena nel tratto [da, a].
    static func tagli(url: URL, da: Double, a: Double, progresso: @escaping @Sendable (Double) -> Void) async throws -> [Double] {
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        g.appliesPreferredTrackTransform = true
        g.maximumSize = CGSize(width: 360, height: 360)
        g.requestedTimeToleranceBefore = .zero
        g.requestedTimeToleranceAfter = .zero
        let passo = 0.1
        let tempi = stride(from: da, through: max(da, a), by: passo).map { CMTime(seconds: $0, preferredTimescale: 600) }
        var distanze: [(t: Double, d: Float)] = []
        var prima: VNFeaturePrintObservation?
        var n = 0
        for await r in g.images(for: tempi) {
            n += 1
            if n % 5 == 0 { progresso(Double(n) / Double(tempi.count)) }
            guard let cg = try? r.image else { continue }
            let req = VNGenerateImageFeaturePrintRequest()
            guard (try? VNImageRequestHandler(cgImage: cg).perform([req])) != nil, let fp = req.results?.first as? VNFeaturePrintObservation else { continue }
            if let p = prima {
                var d: Float = 0
                try? fp.computeDistance(&d, to: p)
                distanze.append((r.requestedTime.seconds, d))
            }
            prima = fp
        }
        guard distanze.count > 3 else { return [] }
        // soglia adattiva: molto sopra il "rumore" normale tra fotogrammi vicini (movimento, luce)
        let valori = distanze.map(\.d).sorted()
        let mediana = valori[valori.count / 2]
        let soglia = max(mediana * 4, valori[Int(Double(valori.count - 1) * 0.9)] * 1.6, 0.35)
        var risultato: [Double] = []
        for (i, x) in distanze.enumerated() where x.d > soglia {
            // un picco solo (il più alto) per cambio, e scene di almeno 0.8 s
            let vicini = distanze[max(0, i - 3)...min(distanze.count - 1, i + 3)]
            guard x.d >= vicini.map(\.d).max()! else { continue }
            // il taglio va sul primo fotogramma della scena nuova: meglio perdere un fotogramma che vederne uno di quella vecchia
            let t = x.t
            if t - da > 0.8, a - t > 0.8, (risultato.last.map { t - $0 > 0.8 } ?? true) { risultato.append(t) }
        }
        return risultato
    }
}
