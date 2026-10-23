import SwiftUI

enum Palette: String, CaseIterable, Identifiable {
    case primarie = "Primarie", ai = "AI", hdr = "HDR", curve = "Curve", warper = "Warper", mixer = "Mixer"
    case qualificatore = "Qualificatore", finestre = "Finestre", effetti = "Effetti", regolazioni = "Regolazioni"
    case cst = "CST", galleria = "Galleria", consegna = "Consegna"
    var id: String { rawValue }
    /// Le palette nella fila: Consegna sta nella pagina Deliver.
    static var visibili: [Palette] { allCases.filter { $0 != .consegna } }
    var icona: String {
        switch self {
        case .primarie: return "circle.circle"
        case .ai: return "wand.and.stars"
        case .hdr: return "sun.max"
        case .curve: return "point.topleft.down.to.point.bottomright.curvepath"
        case .warper: return "circle.grid.cross"
        case .mixer: return "slider.vertical.3"
        case .qualificatore: return "eyedropper.halffull"
        case .finestre: return "circle.dashed"
        case .effetti: return "sparkles"
        case .regolazioni: return "slider.horizontal.3"
        case .cst: return "camera.filters"
        case .galleria: return "photo.stack"
        case .consegna: return "square.and.arrow.up"
        }
    }
}

/// Barra delle palette con icone, come quella sotto il viewer di DaVinci.
struct BarraPalette: View {
    @Binding var scelta: Palette
    /// Chiamato a ogni tocco, anche sulla palette già scelta.
    var tocco: (Palette) -> Void = { _ in }
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Palette.visibili) { p in
                        Button { scelta = p; tocco(p) } label: {
                            VStack(spacing: 2) {
                                Image(systemName: p.icona).font(.system(size: 15))
                                Text(p.rawValue).font(.system(size: 9))
                            }
                            .frame(width: 62, height: 40)
                            .foregroundStyle(scelta == p ? Tema.accento : Tema.testo2)
                            .background(RoundedRectangle(cornerRadius: 6).fill(scelta == p ? Tema.campo : .clear))
                        }
                        .buttonStyle(StilePulsante())
                        .id(p)
                    }
                }
                .padding(.horizontal, 6)
            }
            .onChange(of: scelta) { _, p in withAnimation { proxy.scrollTo(p, anchor: .center) } }
        }
        .frame(height: 46)
        .background(Tema.pannello)
    }
}

/// Riquadro con titolo, usato in diverse palette.
struct Sezione<C: View>: View {
    let titolo: String
    @ViewBuilder var contenuto: () -> C
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(titolo).font(.caption.weight(.semibold)).foregroundStyle(Tema.testo2)
            contenuto()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Tema.pannello))
    }
}

// MARK: - Primarie

struct PannelloPrimarie: View {
    @ObservedObject var studio: Studio
    @State private var log = false

    var body: some View {
        VStack(spacing: 8) {
            TestataPalette(titolo: "Primarie", modificata: studio.nodo.grade.primarieModificate) { studio.nodo.grade.azzeraPrimarie() }
            HStack {
                Picker("", selection: $log) {
                    Text("Primarie").tag(false)
                    Text("Log").tag(true)
                }
                .pickerStyle(.segmented)
                .sceltaMonitor($log, [false, true])
                Button { studio.autoBilancia() } label: {
                    Text("A").font(.system(size: 13, weight: .bold)).frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Tema.campo))
                }
                .buttonStyle(StilePulsante())
                .accessibilityLabel("Bilanciamento automatico")
                Button {
                    studio.contagocce = studio.contagocce == .bianco ? .nessuno : .bianco
                } label: {
                    Image(systemName: "eyedropper").frame(width: 26, height: 26)
                        .foregroundStyle(studio.contagocce == .bianco ? Tema.accento : .white)
                }
                .accessibilityLabel("Contagocce del bianco")
            }
            if studio.contagocce == .bianco {
                Text("Tocca nell'immagine un punto che deve essere bianco o grigio neutro.")
                    .font(.caption2).foregroundStyle(Tema.accento)
            }
            if log {
                FilaRuote(voci: [
                    .init(id: "Ombre", wheel: $studio.nodo.grade.logOmbre, scala: 0.12),
                    .init(id: "Medi", wheel: $studio.nodo.grade.logMedi, scala: 0.12),
                    .init(id: "Luci", wheel: $studio.nodo.grade.logLuci, scala: 0.12),
                ])
                HStack(spacing: 12) {
                    Regolazione(nome: "Range basso", valore: $studio.nodo.grade.logBasso, intervallo: 0.05...0.6, base: 0.3)
                    Regolazione(nome: "Range alto", valore: $studio.nodo.grade.logAlto, intervallo: 0.4...0.95, base: 0.7)
                }
            } else {
                FilaRuote(voci: [
                    .init(id: "Lift", wheel: $studio.nodo.grade.lift, scala: 0.25),
                    .init(id: "Gamma", wheel: $studio.nodo.grade.gamma, scala: 0.25),
                    .init(id: "Gain", wheel: $studio.nodo.grade.gain, base: 1, scala: 0.5),
                    .init(id: "Offset", wheel: $studio.nodo.grade.offset, scala: 0.12),
                ])
            }
            HStack(spacing: 12) {
                Regolazione(nome: "Contrasto", valore: $studio.nodo.grade.contrasto, intervallo: 0...2, base: 1)
                Regolazione(nome: "Pivot", valore: $studio.nodo.grade.pivot, intervallo: 0...1, base: 0.435, formato: "%.3f")
            }
            HStack(spacing: 12) {
                Regolazione(nome: "Saturazione", valore: $studio.nodo.grade.saturazione, intervallo: 0...2, base: 1)
                Regolazione(nome: "Temperatura", valore: $studio.nodo.grade.temperatura, intervallo: -1...1, base: 0)
            }
            HStack(spacing: 12) {
                Regolazione(nome: "Mid/Detail", valore: $studio.nodo.effetti.dettaglio, intervallo: -1...1, base: 0)
                Regolazione(nome: "Hue", valore: $studio.nodo.grade.rotazioneTinta, intervallo: -180...180, base: 0, formato: "%.0f°")
                Regolazione(nome: "Lum Mix", valore: $studio.nodo.grade.lumMix, intervallo: 0...1, base: 1)
            }
            if studio.nodo.grade.nero != .zero || studio.nodo.grade.bilanciamento != SIMD3(1, 1, 1) {
                Button("Azzera bilanciamento automatico / contagocce") {
                    studio.nodo.grade.nero = .zero; studio.nodo.grade.bilanciamento = SIMD3(1, 1, 1)
                }
                .font(.caption)
            }
        }
    }
}

/// Ruote in una fila orizzontale. Se ci stanno tutte restano ferme e si usano subito; altrimenti la fila
/// scorre col dito (anche sopra le ruote) e una ruota si usa solo dopo averla selezionata con un doppio tocco.
struct FilaRuote: View {
    struct Voce: Identifiable {
        let id: String
        let wheel: Binding<Wheel>
        var base: Float = 0
        let scala: Float
    }
    let voci: [Voce]
    @State private var scelta: String?
    /// Ruota selezionata col doppio tocco: l'unica che risponde al dito.
    @State private var selezionata: String?
    @State private var larghezza: CGFloat = 360

    private let spazio: CGFloat = 6
    /// Sotto questa misura una ruota diventa scomoda da usare col dito.
    private let minima: CGFloat = 112

