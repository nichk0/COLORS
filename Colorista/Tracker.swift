import AVFoundation
import Vision
import CoreImage
import ImageIO

/// Tracker delle finestre (l'idea è quella del Tracker della pagina Color di DaVinci, scritto da zero):
/// segue posizione, dimensione e rotazione di ciò che sta dentro la finestra, in avanti o all'indietro.
///
/// Come funziona: dentro la zona si scelgono tanti piccoli riquadri con dettagli, si cerca dove sono finiti
/// nel fotogramma dopo (confronto dei pixel), poi si calcola lo spostamento + zoom + rotazione che spiega meglio
/// tutti quei movimenti, scartando quelli sbagliati. Il tracker di oggetti di Vision fa da guida per i movimenti
/// veloci e capisce quando l'oggetto è sparito.
enum Tracker {
    enum Verso: Sendable { case avanti, indietro }

    /// Un fotogramma tracciato: centro (0…1, y verso il basso come le finestre),
    /// dimensione e rotazione (gradi, antiorario) rispetto al fotogramma di partenza.
    struct Campione: Sendable {
        var tempo: Double
        var centro: SIMD2<Float>
        var scala: Float = 1
        var rotazione: Float = 0
    }

    struct Risultato: Sendable {
        var campioni: [Campione] = []
        /// Il tracker si è fermato prima della fine perché non vedeva più l'oggetto.
        var perso = false
        /// Segui volto: il volto trovato nel fotogramma di partenza (centro 0…1 con y in basso, lato rispetto al lato lungo).
        var volto: (centro: SIMD2<Float>, lato: Float)?
    }

    struct Opzioni: Sendable {
        var dimensione = true
        var rotazione = true
        /// Quanti fotogrammi nuovi al massimo (1 = un fotogramma alla volta).
        var massimoFotogrammi: Int?
        var massimoSecondi: Double = 60
        /// Segui volto (AI): la zona è la faccia trovata da Vision, cercata di nuovo in ogni fotogramma.
        var volto = false
        /// Con più facce si prende quella più vicina a questo punto (0…1, y in basso); se manca, la più grande.
        var voltoVicino: SIMD2<Float>?
    }

    /// Facce nel fotogramma (riquadri di Vision, 0…1 con l'origine in basso). Si può sostituire nelle prove.
    nonisolated(unsafe) static var rilevaVolti: (CVPixelBuffer) -> [CGRect] = { pb in
        let r = VNDetectFaceRectanglesRequest()
        guard (try? VNImageRequestHandler(cvPixelBuffer: pb, options: [:]).perform([r])) != nil else { return [] }
        return (r.results ?? []).map(\.boundingBox)
    }

    /// Facce in pixel, y verso il basso: centro e lato (media geometrica di larghezza e altezza).
    private static func volti(_ f: Fotogramma) -> [(c: SIMD2<Double>, l: Double)] {
        let w = Double(f.w), h = Double(f.h)
        return rilevaVolti(f.pb).map { b in
            (SIMD2(Double(b.midX) * w, (1 - Double(b.midY)) * h), (Double(b.width) * w * Double(b.height) * h).squareRoot())
        }
    }

    /// Per fermare un tracking in corso (pulsante "Ferma").
    final class Interruttore: @unchecked Sendable {
        private let lock = NSLock()
        private var _fermo = false
        var fermo: Bool { lock.lock(); defer { lock.unlock() }; return _fermo }
        func ferma() { lock.lock(); _fermo = true; lock.unlock() }
    }

    /// Un fotogramma già raddrizzato e rimpicciolito: per Vision (colore) e per il confronto dei riquadri (grigio, righe dall'alto).
    struct Fotogramma: @unchecked Sendable {
        let tempo: Double
        let pb: CVPixelBuffer
        let grigio: [UInt8]
        let w: Int, h: Int
    }

