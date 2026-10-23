import AVFoundation
import CoreImage
import Vision

/// Stabilizzazione: misura con Vision lo spostamento tra un fotogramma e il successivo, ricava il percorso della camera,
/// lo ammorbidisce (o lo blocca, "treppiede") e salva la differenza (il tremolio) da togliere in riproduzione ed esportazione.
enum Stabilizzatore {
    /// Analizza il tratto [da, a] del file. Restituisce (tempo, dx, dy) in frazioni del fotogramma, nel verso del compositore
    /// (Core Image, y verso l'alto). `forza` 0…1: quanto si ammorbidisce il movimento (1 = molto liscio).
    static func analizza(url: URL, da: Double, a: Double, forza: Float = 0.6, treppiede: Bool = false,
                         progresso: @escaping @Sendable (Double) -> Void) async throws -> [SIMD3<Float>] {
        let p = try await percorso(url: url, da: da, a: a, progresso: progresso)
        guard p.count > 2 else { return [] }
        let fps = Float(p.count - 1) / max(p.last!.x - p.first!.x, 0.01)
        return correzioni(p, fps: fps, forza: forza, treppiede: treppiede)
    }

    /// Percorso della camera: (tempo, x, y) accumulati in frazioni del fotogramma.
    static func percorso(url: URL, da: Double, a: Double, progresso: @escaping @Sendable (Double) -> Void) async throws -> [SIMD3<Float>] {
        let asset = AVURLAsset(url: url)
        let fps = Double(try await asset.loadTracks(withMediaType: .video).first?.load(.nominalFrameRate) ?? 30)
        let passo = 1 / min(max(fps, 15), 30)          // un'analisi per fotogramma (al massimo 30 al secondo)
        let g = AVAssetImageGenerator(asset: asset)
        g.appliesPreferredTrackTransform = true
        g.maximumSize = CGSize(width: 720, height: 720)
        g.requestedTimeToleranceBefore = .zero
        g.requestedTimeToleranceAfter = .zero
        let tempi = stride(from: da, through: max(da, a), by: passo).map { CMTime(seconds: $0, preferredTimescale: 6000) }
        guard tempi.count > 2 else { return [] }

        // percorso della camera: spostamento accumulato (in frazioni del fotogramma) rispetto al primo
        var percorso: [SIMD3<Float>] = []
        var precedente: CGImage?
        var x: Float = 0, y: Float = 0
        var n = 0
        for await r in g.images(for: tempi) {
            n += 1
            if n % 5 == 0 { progresso(Double(n) / Double(tempi.count)) }
            guard let cg = try? r.image else { continue }
            if let p = precedente {
                let req = VNTranslationalImageRegistrationRequest(targetedCGImage: cg)
                if (try? VNImageRequestHandler(cgImage: p).perform([req])) != nil,
                   let o = req.results?.first as? VNImageTranslationAlignmentObservation {
                    x += Float(o.alignmentTransform.tx) / Float(p.width)
                    y += Float(o.alignmentTransform.ty) / Float(p.height)
                }
            }
            percorso.append(SIMD3(Float(r.requestedTime.seconds), x, y))
            precedente = cg
        }
        return percorso
    }

    /// Dal percorso alle correzioni: percorso − percorso ammorbidito (gaussiana) oppure − media (treppiede).
    static func correzioni(_ percorso: [SIMD3<Float>], fps: Float, forza: Float, treppiede: Bool) -> [SIMD3<Float>] {
        let n = percorso.count
        var liscio = [SIMD2<Float>](repeating: .zero, count: n)
        if treppiede {
            let m = percorso.reduce(SIMD2<Float>.zero) { $0 + SIMD2($1.y, $1.z) } / Float(n)
            liscio = Array(repeating: m, count: n)
        } else {
            // sigma da 0.25 s (leggera) a 1.5 s (molto liscia)
            let sigma = max(1, (0.25 + 1.25 * min(max(forza, 0), 1)) * fps)
            let r = Int(sigma * 3)
            let pesi = (0...r).map { exp(-Float($0 * $0) / (2 * sigma * sigma)) }
            for i in 0..<n {
                var s = SIMD2<Float>.zero, w: Float = 0
                for k in -r...r {
                    let j = min(max(i + k, 0), n - 1)       // ai bordi si ripete il primo/ultimo valore
                    let p = pesi[abs(k)]
                    s += SIMD2(percorso[j].y, percorso[j].z) * p; w += p
                }
                liscio[i] = s / w
            }
        }
        // limite: oltre il 7% servirebbe ingrandire troppo
        return (0..<n).map { i in
            let d = SIMD2(percorso[i].y, percorso[i].z) - liscio[i]
            return SIMD3(percorso[i].x, max(-0.07, min(0.07, d.x)), max(-0.07, min(0.07, d.y)))
        }
    }

    /// Ingrandimento che basta a nascondere i bordi con queste correzioni (da 1.04 a 1.16).
    static func zoom(per c: [SIMD3<Float>]) -> Float {
        let m = c.reduce(Float(0)) { max($0, abs($1.y), abs($1.z)) }
        return min(1.16, max(1.04, 1 + 2 * m + 0.01))
    }

    /// Correzione a un istante del file (interpolata tra i campioni).
    static func correzione(_ c: [SIMD3<Float>], a t: Double) -> SIMD2<Float>? {
        guard let primo = c.first, let ultimo = c.last else { return nil }
        let t = Float(t)
        if t <= primo.x { return SIMD2(primo.y, primo.z) }
        if t >= ultimo.x { return SIMD2(ultimo.y, ultimo.z) }
        // ricerca binaria del tratto
        var lo = 0, hi = c.count - 1
        while hi - lo > 1 { let m = (lo + hi) / 2; if c[m].x <= t { lo = m } else { hi = m } }
        let a = c[lo], b = c[hi]
        let u = (t - a.x) / max(b.x - a.x, 0.0001)
        return SIMD2(a.y + (b.y - a.y) * u, a.z + (b.z - a.z) * u)
    }
}
