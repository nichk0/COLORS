import SwiftUI

/// Editor dei nodi in serie, come nella pagina Color: ingresso → 01 → 02 → … → uscita.
struct GrafoNodi: View {
    @ObservedObject var studio: Studio
    var aggiungiLUT: () -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    presa(etichetta: "RGB")
                    ForEach(Array(studio.nodi.enumerated()), id: \.element.id) { i, n in
                        filo
                        scatola(n, numero: i + 1)
                            .id(n.id)
                    }
                    filo
                    presa(etichetta: "OUT")
                    Menu {
                        Button { studio.aggiungi(.correzione) } label: { Label("Nodo correttore", systemImage: "plus.square") }
                        Button { studio.aggiungi(.correzione); studio.nodi[studio.indice].modo = .parallelo } label: { Label("Nodo parallelo", systemImage: "equal.square") }
                        Button { studio.aggiungi(.correzione); studio.nodi[studio.indice].modo = .layer } label: { Label("Nodo layer", systemImage: "square.3.layers.3d") }
                        Button { studio.aggiungi(.cst) } label: { Label("Color Space Transform", systemImage: "camera.filters") }
                        Button(action: aggiungiLUT) { Label("LUT da file…", systemImage: "cube") }
                    } label: {
                        Image(systemName: "plus.circle.fill").font(.title3).foregroundStyle(Tema.accento)
                    }
                    .padding(.leading, 12)
                }
                .padding(.horizontal, 10)
                .frame(maxHeight: .infinity)
            }
            .onChange(of: studio.selezionato) { _, id in withAnimation { proxy.scrollTo(id, anchor: .center) } }
        }
        .background(Tema.sfondo)
    }

    private var filo: some View {
        Rectangle().fill(Tema.collegamento).frame(width: 18, height: 2)
    }

    private func presa(etichetta: String) -> some View {
        VStack(spacing: 2) {
            Circle().fill(Tema.collegamento).frame(width: 9, height: 9)
            Text(etichetta).font(.system(size: 8, weight: .semibold)).foregroundStyle(Tema.testo2)
        }
    }

    private func scatola(_ n: Nodo, numero: Int) -> some View {
        let sel = n.id == studio.selezionato
        let icona: String = {
            switch n.tipo {
            case .correzione: return n.haMaschera ? "circle.dashed" : "circle.lefthalf.filled"
            case .cst: return "camera.filters"
            case .lut: return "cube"
            }
        }()
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(String(format: "%02d", numero)).font(.system(size: 10, weight: .bold, design: .monospaced))
                Spacer(minLength: 0)
                Image(systemName: icona).font(.system(size: 10))
            }
            Text(n.etichetta).font(.system(size: 10)).lineLimit(1)
            if !n.attivo { Text("spento").font(.system(size: 8)).foregroundStyle(.red) }
            else if n.modo != .serie && numero > 1 {
                Label(n.modo.rawValue, systemImage: n.modo.icona).font(.system(size: 8, weight: .semibold)).foregroundStyle(Tema.accento)
            }
        }
        .padding(6)
        .frame(width: 84, height: 50, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Tema.nodo))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(sel ? Tema.accento : Color.white.opacity(0.12), lineWidth: sel ? 2 : 1))
        .opacity(n.attivo ? 1 : 0.45)
        .onTapGesture { studio.selezionato = n.id }
        .contextMenu {
            Button { if let i = studio.nodi.firstIndex(where: { $0.id == n.id }) { studio.nodi[i].attivo.toggle() } } label: {
                Label(n.attivo ? "Spegni nodo" : "Accendi nodo", systemImage: n.attivo ? "eye.slash" : "eye")
            }
            Button { studio.sposta(n.id, di: -1) } label: { Label("Sposta a sinistra", systemImage: "arrow.left") }
            Button { studio.sposta(n.id, di: 1) } label: { Label("Sposta a destra", systemImage: "arrow.right") }
            Button { studio.selezionato = n.id; studio.azzeraNodo() } label: { Label("Azzera correzione", systemImage: "arrow.counterclockwise") }
            Button(role: .destructive) { studio.elimina(n.id) } label: { Label("Elimina nodo", systemImage: "trash") }
        }
    }
}
