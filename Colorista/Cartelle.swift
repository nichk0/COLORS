import SwiftUI
import UIKit
import AVFoundation
import UniformTypeIdentifiers

/// Cartelle e chiavette collegate a Colors. iOS fa scegliere una cartella solo con la sua finestra sul telefono:
/// la si sceglie una volta, Colors se la ricorda (bookmark) e poi il contenuto si sfoglia dal monitor.
struct CartellaCollegata: Identifiable, Codable, Hashable {
    var id = UUID()
    var nome: String
    var segnalibro: Data
}

@MainActor
final class CartelleCollegate: ObservableObject {
    static let condivise = CartelleCollegate()
    @Published private(set) var cartelle: [CartellaCollegata] = []

    init() {
        if let d = UserDefaults.standard.data(forKey: "cartelleCollegate"),
           let c = try? JSONDecoder().decode([CartellaCollegata].self, from: d) { cartelle = c }
    }

    private func salva() {
        if let d = try? JSONEncoder().encode(cartelle) { UserDefaults.standard.set(d, forKey: "cartelleCollegate") }
    }

    func aggiungi(_ url: URL) {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        guard let s = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else {
            Studio.condiviso.messaggio = "Can't remember this folder."; return
        }
        cartelle.removeAll { $0.nome == url.lastPathComponent }
        cartelle.append(CartellaCollegata(nome: url.lastPathComponent, segnalibro: s))
        salva()
    }

    /// La cartella di Colors in «Sul mio iPhone» (app File): c'è sempre, non va collegata.
    let suiPhone: CartellaCollegata? = {
        let doc = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let s = try? doc.bookmarkData() else { return nil }
        return CartellaCollegata(id: UUID(uuidString: "00000000-0000-0000-0000-00000000C010")!, nome: "On My iPhone › Colors", segnalibro: s)
    }()

    /// Tutte quelle da mostrare: prima «Sul mio iPhone › Colors», poi quelle collegate.
    var tutte: [CartellaCollegata] { (suiPhone.map { [$0] } ?? []) + cartelle }

    func togli(_ id: UUID) {
        cartelle.removeAll { $0.id == id }
        salva()
    }

    /// L'indirizzo della cartella (nil se la chiavetta non è collegata).
    func url(_ c: CartellaCollegata) -> URL? {
        var vecchio = false
        guard let u = try? URL(resolvingBookmarkData: c.segnalibro, options: [], relativeTo: nil, bookmarkDataIsStale: &vecchio) else { return nil }
        return u
    }

    /// Esegue `lavoro` con l'accesso alla cartella aperto.
    func conAccesso<T>(_ c: CartellaCollegata, _ lavoro: (URL) throws -> T) rethrows -> T? {
        guard let u = url(c) else { return nil }
        let ok = u.startAccessingSecurityScopedResource()
        defer { if ok { u.stopAccessingSecurityScopedResource() } }
        return try lavoro(u)
    }

    /// Accesso aperto finché si usa (per copiare file in modo asincrono). Ricordarsi di chiudere.
    func apri(_ c: CartellaCollegata) -> URL? {
        guard let u = url(c) else { return nil }
        _ = u.startAccessingSecurityScopedResource()
        return u
    }
}

/// Un elemento della cartella sfogliata.
struct VoceFile: Identifiable, Hashable {
    enum Tipo { case cartella, video, foto, audio, altro }
    let url: URL
    let tipo: Tipo
    var id: String { url.path }
    var nome: String { url.lastPathComponent }

    /// Estensioni riconosciute anche quando iOS non sa che tipo sono (Blackmagic RAW, MXF…).
    static let estVideo: Set<String> = ["mov", "mp4", "m4v", "braw", "mxf", "avi", "mkv", "3gp", "hevc", "mts", "m2ts", "webm"]
    static let estAudio: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac", "alac", "ogg", "opus", "wma", "m4b", "amr"]
    static let estFoto: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "dng", "raw", "webp", "gif", "bmp"]

    static func tipo(_ u: URL, cartella: Bool) -> Tipo {
        if cartella { return .cartella }
        let e = u.pathExtension.lowercased()
        if estVideo.contains(e) { return .video }
        if estAudio.contains(e) { return .audio }
        if estFoto.contains(e) { return .foto }
        let t = UTType(filenameExtension: e)
        if t?.conforms(to: .movie) ?? false { return .video }
        if t?.conforms(to: .image) ?? false { return .foto }
        if t?.conforms(to: .audio) ?? false { return .audio }
        return .altro
    }
}

