@preconcurrency import AVFoundation
import Foundation

actor StorageService {
    static let shared = StorageService()

    private let fileManager = FileManager.default

    var recordingsRoot: URL {
        get throws {
            let base = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let root = base.appendingPathComponent("Recordings", isDirectory: true)
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            return root
        }
    }

    func makeRecordingDirectory(id: UUID) throws -> URL {
        let directory = try recordingsRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func audioURL(id: UUID, extension ext: String = "m4a") throws -> URL {
        try makeRecordingDirectory(id: id).appendingPathComponent("audio.\(ext)")
    }

    func recoveryAudioURL(id: UUID) throws -> URL {
        try makeRecordingDirectory(id: id).appendingPathComponent("audio-recovery.caf")
    }

    func relativePath(for url: URL) throws -> String {
        let root = try recordingsRoot.path(percentEncoded: false)
        let path = url.path(percentEncoded: false)
        guard path.hasPrefix(root) else { throw CocoaError(.fileWriteInvalidFileName) }
        return String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    func resolve(relativePath: String) throws -> URL {
        try recordingsRoot.appendingPathComponent(relativePath)
    }

    /// Returns the primary audio when it is readable, or the crash-safe CAF
    /// sidecar left by an interrupted microphone recording.
    func resolvePlayableAudio(relativePath: String, id: UUID) throws -> URL {
        let primary = try resolve(relativePath: relativePath)
        if Self.isReadableAudio(at: primary) { return primary }

        let recovery = try recoveryAudioURL(id: id)
        if recovery != primary, Self.isReadableAudio(at: recovery) { return recovery }

        throw AppError.recordingAudioUnavailable
    }

    /// Keeps the compact M4A after a normal stop. If that file could not be
    /// finalized, it promotes the independent CAF recovery copy instead.
    func finalizeCapturedAudio(relativePath: String, id: UUID) throws -> String {
        let primary = try resolve(relativePath: relativePath)
        let recovery = try recoveryAudioURL(id: id)

        if Self.isReadableAudio(at: primary) {
            if fileManager.fileExists(atPath: recovery.path) {
                try? fileManager.removeItem(at: recovery)
            }
            return relativePath
        }

        guard Self.isReadableAudio(at: recovery) else {
            throw AppError.recordingAudioUnavailable
        }
        return try self.relativePath(for: recovery)
    }

    func importAudio(from source: URL, id: UUID) throws -> URL {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        let ext = source.pathExtension.lowercased()
        guard ["m4a", "caf", "wav"].contains(ext) else { throw AppError.unsupportedAudio }
        let destination = try audioURL(id: id, extension: ext)
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        try fileManager.copyItem(at: source, to: destination)
        return destination
    }

    func removeRecording(id: UUID) throws {
        let directory = try recordingsRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        if fileManager.fileExists(atPath: directory.path) { try fileManager.removeItem(at: directory) }
    }

    private static func isReadableAudio(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let fileSize = values.fileSize,
              fileSize > 0,
              let file = try? AVAudioFile(forReading: url)
        else { return false }

        return file.length > 0 && file.processingFormat.sampleRate > 0
    }
}