    var body: some View {
        let n = CGFloat(voci.count)
        let tutte = (larghezza - spazio * (n - 1)) / n
        let scorre = tutte < minima
        // se non ci stanno tutte se ne vedono due e mezza: si capisce che la fila continua
        let lato = scorre ? max(minima, (larghezza - spazio * 2) / 2.5) : min(tutte, 220)
        VStack(spacing: 6) {
            if scorre {
                HStack(spacing: 4) {
                    ForEach(voci) { v in
                        let attiva = (scelta ?? voci.first?.id) == v.id
                        Button { withAnimation(.easeOut(duration: 0.25)) { scelta = v.id } } label: {
                            Text(v.id).font(.caption2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.6)
                                .frame(maxWidth: .infinity).frame(height: 24)
                                .background(RoundedRectangle(cornerRadius: 5).fill(attiva ? Tema.accento.opacity(0.25) : Tema.campo))
                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(attiva ? Tema.accento : .clear, lineWidth: 1.2))
                                .foregroundStyle(attiva ? Tema.accento : (v.wheel.wrappedValue.neutra ? Tema.testo2 : .white))
                        }
                        .buttonStyle(StilePulsante())
                    }
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: spazio) {
                    ForEach(voci) { v in
                        WheelControl(titolo: v.id, wheel: v.wheel, base: v.base, scala: v.scala,
                                     inFila: scorre, selezionata: selezionata == v.id,
                                     seleziona: { selezionata = selezionata == v.id ? nil : v.id })
                            .frame(width: lato)
                            .id(v.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $scelta, anchor: .leading)
            .scrollDisabled(!scorre)
            if scorre {
                Text(selezionata == nil ? "Doppio tocco su una ruota per regolarla." : "Doppio tocco di nuovo sulla ruota per lasciarla.")
                    .font(.caption2).foregroundStyle(Tema.testo2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { larghezza = $0 }
    }
}

// MARK: - HDR a zone

struct PannelloHDR: View {
    @ObservedObject var studio: Studio
    var body: some View {
        VStack(spacing: 8) {
            TestataPalette(titolo: "Ruote HDR", modificata: studio.nodo.grade.hdrModificato) { studio.nodo.grade.azzeraHDR() }
            FilaRuote(voci: (0..<6).map { .init(id: Grade.nomiZone[$0], wheel: $studio.nodo.grade.zone[$0], scala: 0.5) }
                + [.init(id: "Globale", wheel: $studio.nodo.grade.hdrGlobale, scala: 0.5)])
            HStack(spacing: 12) {
                Regolazione(nome: "Temp", valore: $studio.nodo.grade.hdrTemp, intervallo: -1...1, base: 0)
                Regolazione(nome: "Tint", valore: $studio.nodo.grade.hdrTint, intervallo: -1...1, base: 0)
                Regolazione(nome: "Hue", valore: $studio.nodo.grade.hdrHue, intervallo: -180...180, base: 0, formato: "%.0f°")
            }
            HStack(spacing: 12) {
                Regolazione(nome: "Contrasto", valore: $studio.nodo.grade.hdrContrasto, intervallo: 0...2, base: 1, formato: "%.3f")
                Regolazione(nome: "Pivot", valore: $studio.nodo.grade.hdrPivot, intervallo: 0...1, base: 0.435, formato: "%.3f")
                Regolazione(nome: "B/Ofs", valore: $studio.nodo.grade.hdrNeroOffset, intervallo: -1...1, base: 0, formato: "%.3f")
            }
            Text("Ogni ruota lavora su una fascia di luminanza: il cursore sotto è l'esposizione in stop, il puntino il colore. Le fasce si sovrappongono morbidamente, come le zone HDR di DaVinci.")
                .font(.caption2).foregroundStyle(Tema.testo2)
        }
    }
}

// MARK: - Curve

struct PannelloCurve: View {
    @ObservedObject var studio: Studio
    @AppStorage("tipoCurva") private var tipoSalvato = TipoCurva.custom.rawValue
    @State private var canale = 0
    @State private var softClip = false

    private var tipo: TipoCurva { TipoCurva(rawValue: tipoSalvato) ?? .custom }
    private static let coloriCanali = [Color.white, Color(red: 1, green: 0.4, blue: 0.35), Color(red: 0.4, green: 0.9, blue: 0.45), Color(red: 0.4, green: 0.6, blue: 1)]

    private var curva: Binding<Curva> {
        if let kp = tipo.curva { return Binding(get: { studio.nodo.grade[keyPath: kp] }, set: { studio.nodo.grade[keyPath: kp] = $0 }) }
        switch canale {
        case 1: return $studio.nodo.grade.curvaR
        case 2: return $studio.nodo.grade.curvaG
        case 3: return $studio.nodo.grade.curvaB
        default: return $studio.nodo.grade.curvaY
        }
    }

    private var modo: CurveEditor.Modo {
        switch tipo.asse {
        case _ where tipo == .custom: return .personalizzata(Self.coloriCanali[canale])
        case .tinta: return .tinta
        case .luminanza: return .lineare("lum")
        case .saturazione: return .lineare("sat")
        }
    }

    /// La curva mostrata è diversa da quella di partenza.
    private var modificata: Bool { tipo == .custom ? !curva.wrappedValue.eDiagonale : !curva.wrappedValue.punti.isEmpty }

    /// Quali curve del nodo sono state toccate (puntino sull'icona).
    private func usata(_ t: TipoCurva) -> Bool {
        let g = studio.nodo.grade
        if let kp = t.curva { return !g[keyPath: kp].ePiatta }
        return !(g.curvaY.eDiagonale && g.curvaR.eDiagonale && g.curvaG.eDiagonale && g.curvaB.eDiagonale)
    }

    var body: some View {
        VStack(spacing: 8) {
            // barra dei tipi di curva, come in DaVinci
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(TipoCurva.allCases) { t in
                        Button { tipoSalvato = t.rawValue; studio.contagocce = .nessuno } label: {
                            VStack(spacing: 3) {
                                IconaCurva(tipo: t)
                                    .overlay(alignment: .topTrailing) {
                                        if usata(t) { Circle().fill(Tema.accento).frame(width: 6, height: 6).offset(x: 2, y: -2) }
                                    }
                                Text(t.corto).font(.system(size: 9, weight: .semibold)).lineLimit(1)
                            }
                            .frame(width: 52, height: 44)
                            .background(RoundedRectangle(cornerRadius: 6).fill(tipo == t ? Tema.campo : .clear))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(tipo == t ? Tema.accento : .clear, lineWidth: 1.5))
                            .foregroundStyle(tipo == t ? Tema.accento : Tema.testo2)
                        }
                        .buttonStyle(StilePulsante())
                    }
                }
            }
            // titolo + azzera
            HStack(spacing: 8) {
                Text(tipo.rawValue).font(.subheadline.weight(.semibold))
                Spacer(minLength: 4)
                if tipo != .custom {
                    Button {
                        let attivo = studio.contagocce == .curva && studio.curvaContagocce == tipo
                        studio.curvaContagocce = tipo
                        studio.contagocce = attivo ? .nessuno : .curva
                    } label: {
                        Image(systemName: "eyedropper").frame(width: 32, height: 28)
                            .background(RoundedRectangle(cornerRadius: 6).fill(studio.contagocce == .curva ? Tema.accento.opacity(0.25) : Tema.campo))
                            .foregroundStyle(studio.contagocce == .curva ? Tema.accento : .white)
                    }
                    .buttonStyle(StilePulsante())
                    .accessibilityLabel("Contagocce: scegli il colore dall'immagine")
                }
                Button {
                    curva.wrappedValue = tipo == .custom ? .diagonale : .piatta
                } label: {
                    Label("Azzera", systemImage: "arrow.counterclockwise")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 6).fill(modificata ? Tema.accento.opacity(0.25) : Tema.campo))
                        .foregroundStyle(modificata ? Tema.accento : Tema.testo2)
                }
                .buttonStyle(StilePulsante())
                .disabled(!modificata)
            }
            if studio.contagocce == .curva {
                Text("Tocca nell'immagine il colore da cambiare: nascono tre punti, poi trascina quello centrale.")
                    .font(.caption2).foregroundStyle(Tema.accento).frame(maxWidth: .infinity, alignment: .leading)
            }
            // Custom: canali Y R G B
            if tipo == .custom {
                HStack(spacing: 6) {
                    ForEach(0..<4) { k in
                        Button { canale = k } label: {
                            Text(["Y", "R", "G", "B"][k]).font(.subheadline.bold())
                                .frame(maxWidth: .infinity).frame(height: 28)
                                .background(RoundedRectangle(cornerRadius: 6).fill(canale == k ? Tema.campo : Tema.pannello))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(canale == k ? Self.coloriCanali[k] : .clear, lineWidth: 1.5))
                                .foregroundStyle(Self.coloriCanali[k])
                        }
                        .buttonStyle(StilePulsante())
                    }
                }
            }
            // altezza fissa: la curva resta tutta dentro lo schermo
            CurveEditor(curva: curva, modo: modo, etichetta: { [tipo, canale] p in tipo.etichetta(p, canale: canale) })
                .id("\(tipo.rawValue)\(canale)")
                .frame(height: tipo == .custom ? 190 : 160)
            // curve di tinta: i sei colori, come i pulsanti sotto le curve di DaVinci
            if tipo.diTinta, let kp = tipo.curva {
                HStack(spacing: 6) {
                    ForEach(0..<6) { k in
                        Button { studio.nodo.grade[keyPath: kp].aggiungiTre(Float(k) / 6, periodica: true) } label: {
                            Circle().fill(Color(hue: Double(k) / 6, saturation: 0.85, brightness: 0.95))
                                .frame(width: 26, height: 26)
                                .overlay(Circle().stroke(Color.white.opacity(0.4), lineWidth: 1))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(StilePulsante())
                        .accessibilityLabel(["Rossi", "Gialli", "Verdi", "Ciano", "Blu", "Magenta"][k])
                    }
                }
            }
            if tipo == .custom {
                let k = [\SIMD4<Float>.x, \SIMD4<Float>.y, \SIMD4<Float>.z, \SIMD4<Float>.w][canale]
                Regolazione(nome: "Intensità \(["Y", "R", "G", "B"][canale])",
                            valore: Binding(get: { studio.nodo.grade.intensitaCurve[keyPath: k] }, set: { studio.nodo.grade.intensitaCurve[keyPath: k] = $0 }),
                            intervallo: 0...1, base: 1, formato: "%.2f")
                DisclosureGroup(isExpanded: $softClip) {
                    VStack(spacing: 6) {
                        HStack(spacing: 12) {
                            Regolazione(nome: "Basso", valore: $studio.nodo.grade.clipBasso, intervallo: 0...0.3, base: 0, formato: "%.2f")
                            Regolazione(nome: "Morbido basso", valore: $studio.nodo.grade.morbidoBasso, intervallo: 0...1, base: 0, formato: "%.2f")
                        }
                        HStack(spacing: 12) {
                            Regolazione(nome: "Alto", valore: $studio.nodo.grade.clipAlto, intervallo: 0.7...1, base: 1, formato: "%.2f")
                            Regolazione(nome: "Morbido alto", valore: $studio.nodo.grade.morbidoAlto, intervallo: 0...1, base: 0, formato: "%.2f")
                        }
                        Text("Morbido alto recupera le luci bruciate con un passaggio dolce; Morbido basso fa lo stesso con i neri chiusi.")
                            .font(.caption2).foregroundStyle(Tema.testo2).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.top, 6)
                } label: {
                    Text("Soft Clip").font(.caption.weight(.semibold))
                }
                .tint(Tema.accento)
            }
            Text(tipo.spiegazione)
                .font(.caption2).foregroundStyle(Tema.testo2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onDisappear { if studio.contagocce == .curva { studio.contagocce = .nessuno } }
    }
}

// MARK: - Color Warper

struct PannelloWarper: View {
    @ObservedObject var studio: Studio
    @State private var preso: Int?
    @State private var inizio: SIMD2<Float> = .zero

    private static let nt = Grade.warperTinte, na = Grade.warperAnelli
    private static func angolo(_ h: Float) -> Float { (103 + h * 360) * .pi / 180 }

    /// Posizione a schermo di un punto della griglia (con il suo spostamento).
    private func punto(_ i: Int, _ r: CGFloat, _ c: CGPoint) -> CGPoint {
        let tinta = i % PannelloWarper.nt, anello = i / PannelloWarper.nt + 1
        let d = studio.nodo.grade.warper[i]
        let a = PannelloWarper.angolo(Float(tinta) / Float(PannelloWarper.nt) + d.x)
        let rr = CGFloat(min(1.2, max(0, Float(anello) / Float(PannelloWarper.na) + d.y))) * r
        return CGPoint(x: c.x + CGFloat(cos(a)) * rr, y: c.y - CGFloat(sin(a)) * rr)
    }

    private func vicino(_ q: CGPoint, _ r: CGFloat, _ c: CGPoint) -> Int? {
        var best: (Int, CGFloat)?
        for i in 0..<(PannelloWarper.nt * PannelloWarper.na) {
            let p = punto(i, r, c), d = hypot(p.x - q.x, p.y - q.y)
            if d < 30, d < (best?.1 ?? .infinity) { best = (i, d) }
        }
        return best?.0
    }

    /// Nuova posizione in coordinate polari → spostamento di tinta e saturazione del punto.
    private func porta(_ i: Int, a q: CGPoint, _ r: CGFloat, _ c: CGPoint) {
        let dx = Float(q.x - c.x), dy = Float(c.y - q.y)
        let a = atan2(dy, dx), rr = (dx * dx + dy * dy).squareRoot() / Float(r)
        let tinta = Float(i % PannelloWarper.nt) / Float(PannelloWarper.nt), anello = Float(i / PannelloWarper.nt + 1) / Float(PannelloWarper.na)
        var dh = (a * 180 / .pi - 103) / 360 - tinta
        dh -= dh.rounded()
        studio.nodo.grade.warper[i] = SIMD2(max(-0.25, min(0.25, dh)), max(-anello, min(0.5, rr - anello)))
    }

    /// Come il Color Warper di DaVinci: campo tinta/saturazione, griglia, i colori del video sotto, e a fianco gli strumenti.
    var body: some View {
        Group {
            if suMonitor {
                HStack(alignment: .top, spacing: 10) { grafico; strumenti.frame(width: 230) }
            } else {
                VStack(spacing: 10) { grafico.aspectRatio(1.15, contentMode: .fit); strumenti }
            }
        }
        .task(id: studio.risultato?.hash) { campioni = PannelloWarper.campiona(studio.risultato) }
    }

    @Environment(\.suMonitor) private var suMonitor
    /// Punto scelto (resta acceso dopo il trascinamento, come in DaVinci).
    @State private var scelto: Int?
    /// I colori del video (tinta, saturazione) da disegnare sotto la griglia, come il vettorscopio di DaVinci.
    @State private var campioni: [SIMD2<Float>] = []

    private var grafico: some View {
        GeometryReader { g in
            let r = min(g.size.width, g.size.height) / 2.2 - 6
            let c = CGPoint(x: g.size.width / 2, y: g.size.height / 2)
            Canvas { ctx, size in
                // fondo scuro con il campo dei colori: tinte attorno, grigio al centro
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.07)))
                for k in 0..<120 {
                    let h = Double(k) / 120
                    let a0 = Double(PannelloWarper.angolo(Float(h) - 1 / 240)), a1 = Double(PannelloWarper.angolo(Float(h) + 1 / 240))
                    var p = Path(); p.move(to: c)
                    p.addArc(center: c, radius: r * 1.15, startAngle: .radians(-a0), endAngle: .radians(-a1), clockwise: true)
                    ctx.fill(p, with: .color(Color(hue: h, saturation: 0.85, brightness: 0.42)))
                }
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r * 1.15, y: c.y - r * 1.15, width: r * 2.3, height: r * 2.3)),
                         with: .radialGradient(Gradient(colors: [Color(white: 0.32), Color(white: 0.32).opacity(0)]), center: c, startRadius: 0, endRadius: r * 1.15))
                // i colori del video
                for v in campioni {
                    let a = PannelloWarper.angolo(v.x)
                    let rr = CGFloat(min(1.15, v.y)) * r
                    let q = CGPoint(x: c.x + CGFloat(cos(a)) * rr, y: c.y - CGFloat(sin(a)) * rr)
                    ctx.fill(Path(ellipseIn: CGRect(x: q.x - 0.8, y: q.y - 0.8, width: 1.6, height: 1.6)), with: .color(.white.opacity(0.35)))
                }
                // griglia deformata: anelli e raggi bianchi sottili
                var gr = Path()
                for a in 0..<PannelloWarper.na {
                    for t in 0..<PannelloWarper.nt {
                        let i = a * PannelloWarper.nt + t, j = a * PannelloWarper.nt + (t + 1) % PannelloWarper.nt
                        gr.move(to: punto(i, r, c)); gr.addLine(to: punto(j, r, c))
                        if a > 0 { gr.move(to: punto(i, r, c)); gr.addLine(to: punto(i - PannelloWarper.nt, r, c)) }
                        else { gr.move(to: c); gr.addLine(to: punto(i, r, c)) }
                    }
                }
                ctx.stroke(gr, with: .color(.white.opacity(0.55)), lineWidth: 1)
                // punti: bianchi con il bordo scuro; spostati pieni; quello scelto arancione
                for i in 0..<(PannelloWarper.nt * PannelloWarper.na) {
                    let q = punto(i, r, c)
                    let acceso = scelto == i || preso == i
                    let s: CGFloat = acceso ? 6 : 4
                    let rett = CGRect(x: q.x - s, y: q.y - s, width: 2 * s, height: 2 * s)
                    ctx.fill(Path(ellipseIn: rett), with: .color(acceso ? Tema.accento : (studio.nodo.grade.warper[i] != .zero ? .white : Color(white: 0.85))))
                    ctx.stroke(Path(ellipseIn: rett), with: .color(.black.opacity(0.7)), lineWidth: 1)
                }
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)), with: .color(.white))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if preso == nil { preso = vicino(v.startLocation, r, c); scelto = preso }
                    if let i = preso { porta(i, a: v.location, r, c) }
                }
                .onEnded { _ in preso = nil })
            // sul monitor col mouse: tieni premuto e muovi un punto; tasto destro lo rimette a posto
            .zonaEditor(clic: { q in scelto = vicino(q, r, c) },
                        inizia: { q in preso = vicino(q, r, c); if preso != nil { scelto = preso } },
                        muovi: { q in if let i = preso { porta(i, a: q, r, c) } },
                        destro: { q in if let i = vicino(q, r, c) { studio.nodo.grade.warper[i] = .zero } })
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(white: 0.22)))
    }

    /// Pannello "Tools" di DaVinci, in piccolo: tinte, valori del punto scelto, ripristini.
    private var strumenti: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Strumenti").font(.system(size: 12, weight: .semibold))
            Text("Range").font(.system(size: 11)).foregroundStyle(Tema.testo2)
            LinearGradient(colors: (0...12).map { Color(hue: Double($0) / 12, saturation: 0.85, brightness: 0.9) }, startPoint: .leading, endPoint: .trailing)
                .frame(height: 12).clipShape(RoundedRectangle(cornerRadius: 3))
            HStack(spacing: 14) {
                valore("Hue", scelto.map { String(format: "%+.0f°", studio.nodo.grade.warper[$0].x * 360) } ?? "–")
                valore("Sat", scelto.map { String(format: "%+.2f", studio.nodo.grade.warper[$0].y) } ?? "–")
            }
            HStack(spacing: 8) {
                Button { if let i = scelto { studio.nodo.grade.warper[i] = .zero } } label: {
                    Label("Azzera punto", systemImage: "arrow.uturn.backward").font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 8).frame(height: 26).background(RoundedRectangle(cornerRadius: 5).fill(Tema.campo))
                }
                .buttonStyle(StilePulsante())
                .disabled(scelto == nil)
                Button { studio.nodo.grade.warper = Array(repeating: .zero, count: Grade.warperTinte * Grade.warperAnelli); scelto = nil } label: {
                    Label("Azzera tutto", systemImage: "arrow.counterclockwise").font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 8).frame(height: 26).background(RoundedRectangle(cornerRadius: 5).fill(Tema.campo))
                }
                .buttonStyle(StilePulsante())
            }
            Text("Trascina un punto: girando cambia la tinta, verso il bordo la saturazione. I puntini chiari sotto sono i colori del video.")
                .font(.system(size: 10)).foregroundStyle(Tema.testo2)
        }
        .foregroundStyle(Color(white: 0.9))
    }

    private func valore(_ nome: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(nome).font(.system(size: 10)).foregroundStyle(Tema.testo2)
            Text(v).font(.system(size: 12, design: .monospaced))
        }
    }

    /// Tinta e saturazione di una griglia di pixel dell'immagine (piccola: serve solo da guida).
    static func campiona(_ img: UIImage?) -> [SIMD2<Float>] {
        guard let cg = img?.cgImage else { return [] }
        let w = 64, h = 36
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var r: [SIMD2<Float>] = []
        r.reserveCapacity(w * h)
        for k in 0..<(w * h) {
            var hue: CGFloat = 0, sat: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(red: CGFloat(px[k * 4]) / 255, green: CGFloat(px[k * 4 + 1]) / 255, blue: CGFloat(px[k * 4 + 2]) / 255, alpha: 1)
                .getHue(&hue, saturation: &sat, brightness: &b, alpha: &a)
            r.append(SIMD2(Float(hue), Float(sat)))
        }
        return r
    }
}

