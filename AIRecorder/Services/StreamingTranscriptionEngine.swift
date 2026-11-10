@preconcurrency import AVFoundation
import Foundation

protocol StreamingTranscriptionEngine: Actor {
    var events: AsyncStream<TranscriptionEvent> { get }
    func prepare(language: TranscriptionLanguage) async throws
    func setVocabulary(_ phrases: [String]) async throws
    func start() async throws
    func consume(_ buffer: AVAudioPCMBuffer) async throws
    func pause() async
    func resume() async throws
    func finish() async throws -> TranscriptionResult
    func reset() async
}

extension StreamingTranscriptionEngine {
    func setVocabulary(_ phrases: [String]) async throws {}
}

enum TranscriptionEngineFactory {
    static func make(_ kind: TranscriptionEngineKind) -> any StreamingTranscriptionEngine {
        switch kind {
        case .nemotron: NemotronEngine()
        case .appleSpeech: AppleSpeechEngine()
        }
    }
}