    /// `raggio`: grandezza della zona da seguire rispetto al lato lungo (come il raggio delle finestre a cerchio).
    static func traccia(asset: AVAsset, da t0: Double, verso: Verso, centro: SIMD2<Float>, raggio: Float,
                        opzioni: Opzioni, interruttore: Interruttore,
                        progresso: @escaping @Sendable (Double) -> Void) async throws -> Risultato {
        guard let traccia = try await asset.loadTracks(withMediaType: .video).first else { return Risultato() }
        let durata = try await asset.load(.duration).seconds
        let t = try await traccia.load(.preferredTransform)
        let size = try await traccia.load(.naturalSize)
        let fps = Double(max(1, try await traccia.load(.nominalFrameRate)))

        // orientamento del video (i fotogrammi decodificati non sono ruotati)
        let gradi = Int((atan2(Double(t.b), Double(t.a)) * 180 / .pi).rounded())
        let orientamento: CGImagePropertyOrientation
        switch (gradi + 360) % 360 {
        case 90: orientamento = .right
        case 180: orientamento = .down
        case 270: orientamento = .left
        default: orientamento = .up
        }
        let ruotato = orientamento == .right || orientamento == .left
        let W = Float(ruotato ? size.height : size.width), H = Float(ruotato ? size.width : size.height)
        let lato = max(W, H)
        let bw = min(0.6, 2 * raggio * lato / W * 0.8), bh = min(0.6, 2 * raggio * lato / H * 0.8)
        // zona di partenza (0…1, y verso il basso)
        let zona = CGRect(x: CGFloat(centro.x - bw / 2), y: CGFloat(centro.y - bh / 2), width: CGFloat(bw), height: CGFloat(bh))
        let fine = verso == .avanti ? min(durata, t0 + opzioni.massimoSecondi) : max(0, t0 - opzioni.massimoSecondi)
        let mezzo = 0.5 / fps
        let lettore = Lettore(asset: asset, traccia: traccia, orientamento: orientamento)

        return try await Task.detached(priority: .userInitiated) {
            let stato = Stato(zona: zona, opzioni: opzioni, fps: fps)
            func avanzamento(_ tempo: Double) { progresso(min(1, abs(tempo - t0) / max(abs(fine - t0), 0.01))) }

            // ogni fotogramma dentro un autoreleasepool: senza, i fotogrammi decodificati (4K = 12 MB l'uno)
            // restano in memoria fino alla fine e iOS chiude l'app dopo pochi secondi di video
            if verso == .avanti {
                try lettore.avvia(da: t0 - mezzo, a: fine + mezzo)
                defer { lettore.ferma() }
                while autoreleasepool(invoking: {
                    guard let f = lettore.prossimo(), !interruttore.fermo, stato.elabora(f) else { return false }
                    avanzamento(f.tempo)
                    return true
                }) {}
            } else {
                // all'indietro: si leggono blocchi di circa 60 fotogrammi e si percorrono al contrario
                let lunghezza = max(0.5, 60 / fps)
                var fineBlocco = t0 + mezzo
                var ultimo = Double.infinity
                fuori: while fineBlocco > fine {
                    let inizio = max(fine - mezzo, fineBlocco - lunghezza)
                    try lettore.avvia(da: inizio, a: fineBlocco)
                    var blocco: [Fotogramma] = []
                    while let f = autoreleasepool(invoking: { lettore.prossimo() }) {
                        if f.tempo < ultimo - mezzo && f.tempo <= t0 + mezzo { blocco.append(f) }
                    }
                    lettore.ferma()
                    if blocco.isEmpty { break }
                    for f in blocco.reversed() {
                        let continua = autoreleasepool { !interruttore.fermo && stato.elabora(f) }
                        if !continua { break fuori }
                        ultimo = f.tempo
                        avanzamento(f.tempo)
                    }
                    fineBlocco = inizio
                }
            }
            // segui volto: un filo di morbidezza (±50 ms) toglie il tremolio del riconoscimento facce
            let campioni = opzioni.volto ? Tracker.liscia(stato.campioni, raggio: max(1, Int((fps * 0.05).rounded()))) : stato.campioni
            return Risultato(campioni: campioni, perso: stato.perso, volto: stato.volto)
        }.value
    }

    /// Media pesata sui fotogrammi vicini (il primo resta fermo: è il punto di partenza).
    private static func liscia(_ c: [Campione], raggio r: Int) -> [Campione] {
        guard c.count > 2 else { return c }
        var out = c
        for i in 1..<c.count {
            var peso: Float = 0, centro = SIMD2<Float>.zero, scala: Float = 0, rotazione: Float = 0
            for j in max(0, i - r)...min(c.count - 1, i + r) {
                let p = Float(r + 1 - abs(i - j))
                peso += p; centro += c[j].centro * p; scala += c[j].scala * p; rotazione += c[j].rotazione * p
            }
            out[i].centro = centro / peso; out[i].scala = scala / peso; out[i].rotazione = rotazione / peso
        }
        return out
    }

