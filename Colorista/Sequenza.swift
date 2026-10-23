import AVFoundation
import CoreImage
import UIKit

/// Tutto ciò che serve per disegnare una clip della sequenza (letto dal thread del compositore).
final class LivelloClip: @unchecked Sendable {
    let indice: Int
    let nodi: [Nodo]
    let montaggio: Montaggio
    let video: Bool
    let inizioSequenza: Double          // dove parte nella timeline (s)
    let durataSequenza: Double          // quanto dura nella timeline (s)
    let orientamento: CGImagePropertyOrientation
    let foto: CIImage?
    var traccia: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    var titolo: CIImage?                // testo già disegnato alla misura della sequenza
    /// Sottotitoli (tempi nel file), disegnati quando servono e tenuti da parte.
    private let sottotitoli: [Sottotitolo]
    private var disegnati: [UUID: CIImage] = [:]
    private let lock = NSLock()

    func sottotitolo(a t: Double, misura: CGSize) -> CIImage? {
        let ts = tempoSorgente(t)
        guard montaggio.mostraSottotitoli, let s = sottotitoli.first(where: { ts >= $0.inizio && ts < $0.fine }) else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let img = disegnati[s.id] { return img }
        var stile = montaggio.stileSottotitoli
        stile.testo = s.testo
        let img = DisegnaTitolo.immagine(stile, misura: misura)
        if disegnati.count > 40 { disegnati.removeAll() }
        disegnati[s.id] = img
        return img
    }

    /// Correzioni di stabilizzazione e ingrandimento che nasconde i bordi (calcolate dal percorso salvato).
    let stab: [SIMD3<Float>]
    let zoomStab: Float

    init(indice: Int, nodi: [Nodo], montaggio: Montaggio, video: Bool, inizioSequenza: Double, durataSequenza: Double,
         orientamento: CGImagePropertyOrientation, foto: CIImage?) {
        self.indice = indice; self.nodi = nodi; self.montaggio = montaggio; self.video = video
        self.inizioSequenza = inizioSequenza; self.durataSequenza = durataSequenza
        self.orientamento = orientamento; self.foto = foto
        sottotitoli = montaggio.sottotitoli
        if montaggio.stabilizza, montaggio.percorsoStab.count > 2 {
            let p = montaggio.percorsoStab
            let fps = Float(p.count - 1) / max(p.last!.x - p.first!.x, 0.01)
            stab = Stabilizzatore.correzioni(p, fps: fps, forza: montaggio.forzaStab, treppiede: montaggio.treppiede)
            zoomStab = Stabilizzatore.zoom(per: stab)
        } else {
            stab = []; zoomStab = 1
        }
    }

    var fineSequenza: Double { inizioSequenza + durataSequenza }

    /// Tempo nel file sorgente per un istante della sequenza (serve a keyframe, tracker e stabilizzazione).
    func tempoSorgente(_ t: Double) -> Double { montaggio.inizio + (t - inizioSequenza) * montaggio.velocita }
}

/// Impostazioni comuni della sequenza.
final class ContestoSequenza: @unchecked Sendable {
    let livelli: [LivelloClip]
    let misura: CGSize
    let riempi: Bool
    let lut: Int
    init(livelli: [LivelloClip], misura: CGSize, riempi: Bool, lut: Int) {
        self.livelli = livelli; self.misura = misura; self.riempi = riempi; self.lut = lut
    }
}

/// Un tratto della timeline: una clip sola o due durante una transizione.
final class IstruzioneSequenza: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let contesto: ContestoSequenza
    let attivi: [Int]                   // indici dei livelli, in ordine (uscente, entrante)

    init(_ r: CMTimeRange, contesto: ContestoSequenza, attivi: [Int]) {
        timeRange = r; self.contesto = contesto; self.attivi = attivi
        let tracce = attivi.compactMap { i -> NSValue? in
            let t = contesto.livelli[i].traccia
            return t == kCMPersistentTrackID_Invalid ? nil : NSNumber(value: t)
        }
        requiredSourceTrackIDs = tracce.isEmpty ? nil : tracce
    }
}

