@preconcurrency import AVFoundation
import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class RecordingSessionController {
    private let audioCapture = AudioCaptureService()
    private let storage = StorageService.shared
    private let importer = AudioImportService()
    private var engine: (any StreamingTranscriptionEngine)?
    private var warmNemotronEngine: NemotronEngine?
    private var nemotronWarmTask: Task<NemotronEngine, Error>?
    private var nemotronEventTask: Task<Void, Never>?
    private var isAutomaticPrewarming = false
    private var eventTask: Task<Void, Never>?
    private var bufferTask: Task<Void, Never>?
    private var bufferContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var recoveryTask: Task<Void, Never>?
    private var translationDebounceTask: Task<Void, Never>?
    private var translationWorkerTask: Task<Void, Never>?
    private var pendingLiveTranslations = LatestValueMailbox<LiveTranslationRequest>()
    private var frozenTranslationQueue: [LiveTranslationRequest] = []
    private var activeSourcePhrases: [String] = []
    private var context: ModelContext?
    private var phraseSegmenter = LivePhraseSegmenter()
    private let subtitleTranslator = SubtitleTranslationController()
    private var sessionTranslationEnabled = false
    private var sessionTranslationTarget = "en"
    private var sessionRequestedLanguage: TranscriptionLanguage = .automatic

    var state: RecordingSessionState = .idle
    var currentRecording: Recording?
    var liveTranscript = ""
    var elapsed: TimeInterval = 0
    var meterLevel: Float = -80
    var waveform: [Float] = Array(repeating: 0.05, count: 48)
    var modelProgress: Double?
    var modelProgressLabel = ""
    var modelPreparation: ModelPreparationState = .idle
    var importProgress: Double?
    var detectedLanguage: String?
    var liveTranslationBlocks: [LiveTranslationBlock] = []
    var activeTranslation: LiveTranslationBlock?
    var liveProvisional = ""
    var translationNotice: String?

    func prepareNemotron(settings: AppSettings) async -> Bool {
        guard state == .idle else { return false }
        state = .preparing
        modelProgress = nil
        modelProgressLabel = "Conectando…"
        do {
            let selectedEngine = try await preparedNemotronEngine(settings: settings)
            engine = selectedEngine
            await selectedEngine.reset()
            settings.nemotronPrepared = true
            state = .idle
            modelProgress = nil
            cleanupSession(keepingRecording: false)
            return true
        } catch {
            fail(error)
            return false
        }
    }

    func prewarmNemotron(settings: AppSettings) async {
        guard state == .idle,
              settings.engine == .nemotron,
              settings.nemotronPrepared,
              warmNemotronEngine == nil
        else { return }
        isAutomaticPrewarming = true
        defer { isAutomaticPrewarming = false }
        do {
            _ = try await preparedNemotronEngine(settings: settings)
        } catch {
            // Automatic warm-up must not interrupt the library. Starting a
            // recording will retry and surface the error if it persists.
        }
    }

    func start(settings: AppSettings, context: ModelContext) async {
        guard state == .idle else { return }
        self.context = context
        state = .preparing
        currentRecording = nil
        liveTranscript = ""
        detectedLanguage = nil
        liveTranslationBlocks = []
        activeTranslation = nil
        liveProvisional = ""
        translationNotice = nil
        activeSourcePhrases = []
        elapsed = 0
        meterLevel = -80
        waveform = Array(repeating: 0.05, count: 48)
        modelProgress = nil
        modelProgressLabel = ""
        phraseSegmenter.reset()
        sessionTranslationEnabled = settings.translationEnabled
        sessionTranslationTarget = settings.translationTargetLanguage
        sessionRequestedLanguage = settings.language

        do {
            guard await audioCapture.requestPermission() else { throw AppError.microphonePermissionDenied }
            let selectedEngine: any StreamingTranscriptionEngine
            if settings.engine == .nemotron {
                selectedEngine = try await preparedNemotronEngine(settings: settings)
            } else {
                selectedEngine = TranscriptionEngineFactory.make(.appleSpeech)
                observe(await selectedEngine.events)
                try await selectedEngine.prepare(language: settings.language)
            }
            engine = selectedEngine
            try await selectedEngine.start()

            let id = UUID()
            let audioURL = try await storage.audioURL(id: id)
            let relativePath = try await storage.relativePath(for: audioURL)
            let recording = Recording(
                id: id,
                title: Self.defaultTitle(),
                audioRelativePath: relativePath,
                source: .microphone,
                engine: settings.engine,
                requestedLanguage: settings.language,
                translationEnabled: sessionTranslationEnabled,
                translationTargetLanguage: sessionTranslationEnabled ? sessionTranslationTarget : nil
            )
            context.insert(recording)
            try context.save()
            currentRecording = recording

            let pair = AsyncStream<AVAudioPCMBuffer>.makeStream(bufferingPolicy: .bufferingNewest(24))
            bufferContinuation = pair.continuation
            bufferTask = Task {
                do {
                    for await buffer in pair.stream { try await selectedEngine.consume(buffer) }
                } catch {
                    await MainActor.run { self.fail(error) }
                }
            }
            try audioCapture.start(destination: audioURL) { [continuation = pair.continuation] buffer in
                continuation.yield(buffer)
            } onMeter: { [weak self] level, duration in
                Task { @MainActor in self?.updateMeter(level: level, duration: duration) }
            }
            state = .recording
            beginRecoverySnapshots()
        } catch {
            await engine?.reset()
            fail(error)
        }
    }

    func pause() async {
        guard state == .recording else { return }
        audioCapture.pause()
        await engine?.pause()
        if !liveProvisional.isEmpty {
            activeSourcePhrases.append(liveProvisional)
            liveProvisional = ""
        }
        freezeActiveTranslation()
        state = .paused
        currentRecording?.status = .paused
        try? context?.save()
    }

    func resume() async {
        guard state == .paused else { return }
        do {
            try await engine?.resume()
            try audioCapture.resume()
            state = .recording
            currentRecording?.status = .recording
            try? context?.save()
        } catch { fail(error) }
    }

    func stop() async -> Recording? {
        guard state == .recording || state == .paused else { return nil }
        state = .finalizing
        recoveryTask?.cancel()
        let duration = audioCapture.stop()
        bufferContinuation?.finish()
        await bufferTask?.value

        do {
            guard let output = try await engine?.finish(), let recording = currentRecording else {
                throw AppError.invalidState
            }
            recording.duration = duration
            recording.transcript = output.text
            recording.detectedLanguage = output.detectedLanguage ?? detectedLanguage
            recording.status = .saved
            let finalTranslation = await translateFinalCues(output.cues, detectedLanguage: recording.detectedLanguage)
            recording.translationStatus = finalTranslation.status
            recording.cues = output.cues.map { value in
                let cue = TranscriptCue(value: value)
                cue.recording = recording
                return cue
            }
            recording.translatedCues = finalTranslation.values.map {
                let cue = TranslatedSubtitleCue(value: $0)
                cue.recording = recording
                return cue
            }
            try context?.save()
            state = .idle
            cleanupSession(keepingRecording: true)
            return recording
        } catch {
            currentRecording?.duration = duration
            currentRecording?.transcript = liveTranscript
            currentRecording?.status = .interrupted
            try? context?.save()
            fail(error)
            return currentRecording
        }
    }

    func importFile(_ source: URL, settings: AppSettings, context: ModelContext) async -> Recording? {
        guard state == .idle else { return nil }
        state = .preparing
        self.context = context
        importProgress = 0
        liveTranscript = ""
        let id = UUID()
        do {
            let destination = try await storage.importAudio(from: source, id: id)
            let relative = try await storage.relativePath(for: destination)
            let recording = Recording(
                id: id,
                title: source.deletingPathExtension().lastPathComponent,
                audioRelativePath: relative,
                source: .imported,
                engine: settings.engine,
                requestedLanguage: settings.language,
                status: .processing
            )
            context.insert(recording)
            currentRecording = recording
            try context.save()

            let selectedEngine = TranscriptionEngineFactory.make(settings.engine)
            engine = selectedEngine
            observe(await selectedEngine.events)
            try await selectedEngine.prepare(language: settings.language)
            let (output, duration) = try await importer.transcribe(url: destination, engine: selectedEngine) { [weak self] value in
                Task { @MainActor in self?.importProgress = value }
            }
            recording.duration = duration
            recording.transcript = output.text
            recording.detectedLanguage = output.detectedLanguage
            recording.status = .saved
            recording.cues = output.cues.map {
                let cue = TranscriptCue(value: $0); cue.recording = recording; return cue
            }
            try context.save()
            state = .idle
            importProgress = nil
            cleanupSession(keepingRecording: true)
            return recording
        } catch {
            if let recording = currentRecording { context.delete(recording) }
            try? await storage.removeRecording(id: id)
            try? context.save()
            importProgress = nil
            fail(error)
            return nil
        }
    }

    func resetError() {
        if case .failed = state { state = .idle }
        cleanupSession(keepingRecording: false)
    }

    func handleBackgroundTransition() async {
        if state == .recording { await pause() }
    }

    private func observe(_ events: AsyncStream<TranscriptionEvent>) {
        eventTask?.cancel()
        eventTask = Task {
            for await event in events {
                guard !Task.isCancelled else { return }
                handleTranscriptionEvent(event)
            }
        }
    }

    private func observeNemotron(_ selectedEngine: NemotronEngine) {
        guard nemotronEventTask == nil else { return }
        nemotronEventTask = Task {
            for await event in selectedEngine.events {
                guard !Task.isCancelled else { return }
                handleTranscriptionEvent(event)
            }
        }
    }

    private func handleTranscriptionEvent(_ event: TranscriptionEvent) {
        switch event {
        case .preparing: break
        case .modelProgress(let progress, let label):
            modelProgress = progress; modelProgressLabel = label
        case .modelState(let modelState):
            modelPreparation = modelState
            modelProgress = modelState.progress
            modelProgressLabel = modelState.label
        case .ready: modelProgress = nil
        case .partial(let text): handlePartial(text)
        case .finalized(let cue): handleFinalizedCue(cue)
        case .languageDetected(let language):
            detectedLanguage = language
            refreshActiveTranslation()
        case .failed(let message):
            modelPreparation = .failed(message)
            if !isAutomaticPrewarming { state = .failed(message) }
        }
    }

    private func updateMeter(level: Float, duration: TimeInterval) {
        meterLevel = level
        elapsed = duration
        let normalized = max(0.04, min(1, (level + 55) / 55))
        waveform.removeFirst()
        waveform.append(normalized)
    }

    private func handlePartial(_ text: String) {
        liveTranscript = text
        guard sessionTranslationEnabled else { return }
        let phrases = phraseSegmenter.consume(text)
        liveProvisional = phraseSegmenter.provisional(from: text)
        for phrase in phrases { acceptFinalizedPhrase(phrase) }
        detectLanguageFromStableTextIfNeeded()
        refreshActiveTranslation()
    }

    private func handleFinalizedCue(_ cue: TranscriptionCueValue) {
        guard sessionTranslationEnabled else { return }
        acceptFinalizedPhrase(cue.text)
        liveProvisional = ""
        detectLanguageFromStableTextIfNeeded()
        refreshActiveTranslation()
    }

    private func acceptFinalizedPhrase(_ phrase: String) {
        let clean = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, activeSourcePhrases.last != clean else { return }
        if activeSourcePhrases.count >= 2 { freezeActiveTranslation() }
        activeSourcePhrases.append(clean)
        if activeSourcePhrases.joined(separator: " ").split(whereSeparator: \.isWhitespace).count >= 28 {
            freezeActiveTranslation()
        }
    }

    private func refreshActiveTranslation() {
        guard sessionTranslationEnabled else { return }
        guard let source = resolvedTranslationSource() else {
            translationNotice = "Esperando detectar el idioma hablado…"
            return
        }
        if TranslationPolicy.sameLanguage(source, sessionTranslationTarget) {
            translationNotice = "El idioma hablado coincide con el idioma de traducción."
            activeTranslation = nil
            return
        }
        translationNotice = nil
        let text = (activeSourcePhrases + [liveProvisional])
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if activeTranslation == nil {
            activeTranslation = LiveTranslationBlock(sourceText: text)
        } else if activeTranslation?.sourceText != text {
            activeTranslation?.sourceText = text
            activeTranslation?.generation += 1
        }
        activeTranslation?.state = .translating
        guard let block = activeTranslation else { return }
        scheduleLiveTranslation(.init(
            blockID: block.id,
            sourceText: text,
            sourceLanguage: source,
            generation: block.generation,
            isFrozen: false
        ))
    }

    private func scheduleLiveTranslation(_ request: LiveTranslationRequest) {
        translationDebounceTask?.cancel()
        translationDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            pendingLiveTranslations.submit(request)
            startTranslationWorkerIfNeeded()
        }
    }

    private func startTranslationWorkerIfNeeded() {
        guard translationWorkerTask == nil else { return }
        translationWorkerTask = Task { [weak self] in await self?.runTranslationWorker() }
    }

    private func runTranslationWorker() async {
        while !Task.isCancelled {
            let request: LiveTranslationRequest?
            if !frozenTranslationQueue.isEmpty {
                request = frozenTranslationQueue.removeFirst()
            } else {
                request = pendingLiveTranslations.take()
            }
            guard let request else { break }
            do {
                let translated = try await subtitleTranslator.translate(
                    request.sourceText,
                    source: request.sourceLanguage,
                    target: sessionTranslationTarget
                )
                applyLiveTranslation(translated, request: request)
            } catch is CancellationError {
                break
            } catch {
                applyLiveTranslationFailure(request: request)
            }
        }
        translationWorkerTask = nil
        if !frozenTranslationQueue.isEmpty || !pendingLiveTranslations.isEmpty {
            startTranslationWorkerIfNeeded()
        }
    }

    private func applyLiveTranslation(_ text: String, request: LiveTranslationRequest) {
        if request.isFrozen,
           let index = liveTranslationBlocks.firstIndex(where: { $0.id == request.blockID }) {
            liveTranslationBlocks[index].translatedText = text
            liveTranslationBlocks[index].state = .final
        } else if activeTranslation?.id == request.blockID,
                  activeTranslation?.generation == request.generation {
            activeTranslation?.translatedText = text
            activeTranslation?.state = .provisional
        }
    }

    private func applyLiveTranslationFailure(request: LiveTranslationRequest) {
        if request.isFrozen,
           let index = liveTranslationBlocks.firstIndex(where: { $0.id == request.blockID }) {
            liveTranslationBlocks[index].state = .failed
        } else if activeTranslation?.id == request.blockID,
                  activeTranslation?.generation == request.generation {
            activeTranslation?.state = .failed
        }
    }

    private func freezeActiveTranslation() {
        translationDebounceTask?.cancel()
        guard sessionTranslationEnabled,
              !activeSourcePhrases.isEmpty,
              let source = resolvedTranslationSource()
        else { return }
        let text = activeSourcePhrases.joined(separator: " ")
        if TranslationPolicy.sameLanguage(source, sessionTranslationTarget) {
            activeSourcePhrases = []
            activeTranslation = nil
            translationNotice = "El idioma hablado coincide con el idioma de traducción."
            return
        }
        let block = LiveTranslationBlock(sourceText: text, state: .translating)
        liveTranslationBlocks.append(block)
        frozenTranslationQueue.append(.init(
            blockID: block.id,
            sourceText: text,
            sourceLanguage: source,
            generation: block.generation,
            isFrozen: true
        ))
        startTranslationWorkerIfNeeded()
        activeSourcePhrases = []
        activeTranslation = nil
    }

    private func translateFinalCues(
        _ cues: [TranscriptionCueValue],
        detectedLanguage: String?
    ) async -> (values: [TranslatedSubtitleCueValue], status: RecordingTranslationStatus) {
        guard sessionTranslationEnabled else {
            return ([], .none)
        }
        translationDebounceTask?.cancel()
        translationWorkerTask?.cancel()
        await translationWorkerTask?.value
        subtitleTranslator.reset()
        let finalText = cues.map(\.text).joined(separator: " ")
        let source = resolvedTranslationSource(
            detectedLanguage: detectedLanguage,
            fallbackText: finalText
        )
        guard let source else {
            return ([], .failed)
        }
        if TranslationPolicy.sameLanguage(source, sessionTranslationTarget) {
            return ([], .complete)
        }

        let groups = ContextualTranslationGrouper.groups(from: cues)
        var values: [TranslatedSubtitleCueValue] = []
        var failures = 0
        for (index, group) in groups.enumerated() {
            do {
                let translated = try await subtitleTranslator.translate(
                    group.map(\.text).joined(separator: " "),
                    source: source,
                    target: sessionTranslationTarget,
                    quality: .highFidelity
                )
                if let value = ContextualTranslationGrouper.value(
                    for: group,
                    translatedText: translated,
                    index: index
                ) { values.append(value) }
            } catch {
                failures += 1
            }
        }
        if failures == 0 { return (values, .complete) }
        if failures == groups.count { return (values, .failed) }
        return (values, .partial)
    }

    private func resolvedTranslationSource(
        detectedLanguage override: String? = nil,
        fallbackText: String? = nil
    ) -> String? {
        switch sessionRequestedLanguage {
        case .spanish: "es"
        case .english: "en"
        case .german: "de"
        case .automatic:
            if let raw = override ?? detectedLanguage,
               let canonical = SpokenLanguageResolver.canonicalCode(raw)
            {
                canonical
            } else if let fallbackText {
                SpokenLanguageResolver.detect(in: fallbackText)
            } else {
                nil
            }
        }
    }

    private func detectLanguageFromStableTextIfNeeded() {
        guard sessionRequestedLanguage == .automatic, detectedLanguage == nil else { return }
        let stableText = (liveTranslationBlocks.map(\.sourceText) + activeSourcePhrases).joined(separator: " ")
        guard let language = SpokenLanguageResolver.detect(in: stableText) else { return }
        detectedLanguage = language
    }

    private func beginRecoverySnapshots() {
        recoveryTask?.cancel()
        recoveryTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                currentRecording?.duration = elapsed
                currentRecording?.transcript = liveTranscript
                try? context?.save()
            }
        }
    }

    private func fail(_ error: Error) {
        state = .failed(error.localizedDescription)
        modelProgress = nil
    }

    private func preparedNemotronEngine(settings: AppSettings) async throws -> NemotronEngine {
        if let warmNemotronEngine {
            observeNemotron(warmNemotronEngine)
            try await warmNemotronEngine.prepare(language: settings.language)
            return warmNemotronEngine
        }
        if let nemotronWarmTask {
            let selectedEngine = try await nemotronWarmTask.value
            warmNemotronEngine = selectedEngine
            observeNemotron(selectedEngine)
            try await selectedEngine.prepare(language: settings.language)
            return selectedEngine
        }

        let selectedEngine = NemotronEngine()
        observeNemotron(selectedEngine)
        let task = Task<NemotronEngine, Error> {
            try await selectedEngine.prepare(language: settings.language)
            return selectedEngine
        }
        nemotronWarmTask = task
        do {
            let prepared = try await task.value
            nemotronWarmTask = nil
            warmNemotronEngine = prepared
            return prepared
        } catch {
            nemotronWarmTask = nil
            nemotronEventTask?.cancel()
            nemotronEventTask = nil
            throw error
        }
    }

    private func cleanupSession(keepingRecording: Bool) {
        eventTask?.cancel(); eventTask = nil
        bufferTask?.cancel(); bufferTask = nil
        recoveryTask?.cancel(); recoveryTask = nil
        translationDebounceTask?.cancel(); translationDebounceTask = nil
        translationWorkerTask?.cancel(); translationWorkerTask = nil
        pendingLiveTranslations = LatestValueMailbox()
        frozenTranslationQueue = []
        activeSourcePhrases = []
        bufferContinuation = nil
        engine = nil
        subtitleTranslator.reset()
        phraseSegmenter.reset()
        if !keepingRecording { currentRecording = nil }
    }

    private static func defaultTitle() -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Grabación \(formatter.string(from: .now))"
    }
}

private struct LiveTranslationRequest: Sendable {
    let blockID: UUID
    let sourceText: String
    let sourceLanguage: String
    let generation: Int
    let isFrozen: Bool
}
