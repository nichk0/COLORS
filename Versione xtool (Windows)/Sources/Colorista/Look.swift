import Foundation

/// Look pronti: ognuno diventa un nodo correttore con il suo nome, da regolare o spegnere come gli altri.
enum Look: String, CaseIterable, Identifiable {
    case tealOrange = "Teal & Orange"
    case pellicola = "Film"
    case biancoNero = "Black and white"
    case bnRosso = "B&W red filter"
    case caldo = "Warm"
    case freddo = "Cool"
    case bleach = "Bleach bypass"
    case vintage = "Vintage"
    case notte = "Day for night"
    case moody = "Moody"

    var id: String { rawValue }

    /// Ruota spinta verso un colore: angolo sulla ruota (rosso ≈ 103°, come nel vettorscopio) e intensità 0…1.
    private static func ruota(_ gradi: Float, _ intensita: Float, master: Float = 0) -> Wheel {
        let a = gradi * .pi / 180
        return Wheel(x: cos(a) * intensita, y: sin(a) * intensita, master: master)
    }
    private static let arancio: Float = 133, teal: Float = 313, blu: Float = 347, giallo: Float = 167

    var nodo: Nodo {
        var n = Nodo(tipo: .correzione)
        n.nome = rawValue
        var g = Grade()
        switch self {
        case .tealOrange:
            g.lift = Look.ruota(Look.teal, 0.35)
            g.gamma = Look.ruota(Look.teal, 0.08)
            g.gain = Look.ruota(Look.arancio, 0.22)
            g.contrasto = 1.08; g.saturazione = 1.12
        case .pellicola:
            g.contrasto = 1.12
            g.curvaY = Curva(punti: [SIMD2(0, 0.035), SIMD2(0.25, 0.21), SIMD2(0.75, 0.8), SIMD2(1, 0.96)])
            g.saturazione = 0.9; g.temperatura = 0.08
            g.gain = Look.ruota(Look.giallo, 0.06)
            n.effetti.grana = 0.25
        case .biancoNero:
            g.saturazione = 0; g.contrasto = 1.15
        case .bnRosso:
            // come un filtro rosso sull'obiettivo: cielo scuro, pelle chiara
            g.mixer = [0.9, 0.25, -0.15, 0, 1, 0, 0, 0, 1]; g.mixerMono = true; g.contrasto = 1.2
        case .caldo:
            g.temperatura = 0.32; g.saturazione = 1.05
        case .freddo:
            g.temperatura = -0.32; g.tinta = -0.04
        case .bleach:
            g.saturazione = 0.45; g.contrasto = 1.35; g.ombre = -0.1
        case .vintage:
            g.curvaY = Curva(punti: [SIMD2(0, 0.09), SIMD2(0.5, 0.52), SIMD2(1, 0.92)])
            g.saturazione = 0.78; g.temperatura = 0.15
            g.lift = Look.ruota(Look.giallo, 0.18)
        case .notte:
            g.esposizione = -1.3; g.temperatura = -0.55; g.saturazione = 0.7; g.contrasto = 1.1
        case .moody:
            g.ombre = -0.22; g.saturazione = 0.82; g.temperatura = -0.08; g.contrasto = 1.1
            g.lift = Look.ruota(Look.blu, 0.15)
        }
        n.grade = g
        return n
    }
}
