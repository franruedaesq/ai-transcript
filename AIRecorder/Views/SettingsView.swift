import SwiftUI

struct SettingsView: View {
    let settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appLayoutMode) private var appLayoutMode
    @State private var translationAvailability = TranslationAvailabilityController()
    @State private var isShowingTranslationSetup = false
    @AppStorage("appUiLanguage") private var appUiLanguage: String = "system"
    @AppStorage("appAppearance") private var appAppearance: String = "system"
    @AppStorage("recorder.keepScreenAwake") private var keepScreenAwake = false

    var body: some View {
        Form {
            Section("Interfaz") {
                Picker("Idioma de la App", selection: $appUiLanguage) {
                    Text("Sistema").tag("system")
                    Text("Español").tag("es")
                    Text("Inglés").tag("en")
                    Text("Alemán").tag("de")
                }
                Picker("Apariencia", selection: $appAppearance) {
                    Text("Sistema").tag("system")
                    Text("Claro").tag("light")
                    Text("Oscuro").tag("dark")
                }
            }

            Section("Transcripción") {
                Picker("Motor", selection: Bindable(settings).engine) {
                    ForEach(TranscriptionEngineKind.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("Idioma", selection: Bindable(settings).language) {
                    ForEach(availableLanguages) { Text($0.displayName).tag($0) }
                }
                NavigationLink { CustomVocabularyView(settings: settings) } label: {
                    LabeledContent("Vocabulario personalizado", value: "\(settings.customVocabulary.count)")
                }
            }
            Section {
                Toggle("Mantener pantalla encendida", isOn: $keepScreenAwake)
            } header: { Text("Grabación") } footer: {
                Text(
                    appLayoutMode == .pad
                        ? "Desactívalo para permitir que el iPad bloquee la pantalla normalmente mientras la grabación continúa en segundo plano."
                        : "Desactívalo para permitir que el iPhone bloquee la pantalla normalmente mientras la grabación continúa en segundo plano."
                )
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

                NavigationLink {
                    TranslationLanguagesView(settings: settings)
                } label: {
                    LabeledContent(
                        "Gestionar idiomas",
                        value: "\(settings.translationLanguageCodes.count)"
                    )
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
        .task(id: "\(settings.language.rawValue)-\(settings.translationTargetLanguage)-\(settings.translationLanguageCodes.joined(separator: ","))") {
            await translationAvailability.refresh(settings: settings)
        }
        .sheet(isPresented: $isShowingTranslationSetup) {
            TranslationSetupView(settings: settings, availability: translationAvailability) {
                Task { await translationAvailability.refresh(settings: settings) }
            }
        }
    }

    private var availableLanguages: [TranscriptionLanguage] {
        settings.engine == .nemotron ? TranscriptionLanguage.allCases : [.spanish, .english, .german]
    }

    private var translationStatusText: String {
        switch translationAvailability.state {
        case .checking: AppLocalization.string("Comprobando idiomas…")
        case .ready: AppLocalization.string("Idiomas instalados y listos")
        case .needsDownload: AppLocalization.string("Se requiere descargar los idiomas")
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

private struct CustomVocabularyView: View {
    let settings: AppSettings
    @State private var preferred = ""
    @State private var aliases = ""
    @State private var editing: CustomVocabularyEntry?
    var body: some View {
        List {
            Section { Text("Añade nombres, productos, lugares o términos técnicos. Las variantes corrigen de manera determinista los errores habituales en el texto final.").font(.footnote).foregroundStyle(.secondary) }
            Section("Agregar término") {
                TextField("Forma correcta · por ejemplo SwiftData", text: $preferred)
                TextField("Variantes separadas por coma", text: $aliases)
                Button("Agregar") { settings.addVocabularyEntry(preferred: preferred, aliases: parsed(aliases)); preferred = ""; aliases = "" }
                    .disabled(preferred.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Section("Tus términos") {
                if settings.customVocabulary.isEmpty { Text("Todavía no agregaste términos.").foregroundStyle(.secondary) }
                ForEach(settings.customVocabulary) { entry in
                    Button { editing = entry } label: { VStack(alignment: .leading) { Text(entry.preferred).foregroundStyle(.primary); if !entry.aliases.isEmpty { Text(entry.aliases.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) } } }
                        .swipeActions { Button(role: .destructive) { settings.removeVocabularyEntry(id: entry.id) } label: { Label("Eliminar", systemImage: "trash") } }
                }
            }
        }.navigationTitle("Vocabulario").navigationBarTitleDisplayMode(.inline)
            .sheet(item: $editing) { entry in VocabularyEditorSheet(entry: entry) { preferred, aliases in settings.updateVocabularyEntry(id: entry.id, preferred: preferred, aliases: aliases) } }
    }
    private func parsed(_ value: String) -> [String] { value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
}

private struct VocabularyEditorSheet: View {
    let entry: CustomVocabularyEntry
    let save: (String, [String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var preferred: String
    @State private var aliases: String
    init(entry: CustomVocabularyEntry, save: @escaping (String, [String]) -> Void) { self.entry = entry; self.save = save; _preferred = State(initialValue: entry.preferred); _aliases = State(initialValue: entry.aliases.joined(separator: ", ")) }
    var body: some View { NavigationStack { Form { TextField("Forma correcta", text: $preferred); TextField("Variantes separadas por coma", text: $aliases) }.navigationTitle("Editar término").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Guardar") { save(preferred, aliases.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }); dismiss() }.disabled(preferred.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) } } } }
}

private struct TranslationLanguagesView: View {
    let settings: AppSettings
    @State private var availability = TranslationAvailabilityController()
    @State private var searchText = ""
    @State private var languageToExplain: TranslationLanguageOption?
    @State private var isShowingSetup = false

    var body: some View {
        List {
            Section {
                Text("Solo estos idiomas aparecerán en el selector de la pantalla principal.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(selectedLanguages) { language in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(language.displayName)
                            if TranslationPolicy.sameLanguage(language.code, settings.translationTargetLanguage) {
                                Text("Destino actual")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button {
                            prepare(language)
                        } label: {
                            Label("Preparar", systemImage: "arrow.down.circle")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                        .disabled(cannotTranslate(to: language.code))
                        .accessibilityLabel("Preparar \(language.displayName)")
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            settings.removeTranslationLanguage(language.code)
                        } label: {
                            Label("Quitar", systemImage: "minus.circle")
                        }
                        .disabled(settings.translationLanguageCodes.count == 1)
                    }
                }
            } header: {
                Text("Tus idiomas")
            } footer: {
                Text("Preparar descarga, si hace falta, los paquetes de Apple para el idioma hablado seleccionado. Los paquetes se comparten con Traducir y el procesamiento permanece en el dispositivo.")
            }

            Section("Agregar idiomas") {
                if availableLanguages.isEmpty {
                    if case .unavailable(let message) = availability.state {
                        Label(message, systemImage: "iphone.gen3.slash")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else if availability.allSupportedTargets.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Consultando idiomas de Apple…")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("No hay más idiomas que coincidan con la búsqueda.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(availableLanguages) { language in
                        Button {
                            settings.addTranslationLanguage(language.code)
                            languageToExplain = language
                        } label: {
                            HStack {
                                Text(language.displayName)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Idiomas de traducción")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Buscar idioma")
        .task { await availability.refresh(settings: settings) }
        .alert("Idioma agregado", isPresented: Binding(
            get: { languageToExplain != nil },
            set: { if !$0 { languageToExplain = nil } }
        )) {
            Button("Ahora no", role: .cancel) {}
            Button("Usar y preparar ahora") {
                if let languageToExplain { prepare(languageToExplain) }
            }
        } message: {
            Text("\(languageToExplain?.displayName ?? "El idioma") ya aparecerá en la pantalla principal. iOS puede necesitar descargar los paquetes de Apple antes de traducir.")
        }
        .sheet(isPresented: $isShowingSetup) {
            TranslationSetupView(settings: settings, availability: availability) {
                Task { await availability.refresh(settings: settings) }
            }
        }
    }

    private var selectedLanguages: [TranslationLanguageOption] {
        settings.translationLanguageCodes.map {
            TranslationLanguageOption(code: $0, displayName: TranslationPolicy.displayName(for: $0))
        }
    }

    private var availableLanguages: [TranslationLanguageOption] {
        availability.allSupportedTargets.filter { language in
            !settings.translationLanguageCodes.contains(where: {
                TranslationPolicy.sameLanguage($0, language.code)
            }) && (searchText.isEmpty || language.displayName.localizedCaseInsensitiveContains(searchText))
        }
    }

    private func cannotTranslate(to code: String) -> Bool {
        settings.language.translationSourceCode.map {
            TranslationPolicy.sameLanguage($0, code)
        } ?? false
    }

    private func prepare(_ language: TranslationLanguageOption) {
        settings.translationTargetLanguage = language.code
        settings.translationEnabled = false
        isShowingSetup = true
    }
}