/// Compositore della sequenza: correzione colore di ogni clip, inquadratura, stabilizzazione, titolo e transizioni.
final class CompositoreSequenza: NSObject, AVVideoCompositing, @unchecked Sendable {
    private let contestoCI = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .cacheIntermediates: false])
    private let spazio709 = CGColorSpace(name: CGColorSpace.itur_709)!
    private let spazioSRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    // fotogrammi su IOSurface e compatibili Metal: il player li deve poter mostrare (senza: errore -12784 in riproduzione)
    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int](),
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int](),
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ req: AVAsynchronousVideoCompositionRequest) {
        guard let ist = req.videoCompositionInstruction as? IstruzioneSequenza,
              let uscita = req.renderContext.newPixelBuffer() else {
            req.finish(with: NSError(domain: "Colorista", code: 1)); return
        }
        let c = ist.contesto
        let t = req.compositionTime.seconds
        let area = CGRect(origin: .zero, size: c.misura)
        let nero = CIImage(color: .black).cropped(to: area)

        var immagini: [CIImage] = []
        for i in ist.attivi {
            let l = c.livelli[i]
            immagini.append(disegna(l, t: t, req: req, c: c) ?? nero)
        }
        var finale = immagini.first ?? nero
        if immagini.count == 2 {
            let a = c.livelli[ist.attivi[0]], b = c.livelli[ist.attivi[1]]
            let durata = max(a.fineSequenza - b.inizioSequenza, 0.001)
            let p = min(max((t - b.inizioSequenza) / durata, 0), 1)
            finale = transizione(a.montaggio.transizione, immagini[0], immagini[1], p, area)
        }
        contestoCI.render(finale.composited(over: nero).cropped(to: area), to: uscita, bounds: area, colorSpace: spazioSRGB)
        req.finish(withComposedVideoFrame: uscita)
    }

    private func disegna(_ l: LivelloClip, t: Double, req: AVAsynchronousVideoCompositionRequest, c: ContestoSequenza) -> CIImage? {
        var img: CIImage
        if l.video {
            guard let pb = req.sourceFrame(byTrackID: l.traccia) else { return nil }
            img = CIImage(cvPixelBuffer: pb).oriented(l.orientamento)
            img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
        } else {
            guard let f = l.foto else { return nil }
            img = f
        }
        let sorgente = l.tempoSorgente(t)
        // correzione colore della clip (la stessa della pagina Color)
        let catena = Fabbrica.condivisa.catena(nodi: l.nodi, tempo: l.video ? sorgente : nil, size: c.lut, spazio: l.video ? spazio709 : spazioSRGB)
        img = catena.applica(img)
        // stabilizzazione: sposta il fotogramma contro il tremolio e ingrandisce un poco per nascondere i bordi
        if !l.stab.isEmpty, let s = Stabilizzatore.correzione(l.stab, a: sorgente) {
            let e = img.extent, z = CGFloat(l.zoomStab)
            img = img.clampedToExtent()
                .transformed(by: CGAffineTransform(translationX: CGFloat(s.x) * e.width, y: CGFloat(s.y) * e.height))
                .transformed(by: CGAffineTransform(translationX: -e.midX, y: -e.midY).concatenating(CGAffineTransform(scaleX: z, y: z)).concatenating(CGAffineTransform(translationX: e.midX, y: e.midY)))
                .cropped(to: e)
        }
        img = Inquadra.applica(l.montaggio.inquadratura, img)
        // reframe: il soggetto resta al centro quando il formato taglia i bordi (solo senza ritocchi d'inquadratura)
        let centro = l.montaggio.seguiSoggetto && l.montaggio.inquadratura.neutra ? Reframe.centro(l.montaggio.reframe, a: sorgente) : nil
        img = FormatoSocial.adatta(img, a: c.misura, riempi: c.riempi, centro: centro)
        if let titolo = l.titolo {
            // il titolo entra e esce con una breve dissolvenza
            let dentro = t - l.inizioSequenza, fuori = l.fineSequenza - t
            let a = CGFloat(min(1, max(0, min(dentro, fuori) / 0.3)))
            let tt = a >= 1 ? titolo : titolo.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: a)])
            img = tt.composited(over: img)
        }
        if let st = l.sottotitolo(a: t, misura: c.misura) { img = st.composited(over: img) }
        return img
    }

    private func transizione(_ tipo: Transizione, _ a: CIImage, _ b: CIImage, _ p: Double, _ area: CGRect) -> CIImage {
        switch tipo {
        case .nessuna, .incrociata:
            return a.applyingFilter("CIDissolveTransition", parameters: ["inputTargetImage": b, "inputTime": p])
        case .nero, .bianco:
            let colore = CIImage(color: tipo == .nero ? .black : .white).cropped(to: area)
            if p < 0.5 { return a.applyingFilter("CIDissolveTransition", parameters: ["inputTargetImage": colore, "inputTime": p * 2]) }
            return colore.applyingFilter("CIDissolveTransition", parameters: ["inputTargetImage": b, "inputTime": (p - 0.5) * 2])
        }
    }
}

