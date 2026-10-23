import SwiftUI
import AVFoundation
import PhotosUI
import _PhotosUI_SwiftUI

/// Le pagine dell'app, come la barra in basso di DaVinci Resolve.
enum Pagina: String, CaseIterable, Identifiable {
    case media = "Media", edit = "Edit", fusion = "Fusion", color = "Color", deliver = "Deliver"
    /// Le pagine nella barra: Fusion non c'è più (faceva le stesse cose di Color).
    static var visibili: [Pagina] { allCases.filter { $0 != .fusion } }
    var id: String { rawValue }
    var icona: String {
        switch self {
        case .media: return "photo.stack"
        case .edit: return "film"
        case .fusion: return "hexagon"
        case .color: return "circle.lefthalf.filled"
        case .deliver: return "paperplane"
        }
    }
}

struct BarraPagine: View {
    @Binding var scelta: Pagina
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Pagina.visibili) { p in
                Button { scelta = p } label: {
                    VStack(spacing: 3) {
                        Image(systemName: p.icona).font(.system(size: 19, weight: scelta == p ? .semibold : .regular))
                            .frame(height: 24)   // icone di altezze diverse: le scritte restano allineate
                        Text(p.rawValue).font(.system(size: 10, weight: .medium))
                    }
                    .frame(maxWidth: .infinity).frame(height: 48)
                    .contentShape(Rectangle())
                    .foregroundStyle(scelta == p ? Tema.accento : Tema.testo2)
                }
                .buttonStyle(.plain)
            }
        }
        .background(Tema.pannello.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5) }
    }
}

// MARK: - Media

/// Media Pool: tutte le clip del progetto a griglia, con importazione.
struct PaginaMedia: View {
    @ObservedObject var studio: Studio
    var apriLibreria: () -> Void
    var apriFile: () -> Void
    var apriInColor: () -> Void
    @State private var selezionando = false
    @State private var scelte: Set<UUID> = []
    @State private var confermaTogli = false
    @State private var mostraProgetti = false

    var body: some View {
        VStack(spacing: 0) {
            // progetto aperto
            Button { mostraProgetti = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill").foregroundStyle(Tema.accento)
                    Text(studio.progetto.nome).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text("· \(studio.progetto.clips.count) clips").font(.caption).foregroundStyle(Tema.testo2)
                    Spacer()
                    Label("Projects", systemImage: "square.grid.2x2").font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).frame(height: 28)
                        .background(Capsule().fill(Tema.campo))
                }
                .padding(.horizontal, 12).frame(height: 44)
                .background(Tema.sfondo)
            }
            .buttonStyle(.plain)
            HStack(spacing: 10) {
              if selezionando {
                Button(scelte.count == studio.progetto.clips.count ? "None" : "All") {
                    scelte = scelte.count == studio.progetto.clips.count ? [] : Set(studio.progetto.clips.map(\.id))
                }
                .font(.subheadline.weight(.semibold))
                Spacer()
                Text(scelte.isEmpty ? "Tap the clips to remove" : scelte.count == 1 ? "1 selected" : "\(scelte.count) selected").font(.caption).foregroundStyle(Tema.testo2)
                Spacer()
                Button("Done") { selezionando = false; scelte = [] }.font(.subheadline.weight(.semibold))
              } else {
                Button(action: apriLibreria) {
                    Label("Photo Library", systemImage: "photo.on.rectangle").font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12).frame(height: 36)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Tema.accento))
                        .foregroundStyle(.black)
                }
                Button(action: apriFile) {
                    Label("File", systemImage: "folder").font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12).frame(height: 36)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Tema.campo))
                }
                .buttonStyle(.plain)
                Spacer()
                if !studio.progetto.clips.isEmpty {
                    Button("Select") { selezionando = true }.font(.subheadline.weight(.semibold))
                }
              }
            }
            .padding(12)
            .frame(height: 60)
            .background(Tema.pannello)

            if studio.progetto.clips.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "photo.stack").font(.system(size: 44)).foregroundStyle(Tema.testo2)
                    Text("The project is empty").font(.headline)
                    Text("Import photos and videos from the Library or from Files (an external SSD too).")
                        .font(.caption).foregroundStyle(Tema.testo2).multilineTextAlignment(.center)
                }
                .padding(30)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 12) {
                        ForEach(Array(studio.progetto.clips.enumerated()), id: \.element.id) { i, c in
                            cella(c, numero: i + 1)
                        }
                    }
                    .padding(12)
                }
                if selezionando {
                    Button(role: .destructive) { confermaTogli = true } label: {
                        Label(scelte.isEmpty ? "Remove from project" : "Remove \(scelte.count) from project", systemImage: "trash")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity).frame(height: 44)
                            .background(RoundedRectangle(cornerRadius: 10).fill(scelte.isEmpty ? Tema.campo : Color.red.opacity(0.85)))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .disabled(scelte.isEmpty)
                    .padding(12)
                    .background(Tema.pannello)
                }
            }
        }
        .background(Tema.sfondo)
        .sheet(isPresented: $mostraProgetti) { SchedaProgetti(studio: studio) }
        .confirmationDialog("Remove \(scelte.count) clips from the project?", isPresented: $confermaTogli, titleVisibility: .visible) {
            Button("Remove \(scelte.count) clips", role: .destructive) {
                let ids = scelte
                Task { await studio.eliminaClips(ids); scelte = []; selezionando = false }
            }
        } message: {
            Text("The clips and their grades disappear from the project. The photos and videos in the Library are not touched.")
        }
    }

    private func cella(_ c: Clip, numero: Int) -> some View {
        let attiva = c.id == studio.clipAttiva
        return VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                if let img = Archivio.immagine("Miniature", c.miniatura) {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    Rectangle().fill(Tema.campo)
                }
                Image(systemName: c.video ? "video.fill" : "photo").font(.system(size: 10))
                    .padding(4).background(Circle().fill(Color.black.opacity(0.6))).padding(4)
            }
            .frame(height: 74).frame(maxWidth: .infinity).clipped()
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(attiva ? Tema.accento : .clear, lineWidth: 2))
            HStack(spacing: 4) {
                Text(String(format: "%02d", numero)).font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(attiva ? Tema.accento : Tema.testo2)
                Text(c.nome).font(.caption2).lineLimit(1)
            }
        }
        .overlay(alignment: .topTrailing) {
            if selezionando {
                Image(systemName: scelte.contains(c.id) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(scelte.contains(c.id) ? Tema.accento : .white)
                    .background(Circle().fill(Color.black.opacity(0.5)))
                    .padding(5)
            }
        }
        .opacity(selezionando && !scelte.contains(c.id) ? 0.7 : 1)
        .contentShape(Rectangle())
        .onTapGesture {
            if selezionando {
                if scelte.contains(c.id) { scelte.remove(c.id) } else { scelte.insert(c.id) }
            } else {
                Task { await studio.apriClip(c.id); apriInColor() }
            }
        }
        .contextMenu {
            Button { Task { await studio.apriClip(c.id); apriInColor() } } label: { Label("Open in Color", systemImage: "circle.lefthalf.filled") }
            Button { studio.duplicaClip(c.id) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            Button(role: .destructive) { Task { await studio.eliminaClip(c.id) } } label: { Label("Remove from project", systemImage: "trash") }
        }
    }
}

