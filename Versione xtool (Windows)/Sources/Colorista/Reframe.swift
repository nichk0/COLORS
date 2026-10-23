import AVFoundation
import Vision

/// Reframe automatico: dove sta il soggetto in ogni momento (Vision, attenzione/saliency), con un movimento morbido.
enum Reframe {
    /// (tempo nel file, cx, cy) con cx, cy 0…1 e origine in basso (come Core Image).
    static func analizza(url: URL, da: Double, a: Double, progresso: @escaping @Sendable (Double) -> Void) async throws -> [SIMD3<Float>] {
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        g.appliesPreferredTrackTransform = true
        g.maximumSize = CGSize(width: 512, height: 512)
        g.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        g.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
        let tempi = stride(from: da, through: max(da, a), by: 0.2).map { CMTime(seconds: $0, preferredTimescale: 600) }
        var punti: [SIMD3<Float>] = []
        var ultimo = SIMD2<Float>(0.5, 0.5)
        var n = 0
        for await r in g.images(for: tempi) {
            n += 1
            progresso(Double(n) / Double(tempi.count))
            guard let cg = try? r.image else { continue }
            if let c = soggetto(cg) { ultimo = c }
            punti.append(SIMD3(Float(r.requestedTime.seconds), ultimo.x, ultimo.y))
        }
        return liscia(punti)
    }

    /// Centro del soggetto in un fotogramma: prima i volti, poi le persone, poi l'oggetto più evidente
    /// (picco della mappa di "objectness" di Vision, non il riquadro generico che spesso copre tutta l'immagine).
    static func soggetto(_ cg: CGImage) -> SIMD2<Float>? {
        let h = VNImageRequestHandler(cgImage: cg)
        let volti = VNDetectFaceRectanglesRequest()
        let persone = VNDetectHumanRectanglesRequest()
        persone.upperBodyOnly = false
        let oggetti = VNGenerateObjectnessBasedSaliencyImageRequest()
        try? h.perform([volti, persone, oggetti])
        func centroPesato(_ r: [VNDetectedObjectObservation]) -> SIMD2<Float>? {
            guard !r.isEmpty else { return nil }
            let p = r.map { Float($0.boundingBox.width * $0.boundingBox.height) * max($0.confidence, 0.1) }
            let t = max(p.reduce(0, +), 0.0001)
            return zip(r, p).reduce(SIMD2<Float>.zero) { $0 + SIMD2(Float($1.0.boundingBox.midX), Float($1.0.boundingBox.midY)) * $1.1 } / t
        }
        if let c = centroPesato(volti.results ?? []) { return c }
        if let c = centroPesato(persone.results ?? []) { return c }
        // mappa di salienza (piccola, float): baricentro dei valori più alti
        guard let mappa = oggetti.results?.first?.pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(mappa, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mappa, .readOnly) }
        let w = CVPixelBufferGetWidth(mappa), hh = CVPixelBufferGetHeight(mappa), riga = CVPixelBufferGetBytesPerRow(mappa)
        guard let base = CVPixelBufferGetBaseAddress(mappa) else { return nil }
        var valori = [Float](repeating: 0, count: w * hh)
        for y in 0..<hh {
            let r = (base + y * riga).assumingMemoryBound(to: Float.self)
            for x in 0..<w { valori[y * w + x] = r[x] }
        }
        guard let massimo = valori.max(), massimo > 0.05 else { return nil }
        var s = SIMD2<Float>.zero, tot: Float = 0
        for y in 0..<hh { for x in 0..<w {
            let v = valori[y * w + x]
            guard v > massimo * 0.5 else { continue }       // solo il picco
            let p = v * v
            // la mappa ha l'origine in alto: y si capovolge (Core Image ha l'origine in basso)
            s += SIMD2((Float(x) + 0.5) / Float(w), 1 - (Float(y) + 0.5) / Float(hh)) * p; tot += p
        } }
        return tot > 0 ? s / tot : nil
    }

    /// Movimento da camera: media gaussiana (~0.8 s) e niente sobbalzi piccoli.
    static func liscia(_ p: [SIMD3<Float>]) -> [SIMD3<Float>] {
        guard p.count > 2 else { return p }
        let sigma: Float = 4, r = 12
        return p.indices.map { i in
            var s = SIMD2<Float>.zero, w: Float = 0
            for k in -r...r {
                let j = min(max(i + k, 0), p.count - 1)
                let q = exp(-Float(k * k) / (2 * sigma * sigma))
                s += SIMD2(p[j].y, p[j].z) * q; w += q
            }
            return SIMD3(p[i].x, s.x / w, s.y / w)
        }
    }

    static func centro(_ p: [SIMD3<Float>], a t: Double) -> SIMD2<Float>? { Stabilizzatore.correzione(p, a: t) }
}
