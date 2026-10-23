import AVFoundation
import CoreImage

/// Preset di esportazione per i social, come i preset della pagina Deliver di DaVinci.
enum FormatoSocial: String, CaseIterable, Identifiable {
    case originale = "Originale"
    case youtube4K = "YouTube 4K"
    case youtube = "YouTube 1080p"
    case shorts = "YouTube Shorts"
    case reel = "Instagram Reel / Storia"
    case post = "Instagram Post 4:5"
    case quadrato = "Instagram 1:1"
    case tiktok = "TikTok"
    case facebook = "Facebook"
    case x = "X (Twitter)"

    var id: String { String(describing: self) }

    /// Misura in pixel (larghezza × altezza); nil = quella della clip.
    var misura: CGSize? {
        switch self {
        case .originale: return nil
        case .youtube4K: return CGSize(width: 3840, height: 2160)
        case .youtube, .facebook: return CGSize(width: 1920, height: 1080)
        case .shorts, .reel, .tiktok: return CGSize(width: 1080, height: 1920)
        case .post: return CGSize(width: 1080, height: 1350)
        case .quadrato: return CGSize(width: 1080, height: 1080)
        case .x: return CGSize(width: 1280, height: 720)
        }
    }

    var rapporto: String {
        switch self {
        case .originale: return "come la clip"
        case .youtube4K, .youtube, .facebook, .x: return "16:9"
        case .shorts, .reel, .tiktok: return "9:16"
        case .post: return "4:5"
        case .quadrato: return "1:1"
        }
    }

    var icona: String {
        switch self {
        case .originale: return "rectangle.dashed"
        case .youtube4K, .youtube: return "play.rectangle.fill"
        case .shorts: return "play.rectangle.on.rectangle"
        case .reel, .post, .quadrato: return "camera"
        case .tiktok: return "music.note"
        case .facebook: return "person.2"
        case .x: return "xmark"
        }
    }

    /// Il 4K in HEVC (file più piccoli), gli altri in H.264 che tutti i social accettano.
    var hevc: Bool { self == .youtube4K }

    var descrizione: String {
        switch self {
        case .originale: return "Stessa misura della clip, H.264."
        case .youtube4K: return "3840×2160 HEVC: per video girati in 4K."
        case .youtube: return "1920×1080 H.264, il formato standard di YouTube."
        case .shorts: return "1080×1920 verticale, fino a 3 minuti."
        case .reel: return "1080×1920 verticale per Reel e Storie."
        case .post: return "1080×1350: il formato che occupa più spazio nel feed."
        case .quadrato: return "1080×1080 quadrato."
        case .tiktok: return "1080×1920 verticale."
        case .facebook: return "1920×1080 H.264."
        case .x: return "1280×720 H.264, leggero da caricare."
        }
    }

    /// Misura finale per un video: per "Originale" quella della clip (già ruotata nel verso giusto).
    func dimensione(per a: AVAsset) async throws -> CGSize {
        if let misura { return misura }
        guard let t = try await a.loadTracks(withMediaType: .video).first else { throw CocoaError(.fileReadCorruptFile) }
        let (n, tr) = try await t.load(.naturalSize, .preferredTransform)
        let r = CGRect(origin: .zero, size: n).applying(tr)
        // misure pari: i codec le preferiscono
        return CGSize(width: (abs(r.width) / 2).rounded() * 2, height: (abs(r.height) / 2).rounded() * 2)
    }

    /// Per le foto: nil = lascia la foto com'è.
    func dimensioneFoto(sorgente: CGSize) -> CGSize? { misura }

    /// Porta l'immagine alla misura `u`: riempiendo (ritaglio centrato) o adattandola con bande nere.
    /// `centro` (0…1, origine in basso come Core Image): punto da tenere al centro quando si riempie (reframe sul soggetto).
    static func adatta(_ img: CIImage, a u: CGSize, riempi: Bool, centro: SIMD2<Float>? = nil) -> CIImage {
        let e = img.extent
        guard e.width > 0, e.height > 0 else { return img }
        let k = riempi ? max(u.width / e.width, u.height / e.height) : min(u.width / e.width, u.height / e.height)
        var tx = (u.width - e.width * k) / 2 - e.minX * k
        var ty = (u.height - e.height * k) / 2 - e.minY * k
        if riempi, let c = centro {
            // il soggetto al centro, senza mai uscire dall'immagine
            tx = min(-e.minX * k, max(u.width - e.maxX * k, u.width / 2 - (e.minX + CGFloat(c.x) * e.width) * k))
            ty = min(-e.minY * k, max(u.height - e.maxY * k, u.height / 2 - (e.minY + CGFloat(c.y) * e.height) * k))
        }
        let area = CGRect(origin: .zero, size: u)
        let scalata = img.transformed(by: CGAffineTransform(scaleX: k, y: k).concatenating(CGAffineTransform(translationX: tx, y: ty)))
        if riempi { return scalata.cropped(to: area) }
        return scalata.composited(over: CIImage(color: .black).cropped(to: area)).cropped(to: area)
    }
}
