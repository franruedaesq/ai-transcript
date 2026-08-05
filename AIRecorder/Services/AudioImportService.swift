@preconcurrency import AVFoundation
import Foundation

actor AudioImportService {
    typealias ProgressHandler = @Sendable (Double) -> Void

    func transcribe(
        url: URL,
        engine: any StreamingTranscriptionEngine,
        progress: @escaping ProgressHandler
    ) async throws -> (TranscriptionResult, TimeInterval) {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0 else { throw AppError.unsupportedAudio }
        let duration = Double(file.length) / file.processingFormat.sampleRate
        try await engine.start()
        let capacity: AVAudioFrameCount = 16_384
        while file.framePosition < file.length {
            try Task.checkCancellation()
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else {
                throw AppError.unsupportedAudio
            }
            try file.read(into: buffer, frameCount: min(capacity, AVAudioFrameCount(file.length - file.framePosition)))
            if buffer.frameLength == 0 { break }
            try await engine.consume(buffer)
            progress(min(1, Double(file.framePosition) / Double(file.length)))
        }
        return (try await engine.finish(), duration)
    }
}
