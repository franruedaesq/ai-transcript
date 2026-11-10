@preconcurrency import FluidAudio
import Foundation
import Observation
import SwiftData

/// FluidAudio's manager does not yet declare Swift 6 sendability. The manager
/// stays owned by `SpeakerDiarizationWorker`, and its controller prevents
/// overlapping jobs.
private final class SpeakerDiarizerManagerBox: @unchecked Sendable {
    let manager: OfflineDiarizerManager

    init(config: OfflineDiarizerConfig) {
        manager = OfflineDiarizerManager(config: config)
    }

    func prepareModels() async throws {
        try await manager.prepareModels()
    }

    func process(
        url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [SpeakerTurnValue] {
        let result = try await manager.process(url) { completed, total in
            if total > 0 { progress(Double(completed) / Double(total)) }
        }
        return result.segments.map {
            .init(
                speakerID: $0.speakerId,
                startTime: TimeInterval($0.startTimeSeconds),
                endTime: TimeInterval($0.endTimeSeconds),
                confidence: $0.qualityScore
            )
        }
    }
}

private actor SpeakerDiarizationWorker {
    private var manager: SpeakerDiarizerManagerBox?
    private var preparedSpeakerCount: Int?

    func process(
        url: URL,
        expectedSpeakerCount: Int?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [SpeakerTurnValue] {
        let manager = try await preparedManager(expectedSpeakerCount: expectedSpeakerCount)
        let turns = try await manager.process(url: url, progress: progress)
        try Task.checkCancellation()
        return turns
    }

    private func preparedManager(expectedSpeakerCount: Int?) async throws -> SpeakerDiarizerManagerBox {
        if let manager, preparedSpeakerCount == expectedSpeakerCount { return manager }
        var config = OfflineDiarizerConfig()
        // FluidAudio's AMI-SDM meeting benchmark performs materially better at
        // 0.7 than the more merge-prone 0.6 default. A known count overrides
        // the automatic cluster count when the user supplies one.
        config.clustering.threshold = 0.7
        config.clustering.numSpeakers = expectedSpeakerCount
        let manager = SpeakerDiarizerManagerBox(config: config)
        try await manager.prepareModels()
        self.manager = manager
        preparedSpeakerCount = expectedSpeakerCount
        return manager
    }
}

@MainActor @Observable
final class SpeakerDiarizationController {
    private let worker = SpeakerDiarizationWorker()
    var isProcessing = false; var progress: Double?; var statusText: String?; var errorMessage: String?
    func diarize(recording: Recording, context: ModelContext) async {
        guard !isProcessing else { return }
        guard !recording.cues.isEmpty else {
            errorMessage = AppLocalization.string("Reconstruye primero la transcripción para identificar hablantes.")
            return
        }
        isProcessing = true; progress = nil; errorMessage = nil; statusText = AppLocalization.string("Preparando diarización…")
        defer { isProcessing = false; statusText = nil }
        do {
            let url = try await StorageService.shared.resolvePlayableAudio(
                relativePath: recording.audioRelativePath,
                id: recording.id
            )
            statusText = AppLocalization.string("Identificando hablantes…")
            let turns = try await worker.process(
                url: url,
                expectedSpeakerCount: recording.expectedSpeakerCount
            ) { [weak self] value in
                Task { @MainActor in self?.progress = value }
            }
            statusText = AppLocalization.string("Alineando la transcripción…")
            progress = nil
            try SpeakerPersistenceService.replaceDiarization(on: recording, with: turns, context: context)
            progress = 1
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

enum SpeakerLabelFormatter {
    static func displayName(for speakerID: String) -> String {
        let uppercasedID = speakerID.uppercased()
        if uppercasedID.hasPrefix("SPEAKER_"),
           let zeroBasedNumber = Int(uppercasedID.dropFirst("SPEAKER_".count)) {
            return AppLocalization.string("Hablante \(zeroBasedNumber + 1)")
        }
        if speakerID.hasPrefix("S"), let number = Int(speakerID.dropFirst()) { return AppLocalization.string("Hablante \(number)") }
        return AppLocalization.string("Hablante \(speakerID)")
    }

    @MainActor
    static func displayName(for speakerID: String, in recording: Recording) -> String {
        recording.speakerProfiles.first(where: { $0.speakerID == speakerID })?.name
            ?? displayName(for: speakerID)
    }
}