/// Sfoglia dal monitor le cartelle e le chiavette collegate: clic su una cartella = entra, su un file = `scegli`.
struct EsploraFileMonitor: View {
    @ObservedObject var studio: Studio
    /// Quali file si mostrano (oltre alle cartelle).
    let tipi: Set<VoceFile.Tipo>
    let scegli: (CartellaCollegata, URL, VoceFile.Tipo) -> Void
    @ObservedObject private var cartelle = CartelleCollegate.condivise
    @State private var radice: CartellaCollegata?
    @State private var percorso: [String] = []
    @State private var voci: [VoceFile] = []
    @State private var scorri = ScrollPosition(edge: .top)
    @State private var y: CGFloat = 0
    @State private var massimo: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // dove siamo
            HStack(spacing: 4) {
                voceBarra("Folders", "externaldrive") { radice = nil; percorso = []; leggi() }
                if let r = radice {
                    Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(Tema.testo2)
                    voceBarra(r.nome, "folder") { percorso = []; leggi() }
                }
                ForEach(Array(percorso.enumerated()), id: \.offset) { i, p in
                    Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(Tema.testo2)
                    voceBarra(p, "folder") { percorso = Array(percorso.prefix(i + 1)); leggi() }
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            ScrollView {
                VStack(spacing: 3) {
                    if radice == nil {
                        ForEach(cartelle.tutte) { c in
                            riga(icona: c.id == cartelle.suiPhone?.id ? "iphone" : "externaldrive.fill", nome: c.nome, colore: Tema.accento, id: "cart." + c.id.uuidString,
                                 clic: { radice = c; percorso = []; leggi() },
                                 destro: { MenuMonitor.condiviso.apri([VoceMenuMonitor(titolo: "Disconnect «\(c.nome)»", icona: "eject", distruttiva: true) { cartelle.togli(c.id) }]) })
                        }
                        riga(icona: "plus.circle", nome: "Link a folder or a drive… (chosen once on the phone)", colore: Color(white: 0.75), id: "cart.aggiungi",
                             clic: { studio.richiestaCartella = true }, destro: nil)
                        Text("iOS shows its file picker only on the phone: pick the drive, a folder in «On My iPhone» or in iCloud Drive there once, then browse it from here.")
                            .font(.system(size: 10)).foregroundStyle(Tema.testo2).padding(.top, 4)
                    } else if voci.isEmpty {
                        Text("Empty folder, or the drive is not connected.").font(.system(size: 12)).foregroundStyle(Tema.testo2).padding(8)
                    } else {
                        ForEach(voci) { v in
                            riga(icona: icona(v.tipo), nome: v.nome, colore: v.tipo == .cartella ? Tema.accento : Color(white: 0.8), id: "file." + v.id,
                                 clic: {
                                     if v.tipo == .cartella { percorso.append(v.nome); leggi() }
                                     else if let r = radice { scegli(r, v.url, v.tipo) }
                                 }, destro: nil, info: v.tipo == .video || v.tipo == .audio ? (radice, v.url) : nil)
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollPosition($scorri)
            .onScrollGeometryChange(for: CGFloat.self) { max(0, $0.contentSize.height - $0.containerSize.height) } action: { _, m in massimo = m }
            .zonaMonitor("file.scorri", trascina: { d, _ in y = min(massimo, max(0, y - d.height)); scorri.scrollTo(y: y) })
        }
        .onAppear { leggi() }
    }

    private func leggi() {
        y = 0; scorri.scrollTo(edge: .top)
        guard let r = radice else { voci = []; return }
        voci = cartelle.conAccesso(r) { base in
            let cartella = percorso.reduce(base) { $0.appendingPathComponent($1, isDirectory: true) }
            let elementi = (try? FileManager.default.contentsOfDirectory(at: cartella, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            return elementi.map { u in
                let dir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return VoceFile(url: u, tipo: VoceFile.tipo(u, cartella: dir))
            }
            .filter { $0.tipo == .cartella || tipi.contains($0.tipo) }
            .sorted { ($0.tipo == .cartella ? 0 : 1, $0.nome.lowercased()) < ($1.tipo == .cartella ? 0 : 1, $1.nome.lowercased()) }
        } ?? []
    }

    private func icona(_ t: VoceFile.Tipo) -> String {
        switch t {
        case .cartella: return "folder.fill"
        case .video: return "film"
        case .foto: return "photo"
        case .audio: return "music.note"
        case .altro: return "doc"
        }
    }

    private func voceBarra(_ t: String, _ s: String, _ azione: @escaping () -> Void) -> some View {
        Label(t, systemImage: s).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            .foregroundStyle(Color(white: 0.85))
            .zonaMonitor("esplora.barra." + t, clic: { _ in azione() })
    }

    private func riga(icona: String, nome: String, colore: Color, id: String, clic: @escaping () -> Void, destro: (() -> Void)?,
                      info: (CartellaCollegata?, URL)? = nil) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icona).foregroundStyle(colore).frame(width: 18)
            Text(nome).font(.system(size: 12)).lineLimit(1)
            Spacer()
            // codec letto dal file (ProRes 422 HQ, HEVC, Blackmagic RAW…)
            if let (c, u) = info, let c { InfoCodec(cartella: c, url: u) }
        }
        .padding(.horizontal, 8).frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color(white: 0.13)))
        .zonaMonitor(id, clic: { _ in clic() }, destro: destro)
    }
}

/// Controlla che iOS sappia leggere il file prima di importarlo, e se no spiega perché.
enum FormatoFile {
    static func problema(_ u: URL, video: Bool) async -> String? {
        let e = u.pathExtension.lowercased()
        if e == "braw" {
            return "«\(u.lastPathComponent)» is Blackmagic RAW: iOS can't read it (it needs Blackmagic's software). In Blackmagic Camera choose Apple ProRes or HEVC (H.265) as the codec and import those files."
        }
        let a = AVURLAsset(url: u)
        let leggibile = (try? await a.load(.isPlayable)) ?? false
        let tracce = (try? await a.loadTracks(withMediaType: video ? .video : .audio)) ?? []
        if !leggibile || tracce.isEmpty {
            return "iOS can't read «\(u.lastPathComponent)» (.\(e) format). Supported: MOV/MP4 video (H.264, HEVC, ProRes) and MP3, M4A, AAC, WAV, AIFF, FLAC audio."
        }
        return nil
    }
}

/// Il codec di un file, letto dal file stesso (come la colonna "Codec" di DaVinci).
struct InfoCodec: View {
    let cartella: CartellaCollegata
    let url: URL
    @State private var testo = ""

