import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    let settings: AppSettings
    let session: RecordingSessionController
    let selectedRecordingID: UUID?
    let openRecording: ((UUID) -> Void)?
    let recordingDeleted: ((UUID) -> Void)?
    @Environment(\.modelContext) private var context
    @Environment(\.appLayoutMode) private var appLayoutMode
    @Query(sort: \Recording.createdAt, order: .reverse) private var recordings: [Recording]
    @State private var presentedSheet: SheetDestination?
    @State private var isShowingRecorder = false
    @State private var isShowingModelSetup = false
    @State private var isImporting = false
    @State private var recordingIDToDelete: UUID?
    @AppStorage("appUiLanguage") private var appUiLanguage: String = "system"
    @State private var translationAvailability = TranslationAvailabilityController()
    @State private var exportCoordinator = RecordingExportCoordinator()
    @State private var translationMessage: String?
    @State private var searchText = ""
    @State private var searchQuery = ""
    @State private var recordingIDToRename: UUID?
    @State private var renameDraft = ""
    @State private var importMessage: String?

    init(
        settings: AppSettings,
        session: RecordingSessionController,
        selectedRecordingID: UUID? = nil,
        openRecording: ((UUID) -> Void)? = nil,
        recordingDeleted: ((UUID) -> Void)? = nil
    ) {
        self.settings = settings
        self.session = session
        self.selectedRecordingID = selectedRecordingID
        self.openRecording = openRecording
        self.recordingDeleted = recordingDeleted
    }

    private var filteredRecordings: [Recording] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return recordings }
        return recordings.filter { recording in
            recording.title.localizedCaseInsensitiveContains(query)
                || recording.transcript.localizedCaseInsensitiveContains(query)
                || recording.cues.contains { $0.text.localizedCaseInsensitiveContains(query) }
        }
    }

    enum SheetDestination: String, Identifiable {
        case settings
        case translationSetup
        var id: String { rawValue }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: AppVisualStyle.sectionSpacing) {
                LibraryHeader(
                    searchText: $searchText,
                    openSettings: { presentedSheet = .settings }
                )

                if session.state == .finalizing {
                    RecordingFinalizationStatus(
                        label: session.finalizationLabel ?? AppLocalization.string("Procesando"),
                        progress: session.finalizationProgress
                    )
                    .libraryStatusCard()
                }

                if session.modelPreparation.isBusy, settings.engine == .nemotron {
                    ModelWarmupStatus(state: session.modelPreparation)
                        .libraryStatusCard()
                }

                if recordings.isEmpty {
                    LibraryEmptyState()
                        .padding(.top, appLayoutMode == .pad ? 56 : 128)
                        .frame(minHeight: appLayoutMode == .pad ? 380 : 470, alignment: .top)
                } else if filteredRecordings.isEmpty {
                    ContentUnavailableView.search(text: searchQuery)
                        .frame(minHeight: appLayoutMode == .pad ? 300 : 400)
                } else {
                    LazyVStack(spacing: AppVisualStyle.cardSpacing) {
                        ForEach(filteredRecordings) { recording in
                            recordingListItem(recording)
                        }
                    }
                }
            }
            .frame(maxWidth: appLayoutMode == .pad ? 560 : 680)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, AppVisualStyle.pageHorizontalPadding)
            .padding(.top, 0)
            .padding(.bottom, 18)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(AppVisualStyle.screenBackground.ignoresSafeArea())
        .task(id: searchText) { try? await Task.sleep(for: .milliseconds(180)); guard !Task.isCancelled else { return }; searchQuery = searchText }
        .toolbarVisibility(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .bottom) {
            FloatingCaptureBar(
                isImporting: $isImporting,
                isBusy: session.state != .idle,
                engine: settings.engine,
                selectedInputLanguage: settings.language,
                translationEnabled: settings.translationEnabled,
                translationTargets: translationAvailability.supportedTargets,
                selectedTranslationTarget: settings.translationTargetLanguage,
                record: { Task { await startRecording() } },
                selectInputLanguage: { language in Task { await selectInputLanguage(language) } },
                toggleTranslation: { Task { await toggleTranslation() } },
                selectTranslationTarget: { code in
                    Task { await selectTranslationTarget(code) }
                }
            )
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .settings: 
                NavigationStack { SettingsView(settings: settings) }
                    .environment(\.locale, appUiLanguage == "system" ? Locale.current : Locale(identifier: appUiLanguage))
            case .translationSetup:
                TranslationSetupView(settings: settings, availability: translationAvailability) {
                    Task { await translationAvailability.refresh(settings: settings) }
                }
                .environment(\.locale, appUiLanguage == "system" ? Locale.current : Locale(identifier: appUiLanguage))
            }
        }
        .sheet(item: Bindable(exportCoordinator).sharePayload) { payload in
            SystemShareSheet(payload: payload)
        }
        .fullScreenCover(isPresented: $isShowingRecorder) {
            RecordingView(settings: settings, session: session)
        }
        .fullScreenCover(isPresented: $isShowingModelSetup) {
            ModelSetupView(settings: settings, session: session) {
                isShowingModelSetup = false
            }
        }
        .task {
            await translationAvailability.refresh(settings: settings)
        }
        .task(id: "\(settings.language.rawValue)-\(settings.translationTargetLanguage)-\(settings.translationLanguageCodes.joined(separator: ","))") {
            await translationAvailability.refresh(settings: settings)
        }
        .task(id: "\(settings.engine.rawValue)-\(settings.nemotronPrepared)") {
            guard settings.engine == .nemotron, settings.nemotronPrepared else { return }
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await session.prewarmNemotron(settings: settings)
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.mpeg4Audio, .wav, UTType(filenameExtension: "caf") ?? .audio, .json],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            Task { await handleImportedURLs(urls) }
        }
        .overlay {
            if let progress = session.importProgress {
                ProcessingOverlay(title: AppLocalization.string("Transcribiendo archivo"), progress: progress)
            }
        }
        .alert("Eliminar grabación", isPresented: Binding(
            get: { recordingIDToDelete != nil },
            set: { if !$0 { recordingIDToDelete = nil } }
        )) {
            Button("Cancelar", role: .cancel) { recordingIDToDelete = nil }
            Button("Eliminar", role: .destructive) { deleteSelectedRecording() }
        } message: { Text("También se eliminarán el audio y la transcripción.") }
        .alert("No se pudo completar", isPresented: Binding(
            get: { if case .failed = session.state { true } else { false } },
            set: { if !$0 { session.resetError() } }
        )) {
            Button("Aceptar") { session.resetError() }
        } message: {
            if case .failed(let message) = session.state { Text(message) }
        }
        .alert("Subtítulos traducidos", isPresented: Binding(
            get: { translationMessage != nil },
            set: { if !$0 { translationMessage = nil } }
        )) {
            Button("Aceptar", role: .cancel) {}
        } message: { Text(translationMessage ?? "") }
        .alert("Renombrar grabación", isPresented: Binding(get: { recordingIDToRename != nil }, set: { if !$0 { recordingIDToRename = nil } })) {
            TextField("Nombre", text: $renameDraft)
            Button("Cancelar", role: .cancel) { recordingIDToRename = nil }
            Button("Guardar") { commitRename() }.disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("Importación", isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) { Button("Aceptar", role: .cancel) {} } message: { Text(importMessage ?? "") }
        .alert("No se pudo exportar", isPresented: Binding(
            get: { exportCoordinator.errorMessage != nil },
            set: { if !$0 { exportCoordinator.errorMessage = nil } }
        )) {
            Button("Aceptar", role: .cancel) {}
        } message: { Text(exportCoordinator.errorMessage ?? "") }
    }

    private func recordingListItem(_ recording: Recording) -> some View {
        RecordingLibraryCard(
            recording: recording,
            coordinator: exportCoordinator,
            isSelected: selectedRecordingID == recording.id,
            open: openAction(for: recording),
            rename: { beginRename(recording) },
            delete: { recordingIDToDelete = recording.id }
        )
    }

    private func beginRename(_ recording: Recording) { recordingIDToRename = recording.id; renameDraft = recording.title }
    private func openAction(for recording: Recording) -> (() -> Void)? {
        guard let openRecording else { return nil }
        return { openRecording(recording.id) }
    }
    private func commitRename() {
        guard let id = recordingIDToRename, let recording = recordings.first(where: { $0.id == id }) else { return }
        let clean = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines); guard !clean.isEmpty else { return }
        recording.title = clean; try? context.save(); try? RecordingRecoveryStore.write(.init(recording: recording)); recordingIDToRename = nil
    }
    private func handleImportedURLs(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        if urls.contains(where: { $0.pathExtension.lowercased() == "json" }) {
            do { _ = try await RecordingArchiveImportService.restore(from: urls, context: context); importMessage = AppLocalization.string("La copia se restauró correctamente.") }
            catch { importMessage = error.localizedDescription }
            return
        }
        for url in urls {
            _ = await session.importFile(url, settings: settings, context: context)
            if case .failed(let message) = session.state { importMessage = message; session.resetError(); break }
        }
    }

    private func startRecording() async {
        guard session.state == .idle else { return }
        if settings.engine == .nemotron, !settings.nemotronPrepared {
            isShowingModelSetup = true
            return
        }
        if settings.translationEnabled {
            await translationAvailability.refresh(settings: settings)
            guard translationAvailability.state.isReady else {
                if case .needsDownload = translationAvailability.state {
                    presentedSheet = .translationSetup
                } else {
                    translationMessage = translationAvailability.state.explanation
                }
                return
            }
        }
        isShowingRecorder = true
    }

    private func toggleTranslation() async {
        if settings.translationEnabled {
            settings.translationEnabled = false
            return
        }
        await translationAvailability.refresh(settings: settings)
        switch translationAvailability.state {
        case .ready:
            settings.translationEnabled = true
        case .needsDownload:
            presentedSheet = .translationSetup
        default:
            translationMessage = translationAvailability.state.explanation
        }
    }

    private func selectInputLanguage(_ language: TranscriptionLanguage) async {
        let shouldRemainEnabled = settings.translationEnabled
        settings.language = language
        if let source = language.translationSourceCode,
           TranslationPolicy.sameLanguage(source, settings.translationTargetLanguage) {
            settings.translationTargetLanguage = AppSettings.defaultTranslationTarget(for: language)
        }
        await translationAvailability.refresh(settings: settings)
        guard shouldRemainEnabled else { settings.translationEnabled = false; return }
        switch translationAvailability.state {
        case .ready: settings.translationEnabled = true
        case .needsDownload: settings.translationEnabled = false; presentedSheet = .translationSetup
        default: settings.translationEnabled = false; translationMessage = translationAvailability.state.explanation
        }
    }

    private func selectTranslationTarget(_ code: String) async {
        if let source = settings.language.translationSourceCode,
           TranslationPolicy.sameLanguage(source, code) {
            translationMessage = AppLocalization.string("El idioma hablado y el idioma de traducción deben ser diferentes.")
            return
        }
        let shouldRemainEnabled = settings.translationEnabled
        settings.translationTargetLanguage = code
        await translationAvailability.refresh(settings: settings)
        guard shouldRemainEnabled else { settings.translationEnabled = false; return }
        switch translationAvailability.state {
        case .ready:
            settings.translationEnabled = true
        case .needsDownload:
            presentedSheet = .translationSetup
        default:
            translationMessage = translationAvailability.state.explanation
        }
    }

    private func deleteSelectedRecording() {
        guard let id = recordingIDToDelete,
              let recording = recordings.first(where: { $0.id == id }),
              recording.status != .processing
        else { return }
        context.delete(recording)
        try? context.save()
        Task { try? await StorageService.shared.removeRecording(id: id) }
        recordingDeleted?(id)
        recordingIDToDelete = nil
    }
}

