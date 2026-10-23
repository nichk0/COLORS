import Foundation
import UIKit

/// Una versione locale della correzione di una clip (come le "Local Versions" di DaVinci).
struct Versione: Identifiable, Codable, Hashable {
    var id = UUID()
    var nome: String
    var nodi: [Nodo]
}

/// Una clip del progetto: il file è copiato nella cartella dell'app.
struct Clip: Identifiable, Codable, Hashable {
    var id = UUID()
    var nome: String
    var file: String            // percorso relativo dentro Media/
    var video: Bool
    var nodi: [Nodo] = [Nodo(tipo: .correzione)]
    var versioni: [Versione] = []
    var miniatura: String?      // percorso relativo dentro Miniature/
    /// Impostazioni di montaggio (pagina Edit). Facoltative: i progetti vecchi non le hanno.
    var montaggio: Montaggio?

    var taglio: Montaggio {
        get { montaggio ?? Montaggio() }
        set { montaggio = newValue }
    }
}

enum Transizione: String, Codable, CaseIterable, Identifiable {
    case nessuna = "Taglio netto", incrociata = "Dissolvenza incrociata", nero = "Dissolvenza al nero", bianco = "Dissolvenza al bianco"
    var id: String { rawValue }
}

/// Testo sopra la clip.
struct Titolo: Codable, Hashable {
    enum Colore: String, Codable, CaseIterable, Identifiable {
        case bianco = "Bianco", nero = "Nero", giallo = "Giallo", arancio = "Arancio"
        var id: String { rawValue }
    }
    var testo = ""
    var dimensione: Float = 0.07        // rispetto all'altezza del video
    var posizione: Float = 0.82         // 0 = in alto, 1 = in basso
    var colore: Colore = .bianco
    var sfondo = false                  // fascia scura dietro al testo
    var grassetto = true

    init() {}
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ d: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? d }
        testo = v(.testo, testo); dimensione = v(.dimensione, dimensione); posizione = v(.posizione, posizione)
        colore = v(.colore, colore); sfondo = v(.sfondo, sfondo); grassetto = v(.grassetto, grassetto)
    }
}

/// Una riga di sottotitoli (tempi nel file della clip).
struct Sottotitolo: Codable, Hashable, Identifiable {
    var id = UUID()
    var inizio: Double
    var fine: Double
    var testo: String
}

extension Titolo {
    /// Stile predefinito dei sottotitoli: piccoli, in basso, su fascia scura.
    static var sottotitoli: Titolo {
        var t = Titolo()
        t.dimensione = 0.05; t.posizione = 0.88; t.sfondo = true; t.colore = .bianco; t.grassetto = true
        return t
    }
}

/// Inquadratura della clip (come l'Inspector di DaVinci): zoom, spostamento, rotazione, specchio.
struct Inquadratura: Codable, Hashable {
    var zoom: Float = 1
    var x: Float = 0                    // -1…1
    var y: Float = 0
    var rotazione: Int = 0              // 0, 90, 180, 270
    var specchio = false
    var neutra: Bool { self == Inquadratura() }

    init() {}
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ d: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? d }
        zoom = v(.zoom, zoom); x = v(.x, x); y = v(.y, y); rotazione = v(.rotazione, rotazione); specchio = v(.specchio, specchio)
    }
}

/// Tutto il montaggio di una clip: taglio, velocità, audio, transizione verso la successiva, titolo, inquadratura, stabilizzazione.
struct Montaggio: Codable, Hashable {
    var inizio: Double = 0              // secondi nel file
    var fine: Double?                   // nil = fino alla fine del file
    var durataFoto: Double = 3
    var velocita: Double = 1
    var volume: Float = 1
    var audioEntrata: Double = 0        // dissolvenza audio in entrata (s)
    var audioUscita: Double = 0
    var transizione: Transizione = .nessuna   // verso la clip successiva
    var durataTransizione: Double = 0.6
    var titolo = Titolo()
    var inquadratura = Inquadratura()
    var stabilizza = false
    /// (Vecchie versioni: correzioni già calcolate. Non più usate.)
    var stabilizzazione: [SIMD3<Float>] = []
    /// Percorso della camera misurato dall'analisi: (tempo nel file, x, y) in frazioni del fotogramma.
    var percorsoStab: [SIMD3<Float>] = []
    var forzaStab: Float = 0.6
    var treppiede = false
    var sottotitoli: [Sottotitolo] = []
    var mostraSottotitoli = true
    var stileSottotitoli = Titolo.sottotitoli
    /// Reframe automatico: dove sta il soggetto (tempo nel file, cx, cy). Usato quando il formato taglia i bordi.
    var reframe: [SIMD3<Float>] = []
    var seguiSoggetto = false
    /// Spazio vuoto (nero) prima della clip nella timeline: resta quando si accorcia una clip senza spostare le altre (come DaVinci).
    var vuotoPrima: Double = 0

