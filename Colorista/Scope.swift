import UIKit

enum TipoScope: String, CaseIterable, Identifiable {
    case nessuno = "None", parade = "Parade", waveform = "Waveform", vettorscopio = "Vectorscope", istogramma = "Histogram", cie = "CIE 1931"
    var id: String { rawValue }
}

/// Scope calcolati sulla CPU da una copia piccola dell'immagine (256 px di larghezza).
enum Scope {
    static func disegna(_ t: TipoScope, pixel p: [UInt8], larghezza w: Int, altezza h: Int) -> UIImage? {
        switch t {
        case .nessuno: return nil
        case .waveform: return forma(p, w, h, parade: false)
        case .parade: return forma(p, w, h, parade: true)
        case .vettorscopio: return vettorscopio(p, w, h)
        case .istogramma: return istogramma(p, w, h)
        case .cie: return cie(p, w, h)
        }
    }

    private static func forma(_ p: [UInt8], _ w: Int, _ h: Int, parade: Bool) -> UIImage? {
        let H = 128, W = parade ? 384 : 256
        var acc = [[Float]](repeating: [Float](repeating: 0, count: W * H), count: 3)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let r = Float(p[i]), g = Float(p[i + 1]), b = Float(p[i + 2])
                if parade {
                    let cx = x * 128 / w
                    for (k, v) in [r, g, b].enumerated() {
                        let row = H - 1 - Int(v / 255 * Float(H - 1))
                        acc[k][row * W + cx + k * 128] += 1
                    }
                } else {
                    let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
                    let row = H - 1 - Int(l / 255 * Float(H - 1))
                    acc[0][row * W + x] += 1
                }
            }
        }
        let norma = Float(h) * (parade ? 0.04 : 0.06)
        var out = [UInt8](repeating: 0, count: W * H * 4)
        for j in 0..<(W * H) {
            if parade {
                let k = j % W / 128, v = min(1, (acc[k][j] / norma).squareRoot())
                let col: SIMD3<Float> = k == 0 ? SIMD3(1, 0.35, 0.3) : k == 1 ? SIMD3(0.35, 1, 0.4) : SIMD3(0.35, 0.55, 1)
                scrivi(&out, j, col * v)
            } else {
                let v = min(1, (acc[0][j] / norma).squareRoot())
                scrivi(&out, j, SIMD3(0.85, 0.95, 0.85) * v)
            }
        }
        return conGriglia(out, W, H) { c, s in
            c.setStrokeColor(UIColor(white: 1, alpha: 0.12).cgColor)
            c.setLineWidth(1)
            for k in 0...4 {
                let y = CGFloat(k) / 4 * (s.height - 1)
                c.move(to: CGPoint(x: 0, y: y)); c.addLine(to: CGPoint(x: s.width, y: y))
            }
            if parade { for k in 1...2 { let x = CGFloat(k * 128); c.move(to: CGPoint(x: x, y: 0)); c.addLine(to: CGPoint(x: x, y: s.height)) } }
            c.strokePath()
        }
    }

    private static func vettorscopio(_ p: [UInt8], _ w: Int, _ h: Int) -> UIImage? {
        let S = 200
        var acc = [Float](repeating: 0, count: S * S)
        for i in stride(from: 0, to: w * h * 4, by: 4) {
            let r = Float(p[i]) / 255, g = Float(p[i + 1]) / 255, b = Float(p[i + 2]) / 255
            let cb = -0.1146 * r - 0.3854 * g + 0.5 * b
            let cr = 0.5 * r - 0.4542 * g - 0.0458 * b
            let x = Int(100 + cb * 180), y = Int(100 - cr * 180)
            if x >= 0, x < S, y >= 0, y < S { acc[y * S + x] += 1 }
        }
        let norma = Float(w * h) * 0.002
        var out = [UInt8](repeating: 0, count: S * S * 4)
        for j in 0..<(S * S) {
            let v = min(1, (acc[j] / norma).squareRoot())
            scrivi(&out, j, SIMD3(0.8, 0.95, 0.85) * v)
        }
        return conGriglia(out, S, S) { c, s in
            let centro = CGPoint(x: s.width / 2, y: s.height / 2)
            c.setStrokeColor(UIColor(white: 1, alpha: 0.18).cgColor)
            c.setLineWidth(1)
            c.addEllipse(in: CGRect(x: 10, y: 10, width: s.width - 20, height: s.height - 20))
            c.strokePath()
            // bersagli dei colori primari e secondari al 75%
            let colori: [(SIMD3<Float>, UIColor)] = [
                (SIMD3(0.75, 0, 0), .red), (SIMD3(0, 0.75, 0), .green), (SIMD3(0, 0, 0.75), .blue),
                (SIMD3(0.75, 0.75, 0), .yellow), (SIMD3(0, 0.75, 0.75), .cyan), (SIMD3(0.75, 0, 0.75), .magenta),
            ]
            for (v, col) in colori {
                let cb = -0.1146 * v.x - 0.3854 * v.y + 0.5 * v.z, cr = 0.5 * v.x - 0.4542 * v.y - 0.0458 * v.z
                let pt = CGPoint(x: CGFloat(100 + cb * 180), y: CGFloat(100 - cr * 180))
                c.setStrokeColor(col.withAlphaComponent(0.7).cgColor)
                c.stroke(CGRect(x: pt.x - 4, y: pt.y - 4, width: 8, height: 8))
            }
            // linea dei toni pelle (circa 123°)
            let a = 123 * CGFloat.pi / 180
            c.setStrokeColor(UIColor(red: 1, green: 0.75, blue: 0.5, alpha: 0.45).cgColor)
            c.move(to: centro)
            c.addLine(to: CGPoint(x: centro.x + cos(a) * 95, y: centro.y - sin(a) * 95))
            c.strokePath()
        }
    }

    private static func istogramma(_ p: [UInt8], _ w: Int, _ h: Int) -> UIImage? {
        var bins = [[Float]](repeating: [Float](repeating: 0, count: 256), count: 3)
        for i in stride(from: 0, to: w * h * 4, by: 4) {
            bins[0][Int(p[i])] += 1; bins[1][Int(p[i + 1])] += 1; bins[2][Int(p[i + 2])] += 1
        }
        let mx = max(1, bins.flatMap { $0[2..<254] }.max() ?? 1)
        let W = 256, H = 110
        var out = [UInt8](repeating: 0, count: W * H * 4)
        for x in 0..<W {
            let alt = (0..<3).map { Int(min(1, bins[$0][x] / mx) * Float(H - 1)) }
            for y in 0..<H {
                let da = H - 1 - y
                let v = SIMD3<Float>(da < alt[0] ? 0.85 : 0, da < alt[1] ? 0.85 : 0, da < alt[2] ? 0.9 : 0)
                scrivi(&out, y * W + x, v)
            }
        }
        return conGriglia(out, W, H) { _, _ in }
    }

    /// Diagramma di cromaticità CIE 1931 xy con i triangoli Rec.709 e Rec.2020.
    private static func cie(_ p: [UInt8], _ w: Int, _ h: Int) -> UIImage? {
        let S = 200
        func pos(_ x: Float, _ y: Float) -> (Int, Int) { (Int(x / 0.8 * Float(S - 1)), Int((1 - y / 0.9) * Float(S - 1))) }
        var acc = [Float](repeating: 0, count: S * S)
        for i in stride(from: 0, to: w * h * 4, by: 4) {
            let rgb = SIMD3(Float(p[i]), Float(p[i + 1]), Float(p[i + 2])) / 255
            let lin = SIMD3(pow(rgb.x, 2.4), pow(rgb.y, 2.4), pow(rgb.z, 2.4))
            let X = (SIMD3<Float>(0.4124, 0.3576, 0.1805) * lin).sum()
            let Y = (SIMD3<Float>(0.2126, 0.7152, 0.0722) * lin).sum()
            let Z = (SIMD3<Float>(0.0193, 0.1192, 0.9505) * lin).sum()
            let s = X + Y + Z
            guard s > 0.002 else { continue }
            let (x, y) = pos(X / s, Y / s)
            if x >= 0, x < S, y >= 0, y < S { acc[y * S + x] += 1 }
        }
        let norma = Float(w * h) * 0.003
        var out = [UInt8](repeating: 0, count: S * S * 4)
        for j in 0..<(S * S) { scrivi(&out, j, SIMD3(1, 1, 1) * min(1, (acc[j] / norma).squareRoot())) }
        return conGriglia(out, S, S) { c, _ in
            func pt(_ x: Float, _ y: Float) -> CGPoint { let q = pos(x, y); return CGPoint(x: q.0, y: q.1) }
            // contorno approssimato dei colori spettrali
            let locus: [(Float, Float)] = [(0.1741, 0.0050), (0.1440, 0.0297), (0.1241, 0.0578), (0.0913, 0.1327), (0.0454, 0.2950), (0.0082, 0.5384),
                                           (0.0139, 0.7502), (0.0743, 0.8338), (0.1547, 0.8059), (0.2296, 0.7543), (0.3016, 0.6923), (0.3731, 0.6245),
                                           (0.4441, 0.5547), (0.5125, 0.4866), (0.5752, 0.4242), (0.6270, 0.3725), (0.6658, 0.3340), (0.7347, 0.2653)]
            c.setStrokeColor(UIColor(white: 1, alpha: 0.3).cgColor); c.setLineWidth(1)
            c.addLines(between: locus.map { pt($0.0, $0.1) }); c.closePath(); c.strokePath()
            c.setStrokeColor(UIColor(red: 1, green: 0.6, blue: 0.3, alpha: 0.8).cgColor)
            c.addLines(between: [pt(0.64, 0.33), pt(0.30, 0.60), pt(0.15, 0.06)]); c.closePath(); c.strokePath()
            c.setStrokeColor(UIColor(red: 0.4, green: 0.7, blue: 1, alpha: 0.6).cgColor)
            c.addLines(between: [pt(0.708, 0.292), pt(0.170, 0.797), pt(0.131, 0.046)]); c.closePath(); c.strokePath()
            let d = pt(0.3127, 0.3290)
            c.setFillColor(UIColor.white.cgColor); c.fill(CGRect(x: d.x - 2, y: d.y - 2, width: 4, height: 4))
        }
    }

    @inline(__always) private static func scrivi(_ out: inout [UInt8], _ j: Int, _ c: SIMD3<Float>) {
        out[j * 4] = UInt8(min(255, c.x * 255)); out[j * 4 + 1] = UInt8(min(255, c.y * 255))
        out[j * 4 + 2] = UInt8(min(255, c.z * 255)); out[j * 4 + 3] = 255
    }

    private static func conGriglia(_ px: [UInt8], _ w: Int, _ h: Int, _ disegna: (CGContext, CGSize) -> Void) -> UIImage? {
        guard let prov = CGDataProvider(data: Data(px) as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                               provider: prov, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        let s = CGSize(width: w, height: h)
        let fmt = UIGraphicsImageRendererFormat.default(); fmt.scale = 1
        return UIGraphicsImageRenderer(size: s, format: fmt).image { ctx in
            UIImage(cgImage: cg).draw(in: CGRect(origin: .zero, size: s))
            disegna(ctx.cgContext, s)
        }
    }
}
