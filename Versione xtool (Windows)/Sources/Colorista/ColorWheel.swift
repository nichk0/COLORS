import SwiftUI

/// Colori dell'interfaccia, sul grigio scuro della pagina Color di DaVinci.
enum Tema {
    static let sfondo = Color(red: 0.105, green: 0.105, blue: 0.115)
    static let pannello = Color(red: 0.155, green: 0.155, blue: 0.165)
    static let campo = Color(red: 0.2, green: 0.2, blue: 0.215)
    static let bordo = Color(white: 0.26)
    static let accento = Color(red: 0.95, green: 0.5, blue: 0.22)
    static let testo2 = Color(white: 0.62)
    static let nodo = Color(red: 0.27, green: 0.27, blue: 0.285)
    static let collegamento = Color(red: 0.35, green: 0.75, blue: 0.45)
}

/// Ruota colore stile "primarie": si trascina il puntino (movimento relativo, fine), doppio tocco per azzerare.
struct ColorWheel: View {
    @Binding var x: Float
    @Binding var y: Float
    /// Falso in una fila che scorre finché la ruota non è selezionata col doppio tocco: il dito fa scorrere la fila.
    var attiva = true
    /// Nella fila che scorre il doppio tocco seleziona la ruota invece di azzerarla.
    var azzeraConDoppioTocco = true
    @State private var inizio: (Float, Float)?

    /// Colori del bordo: gli stessi della matematica (Wheel.direzione), così la ruota "dice la verità".
    static let stop: [Color] = (0...24).map { i in
        // AngularGradient va in senso orario partendo da destra; la matematica in senso antiorario
        let d = Wheel.direzione(-Float(i) / 24 * 2 * .pi)
        let c = limita(SIMD3<Float>(repeating: 0.5) + d * 0.6, .zero, SIMD3(repeating: 1))
        return Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))
    }

    var body: some View {
        GeometryReader { g in
            let r = min(g.size.width, g.size.height) / 2
            ZStack {
                Circle().fill(AngularGradient(colors: ColorWheel.stop, center: .center))
                Circle().fill(Color(white: 0.13)).padding(r * 0.07)
                Circle().fill(RadialGradient(colors: [Color(white: 0.2), Color(white: 0.14)], center: .center, startRadius: 0, endRadius: r))
                    .padding(r * 0.07)
                Path { p in
                    p.move(to: CGPoint(x: r * 0.3, y: r)); p.addLine(to: CGPoint(x: r * 1.7, y: r))
                    p.move(to: CGPoint(x: r, y: r * 0.3)); p.addLine(to: CGPoint(x: r, y: r * 1.7))
                }.stroke(Color.white.opacity(0.12), lineWidth: 1)
                Circle()
                    .stroke(Color.white, lineWidth: 2)
                    .background(Circle().fill(Color.black.opacity(0.35)))
                    .frame(width: 12, height: 12)
                    .position(x: r + CGFloat(x) * r * 0.86, y: r - CGFloat(y) * r * 0.86)
            }
            .frame(width: r * 2, height: r * 2)
            .contentShape(Circle())
            // senza gesto (ruota non selezionata) il dito resta libero di far scorrere la fila
            .highPriorityGesture(attiva ?
                DragGesture(minimumDistance: 1)
                    .onChanged { v in
                        if inizio == nil { inizio = (x, y) }
                        guard let (x0, y0) = inizio else { return }
                        // metà della corsa del dito: controllo fine come su un pannello
                        var nx = x0 + Float(v.translation.width / r) * 0.5
                        var ny = y0 - Float(v.translation.height / r) * 0.5
                        let m = (nx * nx + ny * ny).squareRoot()
                        if m > 1 { nx /= m; ny /= m }
                        x = nx; y = ny
                    }
                    .onEnded { _ in inizio = nil } : nil
            )
            .simultaneousGesture(azzeraConDoppioTocco ? TapGesture(count: 2).onEnded { x = 0; y = 0 } : nil)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// Ruota + cursore master + valori RGB, come sotto le ruote di DaVinci.
struct WheelControl: View {
    let titolo: String
    @Binding var wheel: Wheel
    /// Valore mostrato per i tre canali (come fa DaVinci: Lift 0, Gamma 0, Gain 1).
    var base: Float = 0
    var scala: Float = 0.25
    /// In una fila che scorre la ruota si usa solo dopo un doppio tocco (selezionata); prima lo swipe fa scorrere la fila.
    var inFila = false
    var selezionata = false
    var seleziona: () -> Void = {}

    var body: some View {
        let attiva = !inFila || selezionata
        VStack(spacing: 4) {
            HStack(spacing: 2) {
                Text(titolo).font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
                    .foregroundStyle(inFila && selezionata ? Tema.accento : .white)
                Spacer(minLength: 0)
                Ripristina(attivo: !wheel.neutra) { wheel = Wheel() }
            }
            ColorWheel(x: $wheel.x, y: $wheel.y, attiva: attiva, azzeraConDoppioTocco: !inFila)
            HStack(spacing: 2) {
                MasterRing(valore: $wheel.master, attiva: attiva, azzeraConDoppioTocco: !inFila)
                Ripristina(attivo: wheel.master != 0) { wheel.master = 0 }
            }
            let v = wheel.colore * scala + SIMD3(repeating: base + wheel.master * scala * 2)
            HStack(spacing: 4) {
                Text(String(format: "%.2f", v.x)).foregroundStyle(Color(red: 1, green: 0.45, blue: 0.4))
                Text(String(format: "%.2f", v.y)).foregroundStyle(Color(red: 0.45, green: 0.9, blue: 0.5))
                Text(String(format: "%.2f", v.z)).foregroundStyle(Color(red: 0.45, green: 0.65, blue: 1))
            }
            .font(.system(size: 10, design: .monospaced))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Tema.pannello))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Tema.accento, lineWidth: 2).opacity(inFila && selezionata ? 1 : 0))
        .contentShape(Rectangle())
        .simultaneousGesture(inFila ? TapGesture(count: 2).onEnded { seleziona() } : nil)
    }
}

