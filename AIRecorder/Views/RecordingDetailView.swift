import SwiftData
import SwiftUI
import UIKit

struct RecordingDetailLookupView: View {
    let recordingID: UUID
    let settings: AppSettings
    let recordingDeleted: ((UUID) -> Void)?
    @Query private var recordings: [Recording]

    init(
        recordingID: UUID,
        settings: AppSettings,
        recordingDeleted: ((UUID) -> Void)? = nil
    ) {
        self.recordingID = recordingID
        self.settings = settings
        self.recordingDeleted = recordingDeleted
        _recordings = Query(filter: #Predicate<Recording> { $0.id == recordingID })
    }

    var body: some View {
        if let recording = recordings.first {
            RecordingDetailView(
                recording: recording,
                settings: settings,
                recordingDeleted: recordingDeleted
            )
        } else {
            ContentUnavailableView("Grabación no encontrada", systemImage: "exclamationmark.triangle")
        }
    }
}

enum RecordingTextTab: String, CaseIterable, Identifiable {
    case transcript
    case translation

    var id: String { rawValue }
    var title: String {
        AppLocalization.string(self == .transcript ? "Transcripción" : "Traducción")
    }
}

private enum TranscriptFontSize: String, CaseIterable, Identifiable {
    case small
    case standard
    case large
    case extraLarge

