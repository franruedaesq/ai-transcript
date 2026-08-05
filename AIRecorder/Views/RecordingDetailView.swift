import SwiftData
import SwiftUI

struct RecordingDetailLookupView: View {
    let recordingID: UUID
    let settings: AppSettings
    @Query private var recordings: [Recording]

    init(recordingID: UUID, settings: AppSettings) {
        self.recordingID = recordingID
        self.settings = settings
        _recordings = Query(filter: #Predicate<Recording> { $0.id == recordingID })
    }

    var body: some View {
        if let recording = recordings.first {
            RecordingDetailView(recording: recording, settings: settings)
        } else {
            ContentUnavailableView("Grabación no encontrada", systemImage: "exclamationmark.triangle")
        }
    }
}

private enum RecordingTextTab: String, CaseIterable, Identifiable {
    case transcript
    case translation

    var id: String { rawValue }
    var title: String { self == .transcript ? "Transcripción" : "Traducción" }
}

private enum TranscriptFontSize: String, CaseIterable, Identifiable {
    case small
    case standard
    case large
    case extraLarge

    var id: String { rawValue }
    var title: String {
        switch self {
        case .small: "Pequeño"
        case .standard: "Normal"
        case .large: "Grande"
        case .extraLarge: "Muy grande"
        }
    }

    var font: Font {
        switch self {
        case .small: .callout
        case .standard: .body
        case .large: .title3
        case .extraLarge: .title2
        }
    }
}

struct RecordingDetailView: View {
    let recording: Recording
    let settings: AppSettings
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var playback = PlaybackController()
    @State private var translator = SubtitleTranslationController()
    @State private var exportCoordinator = RecordingExportCoordinator()
    @State private var selectedTab: RecordingTextTab = .transcript
    @State private var errorMessage: String?
    @State private var isTranslating = false
    @State private var isShowingTranslationSetup = false
    @State private var isConfirmingDelete = false
    @AppStorage("reader.transcriptFontSize") private var storedFontSize = TranscriptFontSize.standard.rawValue