private struct RecordingFinalizationStatus: View {
    let label: String
    let progress: Double?

    var body: some View {
        HStack(spacing: 12) {
            if let progress {
                ProgressView(value: progress).frame(width: 42)
            } else {
                ProgressView()
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(.subheadline.weight(.medium))
                Text(AppLocalization.string("El audio ya está guardado"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

private struct ModelWarmupStatus: View {
    let state: ModelPreparationState

    var body: some View {
        HStack(spacing: 12) {
            if let progress = state.progress {
                ProgressView(value: progress)
                    .frame(width: 42)
            } else {
                ProgressView()
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(state.label)
                    .font(.subheadline.weight(.medium))
                if let progress = state.progress {
                    Text(progress, format: .percent.precision(.fractionLength(0)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else if state == .loading {
                    Text("La descarga ya terminó")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

private struct FloatingCaptureBar: View {
    @Binding var isImporting: Bool
    let isBusy: Bool
    let engine: TranscriptionEngineKind
    let selectedInputLanguage: TranscriptionLanguage
    let translationEnabled: Bool
    let translationTargets: [TranslationLanguageOption]
    let selectedTranslationTarget: String
    let record: () -> Void
    let selectInputLanguage: (TranscriptionLanguage) -> Void
    let toggleTranslation: () -> Void
    let selectTranslationTarget: (String) -> Void

    var body: some View {
        VStack(spacing: 8) {
            languageRoute
            captureTray
        }
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, AppVisualStyle.pageHorizontalPadding)
        .padding(.top, 4)
        .padding(.bottom, 2)
        .disabled(isBusy)
    }

    private var languageRoute: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(inputLanguages) { language in
                    Button { selectInputLanguage(language) } label: {
                        if language == selectedInputLanguage {
                            Label(language.displayName, systemImage: "checkmark")
                        } else {
                            Text(language.displayName)
                        }
                    }
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "globe")
                        .font(.title3)
                    Text(selectedInputLanguage.displayName)
                        .font(.subheadline.bold())
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .tint(.primary)

            if translationEnabled {
                Image(systemName: "arrow.right")
                    .font(.subheadline.bold())
                    .foregroundStyle(.blue)
                    .accessibilityHidden(true)

                Menu {
                    ForEach(translationTargets) { language in
                        Button { selectTranslationTarget(language.code) } label: {
                            if TranslationPolicy.sameLanguage(language.code, selectedTranslationTarget) {
                                Label(language.displayName, systemImage: "checkmark")
                            } else {
                                Text(language.displayName)
                            }
                        }
                        .disabled(selectedInputLanguage.translationSourceCode.map {
                            TranslationPolicy.sameLanguage($0, language.code)
                        } ?? false)
                    }
                    if translationTargets.isEmpty { Text("Comprobando idiomas…") }
                } label: {
                    HStack(spacing: 6) {
                        Text(TranslationPolicy.displayName(for: selectedTranslationTarget))
                            .font(.subheadline.bold())
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.caption2.bold())
                    }
                    .foregroundStyle(.blue)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .tint(.blue)
            }

            Divider()
                .frame(height: 24)

            Toggle("Traducir", isOn: translationBinding)
                .font(.subheadline.bold())
                .foregroundStyle(translationEnabled ? .blue : .secondary)
                .tint(.blue)
                .toggleStyle(CompactSwitchToggleStyle())
                .fixedSize()
        }
        .padding(.horizontal, 15)
        .frame(minHeight: 44)
        .background {
            Capsule()
                .fill(.regularMaterial)
                .frame(height: 32)
                .overlay(Capsule().stroke(.secondary.opacity(0.14), lineWidth: 1))
                .shadow(color: .black.opacity(0.08), radius: 9, y: 4)
        }
        .accessibilityElement(children: .contain)
    }

    private var captureTray: some View {
        ZStack {
            HStack {
                Button("Importar audio", systemImage: "doc.badge.plus") {
                    isImporting = true
                }
                .labelStyle(.iconOnly)
                .font(.title3)
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().stroke(.secondary.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.07), radius: 5, y: 2)
                .frame(width: 44, height: 44)

                Spacer()

                Color.clear
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)
            }

            Button(action: record) {
                ZStack {
                    Circle()
                        .fill(.red.opacity(0.14))
                        .frame(width: 46, height: 46)
                    Circle()
                        .fill(.red)
                        .frame(width: 38, height: 38)
                    Circle()
                        .fill(.white)
                        .frame(width: 12, height: 12)
                }
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AppLocalization.string("Iniciar grabación · idioma de entrada \(selectedInputLanguage.displayName)"))
        }
        .padding(.horizontal, 18)
        .frame(height: 58)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.9), lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 14, y: 8)
    }

    private var translationBinding: Binding<Bool> {
        Binding(
            get: { translationEnabled },
            set: { newValue in
                guard newValue != translationEnabled else { return }
                toggleTranslation()
            }
        )
    }

    private var inputLanguages: [TranscriptionLanguage] {
        engine == .nemotron ? TranscriptionLanguage.allCases : [.spanish, .english, .german]
    }
}

private struct CompactSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                configuration.label

                ZStack {
                    Capsule()
                        .fill(configuration.isOn ? Color.accentColor : Color.secondary.opacity(0.32))

                    HStack(spacing: 0) {
                        if configuration.isOn { Spacer(minLength: 0) }
                        Circle()
                            .fill(.white)
                            .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                        if !configuration.isOn { Spacer(minLength: 0) }
                    }
                    .padding(3)
                }
                .frame(width: 32, height: 20)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.18), value: configuration.isOn)
    }
}

private extension TranslationAvailabilityState {
    var explanation: String {
        switch self {
        case .checking: AppLocalization.string("Comprobando los idiomas de traducción.")
        case .ready: AppLocalization.string("Los idiomas están listos.")
        case .needsDownload: AppLocalization.string("Necesitas descargar los idiomas antes de grabar.")
        case .unsupported(let message), .unavailable(let message), .failed(let message): message
        }
    }
}

private struct ProcessingOverlay: View {
    let title: String
    let progress: Double
    var body: some View {
        VStack(spacing: 16) {
            ProgressView(value: progress).frame(width: 190)
            Text(title).font(.headline)
            Text(progress, format: .percent.precision(.fractionLength(0))).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(28).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24)).shadow(radius: 20)
    }
}

extension TimeInterval {
    var formattedDuration: String {
        let total = max(0, Int(self.rounded()))
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
