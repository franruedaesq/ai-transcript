@preconcurrency import AVFoundation
import Foundation

#if compiler(>=6.2)
import Speech

actor AppleSpeechEngine: StreamingTranscriptionEngine {
    nonisolated let events: AsyncStream<TranscriptionEvent>
    private let continuation: AsyncStream<TranscriptionEvent>.Continuation
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var finalizedText = ""
    private var cueValues: [TranscriptionCueValue] = []

    init() {
        let pair = AsyncStream<TranscriptionEvent>.makeStream(bufferingPolicy: .bufferingNewest(32))
        events = pair.stream
        continuation = pair.continuation
    }

    func prepare(language: TranscriptionLanguage) async throws {
        guard SpeechTranscriber.isAvailable else { throw AppError.appleSpeechUnavailable }
        continuation.yield(.preparing)
        let locale = language.locale
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw AppError.appleSpeechUnavailable
        }
        let transcriber = SpeechTranscriber(
            locale: supported,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange]
        )
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        self.transcriber = transcriber
        self.analyzer = analyzer
        continuation.yield(.ready)
    }

    func start() async throws {
        guard let analyzer, let transcriber else { throw AppError.invalidState }
        finalizedText = ""
        cueValues = []
        let pair = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(64))
        inputContinuation = pair.continuation
        try await analyzer.start(inputSequence: pair.stream)
        resultsTask = Task { [continuation] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        finalizedText += (finalizedText.isEmpty ? "" : " ") + text
                        if let range = result.text.runs.compactMap(\.audioTimeRange).first {
                            let cue = TranscriptionCueValue(
                                index: cueValues.count,
                                startTime: range.start.seconds,
                                endTime: range.end.seconds,
                                text: text,
                                confidence: 1
                            )
                            cueValues.append(cue)
                            continuation.yield(.finalized(cue))
                        }
                    }
                    continuation.yield(.partial(finalizedText + (result.isFinal ? "" : " " + text)))
                }
            } catch {
                continuation.yield(.failed(error.localizedDescription))
            }
        }
    }

    func consume(_ buffer: AVAudioPCMBuffer) async throws {
        guard let format = analyzerFormat, let inputContinuation else { throw AppError.invalidState }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converted = try converter?.convertedCopy(of: buffer, to: format) else { return }
        inputContinuation.yield(AnalyzerInput(buffer: converted))
    }

    func pause() {}
    func resume() async throws {}

    func finish() async throws -> TranscriptionResult {
        inputContinuation?.finish()
        try await analyzer?.finalizeAndFinishThroughEndOfInput()
        await resultsTask?.value
        let cues = CueBuilder.normalized(cueValues)
        return .init(text: finalizedText.cleanedTranscriptSpacing, detectedLanguage: nil, tokens: [], cues: cues)
    }

    func reset() async {
        await analyzer?.cancelAndFinishNow()
        inputContinuation?.finish()
        resultsTask?.cancel()
        finalizedText = ""
        cueValues = []
    }
}

#else
actor AppleSpeechEngine: StreamingTranscriptionEngine {
    nonisolated let events: AsyncStream<TranscriptionEvent>
    private let continuation: AsyncStream<TranscriptionEvent>.Continuation

    init() {
        let pair = AsyncStream<TranscriptionEvent>.makeStream()
        events = pair.stream
        continuation = pair.continuation
    }

    func prepare(language: TranscriptionLanguage) async throws {
        let message = "SpeechTranscriber requiere compilar esta app con Xcode 26 o posterior."
        continuation.yield(.failed(message))
        throw AppError.modelUnavailable(message)
    }
    func start() async throws { throw AppError.appleSpeechUnavailable }
    func consume(_ buffer: AVAudioPCMBuffer) async throws {}
    func pause() async {}
    func resume() async throws {}
    func finish() async throws -> TranscriptionResult { throw AppError.appleSpeechUnavailable }
    func reset() async {}
}
#endif

private extension AVAudioConverter {
    func convertedCopy(of input: AVAudioPCMBuffer, to outputFormat: AVAudioFormat) throws -> AVAudioPCMBuffer? {
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        let inputState = AppleSpeechConversionInputState()
        var conversionError: NSError?
        convert(to: output, error: &conversionError) { _, status in
            guard !inputState.supplied else { status.pointee = .noDataNow; return nil }
            inputState.supplied = true
            status.pointee = .haveData
            return input
        }
        if let conversionError { throw conversionError }
        return output
    }
}

private final class AppleSpeechConversionInputState: @unchecked Sendable {
    var supplied = false
}
