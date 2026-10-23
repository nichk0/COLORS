import SwiftUI

/// Viewer a tutto schermo: zoom a due dita, spostamento, rotazione per i video orizzontali, prima/dopo.
struct SchermoIntero: View {
    @ObservedObject var studio: Studio
    @Binding var bypass: Bool
    @Environment(\.dismiss) private var chiudi

    @State private var zoom: CGFloat = 1
    @State private var zoomInizio: CGFloat = 1
    @State private var spostamento: CGSize = .zero
    @State private var spostamentoInizio: CGSize = .zero
    @State private var ruota = false
    @State private var comandi = true

    var body: some View {
        GeometryReader { g in
            ZStack {
                Color.black
                contenuto
                    // ruotato di 90°: l'immagine orizzontale riempie lo schermo verticale del telefono
                    .frame(width: ruota ? g.size.height : g.size.width, height: ruota ? g.size.width : g.size.height)
                    .rotationEffect(.degrees(ruota ? 90 : 0))
                    .scaleEffect(zoom)
                    .offset(spostamento)
                    .frame(width: g.size.width, height: g.size.height)
                    .contentShape(Rectangle())
                    .gesture(MagnifyGesture()
                        .onChanged { v in zoom = min(max(zoomInizio * v.magnification, 1), 8) }
                        .onEnded { _ in zoomInizio = zoom; if zoom == 1 { centra() } })
                    .simultaneousGesture(DragGesture(minimumDistance: 8)
                        .onChanged { v in
                            guard zoom > 1 else { return }
                            spostamento = CGSize(width: spostamentoInizio.width + v.translation.width,
                                                 height: spostamentoInizio.height + v.translation.height)
                        }
                        .onEnded { _ in spostamentoInizio = spostamento })
                    .onTapGesture(count: 2) { withAnimation(.easeOut(duration: 0.2)) { centra(); zoom = 1; zoomInizio = 1 } }
                    .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { comandi.toggle() } }
                if comandi { barraComandi }
            }
        }
        .ignoresSafeArea()
        .statusBarHidden()
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var contenuto: some View {
        if studio.inRiproduzione {
            VistaPlayer(player: studio.player)
        } else if let img = bypass ? studio.originale : studio.risultato {
            Image(uiImage: img).resizable().interpolation(.high).scaledToFit()
        }
    }

    private var barraComandi: some View {
        VStack {
            HStack(spacing: 10) {
                bottone("xmark") { chiudi() }.accessibilityLabel("Close full screen")
                VStack(alignment: .leading, spacing: 0) {
                    Text(studio.nomeClip).font(.caption.weight(.semibold)).lineLimit(1)
                    if zoom > 1.01 { Text(String(format: "Zoom %.1f×", zoom)).font(.system(size: 10)).foregroundStyle(Tema.testo2) }
                }
                Spacer()
                Button { bypass.toggle() } label: {
                    Text(bypass ? "BEFORE" : "AFTER").font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 10).frame(height: 36)
                        .background(Capsule().fill(bypass ? Tema.accento : Color.black.opacity(0.6)))
                        .foregroundStyle(bypass ? .black : .white)
                }
                .accessibilityLabel("Compare before and after")
                bottone(ruota ? "rectangle.portrait" : "rectangle.landscape.rotate") {
                    withAnimation(.easeInOut(duration: 0.25)) { ruota.toggle(); centra(); zoom = 1; zoomInizio = 1 }
                }
                .accessibilityLabel("Rotate")
            }
            .padding(.horizontal, 14).padding(.top, 58)
            Spacer()
            if studio.eVideo {
                HStack(spacing: 14) {
                    bottone(studio.inRiproduzione ? "pause.fill" : "play.fill") {
                        Task { if studio.inRiproduzione { await studio.pausa() } else { await studio.play() } }
                    }
                    Text(String(format: "%.1f / %.1f s", studio.tempo, studio.durata))
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(.white)
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.bottom, 40)
            } else {
                Text("Pinch to zoom · double-tap to fit · tap to hide the controls")
                    .font(.system(size: 10)).foregroundStyle(Tema.testo2)
                    .padding(.bottom, 36)
            }
        }
    }

    private func bottone(_ icona: String, _ azione: @escaping () -> Void) -> some View {
        Button(action: azione) {
            Image(systemName: icona).font(.system(size: 16, weight: .semibold))
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.black.opacity(0.6)))
                .foregroundStyle(.white)
        }
    }

    private func centra() { spostamento = .zero; spostamentoInizio = .zero }
}
