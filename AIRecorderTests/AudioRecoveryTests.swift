@preconcurrency import AVFoundation
import XCTest
@testable import AIRecorder

final class AudioRecoveryTests: XCTestCase {
    func testUnreadableM4AUsesCrashSafeRecoveryAudio() async throws {
        let id = UUID()
        let storage = StorageService.shared
        let primary = try await storage.audioURL(id: id)
        let recovery = try await storage.recoveryAudioURL(id: id)

        try Data("incomplete m4a".utf8).write(to: primary)
        try writePCMFile(to: recovery)

        let primaryPath = try await storage.relativePath(for: primary)
        let recoveryPath = try await storage.relativePath(for: recovery)
        let resolved = try await storage.resolvePlayableAudio(
            relativePath: primaryPath,
            id: id
        )
        let finalizedPath = try await storage.finalizeCapturedAudio(
            relativePath: primaryPath,
            id: id
        )

        XCTAssertEqual(resolved, recovery)
        XCTAssertEqual(finalizedPath, recoveryPath)
        try await storage.removeRecording(id: id)
    }

    func testFinalizingValidPrimaryRemovesTemporaryRecoveryAudio() async throws {
        let id = UUID()
        let storage = StorageService.shared
        let primary = try await storage.audioURL(id: id, extension: "caf")
        let recovery = try await storage.recoveryAudioURL(id: id)
        try writePCMFile(to: primary)
        try writePCMFile(to: recovery)
        let relativePath = try await storage.relativePath(for: primary)

        let finalizedPath = try await storage.finalizeCapturedAudio(
            relativePath: relativePath,
            id: id
        )

        XCTAssertEqual(finalizedPath, relativePath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recovery.path))
        try await storage.removeRecording(id: id)
    }

    private func writePCMFile(to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410)
        else {
            throw AppError.unsupportedAudio
        }
        buffer.frameLength = buffer.frameCapacity
        buffer.floatChannelData?[0].initialize(repeating: 0, count: Int(buffer.frameLength))
        try file.write(from: buffer)
    }
}