/// Inquadratura (Inspector): rotazione a scatti di 90°, specchio, zoom e spostamento, poi ritaglio alla misura di partenza.
enum Inquadra {
    static func applica(_ q: Inquadratura, _ img: CIImage) -> CIImage {
        guard !q.neutra else { return img }
        var x = img
        if q.specchio { x = x.oriented(.upMirrored) }
        switch ((q.rotazione % 360) + 360) % 360 {
        case 90: x = x.oriented(.right)
        case 180: x = x.oriented(.down)
        case 270: x = x.oriented(.left)
        default: break
        }
        x = x.transformed(by: CGAffineTransform(translationX: -x.extent.minX, y: -x.extent.minY))
        let e = x.extent
        guard q.zoom != 1 || q.x != 0 || q.y != 0 else { return x }
        let z = CGFloat(max(q.zoom, 1))
        // lo spostamento è limitato a quanto lo zoom lascia fuori dal quadro
        let dx = CGFloat(q.x) * e.width * (z - 1) / 2, dy = -CGFloat(q.y) * e.height * (z - 1) / 2
        return x.transformed(by: CGAffineTransform(translationX: -e.midX, y: -e.midY)
            .concatenating(CGAffineTransform(scaleX: z, y: z))
            .concatenating(CGAffineTransform(translationX: e.midX + dx, y: e.midY + dy)))
            .cropped(to: e)
    }
}

/// Disegna il testo di un titolo alla misura della sequenza (trasparente fuori dalle lettere).
enum DisegnaTitolo {
    static func immagine(_ t: Titolo, misura: CGSize) -> CIImage? {
        let testo = t.testo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !testo.isEmpty else { return nil }
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        fmt.opaque = false
        let altezza = max(12, CGFloat(t.dimensione) * misura.height)
        let colore: UIColor = {
            switch t.colore {
            case .bianco: return .white
            case .nero: return .black
            case .giallo: return UIColor(red: 1, green: 0.85, blue: 0.1, alpha: 1)
            case .arancio: return UIColor(red: 0.95, green: 0.5, blue: 0.22, alpha: 1)
            }
        }()
        let stile = NSMutableParagraphStyle()
        stile.alignment = .center
        let ombra = NSShadow()
        ombra.shadowColor = UIColor.black.withAlphaComponent(t.sfondo ? 0 : 0.6)
        ombra.shadowBlurRadius = altezza * 0.08
        ombra.shadowOffset = CGSize(width: 0, height: altezza * 0.03)
        let attr: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: altezza, weight: t.grassetto ? .bold : .regular),
            .foregroundColor: colore, .paragraphStyle: stile, .shadow: ombra,
        ]
        let margine = misura.width * 0.06
        let box = (testo as NSString).boundingRect(with: CGSize(width: misura.width - 2 * margine, height: .greatestFiniteMagnitude),
                                                  options: [.usesLineFragmentOrigin], attributes: attr, context: nil)
        let cy = CGFloat(t.posizione) * misura.height
        let rect = CGRect(x: margine, y: min(max(cy - box.height / 2, 0), misura.height - box.height), width: misura.width - 2 * margine, height: box.height)
        // si disegna solo il riquadro del testo (non tutto il fotogramma): pesa poco anche con tanti sottotitoli
        let fasciaTesto = CGRect(x: margine + (rect.width - box.width) / 2, y: rect.minY, width: box.width, height: rect.height)
        let area = fasciaTesto.insetBy(dx: -altezza * 0.4, dy: -altezza * 0.3).integral
        let ui = UIGraphicsImageRenderer(size: area.size, format: fmt).image { ctx in
            ctx.cgContext.translateBy(x: -area.minX, y: -area.minY)
            if t.sfondo {
                let fascia = UIBezierPath(roundedRect: fasciaTesto.insetBy(dx: -altezza * 0.3, dy: -altezza * 0.2), cornerRadius: altezza * 0.2)
                UIColor.black.withAlphaComponent(0.55).setFill()
                fascia.fill()
            }
            (testo as NSString).draw(with: rect, options: [.usesLineFragmentOrigin], attributes: attr, context: nil)
        }
        // Core Image ha l'origine in basso
        return ui.cgImage.map { CIImage(cgImage: $0).transformed(by: CGAffineTransform(translationX: area.minX, y: misura.height - area.maxY)) }
    }
}

