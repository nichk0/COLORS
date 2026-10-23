import SwiftUI

/// Palette AI: funzioni che analizzano l'immagine (tutto sul telefono, senza internet).
struct PannelloAI: View {
    @ObservedObject var studio: Studio
    @State private var descrizione = ""
    @FocusState private var scrivendo: Bool
    private let esempi = ["Tramonto caldo anni '70", "Thriller freddo e cupo", "Estate pastello", "Noir in bianco e nero", "Blockbuster teal e arancio", "Pellicola sbiadita vintage"]

    var body: some View {
        VStack(spacing: 10) {
            Sezione(titolo: "Auto colore") {
                Button { studio.autoColoreAI() } label: {
                    Label("Correggi con l'AI", systemImage: "wand.and.stars")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity).frame(height: 40)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Tema.accento))
                        .foregroundStyle(.black)
                }
                .buttonStyle(StilePulsante())
                Text("Analizza esposizione, dominante di colore e volti e aggiunge un nodo \"Auto AI\" con curva, ombre/luci, bilanciamento e vivacità. Puoi ritoccarlo nelle altre palette o spegnerlo. Premuto su un nodo Auto AI lo ricalcola.")
                    .font(.caption2).foregroundStyle(Tema.testo2)
            }
            Sezione(titolo: "Look descritto a parole (Apple Intelligence)") {
                HStack(spacing: 8) {
                    TextField("Descrivi il look…", text: $descrizione, axis: .vertical)
                        .lineLimit(1...3)
                        .textFieldStyle(.roundedBorder)
                        .focused($scrivendo)
                        .submitLabel(.go)
                        .onSubmit { crea() }
                    Button(action: crea) {
                        Image(systemName: "sparkles").font(.system(size: 16, weight: .semibold))
                            .frame(width: 40, height: 36)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Tema.accento))
                            .foregroundStyle(.black)
                    }
                    .buttonStyle(StilePulsante())
                    .disabled(descrizione.trimmingCharacters(in: .whitespaces).isEmpty || studio.lavoro != nil)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(esempi, id: \.self) { e in
                            Button { descrizione = e } label: {
                                Text(e).font(.caption)
                                    .padding(.horizontal, 10).frame(height: 28)
                                    .background(Capsule().fill(Tema.campo))
                            }
                            .buttonStyle(StilePulsante())
                        }
                    }
                }
                if let l = studio.lavoro {
                    HStack { ProgressView(); Text(l).font(.caption) }
                }
                Text(LookAParole.motivoNonDisponibile ?? "Il modello gira sull'iPhone, senza internet. Crea un nodo con il nome del look: puoi ritoccarlo come gli altri.")
                    .font(.caption2).foregroundStyle(LookAParole.motivoNonDisponibile == nil ? Tema.testo2 : Tema.accento)
            }
            Sezione(titolo: "Magic Mask AI") {
                HStack(spacing: 8) {
                    bottoneMaschera("Soggetto", "person.and.background.dotted", .soggetto)
                    bottoneMaschera("Sfondo", "rectangle.dashed", .fuoriSoggetto)
                }
                Text("Crea un nodo che corregge solo il soggetto in primo piano (o solo lo sfondo). Poi regolalo con Primarie, Curve…")
                    .font(.caption2).foregroundStyle(Tema.testo2)
            }
        }
    }

    private func crea() {
        scrivendo = false
        let t = descrizione
        Task { await studio.lookDaParole(t) }
    }

    private func bottoneMaschera(_ titolo: String, _ icona: String, _ m: MagicMask) -> some View {
        Button {
            studio.aggiungi(.correzione)
            studio.nodi[studio.indice].magic = m
            studio.nodi[studio.indice].nome = m == .soggetto ? "Soggetto AI" : "Sfondo AI"
            studio.mostraMaschera = true
        } label: {
            Label(titolo, systemImage: icona).font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity).frame(height: 38)
                .background(RoundedRectangle(cornerRadius: 8).fill(Tema.campo))
        }
        .buttonStyle(StilePulsante())
    }
}
