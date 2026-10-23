import SwiftUI

/// Inspector della pagina Edit, come in DaVinci: schede Video / Audio / Transizione / Titolo / File,
/// sezioni con il tasto di azzeramento e valori che si trascinano col mouse (destro = valore iniziale).
struct InspectorMonitor: View {
    @ObservedObject var studio: Studio
    @State private var scheda = "Video"

    private var m: Montaggio { studio.montaggioCorrente }
    private var clip: Clip? { studio.progetto.clips.first { $0.id == studio.clipAttiva } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Inspector").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(clip?.nome ?? "").font(.system(size: 11)).foregroundStyle(Tema.testo2).lineLimit(1)
            }
            .padding(.horizontal, 12).frame(height: 30)
            .overlay(alignment: .bottom) { Rectangle().fill(Color(white: 0.17)).frame(height: 1) }
            HStack(spacing: 0) {
                ForEach(["Video", "Audio", "Transizione", "Titolo", "File"], id: \.self) { t in
                    Button { scheda = t } label: {
                        Text(t).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                            .frame(maxWidth: .infinity).frame(height: 28)
                            .foregroundStyle(scheda == t ? Color.white : Tema.testo2)
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(scheda == t ? Tema.accento : Color(white: 0.2)).frame(height: scheda == t ? 2 : 1)
                            }
                    }
                }
            }
            if clip == nil {
                Text("Scegli una clip nella timeline.").font(.system(size: 12)).foregroundStyle(Tema.testo2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        switch scheda {
                        case "Video": video
                        case "Audio": audio
                        case "Transizione": transizione
                        case "Titolo": titolo
                        default: file
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .background(Tema.pannello)
    }

    // MARK: schede

    @ViewBuilder private var video: some View {
        sezione("Trasformazione", modificata: !m.inquadratura.neutra, azzera: { modifica { $0.inquadratura = Inquadratura() } }) {
            valore("Zoom", 1...3, base: 1, "%.2f×", get: { Double($0.inquadratura.zoom) }, set: { $0.inquadratura.zoom = Float($1) })
            valore("Posizione X", -1...1, base: 0, "%.3f", get: { Double($0.inquadratura.x) }, set: { $0.inquadratura.x = Float($1) })
            valore("Posizione Y", -1...1, base: 0, "%.3f", get: { Double($0.inquadratura.y) }, set: { $0.inquadratura.y = Float($1) })
            riga("Rotazione") {
                ForEach([0, 90, 180, 270], id: \.self) { r in
                    chip("\(r)°", m.inquadratura.rotazione == r) { modifica { $0.inquadratura.rotazione = r } }
                }
            }
            riga("Capovolgi") {
                chip("Orizzontale", m.inquadratura.specchio) { modifica { $0.inquadratura.specchio.toggle() } }
            }
        }
        sezione("Velocità", modificata: m.velocita != 1, azzera: { modifica { $0.velocita = 1 } }) {
            valore("Velocità", 0.25...4, base: 1, "%.0f%%", scala: 100, get: { $0.velocita }, set: { $0.velocita = $1 })
            riga("") {
                ForEach([0.25, 0.5, 1, 2, 4], id: \.self) { v in
                    chip(String(format: v < 1 ? "%.2g×" : "%.0f×", v), abs(m.velocita - v) < 0.001) { modifica { $0.velocita = v } }
                }
            }
        }
        if clip?.video == true {
            sezione("Stabilizzazione", modificata: m.stabilizza, azzera: { modifica { $0.stabilizza = false } }) {
                if m.percorsoStab.isEmpty {
                    tasto(studio.lavoro ?? "Analizza e stabilizza", "hand.raised") { Task { await studio.stabilizzaClip() } }
                } else {
                    riga("Attiva") { chip(m.stabilizza ? "Sì" : "No", m.stabilizza) { modifica { $0.stabilizza.toggle() } } }
                    riga("Modo") {
                        chip("Liscio", !m.treppiede) { modifica { $0.treppiede = false } }
                        chip("Treppiede", m.treppiede) { modifica { $0.treppiede = true } }
                    }
                    if !m.treppiede {
                        valore("Forza", 0...1, base: 0.6, "%.2f", get: { Double($0.forzaStab) }, set: { $0.forzaStab = Float($1) })
                    }
                }
            }
        } else {
            sezione("Durata foto", modificata: m.durataFoto != 3, azzera: { modifica { $0.durataFoto = 3 } }) {
                valore("Durata", 0.5...15, base: 3, "%.1f s", get: { $0.durataFoto }, set: { $0.durataFoto = $1 })
            }
        }
    }

    @ViewBuilder private var audio: some View {
        sezione("Volume", modificata: m.volume != 1, azzera: { modifica { $0.volume = 1 } }) {
            valore("Volume", 0...2, base: 1, "%.0f%%", scala: 100, get: { Double($0.volume) }, set: { $0.volume = Float($1) })
        }
        sezione("Dissolvenze", modificata: m.audioEntrata != 0 || m.audioUscita != 0, azzera: { modifica { $0.audioEntrata = 0; $0.audioUscita = 0 } }) {
            valore("Entrata", 0...5, base: 0, "%.1f s", get: { $0.audioEntrata }, set: { $0.audioEntrata = $1 })
            valore("Uscita", 0...5, base: 0, "%.1f s", get: { $0.audioUscita }, set: { $0.audioUscita = $1 })
        }
    }

    @ViewBuilder private var transizione: some View {
        if studio.progetto.clips.last?.id == studio.clipAttiva {
            nota("È l'ultima clip: la transizione si mette tra una clip e la successiva.")
        } else {
            sezione("Verso la clip successiva", modificata: m.transizione != .nessuna, azzera: { modifica { $0.transizione = .nessuna } }) {
                ForEach(Transizione.allCases) { t in
                    riga("") { chip(t.rawValue, m.transizione == t) { modifica { $0.transizione = t } }; Spacer() }
                }
                if m.transizione != .nessuna {
                    valore("Durata", 0.1...3, base: 0.6, "%.1f s", get: { $0.durataTransizione }, set: { $0.durataTransizione = $1 })
                }
            }
        }
    }

    @ViewBuilder private var titolo: some View {
        sezione("Testo", modificata: !m.titolo.testo.isEmpty, azzera: { modifica { $0.titolo = Titolo() } }) {
            TextField("Scrivi il titolo…", text: Binding(get: { m.titolo.testo }, set: { v in modifica { $0.titolo.testo = v } }))
                .font(.system(size: 12)).textFieldStyle(.plain)
                .padding(.horizontal, 8).frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.07)))
            if !m.titolo.testo.isEmpty {
                valore("Grandezza", 0.03...0.2, base: 0.07, "%.3f", get: { Double($0.titolo.dimensione) }, set: { $0.titolo.dimensione = Float($1) })
                valore("Posizione", 0.05...0.95, base: 0.82, "%.2f", get: { Double($0.titolo.posizione) }, set: { $0.titolo.posizione = Float($1) })
                riga("Colore") {
                    ForEach(Titolo.Colore.allCases) { c in chip(c.rawValue, m.titolo.colore == c) { modifica { $0.titolo.colore = c } } }
                }
                riga("Stile") {
                    chip("Grassetto", m.titolo.grassetto) { modifica { $0.titolo.grassetto.toggle() } }
                    chip("Fascia scura", m.titolo.sfondo) { modifica { $0.titolo.sfondo.toggle() } }
                }
            }
        }
    }

    @ViewBuilder private var file: some View {
        if let c = clip {
            let df = studio.durateFile[c.file]
            sezione("Informazioni", modificata: false, azzera: nil) {
                info("Nome", c.nome)
                info("Tipo", c.video ? "Video" : "Foto")
                if c.video {
                    info("Durata file", df.map { VistaMonitor.timecode($0) } ?? "—")
                    info("Entrata", VistaMonitor.timecode(m.inizio))
                    info("Uscita", VistaMonitor.timecode(m.fine ?? df ?? 0))
                }
                if let i = studio.progetto.clips.firstIndex(where: { $0.id == c.id }), i < studio.posizioniClip.count {
                    info("In timeline", VistaMonitor.timecode(studio.posizioniClip[i].inizio))
                    info("Durata", VistaMonitor.timecode(studio.posizioniClip[i].durata))
                }
                info("Nodi colore", "\(c.nodi.count)")
            }
        }
    }

    // MARK: pezzi

    private func modifica(_ f: (inout Montaggio) -> Void) {
        var n = studio.montaggioCorrente
        f(&n)
        studio.montaggioCorrente = n
    }

    private func sezione<C: View>(_ titolo: String, modificata: Bool, azzera: (() -> Void)?, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill(modificata ? Tema.accento : Color(white: 0.3)).frame(width: 6, height: 6)
                Text(titolo).font(.system(size: 12, weight: .semibold))
                Spacer()
                if let azzera {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 11))
                        .foregroundStyle(modificata ? Color(white: 0.85) : Color(white: 0.35))
                        .frame(width: 24, height: 22)
                        .zonaMonitor("insp.azzera." + titolo, clic: { _ in azzera() })
                }
            }
            c()
        }
        .padding(12)
        .overlay(alignment: .bottom) { Rectangle().fill(Color(white: 0.15)).frame(height: 1) }
    }

    /// Valore come quelli di DaVinci: barra sottile + numero; si trascina a destra/sinistra, clic sulla barra = vai lì.
    private func valore(_ nome: String, _ r: ClosedRange<Double>, base: Double, _ formato: String, scala: Double = 1,
                        get: @escaping (Montaggio) -> Double, set: @escaping (inout Montaggio, Double) -> Void) -> some View {
        let v = get(m)
        let parte = CGFloat((v - r.lowerBound) / (r.upperBound - r.lowerBound))
        func imposta(_ x: Double) {
            var n = Studio.condiviso.montaggioCorrente
            set(&n, min(r.upperBound, max(r.lowerBound, x)))
            Studio.condiviso.montaggioCorrente = n
        }
        return HStack(spacing: 8) {
            Text(nome).font(.system(size: 11)).foregroundStyle(Tema.testo2).frame(width: 78, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(white: 0.22)).frame(height: 3)
                    Capsule().fill(Tema.accento.opacity(0.8)).frame(width: max(0, min(1, parte)) * g.size.width, height: 3)
                    Circle().fill(Color(white: 0.85)).frame(width: 9, height: 9).offset(x: max(0, min(1, parte)) * (g.size.width - 9))
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 20)
            .zonaMonitor("insp.barra." + nome, clic: { p in imposta(r.lowerBound + Double(p.x) * (r.upperBound - r.lowerBound)) },
                         trascina: { _, p in imposta(r.lowerBound + Double(min(1, max(0, p.x))) * (r.upperBound - r.lowerBound)) },
                         destro: { imposta(base) })
            Text(String(format: formato, v * scala)).font(.system(size: 11, design: .monospaced))
                .frame(width: 64, height: 22)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.07)))
                .zonaMonitor("insp.valore." + nome,
                             trascina: { d, _ in imposta(get(Studio.condiviso.montaggioCorrente) + Double(d.width) / 300 * (r.upperBound - r.lowerBound)) },
                             destro: { imposta(base) })
        }
    }

    private func riga<C: View>(_ nome: String, @ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: 6) {
            Text(nome).font(.system(size: 11)).foregroundStyle(Tema.testo2).frame(width: 78, alignment: .leading)
            c()
        }
    }

    private func chip(_ t: String, _ attivo: Bool, _ azione: @escaping () -> Void) -> some View {
        Button(action: azione) {
            Text(t).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                .padding(.horizontal, 8).frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 4).fill(attivo ? Tema.accento.opacity(0.22) : Color(white: 0.11)))
                .foregroundStyle(attivo ? Tema.accento : Color(white: 0.8))
        }
    }

    private func tasto(_ t: String, _ simbolo: String, _ azione: @escaping () -> Void) -> some View {
        Button(action: azione) {
            Label(t, systemImage: simbolo).font(.system(size: 12, weight: .bold))
                .frame(maxWidth: .infinity).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 6).fill(Tema.accento))
                .foregroundStyle(.black)
        }
        .disabled(studio.lavoro != nil)
    }

    private func info(_ nome: String, _ v: String) -> some View {
        HStack {
            Text(nome).font(.system(size: 11)).foregroundStyle(Tema.testo2).frame(width: 90, alignment: .leading)
            Text(v).font(.system(size: 11, design: .monospaced)).lineLimit(1)
            Spacer()
        }
    }

    private func nota(_ t: String) -> some View {
        Text(t).font(.system(size: 11)).foregroundStyle(Tema.testo2).padding(12)
    }
}