// MARK: - RGB Mixer e Color Slice

struct PannelloMixer: View {
    @ObservedObject var studio: Studio
    @State private var vista = 0

    var body: some View {
        VStack(spacing: 8) {
            Picker("", selection: $vista) {
                Text("RGB Mixer").tag(0)
                Text("Color Slice").tag(1)
            }
            .pickerStyle(.segmented)
            .sceltaMonitor($vista, [0, 1])
            if vista == 0 { mixer } else { slice }
        }
    }

    private var mixer: some View {
        VStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { r in
                VStack(alignment: .leading, spacing: 2) {
                    Text("Uscita \(["Rosso", "Verde", "Blu"][r])").font(.caption.weight(.semibold))
                        .foregroundStyle([Color.red, .green, .blue][r])
                    HStack(spacing: 10) {
                        ForEach(0..<3, id: \.self) { k in
                            Regolazione(nome: ["R", "G", "B"][k], valore: $studio.nodo.grade.mixer[r * 3 + k], intervallo: -2...2, base: r == k ? 1 : 0)
                        }
                    }
                }
            }
            HStack {
                Toggle("Mantieni luminanza", isOn: $studio.nodo.grade.mixerPreservaLuma)
                Toggle("Bianco e nero", isOn: $studio.nodo.grade.mixerMono)
            }
            .font(.caption).tint(Tema.accento)
            HStack {
                Button("B/N classico") {
                    studio.nodo.grade.mixer = [0.3, 0.59, 0.11, 0, 1, 0, 0, 0, 1]; studio.nodo.grade.mixerMono = true
                }
                Button("B/N filtro rosso") {
                    studio.nodo.grade.mixer = [0.9, 0.2, -0.1, 0, 1, 0, 0, 0, 1]; studio.nodo.grade.mixerMono = true
                }
                Spacer()
                Button("Azzera") {
                    studio.nodo.grade.mixer = [1, 0, 0, 0, 1, 0, 0, 0, 1]; studio.nodo.grade.mixerMono = false; studio.nodo.grade.mixerPreservaLuma = false
                }
            }
            .font(.caption)
        }
    }

    private var slice: some View {
        VStack(spacing: 6) {
            ForEach(0..<6, id: \.self) { i in
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(Color(hue: Double(i) / 6, saturation: 0.85, brightness: 0.9)).frame(width: 12, height: 12).padding(.top, 3)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(Grade.nomiFette[i]).font(.caption.weight(.semibold))
                        HStack(spacing: 8) {
                            Regolazione(nome: "Tinta", valore: $studio.nodo.grade.fette[i].tinta, intervallo: -1...1, base: 0)
                            Regolazione(nome: "Sat", valore: $studio.nodo.grade.fette[i].saturazione, intervallo: -1...1, base: 0)
                            Regolazione(nome: "Densità", valore: $studio.nodo.grade.fette[i].densita, intervallo: -1...1, base: 0)
                        }
                    }
                }
            }
            Text("Densità: i colori diventano più scuri e \"pieni\", come in pellicola. Tinta e Sat agiscono solo su quella fascia di colore.")
                .font(.caption2).foregroundStyle(Tema.testo2)
        }
    }
}