    private var fontSize: TranscriptFontSize {
        TranscriptFontSize(rawValue: storedFontSize) ?? .standard
    }
    private var cueValues: [TranscriptionCueValue] { recording.orderedCues.map(\.value) }
    private var hasTranslation: Bool {
        !recording.orderedTranslatedCues.isEmpty
            || recording.orderedCues.contains(where: { $0.translatedText?.isEmpty == false })
    }
    private var activeIndex: Int? {
        CueTimeline.activeIndex(at: playback.currentTime, cues: cueValues)
    }
    private var activeTranslatedIndex: Int? {
        recording.orderedTranslatedCues.first {
            playback.currentTime >= $0.startTime && playback.currentTime <= $0.endTime
        }?.index
    }
    private var sourceLanguage: String? {
        switch recording.requestedLanguage {
        case .spanish: "es"
        case .english: "en"
        case .german: "de"
        case .automatic: recording.detectedLanguage.flatMap(SpokenLanguageResolver.canonicalCode)
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                playbackSection

                Section {
                    Picker("Contenido", selection: $selectedTab) {
                        ForEach(RecordingTextTab.allCases) { tab in Text(tab.title).tag(tab) }
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(.init(top: 8, leading: 16, bottom: 8, trailing: 16))
                }

                if selectedTab == .transcript {
                    transcriptSection
                } else {
                    translationSection
                }
            }
            .onChange(of: activeIndex) { _, index in
                guard selectedTab == .transcript, let index else { return }
                withAnimation { proxy.scrollTo("original-\(index)", anchor: .center) }
            }
            .onChange(of: activeTranslatedIndex) { _, index in
                guard selectedTab == .translation, let index else { return }
                withAnimation { proxy.scrollTo("translation-\(index)", anchor: .center) }
            }
        }
        .navigationTitle(recording.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                fontSizeMenu
                RecordingActionsMenu(
                    recording: recording,
                    coordinator: exportCoordinator,
                    includeDelete: true,
                    delete: { isConfirmingDelete = true }
                )
            }
        }
        .task {
            do {
                try playback.load(url: try await StorageService.shared.resolve(relativePath: recording.audioRelativePath))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .onDisappear { playback.stop() }
        .sheet(item: Bindable(exportCoordinator).sharePayload) { payload in
            SystemShareSheet(payload: payload)
        }
        .sheet(isPresented: $isShowingTranslationSetup) {
            RecordingTranslationSheet(
                sourceLanguage: sourceLanguage,
                initialTarget: recording.translationTargetLanguage ?? settings.translationTargetLanguage
            ) { target in
                await translateRecording(to: target, replacingExisting: true)
            }
        }
        .alert("No se pudo completar", isPresented: Binding(
            get: { errorMessage != nil || exportCoordinator.errorMessage != nil },
            set: {
                if !$0 {
                    errorMessage = nil
                    exportCoordinator.errorMessage = nil
                }
            }
        )) {
            Button("Aceptar", role: .cancel) {}
        } message: {
            Text(errorMessage ?? exportCoordinator.errorMessage ?? "")
        }
        .alert("Eliminar grabación", isPresented: $isConfirmingDelete) {
            Button("Cancelar", role: .cancel) {}
            Button("Eliminar", role: .destructive) { deleteRecording() }
        } message: {
            Text("También se eliminarán el audio, la transcripción y la traducción.")
        }
    }

    private var playbackSection: some View {
        Section {
            VStack(spacing: 18) {
                Slider(
                    value: Binding(get: { playback.currentTime }, set: { playback.seek(to: $0) }),
                    in: 0...max(0.1, playback.duration)
                )
                HStack {
                    Text(playback.currentTime.formattedDuration).monospacedDigit()
                    Spacer()
                    Text(playback.duration.formattedDuration).monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                HStack(spacing: 42) {
                    Button { playback.skip(-15) } label: { Image(systemName: "gobackward.15") }
                    Button { playback.toggle() } label: {
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2)
                            .frame(width: 56, height: 56)
                            .background(.blue, in: Circle())
                            .foregroundStyle(.white)
                    }
                    Button { playback.skip(15) } label: { Image(systemName: "goforward.15") }
                }
                .font(.title2)
                .buttonStyle(.plain)
            }
            .padding(.vertical, 12)
        }
    }

    private var transcriptSection: some View {
        Section("Transcripción") {
            if recording.orderedCues.isEmpty {
                Text(recording.transcript.isEmpty ? "Sin transcripción" : recording.transcript)
                    .font(fontSize.font)
                    .lineSpacing(5)
                    .foregroundStyle(recording.transcript.isEmpty ? .secondary : .primary)
            } else {
                ForEach(recording.orderedCues) { cue in
                    Button { playback.seek(to: cue.startTime) } label: {
                        cueRow(time: cue.startTime, text: cue.text, highlighted: activeIndex == cue.index)
                    }
                    .buttonStyle(.plain)
                    .id("original-\(cue.index)")
                }
            }
        }
    }

    @ViewBuilder
    private var translationSection: some View {
        Section("Traducción") {
            if isTranslating {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Traduciendo la grabación…")
                }
            } else if !recording.orderedTranslatedCues.isEmpty {
                ForEach(recording.orderedTranslatedCues) { cue in
                    Button { playback.seek(to: cue.startTime) } label: {
                        cueRow(
                            time: cue.startTime,
                            text: cue.text,
                            highlighted: activeTranslatedIndex == cue.index
                        )
                    }
                    .buttonStyle(.plain)
                    .id("translation-\(cue.index)")
                }
            } else if hasTranslation {
                ForEach(recording.orderedCues) { cue in
                    if let translated = cue.translatedText {
                        Button { playback.seek(to: cue.startTime) } label: {
                            cueRow(time: cue.startTime, text: translated, highlighted: activeIndex == cue.index)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("Sin traducción", systemImage: "translate")
                } description: {
                    Text("Puedes traducir esta transcripción completamente en el dispositivo.")
                } actions: {
                    Button("Traducir esta grabación") {
                        isShowingTranslationSetup = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(sourceLanguage == nil || recording.transcript.isEmpty)
                }
            }

            if recording.translationStatus == .partial || recording.translationStatus == .failed {
                Button {
                    Task {
                        guard let target = recording.translationTargetLanguage else {
                            isShowingTranslationSetup = true
                            return
                        }
                        _ = await translateRecording(to: target, replacingExisting: false)
                    }
                } label: {
                    Label("Reintentar bloques pendientes", systemImage: "arrow.clockwise")
                }
                .disabled(isTranslating)
            }

            if hasTranslation {
                Button("Cambiar idioma de traducción") {
                    isShowingTranslationSetup = true
                }
                .disabled(isTranslating)
            }
        }
    }

    private func cueRow(time: TimeInterval, text: String, highlighted: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(time.formattedDuration)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .leading)
            Text(text)
                .font(fontSize.font)
                .lineSpacing(5)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .listRowBackground(highlighted ? Color.blue.opacity(0.12) : Color.clear)
    }

    private var fontSizeMenu: some View {
        Menu {
            ForEach(TranscriptFontSize.allCases) { size in
                Button {
                    storedFontSize = size.rawValue
                } label: {
                    if size == fontSize {
                        Label(size.title, systemImage: "checkmark")
                    } else {
                        Text(size.title)
                    }
                }
            }
        } label: {
            Image(systemName: "textformat.size")
        }
        .accessibilityLabel("Tamaño del texto")
    }

    private func translateRecording(to target: String, replacingExisting: Bool) async -> Bool {
        guard let sourceLanguage else {
            errorMessage = "No se pudo determinar el idioma original."
            return false
        }
        guard !TranslationPolicy.sameLanguage(sourceLanguage, target) else {
            errorMessage = "El idioma original y el idioma de traducción son iguales."
            return false
        }

        isTranslating = true
        defer { isTranslating = false }
        if replacingExisting {
            for cue in recording.translatedCues { context.delete(cue) }
            recording.translatedCues = []
            recording.cues.forEach { $0.translatedText = nil }
        }

        let sourceCues: [TranscriptionCueValue]
        if cueValues.isEmpty, !recording.transcript.isEmpty {
            sourceCues = [.init(
                index: 0,
                startTime: 0,
                endTime: recording.duration,
                text: recording.transcript,
                confidence: 1
            )]
        } else {
            sourceCues = cueValues
        }
        let groups = ContextualTranslationGrouper.groups(from: sourceCues)
        for (index, group) in groups.enumerated() {
            if !replacingExisting, recording.translatedCues.contains(where: {
                $0.sourceStartIndex == group.first?.index && $0.sourceEndIndex == group.last?.index
            }) { continue }
            do {
                let text = try await translator.translate(
                    group.map(\.text).joined(separator: " "),
                    source: sourceLanguage,
                    target: target,
                    quality: .highFidelity
                )
                if let value = ContextualTranslationGrouper.value(
                    for: group,
                    translatedText: text,
                    index: index
                ) {
                    let cue = TranslatedSubtitleCue(value: value)
                    cue.recording = recording
                    recording.translatedCues.append(cue)
                }
            } catch {
                continue
            }
        }

        let missing = max(0, groups.count - recording.translatedCues.count)
        recording.translationEnabled = true
        recording.translationTargetLanguage = target
        recording.translationStatus = missing == 0
            ? .complete
            : (recording.translatedCues.isEmpty ? .failed : .partial)
        do {
            try context.save()
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        if recording.translatedCues.isEmpty {
            errorMessage = "No se pudo traducir esta grabación."
            return false
        }
        return true
    }

    private func deleteRecording() {
        let id = recording.id
        context.delete(recording)
        try? context.save()
        Task { try? await StorageService.shared.removeRecording(id: id) }
        dismiss()
    }
}