/// Costruisce la sequenza (AVComposition + compositore + mix audio) dalle clip del progetto.
enum Sequenza {
    struct Piano {
        let composizione: AVMutableComposition
        let video: AVMutableVideoComposition
        let audio: AVMutableAudioMix?          // nil se non c'è audio: un mix vuoto fa rifiutare la sequenza al player
        let durata: Double
        let contesto: ContestoSequenza
        var musicaNonValida = false
    }

    /// Durata di una clip nella timeline (taglio e velocità compresi).
    static func durata(_ m: Montaggio, video: Bool, durataFile: Double) -> Double {
        guard video else { return max(0.2, m.durataFoto) }
        let fine = min(m.fine ?? durataFile, durataFile)
        return max(0.1, (fine - min(m.inizio, fine - 0.1)) / max(m.velocita, 0.1))
    }

    static func costruisci(_ p: Progetto, misura: CGSize? = nil, riempi: Bool = false, lut: Int = Studio.lutAnteprima) async throws -> Piano {
        let comp = AVMutableComposition()
        guard let vA = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let vB = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let aA = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
              let aB = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw CocoaError(.featureUnsupported) }
        let tv = [vA, vB], ta = [aA, aB]
        var param: [CMPersistentTrackID: AVMutableAudioMixInputParameters] = [:]
        for a in ta { param[a.trackID] = AVMutableAudioMixInputParameters(track: a) }
        // le variazioni di volume si raccolgono e si applicano alla fine in ordine, senza sovrapposizioni
        // (AVFoundation chiude l'app se due rampe di volume si sovrappongono)
        var volumi: [CMPersistentTrackID: ProgrammaVolume] = [:]

