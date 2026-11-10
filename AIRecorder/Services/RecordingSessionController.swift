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
    private let recoveryWriter = RecordingRecoveryWriter()
    private var engine: (any StreamingTranscriptionEngine)?
    private var warmNemotronEngine: NemotronEngine?
    private var nemotronWarmTask: Task<NemotronEngine, Error>?
    private var nemotronEventTask: Task<Void, Never>?
    private var isAutomaticPrewarming = false
    private var eventTask: Task<Void, Never>?
    private var bufferTask: Task<Void, Never>?
    private var liveBufferGate: BoundedAsyncStreamGate<AVAudioPCMBuffer>?
    private var finalizationTask: Task<Void, Never>?
    private var recoveryWriteTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var inputWatchdogTask: Task<Void, Never>?
    private var translationDebounceTask: Task<Void, Never>?
    private var translationWorkerTask: Task<Void, Never>?
    private var pendingLiveTranslations = LatestValueMailbox<LiveTranslationRequest>()
    private var frozenTranslationQueue: [LiveTranslationRequest] = []
    private var activeSourcePhrases: [String] = []
    private var context: ModelContext?
    private var phraseSegmenter = LivePhraseSegmenter()
    private var languageDetector = StableSpokenLanguageDetector(requiredMatches: 3)
    private let subtitleTranslator = SubtitleTranslationController()
    private var sessionTranslationEnabled = false
    private var sessionTranslationTarget = "en"
    private var sessionRequestedLanguage: TranscriptionLanguage = .automatic
    private var sessionVocabulary: [CustomVocabularyEntry] = []
    private var lastMeterSampleDate = Date.distantPast
    private var lastMeaningfulAudioAt: TimeInterval = 0

    var state: RecordingSessionState = .idle
    var currentRecording: Recording?
    var liveTranscript = ""
    var liveTranscriptBlocks: [LiveTranscriptBlock] = []
    var liveTranscriptProvisional = ""
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
    var sessionNotice: String?
    var finalizationProgress: Double?
    var finalizationLabel: String?
    var activeInputRoute: AudioRouteInfo?
    var inputWarning: String?
    var lastMarkerNotice: String?
    private var streamingGapDetected = false
    private var streamingFailureMessage: String?

    func prepareNemotron(settings: AppSettings) async -> Bool {
        guard state == .idle else { return false }
        state = .preparing
        modelProgress = nil
        modelProgressLabel = AppLocalization.string("Conectando…")
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
        liveTranscriptBlocks = []
        liveTranscriptProvisional = ""
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
        languageDetector.reset()
        streamingGapDetected = false
        streamingFailureMessage = nil
        sessionNotice = nil
        sessionTranslationEnabled = settings.translationEnabled
        sessionTranslationTarget = settings.translationTargetLanguage
        sessionRequestedLanguage = settings.language
        sessionVocabulary = settings.customVocabulary
        activeInputRoute = nil
        inputWarning = nil
        lastMarkerNotice = nil
        lastMeterSampleDate = .now
        lastMeaningfulAudioAt = 0

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
            try await selectedEngine.setVocabulary(settings.vocabularyHints)
            try await selectedEngine.start()

            let id = UUID()
            let audioURL = try await storage.audioURL(id: id)
            let recoveryAudioURL = try await storage.recoveryAudioURL(id: id)
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
            currentRecording = recording
            try context.save()
            try RecordingRecoveryStore.write(.init(recording: recording))

            let pair = AsyncStream<AVAudioPCMBuffer>.makeStream(bufferingPolicy: .bufferingOldest(24))
            let liveBufferGate = BoundedAsyncStreamGate(continuation: pair.continuation)
            self.liveBufferGate = liveBufferGate
            bufferTask = Task.detached(priority: .userInitiated) { [weak self] in
                do {
                    for await buffer in pair.stream { try await selectedEngine.consume(buffer) }
                } catch is CancellationError {
                    return
                } catch {
                    await MainActor.run {
                        self?.streamingGapDetected = true
                        self?.streamingFailureMessage = error.localizedDescription
                        self?.sessionNotice = AppLocalization.string("La transcripción en vivo se interrumpió. El audio continúa guardándose y se verificará al finalizar.")
                    }
                }
            }
            try audioCapture.start(destination: audioURL, recoveryDestination: recoveryAudioURL) { [weak self, liveBufferGate] buffer in
                if liveBufferGate.yield(buffer) == .overflow {
                    Task { @MainActor in
                        self?.streamingGapDetected = true
                        self?.sessionNotice = AppLocalization.string("La transcripción en vivo se está poniendo al día. El audio está guardado y se verificará al finalizar.")
                    }
                }
            } onMeter: { [weak self] level, duration in
                Task { @MainActor in self?.updateMeter(level: level, duration: duration) }
            } onEvent: { [weak self] event in
                Task { @MainActor in self?.handleAudioCaptureEvent(event) }
            }
            state = .recording
            beginRecoverySnapshots()
            beginInputWatchdog()
        } catch {
            liveBufferGate?.finish()
            bufferTask?.cancel()
            await bufferTask?.value
            if let recording = currentRecording {
                context.delete(recording)
                try? context.save()
                try? RecordingRecoveryStore.remove(id: recording.id)
                try? await storage.removeRecording(id: recording.id)
            }
            await engine?.reset()
            cleanupSession(keepingRecording: false)
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
        inputWatchdogTask?.cancel()
        finalizationLabel = AppLocalization.string("Guardando audio…")
        let duration = await audioCapture.stop()
        liveBufferGate?.finish()
        guard let recording = currentRecording else {
            fail(AppError.invalidState)
            return nil
        }

        do {
            recording.audioRelativePath = try await storage.finalizeCapturedAudio(
                relativePath: recording.audioRelativePath,
                id: recording.id
            )
        } catch {
            await bufferTask?.value
            recording.duration = duration
            recording.transcript = liveTranscript
            recording.status = .interrupted
            try? context?.save()
            await flushRecoverySnapshot(for: recording)
            await engine?.reset()
            cleanupSession(keepingRecording: true)
            fail(error)
            return recording
        }

        recording.duration = duration
        recording.transcript = liveTranscript
        recording.status = .processing
        try? context?.save()
        scheduleRecoverySnapshot(for: recording)

        let requiresRetranscription = streamingGapDetected || liveBufferGate?.didOverflow == true
        if requiresRetranscription { bufferTask?.cancel() }
        finalizationTask = Task { [weak self] in
            await self?.finalizeStoppedRecording(
                recording,
                duration: duration,
                requiresRetranscription: requiresRetranscription
            )
        }
        return recording
    }

    private func retranscribeRecordedAudio(_ recording: Recording) async throws -> TranscriptionResult {
        guard let engine else { throw AppError.invalidState }
        let audioURL = try await storage.resolvePlayableAudio(
            relativePath: recording.audioRelativePath,
            id: recording.id
        )
        await engine.reset()
        try await engine.prepare(language: recording.requestedLanguage)
        let (output, _) = try await importer.transcribe(url: audioURL, engine: engine) { [weak self] progress in
            Task { @MainActor in self?.finalizationProgress = progress }
        }
        return output
    }

    private func finalizeStoppedRecording(
        _ recording: Recording,
        duration: TimeInterval,
        requiresRetranscription: Bool
    ) async {
        do {
            await bufferTask?.value
            // The live consumer can report an overflow while stop() drains the
            // final queued buffers. Re-check after it has fully exited so a
            // transcript with an undetected gap is never accepted.
            let shouldRetranscribe = requiresRetranscription
                || streamingGapDetected
                || liveBufferGate?.didOverflow == true
            let rawOutput: TranscriptionResult
            if shouldRetranscribe {
                finalizationLabel = AppLocalization.string("Verificando transcripción desde el audio…")
                finalizationProgress = 0
                rawOutput = try await retranscribeRecordedAudio(recording)
            } else {
                do {
                    guard let output = try await engine?.finish() else { throw AppError.invalidState }
                    rawOutput = output
                } catch {
                    streamingGapDetected = true
                    streamingFailureMessage = error.localizedDescription
                    finalizationLabel = AppLocalization.string("Verificando transcripción desde el audio…")
                    finalizationProgress = 0
                    rawOutput = try await retranscribeRecordedAudio(recording)
                }
            }

            let finalOutput = VocabularyPostProcessor.apply(to: rawOutput, entries: sessionVocabulary)
            finalizationProgress = nil
            finalizationLabel = AppLocalization.string("Guardando transcripción…")
            recording.duration = duration
            recording.transcript = finalOutput.text
            recording.detectedLanguage = finalOutput.detectedLanguage ?? detectedLanguage
            replaceStoredTranscription(on: recording, with: finalOutput)

            if sessionTranslationEnabled {
                finalizationLabel = AppLocalization.string("Finalizando traducción…")
                await translateAndPersistFinalCues(
                    recording: recording,
                    cues: finalOutput.cues,
                    detectedLanguage: recording.detectedLanguage
                )
            } else {
                recording.translationStatus = .none
            }

            recording.status = .saved
            try context?.save()
            await flushRecoverySnapshot(for: recording)
            finalizationLabel = nil
            finalizationProgress = nil
            state = .idle
            cleanupSession(keepingRecording: true)
        } catch {
            recording.duration = duration
            recording.transcript = liveTranscript
            recording.status = .interrupted
            try? context?.save()
            await flushRecoverySnapshot(for: recording)
            finalizationLabel = nil
            finalizationProgress = nil
            cleanupSession(keepingRecording: true)
            fail(error)
        }
        finalizationTask = nil
    }

    private func handleAudioCaptureEvent(_ event: AudioCaptureEvent) {
        switch event {
        case .interruptionBegan:
            guard state == .recording else { return }
            sessionNotice = AppLocalization.string("La grabación fue pausada por otra aplicación o una llamada.")
            Task { await pause() }
        case .interruptionEnded:
            sessionNotice = AppLocalization.string("La interrupción terminó. Pulsa Reanudar para continuar.")
        case .routeChanged(let route):
            let previous = activeInputRoute
            activeInputRoute = route
            if let previous, let route, previous != route {
                sessionNotice = AppLocalization.string("La entrada de audio cambió a \(route.name).")
                lastMeterSampleDate = .now
                lastMeaningfulAudioAt = elapsed
            }
        case .failed(let message):
            if state == .finalizing {
                streamingGapDetected = true
                streamingFailureMessage = message
            } else {
                Task { await emergencyStop(message) }
            }
        }
    }

    private func emergencyStop(_ message: String) async {
        guard state == .recording || state == .paused else { state = .failed(message); return }
        recoveryTask?.cancel()
        inputWatchdogTask?.cancel()
        let duration = await audioCapture.stop()
        liveBufferGate?.finish()
        bufferTask?.cancel()
        await bufferTask?.value
        currentRecording?.duration = duration
        currentRecording?.transcript = liveTranscript
        currentRecording?.status = .interrupted
        if let currentRecording,
           let recoveredPath = try? await storage.finalizeCapturedAudio(
               relativePath: currentRecording.audioRelativePath,
               id: currentRecording.id
           ) {
            currentRecording.audioRelativePath = recoveredPath
        }
        try? context?.save()
        if let currentRecording {
            await flushRecoverySnapshot(for: currentRecording)
        }
        await engine?.reset()
        cleanupSession(keepingRecording: true)
        state = .failed(AppLocalization.string("\(message)\n\nEl audio grabado hasta ese momento se conservó."))
    }

    func importFile(_ source: URL, settings: AppSettings, context: ModelContext) async -> Recording? {
        guard state == .idle else { return nil }
        state = .preparing
        self.context = context
        importProgress = 0
        liveTranscript = ""
        let shouldTranslate = settings.translationEnabled
        let translationTarget = settings.translationTargetLanguage
        let id = UUID()
        var originalSaved = false
        sessionVocabulary = settings.customVocabulary
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
                status: .processing,
                translationEnabled: shouldTranslate,
                translationTargetLanguage: shouldTranslate ? translationTarget : nil
            )
            context.insert(recording)
            currentRecording = recording
            try context.save()
            try RecordingRecoveryStore.write(.init(recording: recording))

            let selectedEngine = TranscriptionEngineFactory.make(settings.engine)
            engine = selectedEngine
            observe(await selectedEngine.events)
            try await selectedEngine.prepare(language: settings.language)
            try await selectedEngine.setVocabulary(settings.vocabularyHints)
            let (rawOutput, duration) = try await importer.transcribe(url: destination, engine: selectedEngine) { [weak self] value in
                Task { @MainActor in self?.importProgress = value }
            }
            let output = VocabularyPostProcessor.apply(to: rawOutput, entries: sessionVocabulary)
            recording.duration = duration
            recording.transcript = output.text
            recording.detectedLanguage = output.detectedLanguage
            recording.status = .saved
            replaceStoredTranscription(on: recording, with: output)
            try context.save()
            originalSaved = true
            try? RecordingRecoveryStore.write(.init(recording: recording))
            if shouldTranslate {
                sessionRequestedLanguage = settings.language
                sessionTranslationTarget = translationTarget
                sessionTranslationEnabled = true
                await translateAndPersistFinalCues(recording: recording, cues: output.cues, detectedLanguage: recording.detectedLanguage)
                try context.save()
                try? RecordingRecoveryStore.write(.init(recording: recording))
            }
            state = .idle
            importProgress = nil
            cleanupSession(keepingRecording: true)
            return recording
        } catch {
            if originalSaved, let recording = currentRecording {
                recording.status = .saved
                if shouldTranslate { recording.translationStatus = .failed }
                try? context.save()
                try? RecordingRecoveryStore.write(.init(recording: recording))
                state = .idle; importProgress = nil; cleanupSession(keepingRecording: true)
                return recording
            }
            if let recording = currentRecording { context.delete(recording) }
            try? await storage.removeRecording(id: id)
            try? context.save()
            importProgress = nil
            fail(error)
            return nil
        }
    }

    func addMarker() {
        guard state == .recording || state == .paused, let recording = currentRecording else { return }
        let marker = RecordingMarker(time: elapsed, title: AppLocalization.string("Marcador \(recording.markers.count + 1)"))
        marker.recording = recording; recording.markers.append(marker)
        try? context?.save()
        scheduleRecoverySnapshot(for: recording)
        lastMarkerNotice = AppLocalization.string("Marcador añadido en \(elapsed.formattedDuration)")
        let id = marker.id
        Task { [weak self] in try? await Task.sleep(for: .seconds(1.5)); guard self?.currentRecording?.markers.contains(where: { $0.id == id }) == true else { return }; self?.lastMarkerNotice = nil }
    }

    func persistRecoveryNow() {
        guard let recording = currentRecording else { return }
        recording.duration = elapsed; recording.transcript = liveTranscript
        try? context?.save()
        scheduleRecoverySnapshot(for: recording)
    }

    private func scheduleRecoverySnapshot(for recording: Recording) {
        let snapshot = RecordingRecoverySnapshot(recording: recording)
        let previousWrite = recoveryWriteTask
        recoveryWriteTask = Task { [recoveryWriter] in
            await previousWrite?.value
            await recoveryWriter.write(snapshot)
        }
    }

    private func flushRecoverySnapshot(for recording: Recording) async {
        scheduleRecoverySnapshot(for: recording)
        await recoveryWriteTask?.value
    }

    private func replaceStoredTranscription(on recording: Recording, with result: TranscriptionResult) {
        recording.cues.forEach { context?.delete($0) }; recording.cues.removeAll()
        recording.tokens.forEach { context?.delete($0) }; recording.tokens.removeAll()
        recording.speakerTurns.forEach { context?.delete($0) }; recording.speakerTurns.removeAll()
        recording.speakerProfiles.forEach { context?.delete($0) }; recording.speakerProfiles.removeAll()
        for value in result.cues { let cue = TranscriptCue(value: value); cue.recording = recording; recording.cues.append(cue) }
        for (index, value) in result.tokens.enumerated() { let token = TranscriptToken(index: index, value: value); token.recording = recording; recording.tokens.append(token) }
    }

    func resetError() {
        if case .failed = state { state = .idle }
        cleanupSession(keepingRecording: false)
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
            guard sessionRequestedLanguage == .automatic else { break }
            if let stableLanguage = languageDetector.observe(language) {
                detectedLanguage = stableLanguage
                refreshActiveTranslation()
            }
        case .failed(let message):
            modelPreparation = .failed(message)
            if state == .recording || state == .paused || state == .finalizing {
                streamingGapDetected = true
                streamingFailureMessage = message
                if state != .finalizing {
                    sessionNotice = AppLocalization.string("La transcripción en vivo se interrumpió. El audio continúa guardándose y se verificará al finalizar.")
                }
            } else if !isAutomaticPrewarming {
                state = .failed(message)
            }
        }
    }

    private func updateMeter(level: Float, duration: TimeInterval) {
        meterLevel = level
        elapsed = duration
        lastMeterSampleDate = .now
        let normalized = max(0.04, min(1, (level + 55) / 55))
        if !waveform.isEmpty { waveform.removeFirst() }
        waveform.append(normalized)
        if level > -58 { lastMeaningfulAudioAt = duration; inputWarning = nil }
        else if duration >= 5, level <= -79, duration - lastMeaningfulAudioAt >= 5 { inputWarning = AppLocalization.string("No se recibe una señal de audio clara. Revisa el micrófono o la entrada seleccionada.") }
        else if duration >= 12, duration - lastMeaningfulAudioAt >= 12 { inputWarning = AppLocalization.string("No se detecta voz desde hace varios segundos. La grabación continúa.") }
    }

    private func handlePartial(_ text: String) {
        liveTranscript = text
        let update = phraseSegmenter.update(text)
        for phrase in update.phrases {
            let clean = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty, liveTranscriptBlocks.last?.text != clean {
                liveTranscriptBlocks.append(LiveTranscriptBlock(text: clean))
            }
        }
        liveTranscriptProvisional = update.provisional
        guard sessionTranslationEnabled else { return }
        liveProvisional = update.provisional
        for phrase in update.phrases { acceptFinalizedPhrase(phrase) }
        detectLanguageFromStableTextIfNeeded()
        refreshActiveTranslation()
    }

    private func handleFinalizedCue(_ cue: TranscriptionCueValue) {
        persistFinalizedCueForRecovery(cue)
        guard sessionTranslationEnabled else { return }
        let finalizedWords = Self.words(in: cue.text)
        let stableText = (liveTranslationBlocks.map(\.sourceText) + activeSourcePhrases)
            .joined(separator: " ")
        let stableWords = Self.words(in: stableText)
        let overlap = Self.suffixPrefixOverlap(stableWords, finalizedWords)
        if overlap < finalizedWords.count {
            acceptFinalizedPhrase(finalizedWords.dropFirst(overlap).joined(separator: " "))
        }
        liveProvisional = ""
        detectLanguageFromStableTextIfNeeded()
        refreshActiveTranslation()
    }

    private func persistFinalizedCueForRecovery(_ value: TranscriptionCueValue) {
        guard state == .recording || state == .paused, let recording = currentRecording else { return }
        if let existing = recording.cues.first(where: { $0.index == value.index }) {
            existing.startTime = value.startTime; existing.endTime = value.endTime; existing.text = value.text; existing.confidence = value.confidence; existing.speakerID = value.speakerID
        } else { let cue = TranscriptCue(value: value); cue.recording = recording; recording.cues.append(cue) }
    }

    private static func words(in text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func suffixPrefixOverlap(_ stable: [String], _ finalized: [String]) -> Int {
        let maximum = min(stable.count, finalized.count)
        guard maximum > 0 else { return 0 }
        for length in stride(from: maximum, through: 1, by: -1) {
            let suffix = stable.suffix(length).map(normalizedWord)
            let prefix = finalized.prefix(length).map(normalizedWord)
            if suffix.elementsEqual(prefix) { return length }
        }
        return 0
    }

    private static func normalizedWord(_ word: String) -> String {
        word.trimmingCharacters(in: .punctuationCharacters).lowercased()
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
            translationNotice = AppLocalization.string("Esperando detectar el idioma hablado…")
            return
        }
        if TranslationPolicy.sameLanguage(source, sessionTranslationTarget) {
            translationNotice = AppLocalization.string("El idioma hablado coincide con el idioma de traducción.")
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
            translationNotice = AppLocalization.string("El idioma hablado coincide con el idioma de traducción.")
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

    private func translateAndPersistFinalCues(recording: Recording, cues: [TranscriptionCueValue], detectedLanguage: String?) async {
        guard sessionTranslationEnabled else {
            recording.translationStatus = .none
            return
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
            recording.translationStatus = .failed
            return
        }
        if TranslationPolicy.sameLanguage(source, sessionTranslationTarget) {
            recording.translatedCues.forEach { context?.delete($0) }
            recording.translatedCues.removeAll()
            recording.translationStatus = .complete
            return
        }
        recording.translationEnabled = true
        recording.translationTargetLanguage = sessionTranslationTarget
        recording.translationStatus = .partial
        let groups = ContextualTranslationGrouper.groups(from: cues)
        let sourceTexts = groups.map { $0.map(\.text).joined(separator: " ") }
        var translatedByIndex = await subtitleTranslator.translateBatch(
            sourceTexts,
            source: source,
            target: sessionTranslationTarget,
            quality: .highFidelity
        )

        for index in groups.indices where translatedByIndex[index] == nil {
            do {
                translatedByIndex[index] = try await subtitleTranslator.translate(
                    sourceTexts[index],
                    source: source,
                    target: sessionTranslationTarget,
                    quality: .highFidelity
                )
            } catch {
                continue
            }
        }

        recording.translatedCues.forEach { context?.delete($0) }
        recording.translatedCues.removeAll()
        for (index, group) in groups.enumerated() {
            guard let translated = translatedByIndex[index],
                  let value = ContextualTranslationGrouper.value(
                    for: group,
                    translatedText: translated,
                    index: index
                  )
            else { continue }
            let cue = TranslatedSubtitleCue(value: value)
            cue.recording = recording
            recording.translatedCues.append(cue)
        }
        let failures = groups.count - recording.translatedCues.count
        if failures == 0 { recording.translationStatus = .complete }
        else if failures == groups.count { recording.translationStatus = .failed }
        else { recording.translationStatus = .partial }
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
        guard let language = SpokenLanguageResolver.detect(in: stableText),
              let stableLanguage = languageDetector.observe(language)
        else { return }
        detectedLanguage = stableLanguage
    }

    private func beginRecoverySnapshots() {
        recoveryTask?.cancel()
        recoveryTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                persistRecoveryNow()
            }
        }
    }

    private func beginInputWatchdog() {
        inputWatchdogTask?.cancel()
        inputWatchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                guard self.state == .recording else { continue }
                if Date().timeIntervalSince(self.lastMeterSampleDate) > 4 {
                    self.inputWarning = AppLocalization.string("No llegan muestras del micrófono. La app conserva el audio disponible; revisa la entrada.")
                }
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
        inputWatchdogTask?.cancel(); inputWatchdogTask = nil
        translationDebounceTask?.cancel(); translationDebounceTask = nil
        translationWorkerTask?.cancel(); translationWorkerTask = nil
        pendingLiveTranslations = LatestValueMailbox()
        frozenTranslationQueue = []
        activeSourcePhrases = []
        liveBufferGate = nil
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
        return AppLocalization.string("Grabación \(formatter.string(from: .now))")
    }
}