    var id: String { rawValue }
    var title: String {
        switch self {
        case .small: AppLocalization.string("Pequeño")
        case .standard: AppLocalization.string("Normal")
        case .large: AppLocalization.string("Grande")
        case .extraLarge: AppLocalization.string("Muy grande")
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

private struct CueEditTarget: Identifiable { let id: UUID; let text: String }

private struct RecordingDetailRenderData {
    let originalCues: [TranscriptCue]
    let translatedCues: [TranslatedSubtitleCue]
    let markers: [RecordingMarker]
    let activeOriginalIndex: Int?
    let activeTranslatedIndex: Int?
    let hasTranslation: Bool
    let speakers: [SpeakerSummaryItem]
    let speakerNames: [String: String]
    let speakerColorIndexes: [String: Int]

    @MainActor
    init(recording: Recording, currentTime: TimeInterval) {
        let orderedOriginalCues = recording.orderedCues
        let orderedTranslatedCues = recording.orderedTranslatedCues

        originalCues = orderedOriginalCues
        let resolvedSpeakerNames = Dictionary(uniqueKeysWithValues: recording.speakerProfiles.map {
            ($0.speakerID, $0.name ?? SpeakerLabelFormatter.displayName(for: $0.speakerID))
        })
        speakerNames = resolvedSpeakerNames
        speakerColorIndexes = Dictionary(uniqueKeysWithValues: recording.speakerProfiles.map {
            ($0.speakerID, $0.colorIndex)
        })
        translatedCues = orderedTranslatedCues
        markers = recording.orderedMarkers
        activeOriginalIndex = CueTimeline.activeIndex(
            at: currentTime,
            cues: orderedOriginalCues.map(\.value)
        )
        activeTranslatedIndex = orderedTranslatedCues.first {
            currentTime >= $0.startTime && currentTime <= $0.endTime
        }?.index
        hasTranslation = !orderedTranslatedCues.isEmpty
            || orderedOriginalCues.contains { $0.translatedText?.isEmpty == false }
        speakers = SpeakerSummaryBuilder.items(for: recording)
    }
}

private struct SpeakerSheetDestination: Identifiable {
    let id: UUID
}

private struct ReviewScrollRequest: Equatable {
    let id = UUID()
    let destinationID: String
    let tab: RecordingTextTab
}

private enum RecordingAudioAvailability {
    case loading
    case available
    case unavailable
}

private struct CueEditorSheet: View {
    let initialText: String
    let save: @MainActor (String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var isSaving = false
    init(initialText: String, save: @escaping @MainActor (String) async -> Bool) { self.initialText = initialText; self.save = save; _text = State(initialValue: initialText) }
    var body: some View {
        NavigationStack { Form { Section("Texto") { TextEditor(text: $text).frame(minHeight: 160) }; Section { Text("Al guardar, sólo se regeneran los bloques traducidos que dependen de este fragmento.").font(.caption).foregroundStyle(.secondary) } }
            .navigationTitle("Editar transcripción").navigationBarTitleDisplayMode(.inline).toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() }.disabled(isSaving) }
                ToolbarItem(placement: .confirmationAction) { Button("Guardar") { Task { isSaving = true; let success = await save(text); isSaving = false; if success { dismiss() } } }.disabled(isSaving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
        }.interactiveDismissDisabled(isSaving)
    }
}

struct RecordingDetailView: View {
    let recording: Recording
    let settings: AppSettings
    let recordingDeleted: ((UUID) -> Void)?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appLayoutMode) private var appLayoutMode
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var playback = PlaybackController()
    @State private var translator = SubtitleTranslationController()
    @State private var exportCoordinator = RecordingExportCoordinator()
    @State private var selectedTab: RecordingTextTab = .transcript
    @State private var errorMessage: String?
    @State private var isTranslating = false
    @State private var isShowingTranslationSetup = false
    @State private var isConfirmingDelete = false
    @State private var isShowingSearch = false
    @State private var searchResults: [RecordingSearchResult] = []
    @State private var scrollRequest: ReviewScrollRequest?
    @State private var cueEditTarget: CueEditTarget?
    @State private var speakerSheet: SpeakerSheetDestination?
    @State private var diarization = SpeakerDiarizationController()
    @State private var isRepairingTranscript = false
    @State private var repairProgress: Double?
    @State private var audioAvailability: RecordingAudioAvailability = .loading
    @AppStorage("reader.transcriptFontSize") private var storedFontSize = TranscriptFontSize.standard.rawValue

    init(
        recording: Recording,
        settings: AppSettings,
        recordingDeleted: ((UUID) -> Void)? = nil
    ) {
        self.recording = recording
        self.settings = settings
        self.recordingDeleted = recordingDeleted
    }

    private var fontSize: TranscriptFontSize {
        TranscriptFontSize(rawValue: storedFontSize) ?? .standard
    }
    private var cueValues: [TranscriptionCueValue] { recording.orderedCues.map(\.value) }
    private var sourceLanguage: String? {
        switch recording.requestedLanguage {
        case .spanish: "es"
        case .english: "en"
        case .german: "de"
        case .automatic: recording.detectedLanguage.flatMap(SpokenLanguageResolver.canonicalCode) ?? SpokenLanguageResolver.detect(in: recording.transcript)
        }
    }
    private var usesIPadTextColumns: Bool {
        appLayoutMode == .pad
            && horizontalSizeClass == .regular
            && !dynamicTypeSize.isAccessibilitySize
    }

    var body: some View {
        let renderData = RecordingDetailRenderData(
            recording: recording,
            currentTime: playback.currentTime
        )

        detailContent(renderData)
        .navigationTitle(recording.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                RecordingReviewTitle(title: recording.title, metadata: recordingMetadata)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Buscar en la grabación", systemImage: "magnifyingglass") {
                    presentSearch(using: renderData)
                }
                .labelStyle(.iconOnly)

                RecordingActionsMenu(
                    recording: recording,
                    coordinator: exportCoordinator,
                    includeDelete: true,
                    textSizeOptions: textSizeOptions,
                    delete: { isConfirmingDelete = true }
                )
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 8) {
            RecordingPlaybackDock(
                playback: playback,
                search: { presentSearch(using: renderData) }
            )
        }
        .task {
            await loadPlayback()
        }
        .onChange(of: playback.isPlaying) { _, isPlaying in
            UIApplication.shared.isIdleTimerDisabled = isPlaying
        }
        .onDisappear {
            playback.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
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
        .sheet(item: $cueEditTarget) { target in CueEditorSheet(initialText: target.text) { text in await saveCueEdit(cueID: target.id, text: text) } }
        .sheet(item: $speakerSheet) { _ in
            SpeakerEditorSheet(
                recording: recording,
                playback: playback,
                diarization: diarization
            )
        }
        .sheet(isPresented: $isShowingSearch) {
            RecordingSearchView(
                recordingTitle: recording.title,
                results: searchResults,
                select: selectSearchResult
            )
        }
        .onChange(of: diarization.errorMessage) { _, message in
            if let message { errorMessage = message; diarization.errorMessage = nil }
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

    @ViewBuilder
    private func detailContent(_ data: RecordingDetailRenderData) -> some View {
        if usesIPadTextColumns {
            iPadContent(data)
        } else {
            compactContent(data)
        }
    }

    private func compactContent(_ data: RecordingDetailRenderData) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: AppVisualStyle.sectionSpacing) {
                    speakerSummary(speakers: data.speakers)

                    if audioAvailability == .unavailable {
                        audioUnavailableCard
                    }

                    if !data.markers.isEmpty {
                        markersCard(data.markers)
                    }

                    if audioAvailability != .unavailable,
                       (recording.status == .interrupted || (data.originalCues.isEmpty && !recording.transcript.isEmpty)) {
                        recoveryCard
                    }

                    Picker("Contenido", selection: $selectedTab) {
                        ForEach(RecordingTextTab.allCases) { tab in Text(tab.title).tag(tab) }
                    }
                    .pickerStyle(.segmented)

                    RecordingReviewSectionHeader(
                        title: selectedTab == .transcript ? "Guion sincronizado" : "Traducción sincronizada",
                        status: audioSyncStatus,
                        isWarning: audioAvailability == .unavailable
                    )

                    if selectedTab == .transcript {
                        transcriptCards(data)
                    } else {
                        translationCards(data)
                    }
                }
                .padding(.horizontal, AppVisualStyle.pageHorizontalPadding)
                .padding(.vertical, AppVisualStyle.sectionSpacing)
            }
            .background(AppVisualStyle.screenBackground)
            .onChange(of: data.activeOriginalIndex) { _, index in
                guard playback.isPlaying, selectedTab == .transcript, let index else { return }
                scroll(proxy, to: "original-\(index)")
            }
            .onChange(of: data.activeTranslatedIndex) { _, index in
                guard playback.isPlaying, selectedTab == .translation, let index else { return }
                scroll(proxy, to: "translation-\(index)")
            }
            .onChange(of: scrollRequest) { _, request in
                guard let request, request.tab == selectedTab else { return }
                scroll(proxy, to: request.destinationID)
            }
        }
    }

    private func iPadContent(_ data: RecordingDetailRenderData) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 12) {
                    speakerSummary(speakers: data.speakers)
                    if audioAvailability == .unavailable { audioUnavailableCard }
                    if !data.markers.isEmpty { markersCard(data.markers) }
                    if audioAvailability != .unavailable,
                       (recording.status == .interrupted || (data.originalCues.isEmpty && !recording.transcript.isEmpty)) {
                        recoveryCard
                    }
                }
                .padding(AppVisualStyle.pageHorizontalPadding)
            }
            .frame(maxHeight: 280)