        var livelli: [LivelloClip] = []
        // le tracce non tengono in vita il loro asset: senza questo l'inserimento fallisce (-12780)
        var vivi: [AVAsset] = []
        var cursore = 0.0                       // fine della clip precedente
        var transPrec = 0.0                     // sovrapposizione con la clip precedente
        var misuraPrima: CGSize?
        var fps: Float = 30
        func cm(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 600) }

        for (i, c) in p.clips.enumerated() {
            let m = c.taglio
            let url = Archivio.url("Media", c.file)
            var durataFile = m.durataFoto
            var orient: CGImagePropertyOrientation = .up
            var foto: CIImage?
            var tracciaV: AVAssetTrack?, tracciaA: AVAssetTrack?
            if c.video {
                let a = AVURLAsset(url: url)
                vivi.append(a)
                durataFile = try await a.load(.duration).seconds
                tracciaV = try await a.loadTracks(withMediaType: .video).first
                tracciaA = try await a.loadTracks(withMediaType: .audio).first
                if let v = tracciaV {
                    let (n, tr, f) = try await v.load(.naturalSize, .preferredTransform, .nominalFrameRate)
                    orient = orientamento(tr)
                    let r = CGRect(origin: .zero, size: n).applying(tr)
                    if misuraPrima == nil { misuraPrima = CGSize(width: abs(r.width), height: abs(r.height)); fps = f > 0 ? f : 30 }
                }
            } else if let ui = UIImage(contentsOfFile: url.path) {
                foto = ui.ridotta(lato: 3840).cgImage.map { CIImage(cgImage: $0) }
                if misuraPrima == nil, let f = foto { misuraPrima = f.extent.size }
            }
            let dur = durata(m, video: c.video, durataFile: durataFile)
            // la transizione della clip precedente fa iniziare questa un po' prima (sovrapposte);
            // mai più di metà di questa clip, così non si sovrappongono mai tre clip
            transPrec = min(transPrec, dur / 2)
            // con uno spazio vuoto prima niente sovrapposizione: la clip parte dopo il buco
            let inizio = m.vuotoPrima > 0.001 ? cursore + m.vuotoPrima : max(0, cursore - transPrec)
            let livello = LivelloClip(indice: i, nodi: c.nodi, montaggio: m, video: c.video, inizioSequenza: inizio, durataSequenza: dur,
                                      orientamento: orient, foto: foto)
            let pista = i % 2
            if let v = tracciaV {
                let fineFile = min(m.fine ?? durataFile, durataFile)
                let da = min(m.inizio, max(0, fineFile - 0.1))
                let gamma = CMTimeRange(start: cm(da), end: cm(fineFile))
                let dove = cm(inizio)
                // spazio vuoto fino a qui (le tracce A e B si alternano)
                let finePista = tv[pista].timeRange.end
                if finePista < dove { tv[pista].insertEmptyTimeRange(CMTimeRange(start: finePista, end: dove)) }
                try tv[pista].insertTimeRange(gamma, of: v, at: dove)
                tv[pista].scaleTimeRange(CMTimeRange(start: dove, duration: gamma.duration), toDuration: cm(dur))
                livello.traccia = tv[pista].trackID
                if let a = tracciaA, m.volume > 0 {
                    let fineA = ta[pista].timeRange.end
                    if fineA < dove { ta[pista].insertEmptyTimeRange(CMTimeRange(start: fineA, end: dove)) }
                    try ta[pista].insertTimeRange(gamma, of: a, at: dove)
                    ta[pista].scaleTimeRange(CMTimeRange(start: dove, duration: gamma.duration), toDuration: cm(dur))
                    // volume e dissolvenze (le transizioni sfumano anche l'audio)
                    let id = ta[pista].trackID
                    let entrata = max(m.audioEntrata, transPrec)
                    let uscita = max(m.audioUscita, m.transizione == .nessuna || i == p.clips.count - 1 ? 0 : m.durataTransizione)
                    let fine = inizio + dur
                    var pv = volumi[id] ?? ProgrammaVolume()
                    pv.imposta(0, a: max(0, inizio - 0.001))
                    if entrata > 0 { pv.rampa(0, m.volume, inizio: inizio, durata: min(entrata, dur / 2)) }
                    else { pv.imposta(m.volume, a: inizio) }
                    if uscita > 0 { pv.rampa(m.volume, 0, inizio: fine - min(uscita, dur / 2), durata: min(uscita, dur / 2)) }
                    volumi[id] = pv
                }
            }
            livelli.append(livello)
            cursore = inizio + dur
            transPrec = (m.transizione == .nessuna || i == p.clips.count - 1) ? 0 : min(m.durataTransizione, dur / 2)
        }
        let totale = cursore
        // le foto non hanno traccia e lo spazio vuoto in fondo non conta: una traccia di riempimento (video nero
        // che il compositore non guarda) fa durare la sequenza quanto deve
        if totale > 0, let nero = try await Riempitivo.traccia(), let tr = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            vivi.append(nero.asset)
            let d = nero.durata
            try tr.insertTimeRange(CMTimeRange(start: .zero, duration: d), of: nero.traccia, at: .zero)
            tr.scaleTimeRange(CMTimeRange(start: .zero, duration: d), toDuration: cm(totale))
            tr.isEnabled = false        // serve solo alla durata
        }

        // audio di sottofondo: le tracce suonano una dopo l'altra (e ricominciano se sono più corte del montaggio).
        // Se un file non si apre, il montaggio si fa lo stesso senza quella traccia.
        var musicaNonValida = false
        let tracce = p.musiche.filter { $0.volume > 0 }
        if !tracce.isEmpty, totale > 0, let tm = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            // (traccia, inizio nel file, durata tagliata, impostazioni)
            var sorgenti: [(AVAssetTrack, Double, Double, Musica)] = []
            for mu in tracce {
                do {
                    let a = AVURLAsset(url: Archivio.url("Media", mu.file))
                    vivi.append(a)
                    if let src = try await a.loadTracks(withMediaType: .audio).first {
                        let df = try await a.load(.duration).seconds
                        let d = mu.durata(file: df)
                        if df > 0.1 { sorgenti.append((src, min(mu.inizio, max(0, df - d)), d, mu)) } else { musicaNonValida = true }
                    } else { musicaNonValida = true }
                } catch { musicaNonValida = true }
            }
            let pm = AVMutableAudioMixInputParameters(track: tm)
            var pv = ProgrammaVolume()
            var t = 0.0
            var pezzi: [(inizio: Double, fine: Double, vol: Float)] = []
            giro: while t < totale, !sorgenti.isEmpty {
                for (src, da, d, mu) in sorgenti {
                    guard t < totale else { break giro }
                    let pezzo = min(d, totale - t)
                    try tm.insertTimeRange(CMTimeRange(start: cm(da), duration: cm(pezzo)), of: src, at: cm(t))
                    let vol = mu.volume
                    // dissolvenze della traccia
                    let e = min(mu.entrata, pezzo / 2)
                    if e > 0.01 { pv.rampa(0, vol, inizio: t, durata: e) } else { pv.imposta(vol, a: t) }
                    let u = min(mu.uscita, pezzo / 2)
                    if u > 0.01, pezzo >= d - 0.01 { pv.rampa(vol, 0, inizio: t + pezzo - u, durata: u) }
                    pezzi.append((t, t + pezzo, vol))
                    t += pezzo
                }
                if !p.ripetiMusica { break }
            }
            // sfumatura finale del montaggio: solo se l'audio arriva fino in fondo
            let df = min(p.dissolvenzaMusica, totale / 2)
            if df > 0, !sorgenti.isEmpty, t >= totale - 0.01 {
                // parte dal volume del pezzo che suona in quel momento
                let vol = pezzi.last { $0.inizio <= totale - df }?.vol ?? pezzi.last?.vol ?? 1
                pv.rampa(vol, 0, inizio: totale - df, durata: df, prioritaria: true)
            }
            pv.applica(a: pm)
            param[tm.trackID] = pm
        }

        let dimensione = misura ?? pari(misuraPrima ?? CGSize(width: 1920, height: 1080))
        let contesto = ContestoSequenza(livelli: livelli, misura: dimensione, riempi: riempi, lut: lut)
        for l in livelli where !l.montaggio.titolo.testo.isEmpty { l.titolo = DisegnaTitolo.immagine(l.montaggio.titolo, misura: dimensione) }

        // istruzioni: si taglia la timeline in tratti dove cambiano le clip visibili
        var bordi = Set<Double>([0, totale])
        for l in livelli { bordi.insert(l.inizioSequenza); bordi.insert(min(l.fineSequenza, totale)) }
        let ordinati = bordi.sorted()
        var istruzioni: [IstruzioneSequenza] = []
        for (a, b) in zip(ordinati, ordinati.dropFirst()) where b - a > 0.0005 {
            let mezzo = (a + b) / 2
            let attivi = livelli.filter { $0.inizioSequenza <= mezzo && mezzo < $0.fineSequenza }.map(\.indice)
            istruzioni.append(IstruzioneSequenza(CMTimeRange(start: cm(a), end: cm(b)), contesto: contesto, attivi: attivi))
        }
        // i tratti devono essere contigui e coprire tutta la durata
        if let ultimo = istruzioni.last, ultimo.timeRange.end != comp.duration, comp.duration > ultimo.timeRange.end {
            istruzioni.append(IstruzioneSequenza(CMTimeRange(start: ultimo.timeRange.end, end: comp.duration), contesto: contesto, attivi: ultimo.attivi))
        }

        for (id, pv) in volumi { if let pa = param[id] { pv.applica(a: pa) } }
        // le tracce rimaste vuote (per esempio audio di clip mute) fanno fallire la riproduzione
        for t in comp.tracks where t.segments.isEmpty {
            param[t.trackID] = nil
            comp.removeTrack(t)
        }
        withExtendedLifetime(vivi) {}
        let vc = AVMutableVideoComposition()
        vc.customVideoCompositorClass = CompositoreSequenza.self
        vc.renderSize = dimensione
        vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(24, min(60, fps.rounded()))))
        vc.instructions = istruzioni
        var mix: AVMutableAudioMix?
        if !param.isEmpty {
            mix = AVMutableAudioMix()
            mix?.inputParameters = Array(param.values)
        }
        return Piano(composizione: comp, video: vc, audio: mix, durata: totale, contesto: contesto, musicaNonValida: musicaNonValida)
    }

    static func pari(_ s: CGSize) -> CGSize { CGSize(width: (s.width / 2).rounded() * 2, height: (s.height / 2).rounded() * 2) }

    /// Orientamento del video dalla sua trasformazione (video girati in verticale, capovolti…).
    static func orientamento(_ t: CGAffineTransform) -> CGImagePropertyOrientation {
        let gradi = Int((atan2(t.b, t.a) * 180 / .pi).rounded())
        switch gradi {
        case 90: return .right
        case -90, 270: return .left
        case 180, -180: return .down
        default: return .up
        }
    }
}