    init() {}
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ d: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? d }
        inizio = v(.inizio, inizio); fine = try? c.decodeIfPresent(Double.self, forKey: .fine); durataFoto = v(.durataFoto, durataFoto)
        velocita = v(.velocita, velocita); volume = v(.volume, volume); audioEntrata = v(.audioEntrata, audioEntrata); audioUscita = v(.audioUscita, audioUscita)
        transizione = v(.transizione, transizione); durataTransizione = v(.durataTransizione, durataTransizione)
        titolo = v(.titolo, titolo); inquadratura = v(.inquadratura, inquadratura)
        stabilizza = v(.stabilizza, stabilizza); stabilizzazione = v(.stabilizzazione, stabilizzazione)
        percorsoStab = v(.percorsoStab, percorsoStab); forzaStab = v(.forzaStab, forzaStab); treppiede = v(.treppiede, treppiede)
        sottotitoli = v(.sottotitoli, sottotitoli); mostraSottotitoli = v(.mostraSottotitoli, mostraSottotitoli); stileSottotitoli = v(.stileSottotitoli, stileSottotitoli)
        reframe = v(.reframe, reframe); seguiSoggetto = v(.seguiSoggetto, seguiSoggetto)
        vuotoPrima = v(.vuotoPrima, vuotoPrima)
    }
}

/// Musica di sottofondo del montaggio.
/// Una traccia audio di sottofondo (musica o audio preso da un video). Le tracce suonano una dopo l'altra.
struct Musica: Codable, Hashable, Identifiable {
    var id = UUID()
    var file: String                    // dentro Media/
    var nome: String
    var volume: Float = 0.6
    var dissolvenzaFinale: Double = 2   // (usata solo dalla vecchia musica singola)
    /// Taglio: si usa solo il tratto [inizio, fine] del file (fine nil = fino in fondo).
    var inizio: Double = 0
    var fine: Double?
    /// Dissolvenze della traccia (s).
    var entrata: Double = 0
    var uscita: Double = 0

    init(file: String, nome: String) { self.file = file; self.nome = nome }

    /// Quanto dura la traccia tagliata, per un file lungo `durataFile`.
    func durata(file durataFile: Double) -> Double {
        let f = min(fine ?? durataFile, durataFile)
        return max(0.1, f - min(inizio, max(0, f - 0.1)))
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        file = try c.decode(String.self, forKey: .file)
        nome = (try? c.decodeIfPresent(String.self, forKey: .nome)) ?? "Audio"
        volume = (try? c.decodeIfPresent(Float.self, forKey: .volume)) ?? 0.6
        dissolvenzaFinale = (try? c.decodeIfPresent(Double.self, forKey: .dissolvenzaFinale)) ?? 2
        inizio = (try? c.decodeIfPresent(Double.self, forKey: .inizio)) ?? 0
        fine = try? c.decodeIfPresent(Double.self, forKey: .fine)
        entrata = (try? c.decodeIfPresent(Double.self, forKey: .entrata)) ?? 0
        uscita = (try? c.decodeIfPresent(Double.self, forKey: .uscita)) ?? 0
    }
}

/// Un fotogramma salvato in galleria, con la correzione che l'ha prodotto.
struct Still: Identifiable, Codable, Hashable {
    var id = UUID()
    var nome: String
    var file: String            // percorso relativo dentro Stills/
    var nodi: [Nodo]
    var data = Date()
}