/// Rotella "master" orizzontale: si trascina a destra/sinistra, doppio tocco per azzerare.
struct MasterRing: View {
    @Binding var valore: Float
    var attiva = true
    var azzeraConDoppioTocco = true
    @State private var inizio: Float?

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            ZStack {
                Capsule().fill(Tema.campo)
                // tacche che scorrono, come la rotella di DaVinci
                Canvas { c, s in
                    let passo: CGFloat = 6
                    let shift = CGFloat(valore) * 60
                    var x = (shift.truncatingRemainder(dividingBy: passo)) - passo
                    while x < s.width + passo {
                        c.fill(Path(CGRect(x: x, y: s.height * 0.3, width: 1, height: s.height * 0.4)), with: .color(.white.opacity(0.18)))
                        x += passo
                    }
                }
                .clipShape(Capsule())
                Capsule().stroke(valore == 0 ? Tema.bordo : Tema.accento.opacity(0.7), lineWidth: 1)
            }
            .contentShape(Rectangle())
            .highPriorityGesture(attiva ? DragGesture(minimumDistance: 1)
                .onChanged { v in
                    if inizio == nil { inizio = valore }
                    valore = min(1, max(-1, (inizio ?? 0) + Float(v.translation.width / w) * 0.8))
                }
                .onEnded { _ in inizio = nil } : nil)
            .simultaneousGesture(azzeraConDoppioTocco ? TapGesture(count: 2).onEnded { valore = 0 } : nil)
        }
        .frame(height: 14)
    }
}

/// Pulsante "ripristina" (la freccia circolare di DaVinci): spento quando il valore è già quello di partenza.
struct Ripristina: View {
    let attivo: Bool
    let azione: () -> Void
    var body: some View {
        Button(action: azione) {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(StilePulsante())
        .foregroundStyle(attivo ? Tema.accento : Tema.testo2.opacity(0.45))
        .disabled(!attivo)
        .accessibilityLabel("Ripristina")
    }
}

/// Cursore con nome, valore e ripristino (anche con doppio tocco sul nome).
struct Regolazione: View {
    let nome: String
    @Binding var valore: Float
    let intervallo: ClosedRange<Float>
    let base: Float
    var formato = "%.2f"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                Text(nome).font(.caption).lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 2)
                Text(String(format: formato, valore)).font(.caption.monospacedDigit())
                    .lineLimit(1).fixedSize()
                    .foregroundStyle(valore == base ? Tema.testo2 : Tema.accento)
                Ripristina(attivo: valore != base) { valore = base }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { valore = base }
            Slider(value: $valore, in: intervallo).tint(Tema.accento)
                // sul monitor: clic o trascina per scegliere il valore, tasto destro per tornare a quello di partenza
                .zonaMonitor(id, clic: { p in imposta(p.x) }, trascina: { _, p in imposta(p.x) }, destro: { valore = base })
        }
    }

    @State private var id = "regolazione." + UUID().uuidString

    private func imposta(_ x: CGFloat) {
        let t = Float(min(1, max(0, x)))
        valore = intervallo.lowerBound + t * (intervallo.upperBound - intervallo.lowerBound)
    }
}

/// Titolo di una palette con il ripristino di tutta la palette (come in alto a destra nelle palette di DaVinci).
struct TestataPalette: View {
    let titolo: String
    let modificata: Bool
    let azzera: () -> Void
    var body: some View {
        HStack {
            Text(titolo).font(.caption.weight(.semibold)).foregroundStyle(Tema.testo2)
            Spacer()
            Button(action: azzera) {
                Label("Azzera", systemImage: "arrow.counterclockwise").font(.caption)
            }
            .buttonStyle(StilePulsante())
            .foregroundStyle(modificata ? Tema.accento : Tema.testo2.opacity(0.45))
            .disabled(!modificata)
        }
    }
}
