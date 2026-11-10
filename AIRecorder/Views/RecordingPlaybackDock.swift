import SwiftUI

struct RecordingPlaybackDock: View {
    let playback: PlaybackController
    let search: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 9) {
                Text(playback.currentTime.formattedDuration)
                Slider(value: playbackPosition, in: 0...max(0.1, playback.duration))
                    .disabled(!playback.isReady)
                Text(playback.duration.formattedDuration)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            HStack {
                Button("Buscar en la grabación", systemImage: "magnifyingglass", action: search)
                    .labelStyle(.iconOnly)

                Spacer()

                Button("Retroceder 15 segundos", systemImage: "gobackward.15") {
                    playback.skip(-15)
                }
                .labelStyle(.iconOnly)
                .disabled(!playback.isReady)

                Spacer()

                Button(playback.isPlaying ? "Pausar" : "Reproducir", systemImage: playback.isPlaying ? "pause.fill" : "play.fill") {
                    playback.toggle()
                }
                .labelStyle(.iconOnly)
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(.blue, in: Circle())
                .shadow(color: .blue.opacity(0.25), radius: 7, y: 4)
                .disabled(!playback.isReady)

                Spacer()

                Button("Avanzar 15 segundos", systemImage: "goforward.15") {
                    playback.skip(15)
                }
                .labelStyle(.iconOnly)
                .disabled(!playback.isReady)

                Spacer()

                Menu {
                    ForEach(playback.supportedRates, id: \.self) { rate in
                        Button {
                            playback.setRate(rate)
                        } label: {
                            if abs(playback.playbackRate - rate) < 0.01 {
                                Label(rateLabel(rate), systemImage: "checkmark")
                            } else {
                                Text(rateLabel(rate))
                            }
                        }
                    }
                } label: {
                    Text(rateLabel(playback.playbackRate))
                        .font(.subheadline)
                        .bold()
                        .frame(minWidth: 44, minHeight: 44)
                        .background(.quaternary, in: Capsule())
                }
                .accessibilityLabel("Velocidad de reproducción: \(rateLabel(playback.playbackRate))")
            }
            .font(.title3)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 13)
        .padding(.bottom, 10)
        .background(.regularMaterial, in: .rect(cornerRadius: 24))
        .overlay(alignment: .topLeading) {
            if playback.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .padding(12)
            }
        }
        .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
        .padding(.horizontal, 14)
    }

    private var playbackPosition: Binding<Double> {
        Binding(
            get: { playback.currentTime },
            set: { value in playback.seek(to: value) }
        )
    }

    private func rateLabel(_ rate: Float) -> String {
        abs(rate.rounded() - rate) < 0.01
            ? "\(Int(rate))×"
            : String(format: "%.2g×", rate)
    }
}