// MARK: - Progetti

/// Gestione progetti (come il Project Manager di DaVinci): nuovo, apri, rinomina, elimina.
struct SchedaProgetti: View {
    @ObservedObject var studio: Studio
    @Environment(\.dismiss) private var chiudi
    @State private var nomeNuovo = ""
    @State private var chiediNuovo = false
    @State private var rinomina = false
    @State private var nomeModificato = ""
    @State private var daEliminare: Progetto?

    var body: some View {
        NavigationStack {
            List {
                Section("Open") {
                    riga(studio.progetto, aperto: true)
                        .swipeActions { Button("Rename") { nomeModificato = studio.progetto.nome; rinomina = true }.tint(Tema.accento) }
                    Button { nomeModificato = studio.progetto.nome; rinomina = true } label: { Label("Rename", systemImage: "pencil") }
                }
                Section {
                    Button { nomeNuovo = ""; chiediNuovo = true } label: { Label("New project", systemImage: "plus.circle.fill") }
                        .font(.headline)
                }
                Section(studio.progettiSalvati.isEmpty ? "No other projects" : "Other projects") {
                    ForEach(studio.progettiSalvati, id: \.id) { p in
                        Button {
                            Task { await studio.apriProgetto(p.id); chiudi() }
                        } label: { riga(p, aperto: false) }
                        .buttonStyle(.plain)
                        .swipeActions { Button("Delete", role: .destructive) { daEliminare = p } }
                        .contextMenu {
                            Button { Task { await studio.apriProgetto(p.id); chiudi() } } label: { Label("Open", systemImage: "folder") }
                            Button(role: .destructive) { daEliminare = p } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
            }
            .navigationTitle("Projects")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { chiudi() } } }
            .onAppear { studio.aggiornaElencoProgetti() }
            .alert("New project", isPresented: $chiediNuovo) {
                TextField("Name", text: $nomeNuovo)
                Button("Cancel", role: .cancel) {}
                Button("Create") { let n = nomeNuovo; Task { await studio.nuovoProgetto(nome: n); chiudi() } }
            } message: { Text("The open project is saved to the list: you'll find it here.") }
            .alert("Rename project", isPresented: $rinomina) {
                TextField("Name", text: $nomeModificato)
                Button("Cancel", role: .cancel) {}
                Button("OK") { studio.rinominaProgetto(nomeModificato) }
            }
            .confirmationDialog("Delete «\(daEliminare?.nome ?? "")»?", isPresented: Binding(get: { daEliminare != nil }, set: { if !$0 { daEliminare = nil } }), titleVisibility: .visible) {
                Button("Delete project", role: .destructive) { if let p = daEliminare { studio.eliminaProgetto(p.id) }; daEliminare = nil }
            } message: { Text("The imported clips and the grades of this project are deleted. The photos and videos in the Library are not touched.") }
        }
        .preferredColorScheme(.dark)
        .tint(Tema.accento)
    }

    private func riga(_ p: Progetto, aperto: Bool) -> some View {
        HStack(spacing: 12) {
            Group {
                if let c = p.clips.first, let img = Archivio.immagine("Miniature", c.miniatura) {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    ZStack { Rectangle().fill(Tema.campo); Image(systemName: "film").foregroundStyle(Tema.testo2) }
                }
            }
            .frame(width: 64, height: 40).clipShape(RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 2) {
                Text(p.nome).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("\(p.clips.count) clips · \(p.modificato.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(Tema.testo2)
            }
            Spacer()
            if aperto { Image(systemName: "checkmark.circle.fill").foregroundStyle(Tema.accento) }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Edit

/// Trasporto della sequenza: play, posizione, salto tra le clip.
struct TrasportoSequenza: View {
    @ObservedObject var studio: Studio

    var body: some View {
        HStack(spacing: 10) {
            Button { saltaClip(-1) } label: { Image(systemName: "backward.end.fill").font(.caption) }
            Button { studio.sequenzaInRiproduzione ? studio.pausaSequenza() : studio.playSequenza() } label: {
                Image(systemName: studio.sequenzaInRiproduzione ? "pause.fill" : "play.fill").font(.title3).frame(width: 26)
            }
            .disabled(studio.durataSequenza <= 0)
            Button { saltaClip(1) } label: { Image(systemName: "forward.end.fill").font(.caption) }
            Slider(value: Binding(get: { studio.tempoSequenza }, set: { studio.vaiSequenza($0) }), in: 0...max(studio.durataSequenza, 0.1))
            Text("\(tc(studio.tempoSequenza)) / \(tc(studio.durataSequenza))")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(Tema.testo2).fixedSize()
        }
        .padding(.horizontal, 10).frame(height: 40)
        .background(Tema.pannello)
    }

    /// Va all'inizio della clip precedente o successiva.
    private func saltaClip(_ verso: Int) {
        let inizi = studio.iniziClip
        let t = studio.tempoSequenza
        if verso > 0 { if let n = inizi.first(where: { $0 > t + 0.05 }) { studio.vaiSequenza(n) } }
        else { studio.vaiSequenza(inizi.last(where: { $0 < t - 0.3 }) ?? 0) }
    }

    private func tc(_ t: Double) -> String {
        let f = Int((t * 25).rounded())
        return String(format: "%02d:%02d:%02d", f / 1500, f / 25 % 60, f % 25)
    }
}

/// Timeline: le clip in sequenza larghe quanto durano (taglio e velocità compresi), la musica sotto, la testina arancione.
struct TimelineEdit: View {
    @ObservedObject var studio: Studio
    @State private var zoom: Double = 0                    // punti per secondo (0 = adatta alla larghezza)
    @State private var zoomInizio: Double = 0
    @State private var rinomina: Clip?
    @State private var nuovoNome = ""
    @State private var strumento: StrumentoEdit = .taglio
    @State private var mostraMusica = false
    @State private var mostraAudioLibreria = false
    @State private var audioScelti: [PhotosPickerItem] = []
    /// Clip o traccia audio che si sta trascinando e di quanto (in punti).
    @State private var trascino: (id: UUID, dx: CGFloat)?

    var body: some View {
        GeometryReader { g in
            let pps = zoom > 0 ? zoom : max(4, Double(g.size.width - 40) / max(studio.durataMontaggio, 1))
            VStack(spacing: 0) {
                comandiClip
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        ZStack(alignment: .topLeading) {
                            VStack(alignment: .leading, spacing: 3) {
                                righello(pps)
                                pistaVideo(pps)
                                pistaMusica(pps)
                            }
                            // testina
                            Rectangle().fill(Tema.accento).frame(width: 2, height: 116)
                                .offset(x: CGFloat(studio.tempoSequenza * pps) - 1)
                                .allowsHitTesting(false)
                                .id("testina")
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                    }
                    .onChange(of: studio.sequenzaInRiproduzione) { _, suona in if !suona { proxy.scrollTo("testina", anchor: .center) } }
                }
                .frame(height: 130)
                .background(Tema.sfondo)
                .gesture(MagnifyGesture()
                    .onChanged { v in zoom = min(max((zoomInizio > 0 ? zoomInizio : pps) * v.magnification, 3), 200) }
                    .onEnded { _ in zoomInizio = zoom })

                Picker("Tool", selection: $strumento) {
                    ForEach(StrumentoEdit.allCases) { Image(systemName: $0.icona).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Tema.pannello)
                ScrollView {
                    PannelloStrumentoEdit(studio: studio, strumento: strumento, mostraMusica: $mostraMusica, mostraAudioLibreria: $mostraAudioLibreria)
                        .padding(10)
                }
                .background(Tema.sfondo)
            }
        }
        .alert("Rename clip", isPresented: Binding(get: { rinomina != nil }, set: { if !$0 { rinomina = nil } })) {
            TextField("Name", text: $nuovoNome)
            Button("Cancel", role: .cancel) {}
            Button("OK") { if let c = rinomina { studio.rinominaClip(c.id, nuovoNome) } }
        }
        .fileImporter(isPresented: $mostraMusica, allowedContentTypes: [.audio, .mp3, .mpeg4Audio, .wav, .aiff, .movie, .item], allowsMultipleSelection: true) { r in
            if case let .success(urls) = r { Task { for u in urls { await studio.aggiungiMusica(u) } } }
        }
        .photosPicker(isPresented: $mostraAudioLibreria, selection: $audioScelti, maxSelectionCount: 10, matching: .videos, preferredItemEncoding: .current)
        .onChange(of: audioScelti) { _, items in
            guard !items.isEmpty else { return }
            Task { await studio.aggiungiAudioDaLibreria(items); audioScelti = [] }
        }
        .task { await studio.aggiornaDurate() }
    }

    private var comandiClip: some View {
        HStack(spacing: 6) {
            if let c = studio.clipCorrente, let i = studio.progetto.clips.firstIndex(where: { $0.id == c.id }) {
                Text(String(format: "%02d", i + 1)).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(Tema.accento)
                Text(c.nome).font(.caption).lineLimit(1)
                Spacer(minLength: 4)
                bottone("arrow.left") { studio.spostaClip(c.id, di: -1); studio.aggiornaSequenza() }.disabled(i == 0)
                bottone("arrow.right") { studio.spostaClip(c.id, di: 1); studio.aggiornaSequenza() }.disabled(i == studio.progetto.clips.count - 1)
                bottone("plus.square.on.square") { studio.duplicaClip(c.id); studio.aggiornaSequenza() }
                bottone("pencil") { nuovoNome = c.nome; rinomina = c }
                bottone("trash", rosso: true) { Task { await studio.eliminaClip(c.id); studio.aggiornaSequenza() } }
            } else {
                Text(studio.progetto.clips.isEmpty ? "The timeline is empty: import clips from the Media page." : "Tap a clip in the timeline")
                    .font(.caption).foregroundStyle(Tema.testo2)
                Spacer()
            }
            if studio.preparandoSequenza { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 10).frame(height: 44)
        .background(Tema.pannello)
    }

    private func righello(_ pps: Double) -> some View {
        let secondi = max(Int(studio.durataMontaggio.rounded(.up)), 1)
        let passo = pps < 8 ? 10 : pps < 30 ? 5 : 1
        return ZStack(alignment: .topLeading) {
            ForEach(Array(stride(from: 0, through: secondi, by: passo)), id: \.self) { s in
                VStack(alignment: .leading, spacing: 1) {
                    Rectangle().fill(Tema.testo2).frame(width: 1, height: 5)
                    Text(String(format: "%02d:%02d", s / 60, s % 60)).font(.system(size: 8, design: .monospaced)).foregroundStyle(Tema.testo2).fixedSize()
                }
                .offset(x: CGFloat(Double(s) * pps))
            }
        }
        .frame(width: CGFloat(Double(secondi) * pps) + 60, height: 18, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture { } // il tocco sul righello non apre clip
        .gesture(DragGesture(minimumDistance: 0).onChanged { v in studio.vaiSequenza(Double(v.location.x) / pps) })
    }

    /// Clip in sequenza. Tieni premuto su una clip e trascinala sopra un'altra per cambiare l'ordine.
    private func pistaVideo(_ pps: Double) -> some View {
        let pos = studio.posizioniClip
        return ZStack(alignment: .topLeading) {
            ForEach(Array(studio.progetto.clips.enumerated()), id: \.element.id) { i, c in
                let inizio = i < pos.count ? pos[i].inizio : 0
                let durata = i < pos.count ? pos[i].durata : 1
                let mio = trascino?.id == c.id
                blocco(c, numero: i + 1, larghezza: max(CGFloat(durata * pps) - 2, 22))
                    .scaleEffect(mio ? 1.06 : 1)
                    .shadow(color: .black.opacity(mio ? 0.6 : 0), radius: 6)
                    .zIndex(mio ? 10 : 0)
                    .offset(x: mio ? trascino!.dx : 0)
                    .gesture(riordina(c.id, centro: (inizio + durata / 2) * pps, centri: pos.map { ($0.inizio + $0.durata / 2) * pps }) { studio.spostaClip(c.id, a: $0) })
                    .offset(x: CGFloat(inizio * pps), y: i % 2 == 0 ? 0 : 4)   // le clip sovrapposte da una transizione si vedono sfalsate
                if c.taglio.transizione != .nessuna, i < studio.progetto.clips.count - 1 {
                    Image(systemName: "rectangle.lefthalf.inset.filled.arrow.left").font(.system(size: 10))
                        .padding(3).background(Circle().fill(Tema.accento)).foregroundStyle(.black)
                        .offset(x: CGFloat((inizio + durata) * pps) - 10, y: 22)
                        .allowsHitTesting(false)
                }
            }
        }
        .overlay(alignment: .topLeading) { segnaPosto(pos.map { $0.inizio * pps }, fine: pos.last.map { ($0.inizio + $0.durata) * pps } ?? 0, centri: pos.map { ($0.inizio + $0.durata / 2) * pps }, ids: studio.progetto.clips.map(\.id), altezza: 60) }
        .frame(height: 60, alignment: .topLeading)
    }

    /// Tracce audio di sottofondo, una dopo l'altra; si riordinano trascinandole come le clip.
    @ViewBuilder
    private func pistaMusica(_ pps: Double) -> some View {
        if studio.progetto.musiche.isEmpty {
            Button { strumento = .audio } label: {
                Label("A1 · add music or audio", systemImage: "plus").font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 6).frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: 3).stroke(Tema.testo2, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                    .foregroundStyle(Tema.testo2)
            }
            .buttonStyle(.plain)
        } else {
            let pos = studio.posizioniMusica
            let fine = studio.durataMontaggio
            ZStack(alignment: .topLeading) {
                ForEach(Array(studio.progetto.musiche.enumerated()), id: \.element.id) { i, m in
                    let inizio = i < pos.count ? pos[i].inizio : 0
                    let durata = i < pos.count ? pos[i].durata : 10
                    HStack(spacing: 4) {
                        Image(systemName: "music.note").font(.system(size: 9))
                        Text(m.nome).font(.system(size: 9, weight: .semibold)).lineLimit(1)
                    }
                    .padding(.horizontal, 6)
                    .frame(width: max(CGFloat(durata * pps) - 2, 30), height: 22, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color(red: 0.2, green: 0.45, blue: 0.3)))
                    .opacity(inizio >= fine && fine > 0 ? 0.4 : 1)        // oltre la fine del montaggio non si sente
                    .contentShape(Rectangle())
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Tema.accento, lineWidth: studio.musicaScelta == m.id ? 2 : 0))
                    .onTapGesture { studio.musicaScelta = m.id; strumento = .audio }
                    .scaleEffect(trascino?.id == m.id ? 1.06 : 1)
                    .zIndex(trascino?.id == m.id ? 10 : 0)
                    .offset(x: trascino?.id == m.id ? trascino!.dx : 0)
                    .gesture(riordina(m.id, centro: (inizio + durata / 2) * pps, centri: pos.map { ($0.inizio + $0.durata / 2) * pps }) { studio.spostaMusica(m.id, a: $0) })
                    .offset(x: CGFloat(inizio * pps))
                }
            }
            .overlay(alignment: .topLeading) { segnaPosto(pos.map { $0.inizio * pps }, fine: pos.last.map { ($0.inizio + $0.durata) * pps } ?? 0, centri: pos.map { ($0.inizio + $0.durata / 2) * pps }, ids: studio.progetto.musiche.map(\.id), altezza: 22) }
            .frame(height: 22, alignment: .topLeading)
        }
    }

    // MARK: riordino trascinando

    /// Posto in cui cadrebbe l'elemento trascinato: il primo il cui centro è oltre il centro trascinato.
    private func posto(_ centro: CGFloat, _ centri: [CGFloat], da i: Int) -> Int {
        var j = centri.filter { $0 < centro }.count
        if j > i { j -= 1 }                         // l'elemento stesso non conta
        return min(max(0, j), centri.count - 1)
    }

    /// Tieni premuto, poi trascina: al rilascio l'elemento va nel posto più vicino.
    private func riordina(_ id: UUID, centro: Double, centri: [Double], sposta: @escaping (Int) -> Void) -> some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .onChanged { v in
                if case .second(true, let d) = v { trascino = (id, d?.translation.width ?? 0) }
            }
            .onEnded { v in
                defer { trascino = nil }
                guard case .second(true, let d) = v, let d, let i = centri.firstIndex(of: centro) else { return }
                let j = posto(CGFloat(centro) + d.translation.width, centri.map { CGFloat($0) }, da: i)
                if j != i { withAnimation(.easeOut(duration: 0.2)) { sposta(j) } }
            }
    }

    /// Linea arancione dove cadrà l'elemento trascinato.
    @ViewBuilder
    private func segnaPosto(_ inizi: [Double], fine: Double, centri: [Double], ids: [UUID], altezza: CGFloat) -> some View {
        if let t = trascino, let i = ids.firstIndex(of: t.id), i < centri.count {
            let j = posto(CGFloat(centri[i]) + t.dx, centri.map { CGFloat($0) }, da: i)
            // la linea va prima dell'elemento j (o dopo l'ultimo)
            let x = j > i ? (j + 1 < inizi.count ? inizi[j + 1] : fine) : inizi[j]
            if j != i {
                Rectangle().fill(Tema.accento).frame(width: 3, height: altezza + 6)
                    .offset(x: CGFloat(x) - 1.5, y: -3)
                    .allowsHitTesting(false)
            }
        }
    }

    private func blocco(_ c: Clip, numero: Int, larghezza w: CGFloat) -> some View {
        let sel = c.id == studio.clipAttiva
        let m = c.taglio
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4).fill(c.video ? Color(red: 0.2, green: 0.33, blue: 0.5) : Color(red: 0.42, green: 0.3, blue: 0.5))
            if let img = Archivio.immagine("Miniature", c.miniatura) {
                Image(uiImage: img).resizable().scaledToFill()
                    .frame(width: min(w - 4, 56), height: 30).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    .padding(.top, 18).padding(.leading, 2)
            }
            Text("\(String(format: "%02d", numero)) \(c.nome)").font(.system(size: 9, weight: .semibold)).lineLimit(1)
                .padding(.horizontal, 4).padding(.top, 3)
            HStack(spacing: 2) {
                if m.velocita != 1 { Text(String(format: "%g×", m.velocita)) }
                if !m.titolo.testo.isEmpty { Image(systemName: "textformat") }
                if m.stabilizza { Image(systemName: "hand.raised.slash") }
                if !m.inquadratura.neutra { Image(systemName: "crop") }
            }
            .font(.system(size: 8, weight: .bold))
            .padding(3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
        .frame(width: w, height: 52)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(sel ? Tema.accento : Color.white.opacity(0.15), lineWidth: sel ? 2 : 1))
        .contentShape(Rectangle())
        .onTapGesture {
            Task {
                await studio.apriClip(c.id)
                if let i = studio.progetto.clips.firstIndex(where: { $0.id == c.id }), i < studio.iniziClip.count { studio.vaiSequenza(studio.iniziClip[i] + 0.01) }
            }
        }
    }

    private func bottone(_ icona: String, rosso: Bool = false, _ azione: @escaping () -> Void) -> some View {
        Button(action: azione) {
            Image(systemName: icona).font(.system(size: 13))
                .frame(width: 34, height: 30)
                .background(RoundedRectangle(cornerRadius: 6).fill(Tema.campo))
                .foregroundStyle(rosso ? Color.red : .white)
        }
        .buttonStyle(.plain)
    }
}

enum StrumentoEdit: String, CaseIterable, Identifiable {
    case taglio = "Trim", velocita = "Speed", audio = "Audio", transizione = "Transition", titolo = "Title", inquadra = "Frame", stabilizza = "Stabilize"
    var id: String { rawValue }
    var icona: String {
        switch self {
        case .taglio: return "scissors"
        case .velocita: return "speedometer"
        case .audio: return "speaker.wave.2"
        case .transizione: return "rectangle.lefthalf.inset.filled.arrow.left"
        case .titolo: return "textformat"
        case .inquadra: return "crop"
        case .stabilizza: return "hand.raised"
        }
    }
}

/// Strumenti di montaggio della clip selezionata.
struct PannelloStrumentoEdit: View {
    @ObservedObject var studio: Studio
    let strumento: StrumentoEdit
    @Binding var mostraMusica: Bool
    @Binding var mostraAudioLibreria: Bool

