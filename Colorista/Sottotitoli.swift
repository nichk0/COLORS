import AVFoundation
import Speech

/// Sottotitoli automatici: il parlato della clip viene trascritto sull'iPhone (riconoscimento vocale di Apple)
/// e diviso in righe brevi a tempo.
enum Trascrizione {
    enum Errore: LocalizedError {
        case permesso, linguaNonDisponibile, senzaAudio, niente
        var errorDescription: String? {
            switch self {
            case .permesso: return "Speech recognition permission is needed (Settings › Colors)."
            case .linguaNonDisponibile: return "Speech recognition for this language is not available on this iPhone."
            case .senzaAudio: return "The clip has no audio."
            case .niente: return "I didn't hear any words to transcribe."
            }
        }
    }

    static let lingue: [(nome: String, codice: String)] = [("Italiano", "it-IT"), ("English", "en-US"), ("Español", "es-ES"), ("Français", "fr-FR"), ("Deutsch", "de-DE")]

    static func autorizza() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .authorized { return true }
        return await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) } }
    }

    /// Trascrive il tratto [da, a] del file. I tempi dei sottotitoli sono nel file.
    /// `sulTelefono`: true se è avvenuto tutto sull'iPhone, false se è servito il server di Apple.
    static func trascrivi(url: URL, da: Double, a: Double, lingua: String) async throws -> (righe: [Sottotitolo], sulTelefono: Bool) {
        guard await autorizza() else { throw Errore.permesso }
        guard let r = SFSpeechRecognizer(locale: Locale(identifier: lingua)), r.isAvailable else { throw Errore.linguaNonDisponibile }

        // solo l'audio del tratto, in un file temporaneo
        let asset = AVURLAsset(url: url)
        guard !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else { throw Errore.senzaAudio }
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent("colors-parlato-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: audio) }
        guard let s = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { throw Errore.senzaAudio }
        s.timeRange = CMTimeRange(start: CMTime(seconds: da, preferredTimescale: 600), end: CMTime(seconds: a, preferredTimescale: 600))
        try await s.export(to: audio, as: .m4a)

        let req = SFSpeechURLRecognitionRequest(url: audio)
        let locale = r.supportsOnDeviceRecognition
        req.requiresOnDeviceRecognition = locale
        req.shouldReportPartialResults = false
        req.addsPunctuation = true
        let risultato: SFSpeechRecognitionResult = try await withCheckedThrowingContinuation { c in
            var finito = false
            r.recognitionTask(with: req) { res, err in
                guard !finito else { return }
                if let err { finito = true; c.resume(throwing: err); return }
                if let res, res.isFinal { finito = true; c.resume(returning: res) }
            }
        }
        let righe = dividi(risultato.bestTranscription.segments, scostamento: da)
        guard !righe.isEmpty else { throw Errore.niente }
        return (righe, locale)
    }

    /// Righe brevi da segmenti di Speech.
    static func dividi(_ parole: [SFTranscriptionSegment], scostamento: Double) -> [Sottotitolo] {
        dividi(parole.map { ($0.substring, $0.timestamp, $0.duration) }, scostamento: scostamento)
    }

    /// Righe brevi: prima si divide in frasi (punto o pausa), poi ogni frase troppo lunga in righe
    /// di lunghezza simile (al massimo ~42 caratteri), spezzando di preferenza dopo una virgola.
    static func dividi(_ parole: [(testo: String, inizio: Double, durata: Double)], scostamento: Double) -> [Sottotitolo] {
        // 1. frasi
        var frasi: [[(testo: String, inizio: Double, durata: Double)]] = [[]]
        for (i, p) in parole.enumerated() {
            if let u = frasi[frasi.count - 1].last, p.inizio - (u.inizio + u.durata) > 0.7 { frasi.append([]) }
            frasi[frasi.count - 1].append(p)
            if p.testo.last.map({ ".?!".contains($0) }) == true, i + 1 < parole.count { frasi.append([]) }
        }
        // 2. righe bilanciate
        var righe: [Sottotitolo] = []
        for f in frasi where !f.isEmpty {
            let lunghezza = f.reduce(0) { $0 + $1.testo.count + 1 } - 1
            let durata = (f.last!.inizio + f.last!.durata) - f.first!.inizio
            let k = max(Int((Double(lunghezza) / 42).rounded(.up)), Int((durata / 4.5).rounded(.up)), 1)
            var tagli: [Int] = []                       // indice della prima parola di ogni riga dopo la prima
            var cumulato: [Int] = []
            var c = 0
            for p in f { c += p.testo.count + 1; cumulato.append(c) }
            for j in 1..<k {
                let obiettivo = Double(lunghezza) * Double(j) / Double(k)
                var migliore = 1, punteggio = Double.infinity
                for i in 1..<f.count where !tagli.contains(i) && i > (tagli.last ?? 0) {
                    var d = abs(Double(cumulato[i - 1]) - obiettivo)
                    if f[i - 1].testo.last == "," { d -= 8 }    // meglio dopo una virgola
                    if d < punteggio { punteggio = d; migliore = i }
                }
                tagli.append(migliore)
            }
            let confini = [0] + tagli + [f.count]
            for (a, b) in zip(confini, confini.dropFirst()) where a < b {
                let pezzo = f[a..<b]
                let ini = pezzo.first!.inizio, fin = pezzo.last!.inizio + pezzo.last!.durata
                righe.append(Sottotitolo(inizio: scostamento + ini, fine: scostamento + max(fin, ini + 0.8), testo: pezzo.map(\.testo).joined(separator: " ")))
            }
        }
        // ogni riga resta finché non arriva la successiva (max 1 s in più), così non lampeggia
        for i in righe.indices where i + 1 < righe.count {
            righe[i].fine = min(righe[i + 1].inizio, righe[i].fine + 1)
        }
        return righe
    }
}
