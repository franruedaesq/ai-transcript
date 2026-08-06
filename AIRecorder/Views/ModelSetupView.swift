import SwiftUI

struct ModelSetupView: View {
    let settings: AppSettings
    let session: RecordingSessionController
    let completed: () -> Void
    @State private var isDownloading = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "waveform.badge.magnifyingglass")
                .font(.system(size: 58, weight: .medium))
                .foregroundStyle(.blue)
                .frame(width: 112, height: 112)
                .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 30))
                .accessibilityHidden(true)

            VStack(spacing: 12) {
                Text("Preparar transcripción local")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                Text("Para transcribir sin enviar tus audios fuera del dispositivo, AI Recorder necesita descargar Nemotron 3.5 una sola vez.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 14) {
                Label("Español, inglés y alemán con detección automática", systemImage: "character.bubble")
                Label("El modelo queda guardado en este dispositivo", systemImage: "iphone")
                Label("Se requiere conexión durante la descarga", systemImage: "wifi")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 20))

            if isDownloading {
                VStack(spacing: 10) {
                    if let progress = session.modelPreparation.progress {
                        ProgressView(value: progress)
                    } else {
                        ProgressView()
                            .controlSize(.large)
                    }
                    HStack {
                        Text(session.modelPreparation.label)
                            .lineLimit(1)
                        Spacer()
                        if let progress = session.modelPreparation.progress {
                            Text(progress, format: .percent.precision(.fractionLength(0)))
                                .monospacedDigit()
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                if session.modelPreparation == .loading {
                    Text("Los archivos ya están descargados. Core ML está cargando el modelo para que la primera grabación comience más rápido.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            Spacer()

            Button {
                Task { await download() }
            } label: {
                HStack {
                    if isDownloading { ProgressView().tint(.white) }
                    Text(isDownloading ? "Preparando…" : "Descargar modelo")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 54)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isDownloading)
            .accessibilityHint("Descarga y prepara Nemotron para transcribir audios localmente")

            Button("Usar Apple Speech Recognition") {
                settings.engine = .appleSpeech
                completed()
            }
            .buttonStyle(.bordered)
            .disabled(isDownloading)
            .accessibilityHint("Continúa sin descargar Nemotron")
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
        .interactiveDismissDisabled(isDownloading)
        .alert("No se pudo descargar", isPresented: Binding(
            get: { if case .failed = session.state { true } else { false } },
            set: { if !$0 { session.resetError() } }
        )) {
            Button("Reintentar") { session.resetError() }
        } message: {
            if case .failed(let message) = session.state { Text(message) }
        }
    }

    private func download() async {
        isDownloading = true
        let success = await session.prepareNemotron(settings: settings)
        isDownloading = false
        if success { completed() }
    }
}