    var body: some View {
        Text(testo).font(.system(size: 10, design: .monospaced)).foregroundStyle(Tema.testo2).lineLimit(1)
            .task(id: url) {
                guard let base = CartelleCollegate.condivise.apri(cartella) else { return }
                defer { base.stopAccessingSecurityScopedResource() }
                testo = await DescriviFile.codec(url)
            }
    }
}

enum DescriviFile {
    private static let nomi: [String: String] = [
        "apch": "ProRes 422 HQ", "apcn": "ProRes 422", "apcs": "ProRes 422 LT", "apco": "ProRes 422 Proxy",
        "ap4h": "ProRes 4444", "ap4x": "ProRes 4444 XQ", "aprn": "ProRes RAW", "aprh": "ProRes RAW HQ",
        "hvc1": "HEVC", "hev1": "HEVC", "avc1": "H.264", "avc3": "H.264", "mp4v": "MPEG-4", "jpeg": "Motion JPEG",
        "aac ": "AAC", "lpcm": "PCM", ".mp3": "MP3", "flac": "FLAC", "alac": "ALAC", "opus": "Opus", "ac-3": "AC-3", "ec-3": "E-AC-3",
    ]

    private static func fourCC(_ c: FourCharCode) -> String {
        let b = [UInt8((c >> 24) & 255), UInt8((c >> 16) & 255), UInt8((c >> 8) & 255), UInt8(c & 255)]
        return String(bytes: b, encoding: .ascii) ?? "?"
    }

    /// "ProRes 422 HQ · 3840×2160 · 25 fps", "HEVC 10 bit…", "Blackmagic RAW (non leggibile)".
    static func codec(_ u: URL) async -> String {
        if u.pathExtension.lowercased() == "braw" { return "Blackmagic RAW · not readable" }
        let a = AVURLAsset(url: u)
        if let v = try? await a.loadTracks(withMediaType: .video).first {
            let (desc, misura, fps) = (try? await v.load(.formatDescriptions, .naturalSize, .nominalFrameRate)) ?? ([], .zero, Float(0))
            guard let f = desc.first else { return "video" }
            let cc = fourCC(CMFormatDescriptionGetMediaSubType(f))
            var nome = nomi[cc] ?? cc
            if cc.hasPrefix("hv") || cc.hasPrefix("hev"),
               let bit = CMFormatDescriptionGetExtension(f, extensionKey: kCMFormatDescriptionExtension_Depth) as? Int, bit > 24 { nome += " 10 bit" }
            return "\(nome) · \(Int(abs(misura.width)))×\(Int(abs(misura.height))) · \(Int(fps.rounded())) fps"
        }
        if let t = try? await a.loadTracks(withMediaType: .audio).first,
           let f = (try? await t.load(.formatDescriptions))?.first {
            let cc = fourCC(CMFormatDescriptionGetMediaSubType(f))
            let hz = CMAudioFormatDescriptionGetStreamBasicDescription(f)?.pointee.mSampleRate ?? 0
            return "\(nomi[cc] ?? cc) · \(Int(hz / 1000)) kHz"
        }
        return "unreadable format"
    }
}
