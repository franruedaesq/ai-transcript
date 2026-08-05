import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    let settings: AppSettings
    let session: RecordingSessionController
    @Environment(\.modelContext) private var context
    @Query(sort: \Recording.createdAt, order: .reverse) private var recordings: [Recording]
    @State private var presentedSheet: SheetDestination?
    @State private var isShowingRecorder = false
    @State private var isShowingModelSetup = false
    @State private var isImporting = false
    @State private var recordingIDToDelete: UUID?
    @State private var translationAvailability = TranslationAvailabilityController()
    @State private var exportCoordinator = RecordingExportCoordinator()
    @State private var translationMessage: String?

    enum SheetDestination: String, Identifiable {
        case settings
        case translationSetup
        var id: String { rawValue }
    }

    var body: some View {
        List {
            if session.modelPreparation.isBusy, settings.engine == .nemotron {
                Section {
                    ModelWarmupStatus(state: session.modelPreparation)
                        .listRowSeparator(.hidden)
                }
            }
            Section {
                if recordings.isEmpty {
                    ContentUnavailableView(
                        "Sin grabaciones",
                        systemImage: "waveform",
                        description: Text("Graba o importa un audio para comenzar.")
                    )
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(recordings) { recording in
                        HStack(spacing: 8) {
                            NavigationLink(value: recording.id) {
                                RecordingRow(recording: recording)
                            }
                            .buttonStyle(.plain)

                            RecordingActionsMenu(
                                recording: recording,
                                coordinator: exportCoordinator,
                                includeDelete: true,
                                delete: { recordingIDToDelete = recording.id }
                            )
                        }
                            .listRowInsets(.init(top: 14, leading: 20, bottom: 14, trailing: 16))
                            .swipeActions {
                                Button(role: .destructive) { recordingIDToDelete = recording.id } label: {
                                    Label("Eliminar", systemImage: "trash")
                                }
                            }
                    }
                }
            } header: {
                HStack {
                    Label("Todas · \(recordings.count)", systemImage: "folder")
                        .font(.subheadline.weight(.medium))
                        .textCase(nil)
                    Spacer()
                }
                .padding(.vertical, 8)
            }
        }
        .listStyle(.plain)
        .navigationTitle("Grabaciones")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { presentedSheet = .settings } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Ajustes")
            }
        }
        .safeAreaInset(edge: .bottom) {
            FloatingCaptureBar(
                isImporting: $isImporting,
                translationEnabled: settings.translationEnabled,
                translationState: translationAvailability.state,
                translationTargets: translationAvailability.supportedTargets,
                selectedTranslationTarget: settings.translationTargetLanguage,
                record: { Task { await startRecording() } },
                toggleTranslation: { Task { await toggleTranslation() } },
                selectTranslationTarget: { code in
                    Task { await selectTranslationTarget(code) }
                }
            )
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .settings: NavigationStack { SettingsView(settings: settings) }
            case .translationSetup:
                TranslationSetupView(settings: settings, availability: translationAvailability) {
                    Task { await translationAvailability.refresh(settings: settings) }
                }
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
            if settings.engine == .nemotron, !settings.nemotronPrepared {
                isShowingModelSetup = true
            }
            await translationAvailability.refresh(settings: settings)
        }
        .task(id: "\(settings.language.rawValue)-\(settings.translationTargetLanguage)") {
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
            allowedContentTypes: [.mpeg4Audio, .wav, UTType(filenameExtension: "caf") ?? .audio],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task { _ = await session.importFile(url, settings: settings, context: context) }
        }
        .overlay {
            if let progress = session.importProgress {
                ProcessingOverlay(title: "Transcribiendo archivo", progress: progress)
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
        .alert("No se pudo exportar", isPresented: Binding(
            get: { exportCoordinator.errorMessage != nil },
            set: { if !$0 { exportCoordinator.errorMessage = nil } }
        )) {
            Button("Aceptar", role: .cancel) {}
        } message: { Text(exportCoordinator.errorMessage ?? "") }
    }

    private func startRecording() async {
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

    private func selectTranslationTarget(_ code: String) async {
        settings.translationTargetLanguage = code
        settings.translationEnabled = false
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

    private func deleteSelectedRecording() {
        guard let id = recordingIDToDelete, let recording = recordings.first(where: { $0.id == id }) else { return }
        context.delete(recording)
        try? context.save()
        Task { try? await StorageService.shared.removeRecording(id: id) }
        recordingIDToDelete = nil
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
    let translationEnabled: Bool
    let translationState: TranslationAvailabilityState
    let translationTargets: [TranslationLanguageOption]
    let selectedTranslationTarget: String
    let record: () -> Void
    let toggleTranslation: () -> Void
    let selectTranslationTarget: (String) -> Void

    var body: some View {
        HStack(spacing: 48) {
            Button { isImporting = true } label: {
                Image(systemName: "doc.badge.plus")
                    .font(.title2)
                    .frame(width: 58, height: 58)
            }
            .buttonStyle(.recorderGlass)
            .accessibilityLabel("Importar audio")
            .contextMenu {
                Button { isImporting = true } label: {
                    Label("Importar audio", systemImage: "doc.badge.plus")
                }
            }

            Button(action: record) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 82, height: 82)
                    .background(.red, in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 4).padding(6))
                    .shadow(color: .red.opacity(0.24), radius: 12, y: 6)
            }
            .accessibilityLabel("Iniciar grabación")

            Button(action: toggleTranslation) {
                Image(systemName: translationIcon)
                    .font(.title2)
                    .foregroundStyle(translationColor)
                    .frame(width: 58, height: 58)
                    .overlay(alignment: .topTrailing) {
                        if translationEnabled {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.blue)
                                .background(.background, in: Circle())
                                .offset(x: 2, y: -2)
                        }
                    }
            }
            .buttonStyle(.recorderGlass)
            .accessibilityLabel(translationEnabled ? "Desactivar subtítulos traducidos" : "Activar subtítulos traducidos")
            .accessibilityHint(translationState.explanation)
            .contextMenu {
                Section("Modo de traducción") {
                    Button(action: toggleTranslation) {
                        Label(
                            translationEnabled ? "Desactivar traducción" : "Activar traducción",
                            systemImage: translationEnabled ? "translate" : "translate"
                        )
                    }
                    Menu("Traducir a") {
                        ForEach(translationTargets) { language in
                            Button {
                                selectTranslationTarget(language.code)
                            } label: {
                                if TranslationPolicy.sameLanguage(language.code, selectedTranslationTarget) {
                                    Label(language.displayName, systemImage: "checkmark")
                                } else {
                                    Text(language.displayName)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
    }

    private var translationIcon: String {
        if translationEnabled { return "translate" }
        if case .needsDownload = translationState { return "arrow.down.circle" }
        return "translate"
    }

    private var translationColor: Color {
        if translationEnabled { return .blue }
        if case .needsDownload = translationState { return .orange }
        if case .ready = translationState { return .primary }
        return .secondary
    }
}

private extension TranslationAvailabilityState {
    var explanation: String {
        switch self {
        case .checking: "Comprobando los idiomas de traducción."
        case .ready: "Los idiomas están listos."
        case .needsDownload: "Necesitas descargar los idiomas antes de grabar."
        case .unsupported(let message), .unavailable(let message), .failed(let message): message
        }
    }
}

private struct RecordingRow: View {
    let recording: Recording

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(recording.title).font(.headline).lineLimit(1)
                Spacer()
                if recording.status != .saved {
                    Text(recording.status == .interrupted ? "Interrumpida" : "Procesando")
                        .font(.caption.weight(.semibold)).foregroundStyle(.orange)
                }
            }
            HStack {
                Text(recording.createdAt, format: .dateTime.day().month(.abbreviated))
                Text("·")
                Text(recording.duration.formattedDuration)
                Spacer()
                Text(recording.detectedLanguage ?? recording.requestedLanguage.displayName)
            }
            .font(.subheadline).foregroundStyle(.secondary)
            MiniWaveform(seed: recording.id.hashValue)
            if !recording.transcript.isEmpty {
                Text(recording.transcript).font(.subheadline).lineLimit(2).foregroundStyle(.secondary)
            }
        }
    }
}

private struct MiniWaveform: View {
    let seed: Int
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<40, id: \.self) { index in
                Capsule().fill(.blue.opacity(0.75)).frame(width: 2, height: CGFloat(4 + abs((seed &+ index * 17) % 16)))
            }
        }.frame(height: 22)
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