// MARK: - Qualificatore e Magic Mask

struct PannelloQualificatore: View {
    @ObservedObject var studio: Studio

    var body: some View {
        VStack(spacing: 10) {
            TestataPalette(titolo: "Qualificatore e Magic Mask", modificata: studio.nodo.qualificatore != Qualificatore() || studio.nodo.magic != .nessuna || studio.nodo.sfocaturaMaschera != 0) { studio.nodo.qualificatore = Qualificatore(); studio.nodo.magic = .nessuna; studio.nodo.sfocaturaMaschera = 0 }
            Sezione(titolo: "Magic Mask (selezione automatica)") {
                Picker("Magic Mask", selection: $studio.nodo.magic) {
                    ForEach([MagicMask.nessuna, .persona, .sfondo]) { Text($0.nome).tag($0) }
                }
                .pickerStyle(.segmented)
                .sceltaMonitor($studio.nodo.magic, [MagicMask.nessuna, .persona, .sfondo])
                Picker("Magic Mask AI", selection: $studio.nodo.magic) {
                    Text("Soggetto AI").tag(MagicMask.soggetto)
                    Text("Tutto tranne il soggetto").tag(MagicMask.fuoriSoggetto)
                }
                .pickerStyle(.segmented)
                .sceltaMonitor($studio.nodo.magic, [MagicMask.soggetto, .fuoriSoggetto])
                Text("Persona: solo le persone. Soggetto AI: qualsiasi cosa in primo piano (animali, oggetti, auto…).")
                    .font(.caption2).foregroundStyle(Tema.testo2)
            }
            HStack {
                Toggle("Qualificatore HSL", isOn: $studio.nodo.qualificatore.attivo).tint(Tema.accento)
                Button {
                    studio.contagocce = studio.contagocce == .qualificatore ? .nessuno : .qualificatore
                } label: {
                    Label("Contagocce", systemImage: "eyedropper")
                        .foregroundStyle(studio.contagocce == .qualificatore ? Tema.accento : .white)
                }
            }
            if studio.contagocce == .qualificatore {
                Text("Tocca nell'immagine il colore da isolare (es. il cielo o la pelle).")
                    .font(.caption2).foregroundStyle(Tema.accento)
            }
            VStack(spacing: 0) {
                Regolazione(nome: "Tinta", valore: $studio.nodo.qualificatore.tinta, intervallo: 0...1, base: 0.08)
                LinearGradient(colors: (0...12).map { Color(hue: Double($0) / 12, saturation: 0.85, brightness: 0.9) }, startPoint: .leading, endPoint: .trailing)
                    .frame(height: 5).clipShape(Capsule())
            }
            Regolazione(nome: "Ampiezza tinta", valore: $studio.nodo.qualificatore.larghezzaTinta, intervallo: 0.005...0.5, base: 0.06, formato: "%.3f")
            HStack(spacing: 12) {
                Regolazione(nome: "Sat min", valore: $studio.nodo.qualificatore.satMin, intervallo: 0...1, base: 0.1)
                Regolazione(nome: "Sat max", valore: $studio.nodo.qualificatore.satMax, intervallo: 0...1, base: 1)
            }
            HStack(spacing: 12) {
                Regolazione(nome: "Lum min", valore: $studio.nodo.qualificatore.lumMin, intervallo: 0...1, base: 0)
                Regolazione(nome: "Lum max", valore: $studio.nodo.qualificatore.lumMax, intervallo: 0...1, base: 1)
            }
            HStack(spacing: 12) {
                Regolazione(nome: "Morbidezza", valore: $studio.nodo.qualificatore.morbidezza, intervallo: 0.001...0.3, base: 0.05, formato: "%.3f")
                Regolazione(nome: "Sfocatura maschera", valore: $studio.nodo.sfocaturaMaschera, intervallo: 0...1, base: 0)
            }
            HStack {
                Toggle("Inverti", isOn: $studio.nodo.qualificatore.inverti)
                Toggle("Mostra maschera", isOn: $studio.mostraMaschera)
            }
            .tint(Tema.accento).font(.caption)
            SceltaVistaMaschera(studio: studio)
            Text("Magic Mask, qualificatore e finestre si moltiplicano: la correzione del nodo vale solo dove sono tutti \"bianchi\".")
                .font(.caption2).foregroundStyle(Tema.testo2)
        }
    }
}

