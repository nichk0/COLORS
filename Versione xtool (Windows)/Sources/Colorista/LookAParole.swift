import Foundation
import FoundationModels

/// Look descritto a parole: il modello di Apple Intelligence (sul telefono, senza internet) sceglie i parametri della correzione.
enum LookAParole {
    enum Errore: LocalizedError {
        case nonDisponibile(String)
        var errorDescription: String? { if case let .nonDisponibile(m) = self { return m }; return nil }
    }

    /// Se il modello si può usare su questo iPhone (nil) o perché no.
    static var motivoNonDisponibile: String? {
        guard #available(iOS 26.0, *) else { return "Requires iOS 26 or later." }
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.deviceNotEligible): return "This iPhone doesn't support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in Settings › Apple Intelligence & Siri."
        case .unavailable(.modelNotReady): return "The Apple Intelligence model is still downloading: try again shortly."
        default: return "Apple Intelligence is not available right now."
        }
    }

    static func nodo(per descrizione: String) async throws -> Nodo {
        guard #available(iOS 26.0, *) else { throw Errore.nonDisponibile("Requires iOS 26 or later.") }
        if let m = motivoNonDisponibile { throw Errore.nonDisponibile(m) }
        let sessione = LanguageModelSession(instructions: """
            You are an expert cinema colorist. Translate the description of a look into the values of a color correction. \
            Use non-zero values for what the look needs: a warm look has positive temperature, a cool one negative, \
            a vintage one has lifted blacks and grain, a gloomy one has negative exposure and shadows. Answer in English.
            """)
        let r = try await sessione.respond(to: "Look: \(descrizione)", generating: LookGenerato.self)
        return r.content.nodo
    }
}

@available(iOS 26.0, *)
@Generable(description: "Color to push an area of the image towards")
enum ColoreLook {
    case nessuno, rosso, arancio, giallo, verde, ciano, teal, blu, viola, magenta

    /// Angolo sulla ruota colore dell'app (il rosso è a 103°, come nel vettorscopio).
    var angolo: Float? {
        switch self {
        case .nessuno: return nil
        case .rosso: return 103
        case .arancio: return 133
        case .giallo: return 167
        case .verde: return 223
        case .ciano: return 283
        case .teal: return 313
        case .blu: return 343
        case .viola: return 13
        case .magenta: return 43
        }
    }
}

// Nota: i valori sono interi da -100 a 100. Con decimali e limiti "strani" (es. 0.6…1.6) il modello va in errore
// (tokengeneration code 10); senza le spiegazioni e il campo "analisi" lascia tutto a 0.
@available(iOS 26.0, *)
@Generable(description: "Parameters of a color correction")
struct LookGenerato {
    @Guide(description: "One-sentence analysis of the look: light, shadow and highlight colors, contrast, saturation, era")
    var analisi: String
    @Guide(description: "Short name of the look, 1-3 words")
    var nome: String
    @Guide(description: "Overall brightness. -100 very dark, 0 unchanged, +100 very bright. Night or gloomy: -30..-60", .range(-100...100))
    var esposizione: Int
    @Guide(description: "Contrast. -100 flat/faded, 0 unchanged, +100 very contrasty. Thriller/dramatic: +30..+60", .range(-100...100))
    var contrasto: Int
    @Guide(description: "Saturation. -100 black and white, 0 unchanged, +100 very strong colors. Vintage: -20..-40, pastel: -20", .range(-100...100))
    var saturazione: Int
    @Guide(description: "Temperature. -100 very cool/blue, 0 neutral, +100 very warm/orange. Sunset: +50..+80, cool: -40..-70", .range(-100...100))
    var temperatura: Int
    @Guide(description: "Tint. -100 green, 0 neutral, +100 magenta", .range(-100...100))
    var tinta: Int
    @Guide(description: "Shadows. -100 deep black, 0 unchanged, +100 very open", .range(-100...100))
    var ombre: Int
    @Guide(description: "Highlights. -100 darkened/recovered, 0 unchanged, +100 brighter", .range(-100...100))
    var luci: Int
    @Guide(description: "Color to give the shadows (split toning)")
    var coloreOmbre: ColoreLook
    @Guide(description: "Strength of the color in the shadows. 0 none, 30 light, 70 strong", .range(0...100))
    var intensitaOmbre: Int
    @Guide(description: "Color to give the highlights (split toning)")
    var coloreLuci: ColoreLook
    @Guide(description: "Strength of the color in the highlights. 0 none, 30 light, 70 strong", .range(0...100))
    var intensitaLuci: Int
    @Guide(description: "Lifted blacks, faded film effect. 0 none, 40 vintage, 80 very faded", .range(0...100))
    var neroSollevato: Int
    @Guide(description: "Film grain. 0 none, 30 light, 70 strong", .range(0...100))
    var grana: Int

    /// Da -100…100 ai valori della correzione, con scale prudenti (il modello tende a esagerare).
    var nodo: Nodo {
        func u(_ v: Int) -> Float { Float(max(-100, min(100, v))) / 100 }
        var n = Nodo(tipo: .correzione)
        n.nome = String(nome.prefix(24))
        var g = Grade()
        g.esposizione = u(esposizione) * 1.0
        g.contrasto = 1 + u(contrasto) * 0.35
        g.saturazione = saturazione < 0 ? 1 + u(saturazione) : 1 + u(saturazione) * 0.4
        g.temperatura = u(temperatura) * 0.5
        g.tinta = u(tinta) * 0.2
        g.ombre = u(ombre) * 0.5
        g.luci = u(luci) * 0.5
        if let a = coloreOmbre.angolo, intensitaOmbre > 0 {
            let r = a * .pi / 180, k = u(intensitaOmbre) * 0.35
            g.lift = Wheel(x: cos(r) * k, y: sin(r) * k, master: 0)
        }
        if let a = coloreLuci.angolo, intensitaLuci > 0 {
            let r = a * .pi / 180, k = u(intensitaLuci) * 0.3
            g.gain = Wheel(x: cos(r) * k, y: sin(r) * k, master: 0)
        }
        if neroSollevato > 0 {
            let k = u(neroSollevato) * 0.08
            g.curvaY = Curva(punti: [SIMD2(0, k), SIMD2(0.5, 0.5 + k * 0.3), SIMD2(1, 1)])
        }
        n.grade = g
        n.effetti.grana = u(grana) * 0.4
        return n
    }
}