/// Un secondo di video nero (160×90: misure più piccole il decoder le rifiuta) creato una volta sola: dà la durata giusta alla sequenza.
enum Riempitivo {
    struct Traccia { let asset: AVAsset; let traccia: AVAssetTrack; let durata: CMTime }

    static var url: URL { FileManager.default.temporaryDirectory.appendingPathComponent("colorista-nero-160.mov") }

    static func traccia() async throws -> Traccia? {
        if !FileManager.default.fileExists(atPath: url.path) { try await crea() }
        let a = AVURLAsset(url: url)
        guard let t = try await a.loadTracks(withMediaType: .video).first else { return nil }
        return Traccia(asset: a, traccia: t, durata: try await a.load(.duration))
    }

    private static func crea() async throws {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".mov")
        let w = try AVAssetWriter(outputURL: tmp, fileType: .mov)
        let inp = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 90])
        let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: inp, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 90])
        w.add(inp)
        guard w.startWriting() else { throw w.error ?? CocoaError(.fileWriteUnknown) }
        w.startSession(atSourceTime: .zero)
        for f in 0...1 {
            while !inp.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, 160, 90, kCVPixelFormatType_32BGRA, nil, &pb)
            guard let pb else { continue }
            CVPixelBufferLockBaseAddress(pb, [])
            memset(CVPixelBufferGetBaseAddress(pb), 0, CVPixelBufferGetDataSize(pb))
            CVPixelBufferUnlockBaseAddress(pb, [])
            ad.append(pb, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: 1))
        }
        inp.markAsFinished()
        await w.finishWriting()
        guard w.status == .completed else { throw w.error ?? CocoaError(.fileWriteUnknown) }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tmp, to: url)
    }
}

