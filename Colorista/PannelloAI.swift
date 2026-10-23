import SwiftUI

/// Palette AI: funzioni che analizzano l'immagine (tutto sul telefono, senza internet).
struct PannelloAI: View {
    @ObservedObject var studio: Studio
    @State private var descrizione = ""
    @FocusState private var scrivendo: Bool
    private let esempi = ["Warm '70s sunset", "Cold, gloomy thriller", "Pastel summer", "Black and white noir", "Teal and orange blockbuster", "Faded vintage film"]

    var body: some View {
        VStack(spacing: 10) {
            Sezione(titolo: "Auto color") {
                Button { studio.autoColoreAI() } label: {
                    Label("Grade with AI", systemImage: "wand.and.stars")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity).frame(height: 40)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Tema.accento))
                        .foregroundStyle(.black)
                }
                .buttonStyle(StilePulsante())
                Text("Analyzes exposure, color cast and faces and adds an \"Auto AI\" node with curve, shadows/highlights, balance and vibrance. You can fine-tune it in the other palettes or turn it off. Pressing it on an Auto AI node recalculates it.")
                    .font(.caption2).foregroundStyle(Tema.testo2)
            }
            Sezione(titolo: "Look described in words (Apple Intelligence)") {
                HStack(spacing: 8) {
                    TextField("Describe the look…", text: $descrizione, axis: .vertical)
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
                Text(LookAParole.motivoNonDisponibile ?? "The model runs on the iPhone, without internet. It creates a node named after the look: you can fine-tune it like the others.")
                    .font(.caption2).foregroundStyle(LookAParole.motivoNonDisponibile == nil ? Tema.testo2 : Tema.accento)
            }
            Sezione(titolo: "Magic Mask AI") {
                HStack(spacing: 8) {
                    bottoneMaschera("Subject", "person.and.background.dotted", .soggetto)
                    bottoneMaschera("Background", "rectangle.dashed", .fuoriSoggetto)
                }
                Text("Creates a node that grades only the subject in the foreground (or only the background). Then adjust it with Primaries, Curves…")
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
            studio.nodi[studio.indice].nome = m == .soggetto ? "AI subject" : "AI background"
            studio.mostraMaschera = true
        } label: {
            Label(titolo, systemImage: icona).font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity).frame(height: 38)
                .background(RoundedRectangle(cornerRadius: 8).fill(Tema.campo))
        }
        .buttonStyle(StilePulsante())
    }
}