/// Un media importato nel Media Pool: non è ancora nella timeline (come in DaVinci).
struct ElementoPool: Identifiable, Codable, Hashable {
    var id = UUID()
    var nome: String
    var file: String            // dentro Media/
    var video: Bool
    var miniatura: String?
}

struct Progetto: Codable {
    var clips: [Clip] = []
    /// Media Pool: media importati da mettere nella timeline quando si vuole.
    var pool: [ElementoPool] = []
    /// Tracce audio di sottofondo, in ordine.
    var musiche: [Musica] = []
    var dissolvenzaMusica: Double = 2   // sfumatura dell'audio di sottofondo alla fine del montaggio
    var ripetiMusica = true             // se le tracce sono più corte del montaggio, si ricomincia
    var stills: [Still] = []
    var clipAttiva: UUID?
    var nome = "Progetto"
    var creato = Date()
    var modificato = Date()
    var id = UUID()

    init() {}

    private enum CodingKeys: String, CodingKey { case clips, pool, musiche, musica, dissolvenzaMusica, ripetiMusica, stills, clipAttiva, nome, creato, modificato, id }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clips = (try? c.decodeIfPresent([Clip].self, forKey: .clips)) ?? []
        pool = (try? c.decodeIfPresent([ElementoPool].self, forKey: .pool)) ?? []
        musiche = (try? c.decodeIfPresent([Musica].self, forKey: .musiche)) ?? []
        // progetti vecchi: una sola musica
        if musiche.isEmpty, let m = try? c.decodeIfPresent(Musica.self, forKey: .musica) {
            musiche = [m]
            dissolvenzaMusica = m.dissolvenzaFinale
        } else {
            dissolvenzaMusica = (try? c.decodeIfPresent(Double.self, forKey: .dissolvenzaMusica)) ?? 2
        }
        ripetiMusica = (try? c.decodeIfPresent(Bool.self, forKey: .ripetiMusica)) ?? true
        stills = (try? c.decodeIfPresent([Still].self, forKey: .stills)) ?? []
        clipAttiva = try? c.decodeIfPresent(UUID.self, forKey: .clipAttiva)
        nome = (try? c.decodeIfPresent(String.self, forKey: .nome)) ?? "Progetto"
        creato = (try? c.decodeIfPresent(Date.self, forKey: .creato)) ?? Date()
        modificato = (try? c.decodeIfPresent(Date.self, forKey: .modificato)) ?? creato
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
    }

    /// Tutti i file di Media, Miniature e Stills che il progetto usa.
    var fileUsati: Set<String> {
        var f = Set(clips.map(\.file))
        f.formUnion(clips.compactMap(\.miniatura))
        f.formUnion(pool.map(\.file))
        f.formUnion(pool.compactMap(\.miniatura))
        f.formUnion(musiche.map(\.file))
        f.formUnion(stills.map(\.file))
        return f
    }
    var vuoto: Bool { clips.isEmpty && musiche.isEmpty && stills.isEmpty }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(clips, forKey: .clips)
        try c.encode(pool, forKey: .pool)
        try c.encode(musiche, forKey: .musiche)
        try c.encode(dissolvenzaMusica, forKey: .dissolvenzaMusica)
        try c.encode(ripetiMusica, forKey: .ripetiMusica)
        try c.encode(stills, forKey: .stills)
        try c.encodeIfPresent(clipAttiva, forKey: .clipAttiva)
        try c.encode(nome, forKey: .nome)
        try c.encode(creato, forKey: .creato)
        try c.encode(modificato, forKey: .modificato)
        try c.encode(id, forKey: .id)
    }
}

