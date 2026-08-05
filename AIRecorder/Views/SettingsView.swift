import SwiftUI

struct SettingsView: View {
    let settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var translationAvailability = TranslationAvailabilityController()
    @State private var isShowingTranslationSetup = false

    var body: some View {
        Form {
            Section("Transcripción") {
                Picker("Motor", selection: Bindable(settings).engine) {
                    ForEach(TranscriptionEngineKind.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("Idioma", selection: Bindable(settings).language) {
                    ForEach(availableLanguages) { Text($0.displayName).tag($0) }
                }
            }
            Section("Modelo Nemotron") {
                LabeledContent("Variante", value: "Multilingual · 1120 ms")
                Text("El modelo se descarga la primera vez y permanece únicamente en este dispositivo.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Subtítulos traducidos") {
                Toggle("Traducir durante la grabación", isOn: Bindable(settings).translationEnabled)
                    .onChange(of: settings.translationEnabled) { _, enabled in
                        guard enabled, !translationAvailability.state.isReady else { return }
                        settings.translationEnabled = false
                        if case .needsDownload = translationAvailability.state {
                            isShowingTranslationSetup = true
                        }
                    }

                Picker("Traducir a", selection: Bindable(settings).translationTargetLanguage) {
                    ForEach(translationAvailability.supportedTargets) { language in
                        Text(language.displayName).tag(language.code)
                    }
                }

                Label(translationStatusText, systemImage: translationStatusIcon)
                    .font(.footnote)
                    .foregroundStyle(translationStatusColor)

                if case .needsDownload = translationAvailability.state {
                    Button("Descargar idiomas") { isShowingTranslationSetup = true }
                }
            }
            Section("Acerca de") {
                Text("Nemotron 3.5 ASR Streaming 0.6B · NVIDIA")
                Link("Licencia OpenMDW 1.1", destination: URL(string: "https://openmdw.ai/license/1-1/")!)
                Text("Audio y transcripciones se guardan localmente. La app no configura servicios cloud.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Ajustes")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Listo") { dismiss() } } }
        .task(id: "\(settings.language.rawValue)-\(settings.translationTargetLanguage)") {
            await translationAvailability.refresh(settings: settings)
        }
        .sheet(isPresented: $isShowingTranslationSetup) {
            TranslationSetupView(settings: settings, availability: translationAvailability) {
                Task { await translationAvailability.refresh(settings: settings) }
            }
        }
    }

    private var availableLanguages: [TranscriptionLanguage] {
        settings.engine == .nemotron ? TranscriptionLanguage.allCases : [.spanish, .english]
    }

    private var translationStatusText: String {
        switch translationAvailability.state {
        case .checking: "Comprobando idiomas…"
        case .ready: "Idiomas instalados y listos"
        case .needsDownload: "Se requiere descargar los idiomas"
        case .unsupported(let message), .unavailable(let message), .failed(let message): message
        }
    }

    private var translationStatusIcon: String {
        switch translationAvailability.state {
        case .ready: "checkmark.circle.fill"
        case .needsDownload: "arrow.down.circle.fill"
        case .checking: "hourglass"
        default: "exclamationmark.triangle.fill"
        }
    }

    private var translationStatusColor: Color {
        switch translationAvailability.state {
        case .ready: .green
        case .needsDownload: .orange
        case .checking: .secondary
        default: .red
        }
    }
}