enum BoundedAsyncStreamYieldResult: Equatable, Sendable {
    case accepted
    case overflow
    case terminated
}

final class BoundedAsyncStreamGate<Element>: @unchecked Sendable {
    private let continuation: AsyncStream<Element>.Continuation
    private let lock = NSLock()
    private var isAccepting = true
    private var overflowed = false

    init(continuation: AsyncStream<Element>.Continuation) {
        self.continuation = continuation
    }

    var didOverflow: Bool {
        lock.lock()
        defer { lock.unlock() }
        return overflowed
    }

    func yield(_ element: sending Element) -> BoundedAsyncStreamYieldResult {
        lock.lock()
        let shouldYield = isAccepting
        lock.unlock()
        guard shouldYield else { return .terminated }

        switch continuation.yield(element) {
        case .enqueued:
            return .accepted
        case .dropped:
            lock.lock()
            overflowed = true
            isAccepting = false
            lock.unlock()
            continuation.finish()
            return .overflow
        case .terminated:
            lock.lock()
            isAccepting = false
            lock.unlock()
            return .terminated
        @unknown default:
            finish()
            return .terminated
        }
    }

    func finish() {
        lock.lock()
        let shouldFinish = isAccepting
        isAccepting = false
        lock.unlock()
        if shouldFinish { continuation.finish() }
    }
}

private actor RecordingRecoveryWriter {
    func write(_ snapshot: RecordingRecoverySnapshot) {
        try? RecordingRecoveryStore.write(snapshot)
    }
}

private struct LiveTranslationRequest: Sendable {
    let blockID: UUID
    let sourceText: String
    let sourceLanguage: String
    let generation: Int
    let isFrozen: Bool
}
