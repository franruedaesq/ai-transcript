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

    func relativePath(for url: URL) throws -> String {
        let root = try recordingsRoot.path(percentEncoded: false)
        let path = url.path(percentEncoded: false)
        guard path.hasPrefix(root) else { throw CocoaError(.fileWriteInvalidFileName) }
        return String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    func resolve(relativePath: String) throws -> URL {
        try recordingsRoot.appendingPathComponent(relativePath)
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
}
