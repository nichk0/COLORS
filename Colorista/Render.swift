import SwiftUI
import AVFoundation

// MARK: - Impostazioni di render (pagina Deliver, come "Render Settings" di DaVinci)

enum CodecRender: String, CaseIterable, Identifiable {
    case h264 = "H.264", hevc = "H.265", prores = "Apple ProRes 422 HQ"
    var id: String { rawValue }
}

enum ContenitoreRender: String, CaseIterable, Identifiable {
    case mov = "QuickTime", mp4 = "MP4"
    var id: String { rawValue }
}

/// Cosa si esporta: tutta la timeline o solo la clip aperta (il menu "Render" sotto il viewer).
enum CosaRender: String, CaseIterable, Identifiable {
    case montaggio = "Entire timeline", clip = "Active clip"
    var id: String { rawValue }
}

/// Un file solo o un file per ogni clip ("Single clip" / "Individual clips").
enum ModoRender: String, CaseIterable, Identifiable {
    case singolo = "Single clip", individuali = "Individual clips"
    var id: String { rawValue }
}

enum QualitaRender: String, CaseIterable, Identifiable {
    case massima = "Best", media = "Media"
    var id: String { rawValue }
}

struct RisoluzioneRender: Hashable, Identifiable {
    let nome: String
    let misura: CGSize?          // nil = come il materiale
    var id: String { nome }

    static let tutte: [RisoluzioneRender] = [
        .init(nome: "Same as timeline", misura: nil),
        .init(nome: "3840 × 2160 Ultra HD", misura: CGSize(width: 3840, height: 2160)),
        .init(nome: "1920 × 1080 HD", misura: CGSize(width: 1920, height: 1080)),
        .init(nome: "1280 × 720 HD", misura: CGSize(width: 1280, height: 720)),
        .init(nome: "2160 × 3840 Vertical 4K", misura: CGSize(width: 2160, height: 3840)),
        .init(nome: "1080 × 1920 Vertical", misura: CGSize(width: 1080, height: 1920)),
        .init(nome: "1080 × 1350 4:5", misura: CGSize(width: 1080, height: 1350)),
        .init(nome: "1080 × 1080 Square", misura: CGSize(width: 1080, height: 1080)),
    ]
}

struct ImpostazioniRender: Equatable {
    var preset = "Custom"
    var nomeFile = "Colors"
    var cosa: CosaRender = .montaggio
    var modo: ModoRender = .singolo
    var video = true
    var contenitore: ContenitoreRender = .mov
    var codec: CodecRender = .h264
    var qualita: QualitaRender = .massima
    var risoluzione = RisoluzioneRender.tutte[0]
    var riempi = false               // misura diversa dal materiale: taglia i bordi invece delle bande nere
    var fps: Int = 0                 // 0 = come il materiale
    var audio = true
    /// Dove finisce il file: nil = Rullino foto, altrimenti una cartella o chiavetta collegata.
    var cartella: UUID?

    /// ProRes vive solo nel QuickTime.
    var contenitoreVero: ContenitoreRender { codec == .prores ? .mov : contenitore }
    var estensione: String { contenitoreVero == .mov ? "mov" : "mp4" }
    var tipoFile: AVFileType { contenitoreVero == .mov ? .mov : .mp4 }
    var codecAudio: String { codec == .prores ? "Linear PCM 24-bit" : "AAC" }

    /// Peso stimato in MB (bitrate tipici, riferiti a 1080p a 30 fps).
    func stimaMB(durata: Double, misuraSorgente: CGSize?) -> Double {
        let m = risoluzione.misura ?? misuraSorgente ?? CGSize(width: 1920, height: 1080)
        let pixel = Double(m.width * m.height) / (1920 * 1080)
        let quadri = Double(fps == 0 ? 30 : fps) / 30
        var mbps: Double
        switch codec {
        case .h264: mbps = qualita == .massima ? 24 : 8
        case .hevc: mbps = qualita == .massima ? 14 : 5
        case .prores: mbps = 220
        }
        mbps *= pixel * quadri
        if !video { mbps = 0 }
        if audio { mbps += codec == .prores ? 2.3 : 0.32 }
        return mbps * durata / 8
    }
}

/// Preset in cima alle impostazioni, come la fila di icone di DaVinci (Custom, YouTube, Vimeo, ProRes…).
struct PresetRender: Identifiable {
    let nome: String
    let icona: String
    let applica: (inout ImpostazioniRender) -> Void
    var id: String { nome }

