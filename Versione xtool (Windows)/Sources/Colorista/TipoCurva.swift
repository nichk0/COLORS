import SwiftUI

/// I tipi di curva della palette, come in DaVinci (Custom + 6 curve "X vs Y").
enum TipoCurva: String, CaseIterable, Identifiable {
    case custom = "Custom", hueHue = "Hue vs Hue", hueSat = "Hue vs Sat", hueLum = "Hue vs Lum"
    case lumSat = "Lum vs Sat", satSat = "Sat vs Sat", satLum = "Sat vs Lum"
    var id: String { rawValue }

    var corto: String {
        switch self {
        case .custom: return "Custom"
        case .hueHue: return "H vs H"
        case .hueSat: return "H vs S"
        case .hueLum: return "H vs L"
        case .lumSat: return "L vs S"
        case .satSat: return "S vs S"
        case .satLum: return "S vs L"
        }
    }

    /// La curva della correzione che si modifica (nil per Custom, che ne ha quattro: Y, R, G, B).
    var curva: WritableKeyPath<Grade, Curva>? {
        switch self {
        case .custom: return nil
        case .hueHue: return \.hueVsHue
        case .hueSat: return \.hueVsSat
        case .hueLum: return \.hueVsLum
        case .lumSat: return \.lumVsSat
        case .satSat: return \.satVsSat
        case .satLum: return \.satVsLum
        }
    }

    var diTinta: Bool { self == .hueHue || self == .hueSat || self == .hueLum }

    /// Cosa c'è sull'asse orizzontale: tinta, luminanza o saturazione.
    enum Asse { case tinta, luminanza, saturazione }
    var asse: Asse { diTinta ? .tinta : self == .lumSat ? .luminanza : .saturazione }

    var spiegazione: String {
        switch self {
        case .custom: return "Tocca per aggiungere un punto e trascinalo. Per toglierlo: toccalo e premi ✕."
        case .hueHue: return "Cambia una tinta in un'altra (es. verdi più gialli). Scegli un colore qui sotto o col contagocce, poi trascina su/giù il punto centrale."
        case .hueSat: return "Più o meno saturazione per una tinta (es. cielo più blu)."
        case .hueLum: return "Più chiara o più scura una tinta (es. cielo più scuro)."
        case .lumSat: return "Saturazione per luminosità (es. ombre meno sature, look pellicola)."
        case .satSat: return "Satura di più i colori spenti o calma quelli già saturi."
        case .satLum: return "Più chiari o più scuri i colori molto saturi (es. scurire i colori accesi)."
        }
    }

    /// Testo del punto selezionato: ingresso → effetto.
    func etichetta(_ p: SIMD2<Float>, canale: Int = 0) -> String {
        let ingresso: String
        switch asse {
        case .tinta: ingresso = String(format: "Tinta %.0f°", p.x * 360)
        case .luminanza: ingresso = String(format: "Lum %.0f%%", p.x * 100)
        case .saturazione: ingresso = String(format: "Sat %.0f%%", p.x * 100)
        }
        switch self {
        case .custom: return String(format: "%@ %.2f → %.2f", ["Y", "R", "G", "B"][canale], p.x, p.y)
        case .hueHue: return ingresso + String(format: " → rotazione %+.0f°", p.y * 180)
        case .hueSat, .lumSat, .satSat: return ingresso + String(format: " → saturazione %+.0f%%", p.y * 100)
        case .hueLum, .satLum: return ingresso + String(format: " → %+.1f stop", p.y * 1.2)
        }
    }
}

extension Curva {
    /// Aggiunge tre punti a zero attorno a `x` (come in DaVinci): quello centrale si trascina, i due ai lati tengono fermo il resto.
    mutating func aggiungiTre(_ x: Float, periodica: Bool, larghezza: Float = 0.08) {
        func dentro(_ v: Float) -> Float { periodica ? (v + 1).truncatingRemainder(dividingBy: 1) : min(max(v, 0), 1) }
        var nuovi = [SIMD2(dentro(x - larghezza), 0), SIMD2(dentro(x), 0), SIMD2(dentro(x + larghezza), 0)]
        // niente doppioni troppo vicini a punti che ci sono già
        nuovi.removeAll { n in punti.contains { abs($0.x - n.x) < 0.015 } }
        punti = (punti + nuovi).sorted { $0.x < $1.x }
    }
}

/// Icona di un tipo di curva: la sfumatura dell'asse orizzontale con una curva sopra.
struct IconaCurva: View {
    let tipo: TipoCurva
    var body: some View {
        Canvas { c, s in
            let r = CGRect(origin: .zero, size: s)
            let colori: [Color]
            switch tipo.asse {
            case .tinta: colori = (0...6).map { Color(hue: Double($0) / 6, saturation: 0.75, brightness: 0.85) }
            case .luminanza: colori = [.black, .white]
            case .saturazione: colori = [Color(white: 0.55), Color(red: 0.9, green: 0.2, blue: 0.2)]
            }
            if tipo == .custom {
                c.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(Color(white: 0.18)))
            } else {
                c.fill(Path(roundedRect: r, cornerRadius: 3), with: .linearGradient(Gradient(colors: colori), startPoint: .zero, endPoint: CGPoint(x: s.width, y: 0)))
                c.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(.black.opacity(0.35)))
            }
            var p = Path()
            if tipo == .custom {
                p.move(to: CGPoint(x: 2, y: s.height - 2))
                p.addCurve(to: CGPoint(x: s.width - 2, y: 2), control1: CGPoint(x: s.width * 0.45, y: s.height - 2), control2: CGPoint(x: s.width * 0.55, y: 2))
            } else {
                p.move(to: CGPoint(x: 1, y: s.height / 2))
                p.addCurve(to: CGPoint(x: s.width - 1, y: s.height / 2), control1: CGPoint(x: s.width * 0.4, y: s.height * 0.1), control2: CGPoint(x: s.width * 0.6, y: s.height * 0.9))
            }
            c.stroke(p, with: .color(.white), lineWidth: 1.5)
        }
        .frame(width: 30, height: 20)
    }
}
