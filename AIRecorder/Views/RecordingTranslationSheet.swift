import SwiftUI

#if canImport(Translation) && !targetEnvironment(simulator)
@preconcurrency import Translation

private enum OnDemandTranslationAvailability: Equatable {
    case checking
    case installed
    case needsDownload
    case unsupported
    case failed(String)
}

struct RecordingTranslationSheet: View {
    let sourceLanguage: String?
    let initialTarget: String
    let translate: (String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var targetLanguage: String
    @State private var options: [TranslationLanguageOption] = []
    @State private var availability: OnDemandTranslationAvailability = .checking
    @State private var configuration: TranslationSession.Configuration?
    @State private var isWorking = false

    init(
        sourceLanguage: String?,
        initialTarget: String,
        translate: @escaping (String) async -> Bool
    ) {
        self.sourceLanguage = sourceLanguage
        self.initialTarget = initialTarget
        self.translate = translate
        _targetLanguage = State(initialValue: initialTarget)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let sourceLanguage {
                    Section("Idiomas") {
                        LabeledContent("Original", value: TranslationPolicy.displayName(for: sourceLanguage))
                        Picker("Traducir a", selection: $targetLanguage) {
                            ForEach(options) { option in
                                Text(option.displayName).tag(option.code)
                            }
                        }
                    }

                    Section {
                        availabilityView
                    }

                    Section {
                        Button {
                            begin()
                        } label: {
                            HStack {
                                if isWorking { ProgressView() }
                                Text(actionTitle)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isWorking || !canBegin)
                    }
                    .listRowBackground(Color.clear)
                } else {
                    ContentUnavailableView(
                        "Idioma desconocido",
                        systemImage: "character.bubble",
                        description: Text("No se pudo determinar el idioma original de esta grabación.")
                    )
                }
            }
            .navigationTitle("Traducir grabación")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }.disabled(isWorking)
                }
            }
            .interactiveDismissDisabled(isWorking)
            .task { await loadLanguages() }
            .task(id: targetLanguage) { await refreshAvailability() }
            .translationTask(configuration) { session in
                guard isWorking else { return }
                do {
                    try await session.prepareTranslation()
                    await runTranslation()
                } catch is CancellationError {
                    isWorking = false
                } catch {
                    isWorking = false
                    availability = .failed(error.localizedDescription)
                }
            }
        }
    }

    @ViewBuilder
    private var availabilityView: some View {
        switch availability {
        case .checking:
            HStack { ProgressView(); Text("Comprobando idiomas…") }
        case .installed:
            Label("Los idiomas están listos", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .needsDownload:
            Label("iOS necesita descargar estos idiomas", systemImage: "arrow.down.circle")
                .foregroundStyle(.orange)
        case .unsupported:
            Label("Este par de idiomas no es compatible", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        }
    }

    private var canBegin: Bool {
        availability == .installed || availability == .needsDownload
    }

    private var actionTitle: String {
        if isWorking { return "Traduciendo…" }
        return availability == .needsDownload ? "Descargar y traducir" : "Traducir"
    }

    private func loadLanguages() async {
        let languages = await LanguageAvailability().supportedLanguages
        options = languages.compactMap { language in
            guard let code = language.languageCode?.identifier,
                  sourceLanguage.map({ !TranslationPolicy.sameLanguage($0, code) }) ?? true
            else { return nil }
            return TranslationLanguageOption(
                code: TranslationPolicy.normalizedCode(code),
                displayName: TranslationPolicy.displayName(for: code)
            )
        }
        .uniquedTranslationLanguages()
        .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }

        if !options.contains(where: { TranslationPolicy.sameLanguage($0.code, targetLanguage) }),
           let first = options.first {
            targetLanguage = first.code
        }
    }

    private func refreshAvailability() async {
        guard let sourceLanguage else {
            availability = .unsupported
            return
        }
        guard !TranslationPolicy.sameLanguage(sourceLanguage, targetLanguage) else {
            availability = .unsupported
            return
        }
        availability = .checking
        let status = await LanguageAvailability().status(
            from: Locale.Language(identifier: sourceLanguage),
            to: Locale.Language(identifier: targetLanguage)
        )
        switch status {
        case .installed: availability = .installed
        case .supported: availability = .needsDownload
        case .unsupported: availability = .unsupported
        @unknown default: availability = .failed("iOS devolvió un estado desconocido.")
        }
    }

    private func begin() {
        guard let sourceLanguage else { return }
        isWorking = true
        if availability == .installed {
            Task { await runTranslation() }
        } else if availability == .needsDownload {
            if #available(iOS 26.4, *) {
                configuration = .init(
                    source: Locale.Language(identifier: sourceLanguage),
                    target: Locale.Language(identifier: targetLanguage),
                    preferredStrategy: .lowLatency
                )
            } else {
                configuration = .init(
                    source: Locale.Language(identifier: sourceLanguage),
                    target: Locale.Language(identifier: targetLanguage)
                )
            }
        }
    }

    private func runTranslation() async {
        let success = await translate(targetLanguage)
        isWorking = false
        if success { dismiss() }
        else { availability = .failed("No se pudo completar la traducción.") }
    }
}

private extension Array where Element == TranslationLanguageOption {
    func uniquedTranslationLanguages() -> [TranslationLanguageOption] {
        var seen = Set<String>()
        return filter { seen.insert($0.code).inserted }
    }
}

#else

struct RecordingTranslationSheet: View {
    let sourceLanguage: String?
    let initialTarget: String
    let translate: (String) async -> Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Requiere un dispositivo real",
                systemImage: "iphone.gen3.slash",
                description: Text("Apple Translation no traduce dentro del Simulator.")
            )
            .navigationTitle("Traducir grabación")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
        }
    }
}
#endif