// MARK: - Finestre e tracker

struct PannelloFinestre: View {
    @ObservedObject var studio: Studio

    private var modificata: Bool { studio.nodo.finestra != Finestra() || !studio.nodo.finestreExtra.isEmpty || studio.nodo.magic != .nessuna }

    var body: some View {
        VStack(spacing: 10) {
            TestataPalette(titolo: "Finestre e Magic Mask", modificata: modificata) {
                studio.nodo.finestra = Finestra(); studio.nodo.finestreExtra = []; studio.finestraScelta = 0
                studio.nodo.magic = .nessuna
            }
            Sezione(titolo: "Magic Mask AI") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach([MagicMask.nessuna, .soggetto, .fuoriSoggetto, .persona, .sfondo]) { m in
                            Button {
                                studio.nodo.magic = m
                                if m != .nessuna { studio.mostraMaschera = true }
                            } label: {
                                Text(m.nome).font(.caption.weight(.semibold))
                                    .padding(.horizontal, 10).frame(height: 30)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(studio.nodo.magic == m ? Tema.accento.opacity(0.25) : Tema.campo))
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(studio.nodo.magic == m ? Tema.accento : .clear, lineWidth: 1.5))
                                    .foregroundStyle(studio.nodo.magic == m ? Tema.accento : .white)
                            }
                            .buttonStyle(StilePulsante())
                        }
                    }
                }
                Text("Soggetto: qualsiasi cosa in primo piano (persone, animali, oggetti). Persona: solo le persone. Con le finestre vale solo dove ci sono tutte e due.")
                    .font(.caption2).foregroundStyle(Tema.testo2)
            }
            // elenco delle finestre del nodo
            HStack(spacing: 6) {
                if studio.nodo.haFinestre {
                    ForEach(0..<studio.numeroFinestre, id: \.self) { i in
                        let f = i == 0 ? studio.nodo.finestra : studio.nodo.finestreExtra[i - 1]
                        Button { studio.finestraScelta = i } label: {
                            HStack(spacing: 3) {
                                Image(systemName: f.tipo == .lineare ? "line.diagonal" : "circle").font(.system(size: 11))
                                Text("\(i + 1)").font(.caption.bold())
                                if !f.traccia.isEmpty { Image(systemName: "scope").font(.system(size: 9)) }
                            }
                            .frame(minWidth: 40).frame(height: 30)
                            .background(RoundedRectangle(cornerRadius: 6).fill(studio.finestraScelta == i ? Tema.accento.opacity(0.25) : Tema.campo))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(studio.finestraScelta == i ? Tema.accento : .clear, lineWidth: 1.5))
                            .foregroundStyle(studio.finestraScelta == i ? Tema.accento : .white)
                        }
                        .buttonStyle(StilePulsante())
                    }
                }
                Button { studio.aggiungiFinestra() } label: {
                    Label(studio.nodo.haFinestre ? "Aggiungi" : "Aggiungi finestra", systemImage: "plus")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Tema.campo))
                }
                .buttonStyle(StilePulsante())
                .disabled(studio.numeroFinestre >= 8)
                Spacer(minLength: 0)
            }
            if studio.nodo.haFinestre && studio.finestraCorrente.tipo != .nessuna {
                HStack {
                    Picker("Forma", selection: $studio.finestraCorrente.tipo) {
                        Text("Cerchio").tag(Finestra.Tipo.cerchio)
                        Text("Lineare").tag(Finestra.Tipo.lineare)
                    }
                    .pickerStyle(.segmented)
                    .sceltaMonitor($studio.finestraCorrente.tipo, [Finestra.Tipo.cerchio, .lineare])
                    Button(role: .destructive) { studio.togliFinestra() } label: {
                        Image(systemName: "trash").frame(width: 34, height: 30)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Tema.campo))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(StilePulsante())
                    .accessibilityLabel("Togli questa finestra")
                }
                Text("Trascina sull'immagine per spostare la finestra \(studio.finestraScelta + 1).")
                    .font(.caption2).foregroundStyle(Tema.accento)
                if studio.finestraCorrente.tipo == .cerchio {
                    Regolazione(nome: "Dimensione", valore: $studio.finestraCorrente.raggio, intervallo: 0.02...1, base: 0.25)
                } else {
                    Regolazione(nome: "Angolo", valore: $studio.finestraCorrente.angolo, intervallo: 0...360, base: 90, formato: "%.0f°")
                }
                HStack(spacing: 12) {
                    Regolazione(nome: "Morbidezza", valore: $studio.finestraCorrente.morbidezza, intervallo: 0.01...1, base: 0.3)
                    Regolazione(nome: "Sfocatura maschera", valore: $studio.nodo.sfocaturaMaschera, intervallo: 0...1, base: 0)
                }
                Toggle("Inverti", isOn: $studio.finestraCorrente.inverti)
                    .tint(Tema.accento).font(.caption)
            }
            if studio.eVideo { SezioneTracker(studio: studio) }
            if studio.nodo.haMaschera {
                Toggle("Mostra maschera", isOn: $studio.mostraMaschera)
                    .tint(Tema.accento).font(.caption)
                SceltaVistaMaschera(studio: studio)
            }
            Text("Con le finestre la correzione del nodo vale solo dentro le forme: con più finestre vale dentro una qualsiasi (es. due volti). Per escludere una zona usa Inverti.")
                .font(.caption2).foregroundStyle(Tema.testo2)
        }
    }
}