/// Variazioni di volume di una traccia: si raccolgono e si applicano in ordine di tempo, accorciando o saltando
/// quelle che si sovrapporrebbero (AVFoundation va in crash con rampe sovrapposte).
struct ProgrammaVolume {
    private struct Evento { var inizio: Double; var durata: Double; var da: Float; var a: Float; var prioritaria: Bool }
    private var eventi: [Evento] = []

    mutating func imposta(_ v: Float, a t: Double) { eventi.append(Evento(inizio: t, durata: 0, da: v, a: v, prioritaria: false)) }
    mutating func rampa(_ da: Float, _ a: Float, inizio: Double, durata: Double, prioritaria: Bool = false) {
        eventi.append(Evento(inizio: inizio, durata: max(0, durata), da: da, a: a, prioritaria: prioritaria))
    }

    func applica(a p: AVMutableAudioMixInputParameters) {
        // una rampa prioritaria (la sfumatura finale) toglie gli eventi che cadono dentro di lei
        let prioritarie = eventi.filter(\.prioritaria)
        let tenuti = eventi.filter { e in e.prioritaria || !prioritarie.contains { e.inizio + e.durata > $0.inizio && e.inizio < $0.inizio + $0.durata } }
        var fine = -Double.infinity
        for e in tenuti.sorted(by: { $0.inizio < $1.inizio }) {
            var t = e.inizio, d = e.durata, da = e.da
            if d < 0.002 {
                // un valore secco: saltato solo se cade dentro una rampa, altrimenti subito dopo la fine della precedente
                if t < fine - 0.0005 { continue }
                t = max(t, fine + 0.0005)
            } else if t < fine + 0.0005 {
                if t + d <= fine + 0.002 { continue }                   // rampa tutta dentro la precedente
                let tolto = fine + 0.001 - t                            // si accorcia, partendo dal volume giusto
                da = e.da + (e.a - e.da) * Float(min(1, tolto / max(d, 0.0001)))
                t += tolto; d -= tolto
            }
            let tempo = CMTime(seconds: max(0, t), preferredTimescale: 6000)
            if d < 0.002 { p.setVolume(e.a, at: tempo); fine = t }
            else { p.setVolumeRamp(fromStartVolume: da, toEndVolume: e.a, timeRange: CMTimeRange(start: tempo, duration: CMTime(seconds: d, preferredTimescale: 6000))); fine = t + d }
        }
    }
}
