import Foundation

/// I progetti salvati prima della traduzione in inglese hanno i valori di questi enum in italiano:
/// qui si leggono sia i nomi nuovi sia quelli vecchi.
private func decodifica<T: RawRepresentable>(_ decoder: Decoder, vecchi: [String: T]) throws -> T where T.RawValue == String {
    let s = try decoder.singleValueContainer().decode(String.self)
    guard let v = T(rawValue: s) ?? vecchi[s] else {
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Valore sconosciuto: \(s)"))
    }
    return v
}

extension Finestra.Tipo {
    init(from decoder: Decoder) throws {
        self = try decodifica(decoder, vecchi: ["Nessuna": .nessuna, "Cerchio": .cerchio, "Lineare": .lineare])
    }
}

extension MagicMask {
    init(from decoder: Decoder) throws {
        self = try decodifica(decoder, vecchi: ["Nessuna": .nessuna, "Persona": .persona, "Sfondo (tutto tranne la persona)": .sfondo,
                                                "Soggetto (AI)": .soggetto, "Tutto tranne il soggetto (AI)": .fuoriSoggetto])
    }
}

extension ModoNodo {
    init(from decoder: Decoder) throws {
        self = try decodifica(decoder, vecchi: ["Serie": .serie, "Parallelo": .parallelo])
    }
}

extension Nodo.Tipo {
    init(from decoder: Decoder) throws {
        self = try decodifica(decoder, vecchi: ["Correttore": .correzione])
    }
}

extension Transizione {
    init(from decoder: Decoder) throws {
        self = try decodifica(decoder, vecchi: ["Taglio netto": .nessuna, "Dissolvenza incrociata": .incrociata,
                                                "Dissolvenza al nero": .nero, "Dissolvenza al bianco": .bianco])
    }
}

extension Titolo.Colore {
    init(from decoder: Decoder) throws {
        self = try decodifica(decoder, vecchi: ["Bianco": .bianco, "Nero": .nero, "Giallo": .giallo, "Arancio": .arancio])
    }
}