/// Tracker della finestra scelta: avanti, indietro, entrambi, un fotogramma alla volta (come la palette Tracker di DaVinci).
struct SezioneTracker: View {
    @ObservedObject var studio: Studio

    private var conFinestra: Bool { studio.nodo.haFinestre && studio.finestraCorrente.tipo != .nessuna }

    var body: some View {
        let traccia = studio.finestraCorrente.traccia
        Sezione(titolo: conFinestra ? "Tracker (finestra \(studio.finestraScelta + 1))" : "Tracker") {
            Button { Task { await studio.seguiVolto() } } label: {
                Label("Segui volto (AI)", systemImage: "face.smiling").font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity).frame(height: 38)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Tema.accento.opacity(0.2)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Tema.accento.opacity(0.6), lineWidth: 1))
                    .foregroundStyle(studio.tracciando || studio.lavoro != nil ? Tema.testo2 : Tema.accento)
            }
            .buttonStyle(StilePulsante())
            .disabled(studio.tracciando || studio.lavoro != nil)
            if conFinestra {
            HStack(spacing: 6) {
                bottone("backward.fill", "Indietro", .indietro)
                bottone("backward.frame.fill", "1 fot.", .fotogrammaIndietro)
                bottone("arrow.left.and.right", "Entrambi", .entrambi)
                bottone("forward.frame.fill", "1 fot.", .fotogrammaAvanti)
                bottone("forward.fill", "Avanti", .avanti)
            }
            }
            if studio.tracciando {
                Button(role: .destructive) { studio.fermaTracking() } label: {
                    Label("Ferma", systemImage: "stop.fill").font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity).frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Tema.campo))
                }
                .buttonStyle(StilePulsante())
            }
            HStack(spacing: 6) {
                Text("Segue:").font(.caption).foregroundStyle(Tema.testo2)
                interruttore("Posizione", .constant(true)).disabled(true)
                interruttore("Dimensione", $studio.tracciaDimensione)
                interruttore("Rotazione", $studio.tracciaRotazione)
                Spacer(minLength: 0)
            }
            if let primo = traccia.first, let ultimo = traccia.last {
                HStack {
                    Text("\(traccia.count) fotogrammi · da \(String(format: "%.2f", primo.tempo)) a \(String(format: "%.2f", ultimo.tempo)) s")
                        .font(.caption).foregroundStyle(Tema.testo2)
                    Spacer()
                    Button("Cancella traccia", role: .destructive) { studio.cancellaTraccia() }.font(.caption)
                        .disabled(studio.tracciando)
                }
            }
            Text("Segui volto: porta la testina dove la faccia si vede bene e premi; la finestra la trova da sola (con più facce, quella più vicina alla finestra) e la segue in tutta la clip. Per altri oggetti: mettici sopra la finestra e scegli la direzione; la segue anche se si avvicina o ruota. Trascinandola si sposta tutta la traccia.")
                .font(.caption2).foregroundStyle(Tema.testo2)
        }
    }

    private func bottone(_ icona: String, _ titolo: String, _ modo: Studio.ModoTracking) -> some View {
        Button { Task { await studio.traccia(modo) } } label: {
            VStack(spacing: 2) {
                Image(systemName: icona).font(.system(size: 15, weight: .semibold))
                Text(titolo).font(.system(size: 9, weight: .medium))
            }
            .frame(maxWidth: .infinity).frame(height: 42)
            .background(RoundedRectangle(cornerRadius: 6).fill(Tema.campo))
        }
        .buttonStyle(StilePulsante())
        .foregroundStyle(studio.tracciando || studio.lavoro != nil ? Tema.testo2 : .white)
        .disabled(studio.tracciando || studio.lavoro != nil)
        .accessibilityLabel(modo == .fotogrammaAvanti ? "Un fotogramma avanti" : modo == .fotogrammaIndietro ? "Un fotogramma indietro" : titolo)
    }

    private func interruttore(_ titolo: String, _ valore: Binding<Bool>) -> some View {
        Button { valore.wrappedValue.toggle() } label: {
            Text(titolo).font(.caption.weight(.semibold))
                .padding(.horizontal, 8).frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(valore.wrappedValue ? Tema.accento.opacity(0.25) : Tema.campo))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(valore.wrappedValue ? Tema.accento : .clear, lineWidth: 1.2))
                .foregroundStyle(valore.wrappedValue ? Tema.accento : Tema.testo2)
        }
        .buttonStyle(StilePulsante())
    }
}

/// Come si vede la maschera quando "Mostra maschera" è acceso.
struct SceltaVistaMaschera: View {
    @ObservedObject var studio: Studio

    var body: some View {
        if studio.mostraMaschera {
            VStack(alignment: .leading, spacing: 4) {
                Picker("Vista maschera", selection: $studio.mascheraBN) {
                    Text("Trasparente").tag(false)
                    Text("Bianco e nero").tag(true)
                }
                .pickerStyle(.segmented)
                .sceltaMonitor($studio.mascheraBN, [false, true])
                Text(studio.mascheraBN ? "Bianco = dove agisce la correzione." : "Vedi le correzioni dentro la maschera mentre le fai; fuori l'immagine è grigia.")
                    .font(.caption2).foregroundStyle(Tema.testo2)
            }
        }
    }
}

// MARK: - Effetti

struct PannelloEffetti: View {
    @ObservedObject var studio: Studio
    var body: some View {
        VStack(spacing: 10) {
            TestataPalette(titolo: "Effetti", modificata: studio.nodo.effetti.attivi) { studio.nodo.effetti = Effetti() }
            Sezione(titolo: "Dettaglio") {
                HStack(spacing: 12) {
                    Regolazione(nome: "Nitidezza", valore: $studio.nodo.effetti.nitidezza, intervallo: 0...1, base: 0)
                    Regolazione(nome: "Midtone Detail", valore: $studio.nodo.effetti.dettaglio, intervallo: -1...1, base: 0)
                }
                HStack(spacing: 12) {
                    Regolazione(nome: "Riduzione rumore", valore: $studio.nodo.effetti.rumore, intervallo: 0...1, base: 0)
                    Regolazione(nome: "Sfocatura", valore: $studio.nodo.effetti.sfocatura, intervallo: 0...1, base: 0)
                }
            }
            Sezione(titolo: "Look pellicola") {
                HStack(spacing: 12) {
                    Regolazione(nome: "Grana", valore: $studio.nodo.effetti.grana, intervallo: 0...1, base: 0)
                    Regolazione(nome: "Dimensione grana", valore: $studio.nodo.effetti.granaGrossa, intervallo: 0...1, base: 0.4)
                }
                HStack(spacing: 12) {
                    Regolazione(nome: "Halation", valore: $studio.nodo.effetti.halation, intervallo: 0...1, base: 0)
                    Regolazione(nome: "Glow", valore: $studio.nodo.effetti.glow, intervallo: 0...1, base: 0)
                }
                Regolazione(nome: "Soglia luci (glow/halation)", valore: $studio.nodo.effetti.soglia, intervallo: 0.3...0.98, base: 0.75)
            }
            Text("Gli effetti lavorano sui pixel vicini: valgono per foto e video, ma non entrano in una LUT. Se il nodo ha una maschera, gli effetti restano dentro la maschera.")
                .font(.caption2).foregroundStyle(Tema.testo2)
        }
    }
}

// MARK: - Regolazioni

struct PannelloRegolazioni: View {
    @ObservedObject var studio: Studio