    /// Stato del tracking fotogramma per fotogramma (coordinate in pixel, y verso il basso).
    private final class Stato: @unchecked Sendable {
        let opzioni: Opzioni
        var zona: CGRect                   // zona di partenza, 0…1 con y verso il basso
        let handler = VNSequenceRequestHandler()
        var richiesta: VNTrackObjectRequest?
        /// Ultimi fotogrammi già tracciati: si confronta con uno di qualche fotogramma fa, così gli errori si sommano meno.
        struct Passato { let f: Fotogramma; let centro: SIMD2<Double>; let scala: Double; let rotazione: Double; let guida: SIMD2<Double> }
        var storia: [Passato] = []
        let distanza = 5
        var lato = SIMD2<Double>.zero      // zona di partenza in pixel
        var campioni: [Campione] = []
        var perso = false
        var volto: (centro: SIMD2<Float>, lato: Float)?
        var latoVolto = 0.0                // lato della faccia alla partenza, in pixel
        var senzaVolto = 0                 // fotogrammi di fila in cui la faccia non si è trovata

        let fps: Double

        init(zona: CGRect, opzioni: Opzioni, fps: Double) {
            self.opzioni = opzioni
            self.zona = zona
            self.fps = fps
        }

        /// Un fotogramma: false quando bisogna fermarsi.
        func elabora(_ f: Fotogramma) -> Bool {
            if let m = opzioni.massimoFotogrammi, campioni.count > m { return false }
            let w = Double(f.w), h = Double(f.h)
            if richiesta == nil {
                if opzioni.volto {
                    // la zona diventa la faccia: la più vicina alla finestra, o la più grande
                    let facce = Tracker.volti(f)
                    let scelta: (c: SIMD2<Double>, l: Double)?
                    if let v = opzioni.voltoVicino {
                        let p = SIMD2(Double(v.x) * w, Double(v.y) * h)
                        scelta = facce.min { let a = $0.c - p, b = $1.c - p; return (a * a).sum() < (b * b).sum() }
                    } else {
                        scelta = facce.max { $0.l < $1.l }
                    }
                    guard let s = scelta else { perso = true; return false }
                    // un po' più grande della faccia (capelli, collo): con le facce piccole i riquadri trovano più dettagli
                    let z = s.l * 1.4
                    zona = CGRect(x: (s.c.x - z / 2) / w, y: (s.c.y - z / 2) / h, width: z / w, height: z / h)
                    latoVolto = s.l
                    volto = (SIMD2(Float(s.c.x / w), Float(s.c.y / h)), Float(s.l / max(w, h)))
                }
                // Vision vuole l'origine in basso
                let box = CGRect(x: zona.minX, y: 1 - zona.maxY, width: zona.width, height: zona.height)
                let r = VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(boundingBox: box))
                r.trackingLevel = .accurate
                richiesta = r
            }
            guard let richiesta else { return false }
            let vision = (try? handler.perform([richiesta], on: f.pb)) != nil ? richiesta.results?.first as? VNDetectedObjectObservation : nil
            if let vision { richiesta.inputObservation = vision }
            var trovata = vision.map { SIMD2(Double($0.boundingBox.midX) * w, (1 - Double($0.boundingBox.midY)) * h) }
            guard let ultimo = storia.last else {
                // primo fotogramma: è il punto di partenza, la finestra resta dov'è (o va sulla faccia)
                let c = SIMD2(Double(zona.midX) * w, Double(zona.midY) * h)
                lato = SIMD2(Double(zona.width) * w, Double(zona.height) * h)
                storia = [Passato(f: f, centro: c, scala: 1, rotazione: 0, guida: trovata ?? c)]
                campioni.append(Campione(tempo: f.tempo, centro: SIMD2(Float(zona.midX), Float(zona.midY))))
                return true
            }
            // segui volto: la faccia di questo fotogramma vicina a dove ci si aspetta
            var faccia: (c: SIMD2<Double>, l: Double)?
            if opzioni.volto {
                let atteso = latoVolto * ultimo.scala
                // persa da un po' (la persona si era girata): la si cerca in tutta l'immagine, grande più o meno uguale
                let lontano = Double(senzaVolto) > fps * 0.3 ? .infinity : atteso * 0.7
                faccia = Tracker.volti(f)
                    .filter { let d = $0.c - ultimo.centro; return (d * d).sum().squareRoot() < lontano && $0.l > atteso * 0.6 && $0.l < atteso * 1.6 }
                    .min { let a = $0.c - ultimo.centro, b = $1.c - ultimo.centro; return (a * a).sum() < (b * b).sum() }
                if let faccia, Double(senzaVolto) > fps * 0.3 {
                    // ritrovata lontano: si riparte da lì (i riquadri del fotogramma prima non c'entrano più)
                    storia = [Passato(f: f, centro: faccia.c, scala: faccia.l / latoVolto, rotazione: ultimo.rotazione, guida: faccia.c)]
                    senzaVolto = 0
                    campioni.append(Campione(tempo: f.tempo, centro: SIMD2(Float(faccia.c.x / w), Float(faccia.c.y / h)),
                                             scala: opzioni.dimensione ? Float(faccia.l / latoVolto) : 1, rotazione: opzioni.rotazione ? Float(ultimo.rotazione) : 0))
                    return true
                }
                if trovata == nil || (vision?.confidence ?? 0) <= 0.25, let faccia { trovata = faccia.c }
                senzaVolto = faccia == nil ? senzaVolto + 1 : 0
                // senza faccia per più di 1 s si rischia di seguire altro (la schiena, i capelli): ci si ferma
                // e si tolgono i fotogrammi senza faccia, così la finestra resta dove la faccia si vedeva
                if Double(senzaVolto) > fps {
                    campioni.removeLast(min(campioni.count - 1, senzaVolto - 1))
                    perso = true
                    return false
                }
            }
            let visto = (vision?.confidence ?? 0) > 0.25 || faccia != nil
            // segui volto: se la faccia sparisce un attimo (girata, coperta da una mano) si continua con i riquadri
            guard visto || (opzioni.volto && Double(senzaVolto) <= fps) else { perso = true; return false }
            // dove cercare: prima dove porta la velocità misurata finora, poi dove dice il tracker di Vision
            let velocita = storia.count >= 2 ? ultimo.centro - storia[storia.count - 2].centro : (trovata ?? ultimo.centro) - ultimo.guida
            let previsto = ultimo.centro + velocita
            let guida = visto ? trovata ?? previsto : previsto
            // confronto con qualche fotogramma fa; se non riesce, con quello subito prima
            var nuovo: Passato?
            fuori: for rif in [storia.first!, ultimo] {
                for spinta in [previsto - rif.centro, guida - rif.guida] {
                    if let m = Tracker.movimento(da: rif.f, a: f, centro: rif.centro, lato: lato * rif.scala, rotazione: rif.rotazione, spinta: spinta) {
                        nuovo = Passato(f: f, centro: m.centro, scala: rif.scala * m.scala, rotazione: rif.rotazione + m.rotazione, guida: guida)
                        break fuori
                    }
                }
            }
            // senza faccia, senza tracker di Vision e senza riquadri non c'è più niente da seguire
            if !visto && nuovo == nil && !(opzioni.volto && Double(senzaVolto) <= fps) { perso = true; return false }
            // nessun dettaglio da confrontare: ci si fida del tracker di Vision
            var p = nuovo ?? Passato(f: f, centro: ultimo.centro + guida - ultimo.guida, scala: ultimo.scala, rotazione: ultimo.rotazione, guida: guida)
            if opzioni.volto {
                // su una faccia piccola lo zoom misurato coi riquadri è ballerino: se ne prende metà
                var scala = ultimo.scala * pow(p.scala / ultimo.scala, 0.5)
                var centro = p.centro
                if let faccia {
                    // la faccia trovata corregge posizione e grandezza (niente deriva);
                    // la rotazione resta quella misurata sui riquadri
                    centro += (faccia.c - centro) * 0.35
                    scala *= pow(faccia.l / (latoVolto * scala), 0.4)
                }
                p = Passato(f: f, centro: centro, scala: scala, rotazione: p.rotazione, guida: guida)
            }
            storia.append(p)
            if storia.count > distanza { storia.removeFirst() }
            campioni.append(Campione(tempo: f.tempo, centro: SIMD2(Float(p.centro.x / w), Float(p.centro.y / h)),
                                     scala: opzioni.dimensione ? Float(p.scala) : 1, rotazione: opzioni.rotazione ? Float(p.rotazione) : 0))
            return true
        }
    }

    /// Movimento della zona tra due fotogrammi vicini (pixel, y verso il basso):
    /// nuovo centro, zoom e rotazione (gradi, antiorario).
    static func movimento(da a: Fotogramma, a b: Fotogramma, centro c: SIMD2<Double>, lato: SIMD2<Double>, rotazione: Double,
                          spinta: SIMD2<Double>) -> (centro: SIMD2<Double>, scala: Double, rotazione: Double)? {
        let m = 7                                  // mezzo lato del riquadro (15×15)
        let cerca = 6 + Int(min(20, (spinta.x * spinta.x + spinta.y * spinta.y).squareRoot() * 0.5))
        // la griglia gira con l'oggetto (antiorario sullo schermo = angolo negativo con y verso il basso)
        let ca = cos(-rotazione * .pi / 180), sa = sin(-rotazione * .pi / 180)
        var p: [SIMD2<Double>] = [], q: [SIMD2<Double>] = []
        a.grigio.withUnsafeBufferPointer { ga in
            b.grigio.withUnsafeBufferPointer { gb in
                let n = 7                          // griglia 7×7 di riquadri nella zona
                for j in 0..<n {
                    for i in 0..<n {
                        let u = lato.x * (Double(i) / Double(n - 1) - 0.5) * 0.8, v = lato.y * (Double(j) / Double(n - 1) - 0.5) * 0.8
                        let px = Int((c.x + ca * u - sa * v).rounded())
                        let py = Int((c.y + sa * u + ca * v).rounded())
                        guard px - m >= 0, py - m >= 0, px + m < a.w, py + m < a.h else { continue }
                        // solo riquadri con dettagli (in una zona piatta il confronto non dice niente)
                        var somma = 0, somma2 = 0
                        for y in (py - m)...(py + m) { for x in (px - m)...(px + m) { let v = Int(ga[y * a.w + x]); somma += v; somma2 += v * v } }
                        let k = (2 * m + 1) * (2 * m + 1)
                        guard somma2 * k - somma * somma > 60 * k * k else { continue }
                        func sad(_ qx: Int, _ qy: Int, _ limite: Int) -> Int {
                            guard qx - m >= 0, qy - m >= 0, qx + m < b.w, qy + m < b.h else { return Int.max }
                            var s = 0
                            for d in -m...m {
                                let ra = (py + d) * a.w + px, rb = (qy + d) * b.w + qx
                                for e in -m...m { s += abs(Int(ga[ra + e]) - Int(gb[rb + e])) }
                                if s >= limite { return s }
                            }
                            return s
                        }
                        let cx = px + Int(spinta.x.rounded()), cy = py + Int(spinta.y.rounded())
                        var migliore = Int.max, bx = cx, by = cy
                        for dy in -cerca...cerca {
                            for dx in -cerca...cerca {
                                let s = sad(cx + dx, cy + dy, migliore)
                                if s < migliore { migliore = s; bx = cx + dx; by = cy + dy }
                            }
                        }
                        guard migliore < Int.max, abs(bx - cx) < cerca, abs(by - cy) < cerca else { continue }
                        // mezzo pixel in più di precisione: parabola sui vicini
                        func fine(_ s0: Int, _ s1: Int, _ s2: Int) -> Double {
                            let d = Double(s0 - 2 * s1 + s2)
                            return d > 0 ? max(-0.5, min(0.5, 0.5 * Double(s0 - s2) / d)) : 0
                        }
                        let ox = fine(sad(bx - 1, by, .max), migliore, sad(bx + 1, by, .max))
                        let oy = fine(sad(bx, by - 1, .max), migliore, sad(bx, by + 1, .max))
                        p.append(SIMD2(Double(px), Double(py)))
                        q.append(SIMD2(Double(bx) + ox, Double(by) + oy))
                    }
                }
            }
        }
        guard var t = similitudine(p, q) else { return nil }
        // seconda passata senza i riquadri che non tornano (riflessi, parti coperte, sfondo)
        let errori = zip(p, q).map { u, v in
            let d = t.applica(u) - v
            return (d.x * d.x + d.y * d.y).squareRoot()
        }
        let soglia = max(0.75, errori.sorted()[errori.count / 2] * 2.5)
        let buoni = errori.indices.filter { errori[$0] <= soglia }
        if buoni.count >= 6, buoni.count < p.count, let t2 = similitudine(buoni.map { p[$0] }, buoni.map { q[$0] }) { t = t2 }
        guard t.s > 0.85, t.s < 1.18, abs(t.angolo) < 0.3 else { return nil }
        // con y verso il basso un angolo positivo è orario: la rotazione delle finestre è antioraria
        return (t.applica(c), t.s, -t.angolo * 180 / .pi)
    }

    /// q ≈ s·R(angolo)·(p − pc) + qc, ai minimi quadrati.
    private struct Similitudine {
        var s: Double, angolo: Double, pc: SIMD2<Double>, qc: SIMD2<Double>
        func applica(_ p: SIMD2<Double>) -> SIMD2<Double> {
            let d = p - pc
            return SIMD2(s * (cos(angolo) * d.x - sin(angolo) * d.y), s * (sin(angolo) * d.x + cos(angolo) * d.y)) + qc
        }
    }

    private static func similitudine(_ p: [SIMD2<Double>], _ q: [SIMD2<Double>]) -> Similitudine? {
        guard p.count >= 6 else { return nil }
        let pc = p.reduce(.zero, +) / Double(p.count), qc = q.reduce(.zero, +) / Double(q.count)
        var sa = 0.0, sb = 0.0, sp = 0.0
        for (u, v) in zip(p, q) {
            let a = u - pc, b = v - qc
            sa += a.x * b.x + a.y * b.y
            sb += a.x * b.y - a.y * b.x
            sp += a.x * a.x + a.y * a.y
        }
        guard sp > 0 else { return nil }
        let s = (sa * sa + sb * sb).squareRoot() / sp
        guard s.isFinite, s > 0 else { return nil }
        return Similitudine(s: s, angolo: atan2(sb, sa), pc: pc, qc: qc)
    }

    /// Legge i fotogrammi del video già raddrizzati e rimpiccioliti (lato lungo 960 px: basta ed è veloce).
    private final class Lettore: @unchecked Sendable {
        let asset: AVAsset
        let traccia: AVAssetTrack
        let orientamento: CGImagePropertyOrientation
        let contesto = CIContext(options: [.cacheIntermediates: false])
        let grigi = CGColorSpaceCreateDeviceGray()
        var reader: AVAssetReader?
        var uscita: AVAssetReaderTrackOutput?

        init(asset: AVAsset, traccia: AVAssetTrack, orientamento: CGImagePropertyOrientation) {
            self.asset = asset; self.traccia = traccia; self.orientamento = orientamento
        }

        func avvia(da: Double, a: Double) throws {
            ferma()
            let r = try AVAssetReader(asset: asset)
            r.timeRange = CMTimeRange(start: CMTime(seconds: max(0, da), preferredTimescale: 600),
                                      end: CMTime(seconds: max(da, a), preferredTimescale: 600))
            let o = AVAssetReaderTrackOutput(track: traccia, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange])
            o.alwaysCopiesSampleData = false
            r.add(o)
            guard r.startReading() else { throw r.error ?? CocoaError(.fileReadUnknown) }
            reader = r; uscita = o
        }

        func prossimo() -> Fotogramma? {
            while let sb = uscita?.copyNextSampleBuffer() {
                guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
                if let f = converti(pb, CMSampleBufferGetPresentationTimeStamp(sb).seconds) { return f }
            }
            return nil
        }

        func ferma() { reader?.cancelReading(); reader = nil; uscita = nil }

        private func converti(_ pb: CVPixelBuffer, _ tempo: Double) -> Fotogramma? {
            var img = CIImage(cvPixelBuffer: pb).oriented(orientamento)
            img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
            let k = min(1, 960 / max(img.extent.width, img.extent.height))
            img = img.transformed(by: CGAffineTransform(scaleX: k, y: k))
            let w = Int(img.extent.width.rounded()), h = Int(img.extent.height.rounded())
            let area = CGRect(x: 0, y: 0, width: w, height: h)
            var out: CVPixelBuffer?
            CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &out)
            guard let out else { return nil }
            contesto.render(img, to: out, bounds: area, colorSpace: nil)
            var grigio = [UInt8](repeating: 0, count: w * h)
            contesto.render(img, toBitmap: &grigio, rowBytes: w, bounds: area, format: .L8, colorSpace: grigi)
            return Fotogramma(tempo: tempo, pb: out, grigio: grigio, w: w, h: h)
        }
    }
}
