import SwiftUI

#if canImport(Translation) && !targetEnvironment(simulator)
@preconcurrency import Translation

struct TranslationSetupView: View {
    let settings: AppSettings
    let availability: TranslationAvailabilityController
    let completed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pairs: [TranslationPair] = []
    @State private var pairIndex = 0
    @State private var configuration: TranslationSession.Configuration?
    @State private var isPreparing = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Spacer()
                Image(systemName: "translate")
                    .font(.system(size: 48, weight: .semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 104, height: 104)
                    .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 28))

                Text("Preparar subtítulos traducidos")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                Text("iOS descargará los idiomas necesarios. Los paquetes se comparten con la app Traducir y el texto se procesa en este dispositivo.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if isPreparing {
                    ProgressView("Preparando idioma \(pairIndex + 1) de \(max(1, pairs.count))…")
                        .controlSize(.large)
                }

                Spacer()
                Button {
                    beginPreparation()
                } label: {
                    Text(isPreparing ? "Preparando…" : "Descargar idiomas")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isPreparing)
            }
            .padding(28)
            .navigationTitle("Traducción")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }.disabled(isPreparing)
                }
            }
            .interactiveDismissDisabled(isPreparing)
            .translationTask(configuration) { session in
                guard isPreparing else { return }
                do {
                    try await session.prepareTranslation()
                    await advance()
                } catch is CancellationError {
                    isPreparing = false
                } catch {
                    isPreparing = false
                    errorMessage = error.localizedDescription
                }
            }
            .alert("No se pudieron preparar los idiomas", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("Aceptar", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
        }
    }

    private func beginPreparation() {
        pairs = TranslationPolicy.requiredPairs(
            spokenLanguage: settings.language,
            target: settings.translationTargetLanguage
        )
        guard !pairs.isEmpty else { return }
        pairIndex = 0
        isPreparing = true
        configuration = makeConfiguration(for: pairs[0])
    }

    private func advance() async {
        pairIndex += 1
        if pairIndex < pairs.count {
            configuration = makeConfiguration(for: pairs[pairIndex])
            return
        }
        await availability.refresh(settings: settings)
        isPreparing = false
        if availability.state.isReady {
            settings.translationEnabled = true
            completed()
            dismiss()
        } else {
            errorMessage = "Los paquetes todavía no están listos. Espera a que iOS termine la descarga y vuelve a intentarlo."
        }
    }

    private func makeConfiguration(for pair: TranslationPair) -> TranslationSession.Configuration {
        if #available(iOS 26.4, *) {
            return .init(
                source: Locale.Language(identifier: pair.source),
                target: Locale.Language(identifier: pair.target),
                preferredStrategy: .lowLatency
            )
        }
        return .init(
            source: Locale.Language(identifier: pair.source),
            target: Locale.Language(identifier: pair.target)
        )
    }
}

#else

struct TranslationSetupView: View {
    let settings: AppSettings
    let availability: TranslationAvailabilityController
    let completed: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Requiere un dispositivo real",
                systemImage: "iphone.gen3.slash",
                description: Text("Apple Translation no descarga idiomas ni traduce dentro del Simulator.")
            )
            .navigationTitle("Traducción")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
        }
    }
}
#endif