    var body: some View {
        VStack(spacing: 10) {
            TestataPalette(titolo: "Regolazioni", modificata: studio.nodo.grade.regolazioniModificate) { studio.nodo.grade.azzeraRegolazioni() }
            HStack(spacing: 12) {
                Regolazione(nome: "Esposizione", valore: $studio.nodo.grade.esposizione, intervallo: -3...3, base: 0)
                Regolazione(nome: "Temperatura", valore: $studio.nodo.grade.temperatura, intervallo: -1...1, base: 0)
            }
            HStack(spacing: 12) {
                Regolazione(nome: "Tinta", valore: $studio.nodo.grade.tinta, intervallo: -1...1, base: 0)
                Regolazione(nome: "Color Boost", valore: $studio.nodo.grade.colorBoost, intervallo: -1...1, base: 0)
            }
            HStack(spacing: 12) {
                Regolazione(nome: "Ombre", valore: $studio.nodo.grade.ombre, intervallo: -1...1, base: 0)
                Regolazione(nome: "Luci", valore: $studio.nodo.grade.luci, intervallo: -1...1, base: 0)
            }
            HStack(spacing: 12) {
                Regolazione(nome: "Saturazione", valore: $studio.nodo.grade.saturazione, intervallo: 0...2, base: 1)
                Regolazione(nome: "Rotazione tinta", valore: $studio.nodo.grade.rotazioneTinta, intervallo: -180...180, base: 0, formato: "%.0f°")
            }
            HStack(spacing: 12) {
                Regolazione(nome: "Contrasto", valore: $studio.nodo.grade.contrasto, intervallo: 0...2, base: 1)
                Regolazione(nome: "Pivot", valore: $studio.nodo.grade.pivot, intervallo: 0...1, base: 0.435, formato: "%.3f")
            }
            Text("Doppio tocco sul nome di un cursore per azzerarlo.")
                .font(.caption2).foregroundStyle(Tema.testo2)
        }
    }
}

// MARK: - CST

struct PannelloCST: View {
    @ObservedObject var studio: Studio

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if studio.nodo.tipo != .cst {
                Text("Il Color Space Transform trasforma il footage Log della camera in Rec.709. Si aggiunge come nodo a sé, all'inizio della catena.")
                    .font(.caption).foregroundStyle(Tema.testo2)
                Button { studio.aggiungi(.cst) } label: { Label("Aggiungi nodo CST", systemImage: "plus") }
            } else {
                TestataPalette(titolo: "Color Space Transform", modificata: studio.nodo.cst.esposizione != 0 || !studio.nodo.cst.toneMapping || !studio.nodo.cst.compressioneGamut) { let cam = studio.nodo.cst.camera; studio.nodo.cst = CST(camera: cam) }
                Picker("Camera / gamma di ingresso", selection: $studio.nodo.cst.camera) {
                    ForEach(CST.Camera.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                .menuMonitor($studio.nodo.cst.camera, CST.Camera.allCases, nome: { $0.rawValue })
                HStack {
                    Text("Uscita").font(.caption)
                    Spacer()
                    Text("Rec.709 · Gamma 2.4").font(.caption).foregroundStyle(Tema.testo2)
                }
                Regolazione(nome: "Esposizione (stop)", valore: $studio.nodo.cst.esposizione, intervallo: -3...3, base: 0)
                Toggle("Tone mapping (recupera le alte luci)", isOn: $studio.nodo.cst.toneMapping).tint(Tema.accento).font(.caption)
                Toggle("Gamut mapping (i colori fuori gamma rientrano morbidi)", isOn: $studio.nodo.cst.compressioneGamut).tint(Tema.accento).font(.caption)
                Text("Per il footage Blackmagic girato in \"Film\": scegli Blackmagic Film Gen 5. Metti le correzioni nei nodi dopo il CST.")
                    .font(.caption2).foregroundStyle(Tema.testo2)
            }
        }
    }
}

struct PannelloLUTNodo: View {
    @ObservedObject var studio: Studio
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let l = studio.nodo.lut {
                Text("LUT: \(l.titolo)").font(.subheadline)
                Text(l.descrizione).font(.caption).foregroundStyle(Tema.testo2)
            }
            Text("Questo nodo applica una LUT importata. Spegnilo o spostalo dal grafo dei nodi (tieni premuto sul nodo).")
                .font(.caption2).foregroundStyle(Tema.testo2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Galleria e versioni

struct PannelloGalleria: View {
    @ObservedObject var studio: Studio

    var body: some View {
        VStack(spacing: 10) {
            Sezione(titolo: "Color Match · copia i colori di un'altra inquadratura") {
                let altre = studio.progetto.clips.filter { $0.id != studio.clipAttiva }
                if altre.isEmpty && studio.progetto.stills.isEmpty {
                    Text("Serve un riferimento: un'altra clip nel progetto o uno still nella galleria.").font(.caption2).foregroundStyle(Tema.testo2)
                } else {
                    if !altre.isEmpty {
                        Menu {
                            ForEach(altre) { c in Button(c.nome) { Task { await studio.colorMatch(clip: c.id) } } }
                        } label: { Label("Abbina a una clip…", systemImage: "wand.and.rays") }
                        .font(.subheadline)
                    }
                    Text("Aggiunge un nodo \"Color Match\" che porta livelli e colori di questa clip verso il riferimento. Per gli still: tieni premuto e scegli Color Match.")
                        .font(.caption2).foregroundStyle(Tema.testo2)
                }
            }
            HStack {
                Button { studio.catturaStill() } label: { Label("Cattura still", systemImage: "camera.viewfinder") }
                Spacer()
                Button { studio.salvaVersione() } label: { Label("Salva versione", systemImage: "square.stack.3d.up") }
            }
            .font(.subheadline)
            Sezione(titolo: "Stills · tocca per confrontare (split-screen), tieni premuto per applicare") {
                if studio.progetto.stills.isEmpty {
                    Text("Nessuno still. Cattura il fotogramma di un'inquadratura riuscita per far combaciare le altre.")
                        .font(.caption2).foregroundStyle(Tema.testo2)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], spacing: 6) {
                    ForEach(studio.progetto.stills) { s in
                        VStack(spacing: 2) {
                            if let img = Archivio.immagine("Stills", s.file) {
                                Image(uiImage: img).resizable().scaledToFill().frame(height: 56).clipped()
                            }
                            Text(s.nome).font(.system(size: 9)).lineLimit(1)
                        }
                        .padding(3)
                        .background(RoundedRectangle(cornerRadius: 5).stroke(studio.confronto?.id == s.id ? Tema.accento : Tema.bordo, lineWidth: studio.confronto?.id == s.id ? 2 : 1))
                        .onTapGesture { studio.confronto = studio.confronto?.id == s.id ? nil : s }
                        .contextMenu {
                            Button { studio.applicaStill(s) } label: { Label("Applica questa correzione", systemImage: "wand.and.rays") }
                            Button { studio.colorMatch(still: s) } label: { Label("Color Match da questo still", systemImage: "eyedropper.halffull") }
                            Button { studio.confronto = s } label: { Label("Confronta", systemImage: "rectangle.split.2x1") }
                            Button(role: .destructive) { studio.eliminaStill(s) } label: { Label("Elimina", systemImage: "trash") }
                        }
                    }
                }
            }
            Sezione(titolo: "Versioni della clip") {
                let versioni = studio.clipCorrente?.versioni ?? []
                if versioni.isEmpty {
                    Text("Salva più versioni della correzione per provare look diversi sulla stessa clip.")
                        .font(.caption2).foregroundStyle(Tema.testo2)
                }
                ForEach(versioni) { v in
                    HStack {
                        Button(v.nome) { studio.caricaVersione(v) }
                        Spacer()
                        Text("\(v.nodi.count) nodi").font(.caption2).foregroundStyle(Tema.testo2)
                        Button(role: .destructive) { studio.eliminaVersione(v) } label: { Image(systemName: "trash") }
                    }
                    .font(.caption)
                }
            }
        }
    }
}

// MARK: - Consegna

struct PannelloConsegna: View {
    @ObservedObject var studio: Studio
    @Binding var nomeLUT: String
    @Binding var dimensioneLUT: Int
    var salvaLUT: () -> Void
    var importaLUT: () -> Void
    var salvaTutte: () -> Void
    var salvaCDL: () -> Void
    @State private var foto: Image?
    @State private var formato: FormatoVideo = .prores
    @State private var guida = false
    @State private var social: FormatoSocial = .reel
    @State private var riempi = true
    @State private var fotoPerSocial: Image?
    @State private var montaggioIntero = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            sezioneSocial
            Sezione(titolo: "Esporta LUT (.cube, come \"Generate LUT\" di DaVinci)") {
                TextField("Nome", text: $nomeLUT).textFieldStyle(.roundedBorder)
                Picker("Punti", selection: $dimensioneLUT) {
                    Text("17").tag(17); Text("33").tag(33); Text("65").tag(65)
                }
                .pickerStyle(.segmented)
                .sceltaMonitor($dimensioneLUT, [17, 33, 65])
                Button(action: salvaLUT) { Label("Salva LUT di questa clip", systemImage: "cube") }
                if studio.progetto.clips.count > 1 {
                    Button(action: salvaTutte) { Label("Salva una LUT per ogni clip (\(studio.progetto.clips.count))", systemImage: "square.stack.3d.down.right") }
                }
                Text("Funziona in DaVinci, Premiere, Final Cut e nelle camere. I nodi con maschere o effetti non entrano in una LUT.")
                    .font(.caption2).foregroundStyle(Tema.testo2)
            }
            Sezione(titolo: "Esporta CDL (Galleria di DaVinci)") {
                Button(action: salvaCDL) { Label("Salva correzione come ASC CDL (.cdl)", systemImage: "doc.badge.gearshape") }
                Text("Il CDL contiene solo Slope/Offset/Power e Saturazione: si importa nella Galleria di DaVinci e si applica come grade modificabile. Curve e secondarie non ci stanno: l'app ti dice quanto è fedele.")
                    .font(.caption2).foregroundStyle(Tema.testo2)
            }
            Sezione(titolo: "Importa") {
                Button(action: importaLUT) { Label("LUT (.cube 1D/3D) o CDL (.cdl .cc .ccc) come nodo", systemImage: "square.and.arrow.down") }
            }
            Sezione(titolo: "Portare il lavoro in DaVinci Resolve") {
                Button(guida ? "Nascondi" : "Come si fa") { guida.toggle() }.font(.caption)
                if guida {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("LUT: in DaVinci, pagina Color → tasto destro sul nodo → LUT, oppure copia il .cube nella cartella LUT (Impostazioni progetto → Color Management → Apri cartella LUT → Aggiorna elenchi). Per più clip usa \"una LUT per ogni clip\": hanno il nome della clip.")
                        Text("CDL: pagina Color → Galleria → tasto destro → Importa → scegli il .cdl → tasto destro sullo still → Applica grade.")
                        Text("Il progetto di DaVinci (.drp) e i suoi grade (.drx) sono formati chiusi di Blackmagic: Colors non li scrive. LUT e CDL sono il modo standard di passare una correzione.")
                    }
                    .font(.caption2).foregroundStyle(Tema.testo2)
                }
            }
            if studio.eVideo {
                Sezione(titolo: "Video") {
                    Picker("Formato", selection: $formato) {
                        ForEach(FormatoVideo.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .sceltaMonitor($formato, FormatoVideo.allCases)
                    if let s = studio.lavoro {
                        HStack { ProgressView(); Text(s).font(.caption) }
                    } else {
                        Button { Task { await studio.esportaVideo(formato) } } label: {
                            Label("Esporta video corretto nel Rullino", systemImage: "film")
                        }
                    }
                    Text(formato == .prores ? "ProRes 422 HQ 10 bit: massima qualità per montare o rifinire altrove (file grandi)." : "HEVC: file piccoli, ottimo per condividere.")
                        .font(.caption2).foregroundStyle(Tema.testo2)
                }
            } else {
                Sezione(titolo: "Foto") {
                    if let f = foto {
                        ShareLink(item: f, preview: SharePreview("Foto Colors", image: f)) {
                            Label("Condividi / salva la foto", systemImage: "square.and.arrow.up")
                        }
                    }
                    Button {
                        if let ui = studio.fotoCorretta() { foto = Image(uiImage: ui) }
                    } label: { Label("Prepara foto a piena risoluzione", systemImage: "wand.and.stars") }
                }
            }
        }
    }

