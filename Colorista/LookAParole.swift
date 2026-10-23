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
        guard #available(iOS 26.0, *) else { return "Serve iOS 26 o più recente." }
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.deviceNotEligible): return "Questo iPhone non supporta Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled): return "Attiva Apple Intelligence in Impostazioni › Apple Intelligence e Siri."
        case .unavailable(.modelNotReady): return "Il modello di Apple Intelligence si sta ancora scaricando: riprova tra poco."
        default: return "Apple Intelligence non è disponibile in questo momento."
        }
    }

    static func nodo(per descrizione: String) async throws -> Nodo {
        guard #available(iOS 26.0, *) else { throw Errore.nonDisponibile("Serve iOS 26 o più recente.") }
        if let m = motivoNonDisponibile { throw Errore.nonDisponibile(m) }
        let sessione = LanguageModelSession(instructions: """
            Sei un colorista cinematografico esperto. Traduci la descrizione di un look nei valori di una correzione colore. \
            Usa valori diversi da zero per ciò che il look richiede: un look caldo ha temperatura positiva, uno freddo negativa, \
            uno vintage ha nero sollevato e grana, uno cupo ha esposizione e ombre negative. Rispondi in italiano.
            """)
        let r = try await sessione.respond(to: "Look: \(descrizione)", generating: LookGenerato.self)
        return r.content.nodo
    }
}

@available(iOS 26.0, *)
@Generable(description: "Colore verso cui spingere una zona dell'immagine")
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
@Generable(description: "Parametri di una correzione colore")
struct LookGenerato {
    @Guide(description: "Analisi del look in una frase: luce, colori di ombre e luci, contrasto, saturazione, epoca")
    var analisi: String
    @Guide(description: "Nome breve del look, 1-3 parole")
    var nome: String
    @Guide(description: "Luminosità generale. -100 molto scuro, 0 invariato, +100 molto chiaro. Notte o cupo: -30..-60", .range(-100...100))
    var esposizione: Int
    @Guide(description: "Contrasto. -100 piatto/sbiadito, 0 invariato, +100 molto contrastato. Thriller/drammatico: +30..+60", .range(-100...100))
    var contrasto: Int
    @Guide(description: "Saturazione. -100 bianco e nero, 0 invariata, +100 colori fortissimi. Vintage: -20..-40, pastello: -20", .range(-100...100))
    var saturazione: Int
    @Guide(description: "Temperatura. -100 molto freddo/blu, 0 neutro, +100 molto caldo/arancio. Tramonto: +50..+80, freddo: -40..-70", .range(-100...100))
    var temperatura: Int
    @Guide(description: "Tinta. -100 verde, 0 neutro, +100 magenta", .range(-100...100))
    var tinta: Int
    @Guide(description: "Ombre. -100 nere e profonde, 0 invariate, +100 molto aperte", .range(-100...100))
    var ombre: Int
    @Guide(description: "Alte luci. -100 scurite/recuperate, 0 invariate, +100 più brillanti", .range(-100...100))
    var luci: Int
    @Guide(description: "Colore da dare alle ombre (split toning)")
    var coloreOmbre: ColoreLook
    @Guide(description: "Forza del colore nelle ombre. 0 nessuna, 30 leggera, 70 forte", .range(0...100))
    var intensitaOmbre: Int
    @Guide(description: "Colore da dare alle alte luci (split toning)")
    var coloreLuci: ColoreLook
    @Guide(description: "Forza del colore nelle alte luci. 0 nessuna, 30 leggera, 70 forte", .range(0...100))
    var intensitaLuci: Int
    @Guide(description: "Nero sollevato, effetto pellicola sbiadita. 0 nessuno, 40 vintage, 80 molto sbiadito", .range(0...100))
    var neroSollevato: Int
    @Guide(description: "Grana da pellicola. 0 nessuna, 30 leggera, 70 forte", .range(0...100))
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