/// Salvataggio su disco: Documents/Colorista/{progetto.json, Media, Miniature, Stills}.
enum Archivio {
    static let radice: URL = {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Colorista", isDirectory: true)
        for sub in ["Media", "Miniature", "Stills", "Progetti"] {
            try? FileManager.default.createDirectory(at: d.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        return d
    }()

    static func url(_ cartella: String, _ nome: String) -> URL { radice.appendingPathComponent(cartella).appendingPathComponent(nome) }
    static var fileProgetto: URL { radice.appendingPathComponent("progetto.json") }

    static func carica() -> Progetto {
        guard let d = try? Data(contentsOf: fileProgetto) else { return Progetto() }
        guard let p = try? JSONDecoder().decode(Progetto.self, from: d) else {
            // file illeggibile: lo si mette da parte invece di perderlo al primo salvataggio
            try? d.write(to: fileCopia, options: .atomic)
            return Progetto()
        }
        // tiene solo le clip il cui file esiste ancora
        var q = p
        q.clips = p.clips.filter { FileManager.default.fileExists(atPath: url("Media", $0.file).path) }
        return q
    }

    static var fileCopia: URL { radice.appendingPathComponent("progetto-copia.json") }

    static func salva(_ p: Progetto) {
        var p = p
        p.modificato = Date()
        guard let d = try? JSONEncoder().encode(p) else { return }
        // rete di sicurezza: se si sta per scrivere un progetto vuoto sopra uno che ha clip, si tiene una copia
        if p.clips.isEmpty, let vecchio = try? Data(contentsOf: fileProgetto),
           let v = try? JSONDecoder().decode(Progetto.self, from: vecchio), !v.clips.isEmpty {
            try? vecchio.write(to: fileCopia, options: .atomic)
        }
        try? d.write(to: fileProgetto, options: .atomic)
    }

    /// Copia un file nella cartella Media e restituisce il nome relativo.
    static func importa(_ sorgente: URL) throws -> String {
        let nome = UUID().uuidString.prefix(8) + "-" + sorgente.lastPathComponent
        let dst = url("Media", String(nome))
        if FileManager.default.fileExists(atPath: dst.path) { try FileManager.default.removeItem(at: dst) }
        try FileManager.default.copyItem(at: sorgente, to: dst)
        return String(nome)
    }

    static func importa(dati: Data, estensione: String) throws -> String {
        let nome = UUID().uuidString.prefix(8) + "." + estensione
        try dati.write(to: url("Media", String(nome)))
        return String(nome)
    }

    static func salvaImmagine(_ img: UIImage, cartella: String, lato: CGFloat) -> String? {
        let nome = UUID().uuidString + ".jpg"
        guard let d = img.ridotta(lato: lato).jpegData(compressionQuality: 0.85) else { return nil }
        try? d.write(to: url(cartella, nome))
        return nome
    }

    static func immagine(_ cartella: String, _ nome: String?) -> UIImage? {
        guard let nome else { return nil }
        return UIImage(contentsOfFile: url(cartella, nome).path)
    }

    // MARK: progetti salvati (quelli non aperti stanno in Progetti/<id>.json; quello aperto in progetto.json)

    private static func urlArchiviato(_ id: UUID) -> URL { url("Progetti", id.uuidString + ".json") }

    static func archivia(_ p: Progetto) {
        var p = p
        p.modificato = Date()
        guard let d = try? JSONEncoder().encode(p) else { return }
        try? d.write(to: urlArchiviato(p.id), options: .atomic)
    }

    static func caricaArchiviato(_ id: UUID) -> Progetto? {
        guard let d = try? Data(contentsOf: urlArchiviato(id)) else { return nil }
        return try? JSONDecoder().decode(Progetto.self, from: d)
    }

    static func rimuoviArchiviato(_ id: UUID) { try? FileManager.default.removeItem(at: urlArchiviato(id)) }

    /// Progetti salvati, dal più recente.
    static func elencoArchiviati() -> [Progetto] {
        let dir = radice.appendingPathComponent("Progetti")
        let file = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return file.filter { $0.pathExtension == "json" }
            .compactMap { (try? Data(contentsOf: $0)).flatMap { try? JSONDecoder().decode(Progetto.self, from: $0) } }
            .sorted { $0.modificato > $1.modificato }
    }

    /// Il file è usato da un altro progetto salvato? (per non cancellare media condivisi)
    static func fileUsatoAltrove(_ file: String, progetto: Progetto) -> Bool {
        elencoArchiviati().contains { $0.id != progetto.id && $0.fileUsati.contains(file) }
    }

    static func elimina(_ cartella: String, _ nome: String?) {
        guard let nome else { return }
        try? FileManager.default.removeItem(at: url(cartella, nome))
    }
}