    static let tutti: [PresetRender] = [
        .init(nome: "Custom", icona: "slider.horizontal.3") { _ in },
        .init(nome: "H.264 Master", icona: "film") { s in
            s.codec = .h264; s.contenitore = .mov; s.qualita = .massima; s.risoluzione = RisoluzioneRender.tutte[0]; s.fps = 0
        },
        .init(nome: "H.265 Master", icona: "film.stack") { s in
            s.codec = .hevc; s.contenitore = .mov; s.qualita = .massima; s.risoluzione = RisoluzioneRender.tutte[0]; s.fps = 0
        },
        .init(nome: "ProRes Master", icona: "rectangle.stack.badge.play") { s in
            s.codec = .prores; s.risoluzione = RisoluzioneRender.tutte[0]; s.fps = 0
        },
        .init(nome: "YouTube 1080p", icona: "play.rectangle.fill") { s in
            s.codec = .h264; s.contenitore = .mp4; s.qualita = .massima; s.risoluzione = RisoluzioneRender.tutte[2]; s.riempi = false
        },
        .init(nome: "YouTube 4K", icona: "play.rectangle.on.rectangle.fill") { s in
            s.codec = .hevc; s.contenitore = .mp4; s.qualita = .massima; s.risoluzione = RisoluzioneRender.tutte[1]; s.riempi = false
        },
        .init(nome: "Reel / TikTok", icona: "iphone") { s in
            s.codec = .h264; s.contenitore = .mp4; s.qualita = .massima; s.risoluzione = RisoluzioneRender.tutte[5]; s.riempi = true; s.fps = 30
        },
        .init(nome: "Instagram 4:5", icona: "camera") { s in
            s.codec = .h264; s.contenitore = .mp4; s.qualita = .massima; s.risoluzione = RisoluzioneRender.tutte[6]; s.riempi = true; s.fps = 30
        },
    ]
}

/// Un lavoro nella coda di render.
struct LavoroRender: Identifiable {
    enum Stato: Equatable { case attesa, inCorso(Double), fatto(Double), errore(String) }
    let id = UUID()
    let numero: Int
    let nome: String
    let impostazioni: ImpostazioniRender
    let clip: UUID?                  // nil = tutta la timeline
    let durata: Double
    var stato: Stato = .attesa
}

// MARK: - Pannello "Impostazioni render" (a sinistra nella pagina Deliver)

struct ImpostazioniRenderMonitor: View {
    @ObservedObject var studio: Studio
    @State private var scheda = "Video"

    private var s: ImpostazioniRender { studio.impostazioniRender }