    /// Preset per i social, come in Deliver di DaVinci.
    private var sezioneSocial: some View {
        Sezione(titolo: "Social e web") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 6)], spacing: 6) {
                ForEach(FormatoSocial.allCases) { f in
                    Button { social = f; fotoPerSocial = nil } label: {
                        VStack(spacing: 3) {
                            Image(systemName: f.icona).font(.system(size: 15)).frame(height: 18)
                            Text(f.rawValue).font(.system(size: 10, weight: .semibold)).lineLimit(2).multilineTextAlignment(.center)
                                .minimumScaleFactor(0.8).padding(.horizontal, 4)
                            Text(f.rapporto).font(.system(size: 9)).foregroundStyle(Tema.testo2)
                        }
                        .frame(maxWidth: .infinity).frame(height: 70)
                        .background(RoundedRectangle(cornerRadius: 8).fill(social == f ? Tema.accento.opacity(0.22) : Tema.campo))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(social == f ? Tema.accento : .clear, lineWidth: 1.5))
                        .foregroundStyle(social == f ? Tema.accento : .white)
                    }
                    .buttonStyle(StilePulsante())
                }
            }
            Text(social.descrizione).font(.caption2).foregroundStyle(Tema.testo2)
            if studio.progetto.clips.count > 1 {
                Picker("Cosa esportare", selection: $montaggioIntero) {
                    Text("Questa clip").tag(false)
                    Text("Montaggio intero (\(studio.progetto.clips.count) clip)").tag(true)
                }
                .pickerStyle(.segmented)
                .sceltaMonitor($montaggioIntero, [false, true])
            }
            if social != .originale {
                Picker("Inquadratura", selection: $riempi) {
                    Text("Riempi (taglia i bordi)").tag(true)
                    Text("Adatta (bande nere)").tag(false)
                }
                .pickerStyle(.segmented)
                .sceltaMonitor($riempi, [true, false])
                .onChange(of: riempi) { _, _ in fotoPerSocial = nil }
            }
            if studio.eVideo || montaggioIntero {
                if let s = studio.lavoro {
                    HStack { ProgressView(); Text(s).font(.caption) }
                } else {
                    Button { Task { if montaggioIntero { await studio.esportaMontaggio(social, riempi: social == .originale ? false : riempi) } else { await studio.esportaSocial(social, riempi: riempi) } } } label: {
                        Label("Esporta per \(social.rawValue)", systemImage: "paperplane.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity).frame(height: 40)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Tema.accento))
                            .foregroundStyle(.black)
                    }
                    .buttonStyle(StilePulsante())
                }
            } else {
                Button {
                    if let ui = studio.fotoSocial(social, riempi: riempi) { fotoPerSocial = Image(uiImage: ui) }
                } label: {
                    Label("Prepara foto per \(social.rawValue)", systemImage: "wand.and.stars")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity).frame(height: 40)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Tema.accento))
                        .foregroundStyle(.black)
                }
                .buttonStyle(StilePulsante())
                if let f = fotoPerSocial {
                    ShareLink(item: f, preview: SharePreview("Foto \(social.rawValue)", image: f)) {
                        Label("Condividi / salva la foto", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
    }
}

// MARK: - ripristino per palette

extension Grade {
    var primarieModificate: Bool {
        let b = Grade()
        return lift != b.lift || gamma != b.gamma || gain != b.gain || offset != b.offset
            || logOmbre != b.logOmbre || logMedi != b.logMedi || logLuci != b.logLuci || logBasso != b.logBasso || logAlto != b.logAlto
            || contrasto != b.contrasto || pivot != b.pivot || saturazione != b.saturazione || temperatura != b.temperatura
            || nero != b.nero || bilanciamento != b.bilanciamento
    }
    mutating func azzeraPrimarie() {
        let b = Grade()
        lift = b.lift; gamma = b.gamma; gain = b.gain; offset = b.offset
        logOmbre = b.logOmbre; logMedi = b.logMedi; logLuci = b.logLuci; logBasso = b.logBasso; logAlto = b.logAlto
        contrasto = b.contrasto; pivot = b.pivot; saturazione = b.saturazione; temperatura = b.temperatura
        nero = b.nero; bilanciamento = b.bilanciamento
    }
    var regolazioniModificate: Bool {
        let b = Grade()
        return esposizione != b.esposizione || temperatura != b.temperatura || tinta != b.tinta || colorBoost != b.colorBoost
            || ombre != b.ombre || luci != b.luci || saturazione != b.saturazione || rotazioneTinta != b.rotazioneTinta
            || contrasto != b.contrasto || pivot != b.pivot
    }
    mutating func azzeraRegolazioni() {
        let b = Grade()
        esposizione = b.esposizione; temperatura = b.temperatura; tinta = b.tinta; colorBoost = b.colorBoost
        ombre = b.ombre; luci = b.luci; saturazione = b.saturazione; rotazioneTinta = b.rotazioneTinta
        contrasto = b.contrasto; pivot = b.pivot
    }
}