    private var m: Binding<Montaggio> { Binding(get: { studio.montaggioCorrente }, set: { studio.montaggioCorrente = $0 }) }
    private var video: Bool { studio.clipCorrente?.video ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(strumento.rawValue).font(.caption.weight(.semibold)).foregroundStyle(Tema.testo2)
            if studio.clipCorrente == nil && strumento != .audio {
                Text("Select a clip in the timeline.").font(.caption).foregroundStyle(Tema.testo2)
            } else {
                switch strumento {
                case .taglio: taglio
                case .velocita: velocita
                case .audio: audio
                case .transizione: transizione
                case .titolo: titolo
                case .inquadra: inquadra
                case .stabilizza: stabilizza
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: taglio

    @ViewBuilder private var taglio: some View {
        if video {
            let d = max(studio.durataFileCorrente, 0.2)
            let fine = min(m.wrappedValue.fine ?? d, d)
            Regolazione(nome: "Start (s)", valore: Binding(get: { Float(m.wrappedValue.inizio) }, set: { m.wrappedValue.inizio = Double(min($0, Float(fine) - 0.1)) }),
                        intervallo: 0...Float(d), base: 0, formato: "%.2f")
            Regolazione(nome: "End (s)", valore: Binding(get: { Float(fine) }, set: { v in
                let x = Double(max(v, Float(m.wrappedValue.inizio) + 0.1)); m.wrappedValue.fine = x >= d - 0.01 ? nil : x }),
                        intervallo: 0...Float(d), base: Float(d), formato: "%.2f")
            Text(String(format: "In the timeline it lasts %.2f s (file %.2f s).", Sequenza.durata(m.wrappedValue, video: true, durataFile: d), d))
                .font(.caption2).foregroundStyle(Tema.testo2)
            HStack(spacing: 8) {
                Button {
                    // taglia in due alla testina: la parte dopo diventa una nuova clip
                    studio.dividiAllaTestina()
                } label: {
                    Label("Split at playhead", systemImage: "scissors").font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity).frame(height: 34)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Tema.campo))
                }
                .buttonStyle(.plain)
                Button { Task { await studio.dividiPerScene() } } label: {
                    Label("Split by scenes (AI)", systemImage: "wand.and.stars").font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity).frame(height: 34)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Tema.accento)).foregroundStyle(.black)
                }
                .buttonStyle(.plain)
                .disabled(studio.lavoro != nil)
            }
            if let l = studio.lavoro { HStack { ProgressView(); Text(l).font(.caption) } }
        } else {
            Regolazione(nome: "Photo duration (s)", valore: Binding(get: { Float(m.wrappedValue.durataFoto) }, set: { m.wrappedValue.durataFoto = Double($0) }),
                        intervallo: 0.5...15, base: 3, formato: "%.1f")
        }
    }

    // MARK: velocità

    @ViewBuilder private var velocita: some View {
        if video {
            let scelte: [Double] = [0.25, 0.5, 0.75, 1, 1.5, 2, 4, 8]
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 60), spacing: 6)], spacing: 6) {
                ForEach(scelte, id: \.self) { v in
                    Button { m.wrappedValue.velocita = v } label: {
                        Text(String(format: "%g×", v)).font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity).frame(height: 34)
                            .background(RoundedRectangle(cornerRadius: 6).fill(m.wrappedValue.velocita == v ? Tema.accento.opacity(0.25) : Tema.campo))
                            .foregroundStyle(m.wrappedValue.velocita == v ? Tema.accento : .white)
                    }
                    .buttonStyle(.plain)
                }
            }
            Regolazione(nome: "Precise speed", valore: Binding(get: { Float(m.wrappedValue.velocita) }, set: { m.wrappedValue.velocita = Double($0) }),
                        intervallo: 0.1...8, base: 1, formato: "%.2f×")
            Text("Below 1× slow motion (smoother if you shoot at 60 or 120 fps), above 1× fast. The audio changes speed without changing pitch.")
                .font(.caption2).foregroundStyle(Tema.testo2)
        } else {
            Text("Speed applies to videos. For a photo change the duration in Trim.").font(.caption).foregroundStyle(Tema.testo2)
        }
    }

    // MARK: audio

    @ViewBuilder private var audio: some View {
        if studio.clipCorrente != nil && video {
            Sezione(titolo: "Clip audio") {
                Regolazione(nome: "Volume", valore: m.volume, intervallo: 0...2, base: 1, formato: "%.2f")
                HStack(spacing: 12) {
                    Regolazione(nome: "Fade in (s)", valore: Binding(get: { Float(m.wrappedValue.audioEntrata) }, set: { m.wrappedValue.audioEntrata = Double($0) }), intervallo: 0...5, base: 0, formato: "%.1f")
                    Regolazione(nome: "Fade out (s)", valore: Binding(get: { Float(m.wrappedValue.audioUscita) }, set: { m.wrappedValue.audioUscita = Double($0) }), intervallo: 0...5, base: 0, formato: "%.1f")
                }
            }
        }
        Sezione(titolo: "Music and background audio") {
            ForEach(Array(studio.progetto.musiche.enumerated()), id: \.element.id) { i, mu in
                let scelta = studio.musicaScelta == mu.id
                VStack(spacing: 6) {
                    HStack {
                        Text("A\(i + 1)").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(Tema.accento)
                        Image(systemName: "music.note")
                        Text(mu.nome).font(.caption).lineLimit(1)
                        Spacer()
                        Image(systemName: scelta ? "chevron.up" : "chevron.down").font(.caption2).foregroundStyle(Tema.testo2)
                        Button(role: .destructive) { studio.togliMusica(mu.id) } label: { Image(systemName: "trash") }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { studio.musicaScelta = scelta ? nil : mu.id } }
                    Regolazione(nome: "Volume", valore: Binding(get: { studio.volumeMusica(mu.id) }, set: { studio.impostaVolumeMusica(mu.id, $0) }), intervallo: 0...1.5, base: 0.6, formato: "%.2f")
                    if scelta { tagliaTraccia(mu) }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Tema.campo))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Tema.accento, lineWidth: scelta ? 1.5 : 0))
            }
            HStack(spacing: 8) {
                Button { mostraMusica = true } label: {
                    Label("From Files", systemImage: "folder").font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity).frame(height: 34)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Tema.campo))
                }
                .buttonStyle(.plain)
                Button { mostraAudioLibreria = true } label: {
                    Label("Audio from videos (Library)", systemImage: "video").font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity).frame(height: 34)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Tema.campo))
                }
                .buttonStyle(.plain)
            }
            if !studio.progetto.musiche.isEmpty {
                Regolazione(nome: "Final fade (s)", valore: Binding(get: { Float(studio.dissolvenzaMusica) }, set: { studio.dissolvenzaMusica = Double($0) }), intervallo: 0...8, base: 2, formato: "%.1f")
                Toggle("Loop if shorter than the edit", isOn: Binding(get: { studio.ripetiMusica }, set: { studio.ripetiMusica = $0 }))
                    .tint(Tema.accento).font(.caption)
            }
            Text("Tracks play one after another. Tap a track to trim it; to change the order hold it in the timeline and drag it. To remove a piece in the middle: split twice and delete the middle part.")
                .font(.caption2).foregroundStyle(Tema.testo2)
        }
    }

    /// Taglio e dissolvenze di una traccia audio.
    @ViewBuilder private func tagliaTraccia(_ mu: Musica) -> some View {
        let df = studio.durateFile[mu.file] ?? 0
        if df > 0 {
            let fine = min(mu.fine ?? df, df)
            Regolazione(nome: "Start (s)", valore: Binding(get: { Float(mu.inizio) }, set: { v in
                studio.modificaMusica(mu.id) { $0.inizio = Double(min(v, Float(fine) - 0.5)) } }),
                        intervallo: 0...Float(df), base: 0, formato: "%.1f")
            Regolazione(nome: "End (s)", valore: Binding(get: { Float(fine) }, set: { v in
                studio.modificaMusica(mu.id) { m in let x = Double(max(v, Float(m.inizio) + 0.5)); m.fine = x >= df - 0.05 ? nil : x } }),
                        intervallo: 0...Float(df), base: Float(df), formato: "%.1f")
            HStack(spacing: 12) {
                Regolazione(nome: "Fade in (s)", valore: Binding(get: { Float(mu.entrata) }, set: { v in studio.modificaMusica(mu.id) { $0.entrata = Double(v) } }),
                            intervallo: 0...5, base: 0, formato: "%.1f")
                Regolazione(nome: "Fade out (s)", valore: Binding(get: { Float(mu.uscita) }, set: { v in studio.modificaMusica(mu.id) { $0.uscita = Double(v) } }),
                            intervallo: 0...5, base: 0, formato: "%.1f")
            }
            HStack {
                Text(String(format: "Using %.1f s of %.1f s", mu.durata(file: df), df)).font(.caption2).foregroundStyle(Tema.testo2)
                Spacer()
                Button { studio.dividiMusicaAllaTestina(mu.id) } label: {
                    Label("Split at playhead", systemImage: "scissors").font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Tema.sfondo))
                }
                .buttonStyle(.plain)
            }
        } else {
            HStack { ProgressView().controlSize(.small); Text("Reading duration…").font(.caption2).foregroundStyle(Tema.testo2) }
        }
    }

    // MARK: transizione

    @ViewBuilder private var transizione: some View {
        let ultima = studio.progetto.clips.last?.id == studio.clipAttiva
        if ultima {
            Text("This is the last clip: a transition goes between a clip and the next one.").font(.caption).foregroundStyle(Tema.testo2)
        } else {
            Text("To the next clip:").font(.caption)
            ForEach(Transizione.allCases) { t in
                Button { m.wrappedValue.transizione = t } label: {
                    HStack {
                        Image(systemName: m.wrappedValue.transizione == t ? "largecircle.fill.circle" : "circle")
                        Text(t.rawValue)
                        Spacer()
                    }
                    .font(.subheadline)
                    .foregroundStyle(m.wrappedValue.transizione == t ? Tema.accento : .white)
                }
                .buttonStyle(.plain)
            }
            if m.wrappedValue.transizione != .nessuna {
                Regolazione(nome: "Duration (s)", valore: Binding(get: { Float(m.wrappedValue.durataTransizione) }, set: { m.wrappedValue.durataTransizione = Double($0) }), intervallo: 0.1...3, base: 0.6, formato: "%.1f")
            }
            Text("Dissolves also crossfade the audio between the two clips.").font(.caption2).foregroundStyle(Tema.testo2)
        }
    }

    // MARK: titolo

    @ViewBuilder private var titolo: some View {
        TextField("Type the title…", text: m.titolo.testo, axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(1...3)
        if !m.wrappedValue.titolo.testo.isEmpty {
            Picker("Color", selection: m.titolo.colore) {
                ForEach(Titolo.Colore.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            HStack(spacing: 12) {
                Regolazione(nome: "Size", valore: m.titolo.dimensione, intervallo: 0.03...0.2, base: 0.07, formato: "%.2f")
                Regolazione(nome: "Position", valore: m.titolo.posizione, intervallo: 0.05...0.95, base: 0.82, formato: "%.2f")
            }
            HStack {
                Toggle("Bold", isOn: m.titolo.grassetto)
                Toggle("Dark band", isOn: m.titolo.sfondo)
            }
            .tint(Tema.accento).font(.caption)
            Button(role: .destructive) { m.wrappedValue.titolo = Titolo() } label: { Label("Remove title", systemImage: "trash") }.font(.caption)
        }
        Text("The title stays for the whole clip and fades in and out. Position: 0 top, 1 bottom.")
            .font(.caption2).foregroundStyle(Tema.testo2)
        sottotitoli
    }

    // MARK: sottotitoli automatici (AI)

    @ViewBuilder private var sottotitoli: some View {
        Sezione(titolo: "Automatic captions (AI)") {
            if !video {
                Text("Captions are created from the speech in the videos.").font(.caption).foregroundStyle(Tema.testo2)
            } else {
                HStack {
                    Picker("Language", selection: $studio.linguaSottotitoli) {
                        ForEach(Trascrizione.lingue, id: \.codice) { Text($0.nome).tag($0.codice) }
                    }
                    .pickerStyle(.menu)
                    Spacer()
                    if let l = studio.lavoro {
                        ProgressView().controlSize(.small); Text(l).font(.caption)
                    } else {
                        Button { Task { await studio.generaSottotitoli() } } label: {
                            Label(m.wrappedValue.sottotitoli.isEmpty ? "Create from speech" : "Redo", systemImage: "captions.bubble")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12).frame(height: 32)
                                .background(RoundedRectangle(cornerRadius: 7).fill(Tema.accento)).foregroundStyle(.black)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if !m.wrappedValue.sottotitoli.isEmpty {
                    Toggle("Show captions", isOn: m.mostraSottotitoli).tint(Tema.accento).font(.caption)
                    Picker("Color", selection: m.stileSottotitoli.colore) {
                        ForEach(Titolo.Colore.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    HStack(spacing: 12) {
                        Regolazione(nome: "Size", valore: m.stileSottotitoli.dimensione, intervallo: 0.03...0.1, base: 0.05, formato: "%.2f")
                        Toggle("Band", isOn: m.stileSottotitoli.sfondo).tint(Tema.accento).font(.caption).frame(width: 110)
                    }
                    ForEach(m.sottotitoli) { $riga in
                        HStack(alignment: .top, spacing: 6) {
                            Button { studio.vaiSequenza(tempoInSequenza(riga.inizio)) } label: {
                                Text(String(format: "%.1f", riga.inizio)).font(.system(size: 10, design: .monospaced))
                                    .frame(width: 34, alignment: .leading).foregroundStyle(Tema.accento)
                            }
                            .buttonStyle(.plain)
                            TextField("", text: $riga.testo, axis: .vertical).font(.caption).lineLimit(1...3)
                            Button(role: .destructive) { m.wrappedValue.sottotitoli.removeAll { $0.id == riga.id } } label: {
                                Image(systemName: "minus.circle").font(.caption)
                            }
                            .buttonStyle(.plain).foregroundStyle(.red)
                        }
                    }
                }
                Text("Speech is transcribed on the iPhone. You can correct every line; the orange number moves the playhead there.")
                    .font(.caption2).foregroundStyle(Tema.testo2)
            }
        }
    }

    /// Da un tempo nel file della clip attiva al tempo nella timeline.
    private func tempoInSequenza(_ t: Double) -> Double {
        guard let i = studio.progetto.clips.firstIndex(where: { $0.id == studio.clipAttiva }), i < studio.iniziClip.count else { return 0 }
        let m = studio.montaggioCorrente
        return studio.iniziClip[i] + max(0, t - m.inizio) / max(m.velocita, 0.1)
    }

    // MARK: inquadratura

    @ViewBuilder private var inquadra: some View {
        HStack(spacing: 8) {
            Button { m.wrappedValue.inquadratura.rotazione = (m.wrappedValue.inquadratura.rotazione + 90) % 360 } label: {
                Label("Rotate 90°", systemImage: "rotate.right").font(.caption.weight(.semibold))
                    .padding(.horizontal, 10).frame(height: 32).background(RoundedRectangle(cornerRadius: 6).fill(Tema.campo))
            }
            .buttonStyle(.plain)
            Button { m.wrappedValue.inquadratura.specchio.toggle() } label: {
                Label("Mirror", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right").font(.caption.weight(.semibold))
                    .padding(.horizontal, 10).frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 6).fill(m.wrappedValue.inquadratura.specchio ? Tema.accento.opacity(0.25) : Tema.campo))
            }
            .buttonStyle(.plain)
            Spacer()
            Button("Reset") { m.wrappedValue.inquadratura = Inquadratura() }.font(.caption).disabled(m.wrappedValue.inquadratura.neutra)
        }
        Regolazione(nome: "Zoom", valore: m.inquadratura.zoom, intervallo: 1...3, base: 1, formato: "%.2f×")
        HStack(spacing: 12) {
            Regolazione(nome: "Horizontal", valore: m.inquadratura.x, intervallo: -1...1, base: 0)
            Regolazione(nome: "Vertical", valore: m.inquadratura.y, intervallo: -1...1, base: 0)
        }
        Text("With zoom you can crop and move the framing. Rotation \(m.wrappedValue.inquadratura.rotazione)°.")
            .font(.caption2).foregroundStyle(Tema.testo2)
        Sezione(titolo: "Automatic 9:16 reframe (AI)") {
            if video {
                if let l = studio.lavoro {
                    HStack { ProgressView(); Text(l).font(.caption) }
                } else {
                    Button { Task { await studio.analizzaReframe() } } label: {
                        Label(m.wrappedValue.reframe.isEmpty ? "Follow the subject" : "Analyze again", systemImage: "person.crop.rectangle")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity).frame(height: 38)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Tema.accento)).foregroundStyle(.black)
                    }
                    .buttonStyle(.plain)
                }
                if !m.wrappedValue.reframe.isEmpty {
                    Toggle("Follow the subject", isOn: m.seguiSoggetto).tint(Tema.accento).font(.caption)
                }
            }
            Toggle("Vertical 9:16 preview", isOn: $studio.anteprimaVerticale).tint(Tema.accento).font(.caption)
            Text("When you export vertically (TikTok, Reels, Shorts) the crop follows the subject instead of staying centered. Not used if you zoomed or rotated manually.")
                .font(.caption2).foregroundStyle(Tema.testo2)
        }
    }

    // MARK: stabilizzazione

    @ViewBuilder private var stabilizza: some View {
        if video {
            if let l = studio.lavoro {
                HStack { ProgressView(); Text(l).font(.caption) }
            } else {
                Button { Task { await studio.stabilizzaClip() } } label: {
                    Label(m.wrappedValue.percorsoStab.isEmpty ? "Analyze and stabilize" : "Analyze again", systemImage: "hand.raised")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity).frame(height: 38)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Tema.accento)).foregroundStyle(.black)
                }
                .buttonStyle(.plain)
            }
            if !m.wrappedValue.percorsoStab.isEmpty {
                Toggle("Stabilization on", isOn: m.stabilizza).tint(Tema.accento).font(.caption)
                if m.wrappedValue.stabilizza {
                    Picker("Mode", selection: m.treppiede) {
                        Text("Smooth motion").tag(false)
                        Text("Tripod (locked)").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if !m.wrappedValue.treppiede {
                        Regolazione(nome: "Strength", valore: m.forzaStab, intervallo: 0...1, base: 0.6, formato: "%.2f")
                    }
                }
            }
            Text(m.wrappedValue.treppiede
                 ? "Tripod: the framing stays still as if on a tripod (good for shots without intended movement)."
                 : "Removes hand shake and keeps intended movement; more strength = smoother motion. The image is only enlarged as much as needed to hide the edges.")
                .font(.caption2).foregroundStyle(Tema.testo2)
        } else {
            Text("Stabilization applies to videos.").font(.caption).foregroundStyle(Tema.testo2)
        }
    }
}
