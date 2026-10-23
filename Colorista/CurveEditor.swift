import SwiftUI

/// Editor di curve: tocca per aggiungere un punto, trascina per spostarlo; il punto toccato si toglie con ✕ (o doppio tocco).
struct CurveEditor: View {
    enum Modo: Equatable {
        case personalizzata(Color)   // x e y 0…1, diagonale
        case tinta                   // x = tinta (ad anello), y -1…1
        case lineare(String)         // x = luminanza o saturazione, y -1…1
    }

    @Binding var curva: Curva
    let modo: Modo
    /// Testo del punto selezionato (ingresso → effetto), mostrato in basso a sinistra.
    var etichetta: ((SIMD2<Float>) -> String)? = nil
    @State private var preso: Int?
    @State private var ultimoTocco: (Date, Int)?
    /// Ultimo punto toccato: resta evidenziato e si può togliere con ✕.
    @State private var scelto: Int?

    private var periodica: Bool { modo == .tinta }
    private var centrata: Bool { if case .personalizzata = modo { return false }; return true }

    var body: some View {
        GeometryReader { g in
            let s = g.size
            ZStack {
                Rectangle().fill(Color(white: 0.09))
                Canvas { c, s in disegna(c, s) }
            }
            .contentShape(Rectangle())
            // precedenza sul pannello che scorre: dentro la curva il dito muove i punti
            .highPriorityGesture(DragGesture(minimumDistance: 0)
                .onChanged { v in trascina(v, s) }
                .onEnded { v in fine(v, s) })
            // sul monitor col mouse: tieni premuto e muovi = sposta (o crea) un punto, clic = scegli o aggiungi, destro = togli
            .zonaEditor(clic: { q in scelto = vicino(q, s) ?? aggiungi(daSchermo(q, s)) },
                        inizia: { q in preso = vicino(q, s) ?? aggiungi(daSchermo(q, s)); scelto = preso },
                        muovi: { q in if let i = preso { sposta(i, a: daSchermo(q, s)) } },
                        destro: { q in if let i = vicino(q, s) { togli(i) } })
            .overlay(alignment: .bottomLeading) {
                if let e = etichetta, let i = preso ?? scelto, i < curva.punti.count {
                    Text(e(curva.punti[i]))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(Color.black.opacity(0.7)))
                        .foregroundStyle(Tema.accento)
                        .padding(6).padding(.bottom, centrata ? 10 : 0)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let i = scelto, rimovibile(i) {
                    Button { togli(i) } label: {
                        Label("Togli punto", systemImage: "xmark")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 8).frame(height: 26)
                            .background(Capsule().fill(Color.black.opacity(0.75)))
                            .foregroundStyle(Tema.accento)
                    }
                    .buttonStyle(StilePulsante())
                    .padding(6)
                }
            }
        }
        // curva cambiata da fuori (Azzera, Annulla…): il punto scelto non vale più
        .onChange(of: curva.punti.count) { _, _ in if preso == nil { scelto = nil } }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Tema.bordo))
    }

    // MARK: coordinate

    private func aSchermo(_ p: SIMD2<Float>, _ s: CGSize) -> CGPoint {
        let y = centrata ? (p.y + 1) / 2 : p.y
        return CGPoint(x: CGFloat(p.x) * s.width, y: (1 - CGFloat(y)) * s.height)
    }

    private func daSchermo(_ q: CGPoint, _ s: CGSize) -> SIMD2<Float> {
        let x = Float(min(max(q.x / s.width, 0), 1))
        var y = Float(min(max(1 - q.y / s.height, 0), 1))
        if centrata { y = y * 2 - 1 }
        return SIMD2(x, y)
    }

    private var tabella: [Float] {
        switch modo {
        case .tinta: return Spline.tabellaPeriodica(curva.punti, 180)
        default: return Spline.tabellaMonotona(curva.punti, 180)
        }
    }

    // MARK: disegno

    private func disegna(_ c: GraphicsContext, _ s: CGSize) {
        // sfondo informativo
        if case .tinta = modo {
            let colori = (0...12).map { Color(hue: Double($0) / 12, saturation: 0.8, brightness: 0.8) }
            c.fill(Path(CGRect(x: 0, y: s.height - 10, width: s.width, height: 10)),
                   with: .linearGradient(Gradient(colors: colori), startPoint: .zero, endPoint: CGPoint(x: s.width, y: 0)))
        } else if case let .lineare(asse) = modo {
            let colori: [Color] = asse == "sat" ? [Color(white: 0.5), .red] : [.black, .white]
            c.fill(Path(CGRect(x: 0, y: s.height - 10, width: s.width, height: 10)),
                   with: .linearGradient(Gradient(colors: colori), startPoint: .zero, endPoint: CGPoint(x: s.width, y: 0)))
        }
        // griglia
        var griglia = Path()
        for k in 1..<4 {
            let x = s.width * CGFloat(k) / 4, y = s.height * CGFloat(k) / 4
            griglia.move(to: CGPoint(x: x, y: 0)); griglia.addLine(to: CGPoint(x: x, y: s.height))
            griglia.move(to: CGPoint(x: 0, y: y)); griglia.addLine(to: CGPoint(x: s.width, y: y))
        }
        c.stroke(griglia, with: .color(.white.opacity(0.07)))
        // riferimento: diagonale o linea dello zero
        var rif = Path()
        if centrata { rif.move(to: CGPoint(x: 0, y: s.height / 2)); rif.addLine(to: CGPoint(x: s.width, y: s.height / 2)) }
        else { rif.move(to: CGPoint(x: 0, y: s.height)); rif.addLine(to: CGPoint(x: s.width, y: 0)) }
        c.stroke(rif, with: .color(.white.opacity(0.15)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        // curva
        let t = tabella
        var linea = Path()
        for (j, v) in t.enumerated() {
            let x = periodica ? Float(j) / Float(t.count) : Float(j) / Float(t.count - 1)
            let q = aSchermo(SIMD2(x, curva.punti.isEmpty ? 0 : v), s)
            if j == 0 { linea.move(to: q) } else { linea.addLine(to: q) }
        }
        if periodica, let v = t.first { linea.addLine(to: aSchermo(SIMD2(1, curva.punti.isEmpty ? 0 : v), s)) }
        let colore: Color = { if case let .personalizzata(c) = modo { return c }; return .white }()
        c.stroke(linea, with: .color(colore), lineWidth: 1.6)
        // punti
        for (i, p) in curva.punti.enumerated() {
            let q = aSchermo(p, s)
            let evid = preso == i || scelto == i
            let r: CGFloat = evid ? 6.5 : 5
            c.fill(Path(ellipseIn: CGRect(x: q.x - r, y: q.y - r, width: 2 * r, height: 2 * r)), with: .color(evid ? Tema.accento : .white))
        }
    }

    // MARK: gesti

    private func vicino(_ q: CGPoint, _ s: CGSize) -> Int? {
        var best: (Int, CGFloat)?
        for (i, p) in curva.punti.enumerated() {
            let a = aSchermo(p, s), d = hypot(a.x - q.x, a.y - q.y)
            if d < 26, d < (best?.1 ?? .infinity) { best = (i, d) }
        }
        return best?.0
    }

    private func trascina(_ v: DragGesture.Value, _ s: CGSize) {
        if preso == nil {
            if let i = vicino(v.startLocation, s) { preso = i }
            else { preso = aggiungi(daSchermo(v.startLocation, s)) }
        }
        guard let i = preso else { return }
        sposta(i, a: daSchermo(v.location, s))
    }

    private func sposta(_ i: Int, a punto: SIMD2<Float>) {
        guard i < curva.punti.count else { return }
        var p = punto
        // l'ordine dei punti non cambia: x resta tra i vicini
        let pts = curva.punti
        if i > 0 { p.x = max(p.x, pts[i - 1].x + 0.01) }
        if i < pts.count - 1 { p.x = min(p.x, pts[i + 1].x - 0.01) }
        curva.punti[i] = p
    }

    private func fine(_ v: DragGesture.Value, _ s: CGSize) {
        defer { preso = nil }
        scelto = preso
        guard hypot(v.translation.width, v.translation.height) < 4, let i = preso else { return }
        // doppio tocco sullo stesso punto: lo si toglie
        if let (t, j) = ultimoTocco, j == i, Date().timeIntervalSince(t) < 0.5 {
            togli(i)
            ultimoTocco = nil
        } else {
            ultimoTocco = (Date(), i)
        }
    }

    /// Gli estremi della curva personalizzata restano sempre.
    private func rimovibile(_ i: Int) -> Bool {
        i < curva.punti.count && (centrata || (i != 0 && i != curva.punti.count - 1))
    }

    private func togli(_ i: Int) {
        guard rimovibile(i) else { return }
        curva.punti.remove(at: i)
        // su Hue vs…/Lum vs Sat, se restano solo le due ancore a zero la curva torna piatta
        if centrata && curva.punti.allSatisfy({ abs($0.y) < 0.001 }) { curva.punti = [] }
        scelto = nil
    }

    /// Aggiunge un punto; su una curva di tinta vuota mette anche due "ancore" a zero ai lati.
    private func aggiungi(_ p: SIMD2<Float>) -> Int {
        var pts = curva.punti
        var nuovo = p
        if centrata && pts.isEmpty {
            nuovo.y = 0
            let l = periodica ? (p.x - 0.15 + 1).truncatingRemainder(dividingBy: 1) : max(0, p.x - 0.2)
            let r = periodica ? (p.x + 0.15).truncatingRemainder(dividingBy: 1) : min(1, p.x + 0.2)
            pts = [SIMD2(l, 0), SIMD2(r, 0)]
        } else if !centrata {
            nuovo.y = Spline.leggi(Spline.tabellaMonotona(pts, 256), p.x)   // il nuovo punto nasce sulla curva
        }
        pts.append(nuovo)
        pts.sort { $0.x < $1.x }
        curva.punti = pts
        return pts.firstIndex(of: nuovo) ?? 0
    }
}