    var body: some View {
        VStack(spacing: 0) {
            testata("Render settings", destra: s.preset)
            // fila di preset
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(PresetRender.tutti) { p in
                        let attivo = p.nome == s.preset
                        Button {
                            var n = studio.impostazioniRender
                            p.applica(&n); n.preset = p.nome
                            studio.impostazioniRender = n
                        } label: {
                            VStack(spacing: 3) {
                                Image(systemName: p.icona).font(.system(size: 17))
                                Text(p.nome).font(.system(size: 9, weight: .medium)).lineLimit(1)
                            }
                            .frame(width: 74, height: 50)
                            .background(RoundedRectangle(cornerRadius: 6).fill(attivo ? Tema.accento.opacity(0.18) : Color(white: 0.11)))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(attivo ? Tema.accento : Color.clear, lineWidth: 1))
                            .foregroundStyle(attivo ? Tema.accento : Color(white: 0.8))
                        }
                    }
                }
                .padding(8)
            }
            .background(Color(white: 0.085))
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    riga("File name") {
                        Text(s.nomeFile).font(.system(size: 12)).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8).frame(height: 24)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.07)))
                            .zonaMonitor("render.nomeFile", clic: { _ in
                                let st = Studio.condiviso
                                st.testoMonitor = TestoMonitor(titolo: "File name", testo: st.impostazioniRender.nomeFile) { st.impostazioniRender.nomeFile = $0 }
                            })
                    }
                    riga("Position") {
                        let cart = CartelleCollegate.condivise.tutte.first { $0.id == s.cartella }
                        Label(cart?.nome ?? "Camera Roll", systemImage: cart == nil ? "photo.on.rectangle" : "externaldrive")
                            .font(.system(size: 12)).foregroundStyle(Color(white: 0.85))
                        Spacer()
                        Image(systemName: "chevron.down").font(.system(size: 10)).foregroundStyle(Tema.testo2)
                    }
                    .zonaMonitor("render.posizione", clic: { _ in
                        var voci = [VoceMenuMonitor(titolo: "Camera Roll", icona: "photo.on.rectangle") { Studio.condiviso.impostazioniRender.cartella = nil }]
                        voci += CartelleCollegate.condivise.tutte.map { c in
                            VoceMenuMonitor(titolo: c.nome, icona: "externaldrive") { Studio.condiviso.impostazioniRender.cartella = c.id }
                        }
                        voci.append(VoceMenuMonitor(titolo: "Link a folder or drive…", icona: "plus.circle") { Studio.condiviso.richiestaCartella = true })
                        MenuMonitor.condiviso.apri(voci)
                    })
                    HStack(spacing: 0) {
                        ForEach(ModoRender.allCases) { m in
                            segmento(m.rawValue, s.modo == m) { studio.impostazioniRender.modo = m }
                        }
                    }
                    // schede Video / Audio / File
                    HStack(spacing: 0) {
                        ForEach(["Video", "Audio", "File"], id: \.self) { t in
                            Button { scheda = t } label: {
                                Text(t).font(.system(size: 12, weight: .semibold))
                                    .frame(maxWidth: .infinity).frame(height: 28)
                                    .foregroundStyle(scheda == t ? Color.white : Tema.testo2)
                                    .overlay(alignment: .bottom) {
                                        Rectangle().fill(scheda == t ? Tema.accento : Color(white: 0.2)).frame(height: scheda == t ? 2 : 1)
                                    }
                            }
                        }
                    }
                    .padding(.top, 4)
                    switch scheda {
                    case "Video": schedaVideo
                    case "Audio": schedaAudio
                    default: schedaFile
                    }
                }
                .padding(12)
            }
            .scrollBounceBehavior(.basedOnSize)
            // in fondo: peso stimato e "Aggiungi alla coda di render"
            VStack(spacing: 8) {
                HStack {
                    Text("Estimated size").font(.system(size: 11)).foregroundStyle(Tema.testo2)
                    Spacer()
                    Text(Self.peso(s.stimaMB(durata: studio.durataRender, misuraSorgente: studio.misuraSorgente)))
                        .font(.system(size: 11, design: .monospaced))
                }
                Button { studio.aggiungiAllaCoda() } label: {
                    Text("Add to render queue").font(.system(size: 13, weight: .bold))
                        .frame(maxWidth: .infinity).frame(height: 34)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Tema.accento))
                        .foregroundStyle(.black)
                }
            }
            .padding(12)
            .background(Color(white: 0.09))
        }
        .background(Tema.pannello)
    }

    private var schedaVideo: some View {
        VStack(alignment: .leading, spacing: 9) {
            riga("Export video") { interruttore(s.video) { studio.impostazioniRender.video.toggle() }; Spacer() }
            riga("Format") {
                tendina(s.contenitoreVero.rawValue, attiva: s.codec != .prores) {
                    ContenitoreRender.allCases.map { c in VoceMenuMonitor(titolo: c.rawValue, icona: "shippingbox") { Studio.condiviso.impostazioniRender.contenitore = c } }
                }
            }
            riga("Codec") {
                tendina(s.codec.rawValue) {
                    CodecRender.allCases.map { c in VoceMenuMonitor(titolo: c.rawValue, icona: "film") { Studio.condiviso.impostazioniRender.codec = c } }
                }
            }
            if s.codec != .prores {
                riga("Quality") {
                    tendina(s.qualita.rawValue) {
                        QualitaRender.allCases.map { q in VoceMenuMonitor(titolo: q.rawValue, icona: "dial.medium") { Studio.condiviso.impostazioniRender.qualita = q } }
                    }
                }
            }
            riga("Resolution") {
                tendina(s.risoluzione.nome) {
                    RisoluzioneRender.tutte.map { r in VoceMenuMonitor(titolo: r.nome, icona: "aspectratio") { Studio.condiviso.impostazioniRender.risoluzione = r } }
                }
            }
            if s.risoluzione.misura != nil {
                riga("Scaling") {
                    HStack(spacing: 0) {
                        segmento("Fit", !s.riempi) { studio.impostazioniRender.riempi = false }
                        segmento("Fill", s.riempi) { studio.impostazioniRender.riempi = true }
                    }
                }
            }
            riga("Frame rate") {
                tendina(s.fps == 0 ? "Same as source" : "\(s.fps) fps") {
                    [0, 24, 25, 30, 50, 60].map { f in
                        VoceMenuMonitor(titolo: f == 0 ? "Same as source" : "\(f) fps", icona: "speedometer") { Studio.condiviso.impostazioniRender.fps = f }
                    }
                }
            }
            Text(s.codec == .prores ? "ProRes 422 HQ 10-bit: master quality, large files. Ideal for bringing the work back into DaVinci."
                 : s.codec == .hevc ? "H.265 10-bit: half the size of H.264 at the same quality."
                 : "H.264: opens everywhere, good for social media and sharing.")
                .font(.system(size: 10)).foregroundStyle(Tema.testo2).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var schedaAudio: some View {
        VStack(alignment: .leading, spacing: 9) {
            riga("Export audio") { interruttore(s.audio) { studio.impostazioniRender.audio.toggle() }; Spacer() }
            if s.audio {
                riga("Codec") { Text(s.codecAudio).font(.system(size: 12)); Spacer() }
                riga("Sample rate") { Text("48000 Hz").font(.system(size: 12)); Spacer() }
                riga("Channels") { Text("Stereo").font(.system(size: 12)); Spacer() }
            }
        }
    }

    private var schedaFile: some View {
        VStack(alignment: .leading, spacing: 9) {
            riga("Name") { Text("\(s.nomeFile).\(s.estensione)").font(.system(size: 12, design: .monospaced)); Spacer() }
            riga("Container") { Text(s.contenitoreVero.rawValue).font(.system(size: 12)); Spacer() }
            Text(s.modo == .individuali ? "One file per timeline clip, with the clip name appended." : "A single file with the whole selection.")
                .font(.system(size: 10)).foregroundStyle(Tema.testo2)
        }
    }

    static func peso(_ mb: Double) -> String {
        mb >= 1000 ? String(format: "%.2f GB", mb / 1000) : String(format: "%.0f MB", max(1, mb))
    }

    // MARK: pezzi

    private func testata(_ t: String, destra: String) -> some View {
        HStack {
            Text(t).font(.system(size: 12, weight: .semibold))
            Text("–").foregroundStyle(Tema.testo2)
            Text(destra).font(.system(size: 12)).foregroundStyle(Tema.testo2).lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 12).frame(height: 30)
        .overlay(alignment: .bottom) { Rectangle().fill(Color(white: 0.17)).frame(height: 1) }
    }

    private func riga<C: View>(_ nome: String, @ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: 8) {
            Text(nome).font(.system(size: 11)).foregroundStyle(Tema.testo2).frame(width: 92, alignment: .leading)
            c()
        }
    }

    private func segmento(_ t: String, _ attivo: Bool, _ azione: @escaping () -> Void) -> some View {
        Button(action: azione) {
            Text(t).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                .frame(maxWidth: .infinity).frame(height: 24)
                .background(Rectangle().fill(attivo ? Tema.accento.opacity(0.22) : Color(white: 0.11)))
                .foregroundStyle(attivo ? Tema.accento : Color(white: 0.8))
        }
    }

    private func interruttore(_ on: Bool, _ azione: @escaping () -> Void) -> some View {
        Button(action: azione) {
            Image(systemName: on ? "checkmark.square.fill" : "square").font(.system(size: 15))
                .foregroundStyle(on ? Tema.accento : Tema.testo2)
        }
    }

    /// Campo a tendina come quelli di DaVinci: un clic apre il menu delle scelte.
    private func tendina(_ valore: String, attiva: Bool = true, _ voci: @escaping () -> [VoceMenuMonitor]) -> some View {
        HStack {
            Text(valore).font(.system(size: 12)).lineLimit(1)
            Spacer()
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Tema.testo2)
        }
        .padding(.horizontal, 8).frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.07)))
        .opacity(attiva ? 1 : 0.5)
        .contentShape(Rectangle())
        .zonaMonitor("tendina." + valore, clic: { _ in if attiva { MenuMonitor.condiviso.apri(voci()) } })
    }
}