            Divider()

            HStack(spacing: 0) {
                iPadTranscriptColumn(data)
                if data.hasTranslation || isTranslating {
                    Divider()
                    iPadTranslationColumn(data)
                }
            }
        }
    }

    private func iPadTranscriptColumn(_ data: RecordingDetailRenderData) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: AppVisualStyle.sectionSpacing) {
                    RecordingReviewSectionHeader(
                        title: "Guion sincronizado",
                        status: audioSyncStatus,
                        isWarning: audioAvailability == .unavailable
                    )
                    transcriptCards(data)
                }
                .padding(AppVisualStyle.pageHorizontalPadding)
            }
            .background(AppVisualStyle.screenBackground)
                .onChange(of: data.activeOriginalIndex) { _, index in
                    guard playback.isPlaying, let index else { return }
                    scroll(proxy, to: "original-\(index)")
                }
                .onChange(of: scrollRequest) { _, request in
                    guard let request, request.tab == .transcript else { return }
                    scroll(proxy, to: request.destinationID)
                }
        }
    }

    private func iPadTranslationColumn(_ data: RecordingDetailRenderData) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: AppVisualStyle.sectionSpacing) {
                    RecordingReviewSectionHeader(
                        title: "Traducción sincronizada",
                        status: audioSyncStatus,
                        isWarning: audioAvailability == .unavailable
                    )
                    translationCards(data)
                }
                .padding(AppVisualStyle.pageHorizontalPadding)
            }
            .background(AppVisualStyle.screenBackground)
                .onChange(of: data.activeTranslatedIndex) { _, index in
                    guard playback.isPlaying, let index else { return }
                    scroll(proxy, to: "translation-\(index)")
                }
                .onChange(of: scrollRequest) { _, request in
                    guard let request, request.tab == .translation else { return }
                    scroll(proxy, to: request.destinationID)
                }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, to id: String) {
        if reduceMotion {
            proxy.scrollTo(id, anchor: .center)
        } else {
            withAnimation { proxy.scrollTo(id, anchor: .center) }
        }
    }

    @ViewBuilder
    private func transcriptCards(_ data: RecordingDetailRenderData) -> some View {
        if data.originalCues.isEmpty {
            RecordingReviewCueCard(
                speakerName: nil,
                speakerColor: .blue,
                startTime: 0,
                endTime: recording.duration,
                text: recording.transcript.isEmpty ? AppLocalization.string("Sin transcripción") : recording.transcript,
                secondaryText: nil,
                textFont: fontSize.font,
                isActive: false,
                select: { playback.seek(to: 0) },
                edit: nil
            )
            .id("transcript-full")
        } else {
            ForEach(data.originalCues) { cue in
                let speakerName = cue.speakerID.map {
                    data.speakerNames[$0] ?? SpeakerLabelFormatter.displayName(for: $0)
                }
                let color = SpeakerPalette.color(at: cue.speakerID.flatMap { data.speakerColorIndexes[$0] } ?? 0)
                let inlineTranslation = inlineTranslation(for: cue, data: data)
                RecordingReviewCueCard(
                    speakerName: speakerName,
                    speakerColor: color,
                    startTime: cue.startTime,
                    endTime: inlineTranslation.map { _ in inlineTranslationEndTime(for: cue, data: data) } ?? cue.endTime,
                    text: cue.text,
                    secondaryText: inlineTranslation,
                    textFont: fontSize.font,
                    isActive: data.activeOriginalIndex == cue.index,
                    select: { playback.seek(to: cue.startTime) },
                    edit: { cueEditTarget = .init(id: cue.id, text: cue.text) }
                )
                .id("original-\(cue.index)")
            }
        }
    }

    @ViewBuilder
    private func translationCards(_ data: RecordingDetailRenderData) -> some View {
        if isTranslating {
            HStack(spacing: 12) {
                ProgressView()
                Text("Traduciendo la grabación…")
            }
            .frame(maxWidth: .infinity)
            .padding(AppVisualStyle.cardPadding)
            .appCardSurface()
        } else if !data.translatedCues.isEmpty {
            ForEach(data.translatedCues) { cue in
                let identity = translatedSpeakerIdentity(for: cue, data: data)
                RecordingReviewCueCard(
                    speakerName: identity.name ?? identity.id.map(SpeakerLabelFormatter.displayName),
                    speakerColor: SpeakerPalette.color(at: identity.colorIndex),
                    startTime: cue.startTime,
                    endTime: cue.endTime,
                    text: cue.text,
                    secondaryText: nil,
                    textFont: fontSize.font,
                    isActive: data.activeTranslatedIndex == cue.index,
                    select: { playback.seek(to: cue.startTime) },
                    edit: nil
                )
                .id("translation-\(cue.index)")
            }
        } else if data.hasTranslation {
            ForEach(data.originalCues) { cue in
                if let translated = cue.translatedText, !translated.isEmpty {
                    let speakerName = cue.speakerID.map {
                        data.speakerNames[$0] ?? SpeakerLabelFormatter.displayName(for: $0)
                    }
                    let color = SpeakerPalette.color(at: cue.speakerID.flatMap { data.speakerColorIndexes[$0] } ?? 0)
                    RecordingReviewCueCard(
                        speakerName: speakerName,
                        speakerColor: color,
                        startTime: cue.startTime,
                        endTime: cue.endTime,
                        text: translated,
                        secondaryText: nil,
                        textFont: fontSize.font,
                        isActive: data.activeOriginalIndex == cue.index,
                        select: { playback.seek(to: cue.startTime) },
                        edit: nil
                    )
                    .id("translation-original-\(cue.index)")
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
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }

        if recording.translationStatus == .partial || recording.translationStatus == .failed {
            Button("Reintentar bloques pendientes", systemImage: "arrow.clockwise") {
                Task { await retryPendingTranslations() }
            }
            .disabled(isTranslating)
        }

        if data.hasTranslation {
            Button("Cambiar idioma de traducción") {
                isShowingTranslationSetup = true
            }
            .disabled(isTranslating)
        }
    }

    private func speakerSummary(speakers: [SpeakerSummaryItem]) -> some View {
        RecordingSpeakerSummaryBar(
            speakers: speakers,
            hasTranscriptCues: !recording.cues.isEmpty,
            isProcessing: diarization.isProcessing,
            progress: diarization.progress,
            statusText: diarization.statusText,
            hasPlayableAudio: audioAvailability == .available,
            identify: { Task { await diarization.diarize(recording: recording, context: context) } },
            edit: { speakerSheet = .init(id: recording.id) }
        )
    }

    private func translatedSpeakerIdentity(
        for cue: TranslatedSubtitleCue,
        data: RecordingDetailRenderData
    ) -> (id: String?, name: String?, colorIndex: Int) {
        let ids = data.originalCues
            .filter { $0.index >= cue.sourceStartIndex && $0.index <= cue.sourceEndIndex }
            .compactMap(\.speakerID)
            .reduce(into: [String]()) { result, id in
                if !result.contains(id) { result.append(id) }
            }
        guard let firstID = ids.first else { return (nil, nil, 0) }
        let name = ids.map { data.speakerNames[$0] ?? SpeakerLabelFormatter.displayName(for: $0) }
            .joined(separator: " + ")
        return (firstID, name, data.speakerColorIndexes[firstID] ?? 0)
    }

    private func inlineTranslation(
        for cue: TranscriptCue,
        data: RecordingDetailRenderData
    ) -> String? {
        if let translatedText = cue.translatedText, !translatedText.isEmpty {
            return translatedText
        }
        return data.translatedCues.first { $0.sourceStartIndex == cue.index }?.text
    }

    private func inlineTranslationEndTime(
        for cue: TranscriptCue,
        data: RecordingDetailRenderData
    ) -> TimeInterval {
        data.translatedCues.first { $0.sourceStartIndex == cue.index }?.endTime ?? cue.endTime
    }

    private func markersCard(_ markers: [RecordingMarker]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("Marcadores", systemImage: "bookmark.fill")
                .font(.headline)
                .foregroundStyle(.blue)
                .padding(.bottom, 8)

            ForEach(Array(markers.enumerated()), id: \.element.id) { index, marker in
                if index > 0 { Divider() }
                HStack(spacing: 8) {
                    Button {
                        playback.seek(to: marker.time)
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(marker.title)
                                    .foregroundStyle(.primary)
                                Text(marker.time.formattedDuration)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "play.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button("Eliminar marcador", systemImage: "trash", role: .destructive) {
                        deleteMarker(marker)
                    }
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
                }
                .padding(.vertical, 7)
            }
        }
        .padding(AppVisualStyle.cardPadding)
        .appCardSurface()
    }

    private var recoveryCard: some View {
        Group {
            if isRepairingTranscript {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Reconstruyendo transcripción desde el audio…", systemImage: "waveform.badge.magnifyingglass")
                        .font(.subheadline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if let repairProgress { ProgressView(value: repairProgress) } else { ProgressView() }
                }
            } else {
                Button {
                    Task { await rebuildTranscriptFromAudio() }
                } label: {
                    Label("Reconstruir transcripción desde el audio", systemImage: "waveform.badge.magnifyingglass")
                        .font(.subheadline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .allowsTightening(true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppVisualStyle.cardPadding)
        .appCardSurface()
    }

    private var audioUnavailableCard: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text("Audio no disponible")
                    .font(.headline)
                Text("El audio de esta grabación no se puede abrir. La transcripción sigue disponible.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "waveform.slash")
                .foregroundStyle(.orange)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppVisualStyle.cardPadding)
        .appCardSurface()
    }

    private var audioSyncStatus: LocalizedStringKey {
        audioAvailability == .unavailable ? "Audio no disponible" : "Sincronizado con el audio"
    }

    private func loadPlayback() async {
        do {
            let url = try await StorageService.shared.resolvePlayableAudio(
                relativePath: recording.audioRelativePath,
                id: recording.id
            )
            try await playback.load(url: url)
            audioAvailability = .available

            let resolvedPath = try await StorageService.shared.relativePath(for: url)
            if resolvedPath != recording.audioRelativePath {
                recording.audioRelativePath = resolvedPath
                try context.save()
                try? RecordingRecoveryStore.write(.init(recording: recording))
            }
        } catch is CancellationError {
            return
        } catch {
            playback.stop()
            audioAvailability = .unavailable
        }
    }

    private func deleteMarker(_ marker: RecordingMarker) { context.delete(marker); do { try context.save(); try RecordingRecoveryStore.write(.init(recording: recording)) } catch { errorMessage = error.localizedDescription } }
    private func saveCueEdit(cueID: UUID, text: String) async -> Bool { do { let result = try await TranscriptEditingService.updateCue(recording: recording, cueID: cueID, newText: text, context: context); if let message = result.translationError { errorMessage = AppLocalization.string("El texto fue guardado, pero una traducción quedó pendiente: \(message)") }; return true } catch { errorMessage = error.localizedDescription; return false } }

    private func rebuildTranscriptFromAudio() async {
        guard !isRepairingTranscript else { return }
        isRepairingTranscript = true; repairProgress = 0
        defer { isRepairingTranscript = false; repairProgress = nil }
        do {
            let engine = TranscriptionEngineFactory.make(recording.engine)
            try await engine.prepare(language: recording.requestedLanguage)
            try await engine.setVocabulary(settings.vocabularyHints)
            let url = try await StorageService.shared.resolvePlayableAudio(
                relativePath: recording.audioRelativePath,
                id: recording.id
            )
            let (rawResult, duration) = try await AudioImportService().transcribe(url: url, engine: engine) { progress in Task { @MainActor in repairProgress = progress } }
            let result = VocabularyPostProcessor.apply(to: rawResult, entries: settings.customVocabulary)
            recording.cues.forEach { context.delete($0) }; recording.cues.removeAll()
            recording.tokens.forEach { context.delete($0) }; recording.tokens.removeAll()
            recording.speakerTurns.forEach { context.delete($0) }; recording.speakerTurns.removeAll()
            recording.speakerProfiles.forEach { context.delete($0) }; recording.speakerProfiles.removeAll()
            for value in result.cues { let cue = TranscriptCue(value: value); cue.recording = recording; recording.cues.append(cue) }
            for (index, value) in result.tokens.enumerated() { let token = TranscriptToken(index: index, value: value); token.recording = recording; recording.tokens.append(token) }
            recording.duration = duration; recording.transcript = result.text; recording.detectedLanguage = result.detectedLanguage ?? recording.detectedLanguage; recording.status = .saved
            if !recording.translatedCues.isEmpty { recording.translatedCues.forEach { $0.needsRetranslation = true }; recording.translationStatus = .partial }
            try context.save(); try RecordingRecoveryStore.write(.init(recording: recording))
        } catch { errorMessage = error.localizedDescription }
    }

    private var textSizeOptions: [RecordingTextSizeOption] {
        TranscriptFontSize.allCases.map { size in
            RecordingTextSizeOption(
                id: size.id,
                title: size.title,
                isSelected: size == fontSize,
                select: { storedFontSize = size.rawValue }
            )
        }
    }

    private var recordingMetadata: String {
        let duration = recording.duration.formattedDuration
        let source = (sourceLanguage ?? "auto").uppercased()
        guard let target = recording.translationTargetLanguage, !target.isEmpty else {
            return "\(duration) · \(source)"
        }
        return "\(duration) · \(source) → \(target.uppercased())"
    }

    private func presentSearch(using data: RecordingDetailRenderData) {
        searchResults = makeSearchResults(using: data)
        isShowingSearch = true
    }

    private func selectSearchResult(_ result: RecordingSearchResult) {
        selectedTab = result.tab
        playback.seek(to: result.startTime)
        Task { @MainActor in
            await Task.yield()
            scrollRequest = .init(destinationID: result.destinationID, tab: result.tab)
        }
    }

    private func makeSearchResults(using data: RecordingDetailRenderData) -> [RecordingSearchResult] {
        var results: [RecordingSearchResult] = data.originalCues.map { cue in
            RecordingSearchResult(
                id: "transcript-\(cue.id)",
                kind: .transcript,
                tab: .transcript,
                destinationID: "original-\(cue.index)",
                startTime: cue.startTime,
                endTime: cue.endTime,
                speakerName: cue.speakerID.flatMap { data.speakerNames[$0] },
                text: cue.text
            )
        }

        if data.originalCues.isEmpty, !recording.transcript.isEmpty {
            results.append(.init(
                id: "transcript-full",
                kind: .transcript,
                tab: .transcript,
                destinationID: "transcript-full",
                startTime: 0,
                endTime: recording.duration,
                speakerName: nil,
                text: recording.transcript
            ))
        }

        if !data.translatedCues.isEmpty {
            results += data.translatedCues.map { cue in
                RecordingSearchResult(
                    id: "translation-\(cue.id)",
                    kind: .translation,
                    tab: .translation,
                    destinationID: "translation-\(cue.index)",
                    startTime: cue.startTime,
                    endTime: cue.endTime,
                    speakerName: translatedSpeakerIdentity(for: cue, data: data).name,
                    text: cue.text
                )
            }
        } else {
            results += data.originalCues.compactMap { cue in
                guard let text = cue.translatedText, !text.isEmpty else { return nil }
                return RecordingSearchResult(
                    id: "translation-original-\(cue.id)",
                    kind: .translation,
                    tab: .translation,
                    destinationID: "translation-original-\(cue.index)",
                    startTime: cue.startTime,
                    endTime: cue.endTime,
                    speakerName: cue.speakerID.flatMap { data.speakerNames[$0] },
                    text: text
                )
            }
        }

        return results
    }

    private func retryPendingTranslations() async {
        guard let target = recording.translationTargetLanguage else {
            isShowingTranslationSetup = true
            return
        }
        _ = await translateRecording(to: target, replacingExisting: false)
    }

    private func translateRecording(to target: String, replacingExisting: Bool) async -> Bool {
        guard let sourceLanguage else {
            errorMessage = AppLocalization.string("No se pudo determinar el idioma original.")
            return false
        }
        guard !TranslationPolicy.sameLanguage(sourceLanguage, target) else {
            errorMessage = AppLocalization.string("El idioma original y el idioma de traducción son iguales.")
            return false
        }

        isTranslating = true
        defer { isTranslating = false }
        if replacingExisting {
            for cue in recording.translatedCues { context.delete(cue) }
            recording.translatedCues = []
            recording.cues.forEach { $0.translatedText = nil }
            recording.translationStatus = .partial
            do {
                try context.save()
            } catch {
                errorMessage = error.localizedDescription
                return false
            }
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
        if !replacingExisting {
            let dirty = recording.translatedCues.filter(\.needsRetranslation)
            for translatedCue in dirty {
                let dependent = recording.orderedCues.filter { $0.index >= translatedCue.sourceStartIndex && $0.index <= translatedCue.sourceEndIndex }
                guard !dependent.isEmpty else { continue }
                do {
                    translatedCue.text = try await translator.translate(dependent.map(\.text).joined(separator: " "), source: sourceLanguage, target: target, quality: .highFidelity)
                    translatedCue.startTime = dependent.first?.startTime ?? translatedCue.startTime
                    translatedCue.endTime = dependent.last?.endTime ?? translatedCue.endTime
                    translatedCue.needsRetranslation = false
                    try context.save(); try? RecordingRecoveryStore.write(.init(recording: recording))
                } catch { continue }
            }
        }
        for (index, group) in groups.enumerated() {
            if !replacingExisting, recording.translatedCues.contains(where: {
                !$0.needsRetranslation && $0.sourceStartIndex == group.first?.index && $0.sourceEndIndex == group.last?.index
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
                    try context.save()
                }
            } catch {
                continue
            }
        }

        let cleanTranslated = recording.translatedCues.filter { !$0.needsRetranslation }
        let allCovered = sourceCues.allSatisfy { sourceCue in cleanTranslated.contains { sourceCue.index >= $0.sourceStartIndex && sourceCue.index <= $0.sourceEndIndex } }
        recording.translationEnabled = true
        recording.translationTargetLanguage = target
        recording.translationStatus = allCovered ? .complete : (cleanTranslated.isEmpty ? .failed : .partial)
        do {
            try context.save()
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        if recording.translatedCues.isEmpty {
            errorMessage = AppLocalization.string("No se pudo traducir esta grabación.")
            return false
        }
        return true
    }

    private func deleteRecording() {
        let id = recording.id
        context.delete(recording)
        try? context.save()
        Task { try? await StorageService.shared.removeRecording(id: id) }
        recordingDeleted?(id)
        dismiss()
    }
}