// MARK: - Coda di render (a destra nella pagina Deliver)

struct CodaRenderMonitor: View {
    @ObservedObject var studio: Studio

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Render queue").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(studio.codaRender.count)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Tema.testo2)
            }
            .padding(.horizontal, 12).frame(height: 30)
            .overlay(alignment: .bottom) { Rectangle().fill(Color(white: 0.17)).frame(height: 1) }
            if studio.codaRender.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray").font(.system(size: 24)).foregroundStyle(Tema.testo2)
                    Text("No jobs in the queue").font(.system(size: 12)).foregroundStyle(Tema.testo2)
                    Text("Choose the settings on the left and press “Add to render queue”.")
                        .font(.system(size: 10)).foregroundStyle(Tema.testo2).multilineTextAlignment(.center)
                }
                .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(studio.codaRender) { l in scheda(l) }
                    }
                    .padding(8)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            HStack(spacing: 8) {
                Button { studio.svuotaCodaFatti() } label: {
                    Image(systemName: "trash").font(.system(size: 13))
                        .frame(width: 34, height: 32)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Tema.campo))
                }
                .disabled(studio.renderInCorso)
                Button { Task { await studio.renderTutto() } } label: {
                    Text(studio.renderInCorso ? "Rendering…" : "Render All").font(.system(size: 13, weight: .bold))
                        .frame(maxWidth: .infinity).frame(height: 32)
                        .background(RoundedRectangle(cornerRadius: 6).fill(studio.renderInCorso ? Tema.campo : Tema.accento))
                        .foregroundStyle(studio.renderInCorso ? Tema.testo2 : .black)
                }
                .disabled(studio.renderInCorso || !studio.codaRender.contains { $0.stato == .attesa || Self.errore($0.stato) })
            }
            .padding(10)
            .background(Color(white: 0.09))
        }
        .background(Tema.pannello)
    }

    static func errore(_ s: LavoroRender.Stato) -> Bool { if case .errore = s { return true }; return false }

    private func scheda(_ l: LavoroRender) -> some View {
        let i = l.impostazioni
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Job \(l.numero)").font(.system(size: 11, weight: .bold))
                Text(l.nome).font(.system(size: 11)).foregroundStyle(Tema.testo2).lineLimit(1)
                Spacer()
                if case .inCorso = l.stato {} else {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Tema.testo2)
                        .frame(width: 22, height: 22)
                        .zonaMonitor("coda.togli.\(l.id)", clic: { _ in Studio.condiviso.togliDallaCoda(l.id) })
                }
            }
            Text("\(i.codec.rawValue) · \(i.risoluzione.misura.map { "\(Int($0.width))×\(Int($0.height))" } ?? "original") · \(i.fps == 0 ? "original fps" : "\(i.fps) fps")")
                .font(.system(size: 10)).foregroundStyle(Tema.testo2)
            Text("\(i.nomeFile).\(i.estensione) · \(VistaMonitor.timecode(l.durata))")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(Tema.testo2)
            switch l.stato {
            case .attesa:
                Text("Queued").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color(white: 0.75))
            case .inCorso(let p):
                ProgressView(value: p).tint(Tema.accento)
                Text("\(Int(p * 100))%").font(.system(size: 10, design: .monospaced)).foregroundStyle(Tema.accento)
            case .fatto(let mb):
                Label("Completed · \(ImpostazioniRenderMonitor.peso(mb)) saved", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(Color(red: 0.4, green: 0.85, blue: 0.5))
            case .errore(let e):
                Label(e, systemImage: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(Color(red: 1, green: 0.45, blue: 0.4))
                    .lineLimit(2)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.11)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(l.stato == .attesa ? Color(white: 0.2) : Color.clear, lineWidth: 1))
    }
}

/// Sotto il viewer della pagina Deliver: "Render: Intera timeline / Clip attiva" con entrata e durata.
struct BarraRenderMonitor: View {
    @ObservedObject var studio: Studio

    var body: some View {
        HStack(spacing: 14) {
            Text("Render").font(.system(size: 12)).foregroundStyle(Tema.testo2)
            HStack(spacing: 0) {
                ForEach(CosaRender.allCases) { c in
                    let attiva = studio.impostazioniRender.cosa == c
                    Button { studio.impostazioniRender.cosa = c } label: {
                        Text(c.rawValue).font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 12).frame(height: 24)
                            .background(Rectangle().fill(attiva ? Tema.accento.opacity(0.22) : Color(white: 0.11)))
                            .foregroundStyle(attiva ? Tema.accento : Color(white: 0.8))
                    }
                }
            }
            Spacer()
            Text("DURATION").font(.system(size: 10, weight: .semibold)).foregroundStyle(Tema.testo2)
            Text(VistaMonitor.timecode(studio.durataRender)).font(.system(size: 12, design: .monospaced))
        }
        .padding(.horizontal, 12).frame(height: 34)
        .background(Tema.pannello)
    }
}
