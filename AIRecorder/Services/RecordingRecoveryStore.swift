import Foundation

/// A small, independent recovery record. It deliberately avoids SwiftData so
/// recordings can still be recovered if the store cannot be opened or migrated.
struct RecordingRecoverySnapshot: Codable, Sendable {
    let id: UUID
    let title: String
    let createdAt: Date
    let duration: TimeInterval
    let audioRelativePath: String
    let source: RecordingSource
    let engine: TranscriptionEngineKind
    let requestedLanguage: TranscriptionLanguage
    let detectedLanguage: String?
    let transcript: String
    let status: RecordingStatus
    let translationEnabled: Bool
    let translationTargetLanguage: String?
    let translationStatus: RecordingTranslationStatus?
    let expectedSpeakerCount: Int?
    let cues: [TranscriptionCueValue]?
    let tokens: [AppTokenTiming]?
    let translatedCues: [TranslatedSubtitleCueValue]?
    let markers: [RecordingMarkerValue]?
    let speakerProfiles: [SpeakerProfileValue]?
    let speakerTurns: [SpeakerTurnValue]?

    @MainActor
    init(recording: Recording) {
        id = recording.id
        title = recording.title
        createdAt = recording.createdAt
        duration = recording.duration
        audioRelativePath = recording.audioRelativePath
        source = recording.source
        engine = recording.engine
        requestedLanguage = recording.requestedLanguage
        detectedLanguage = recording.detectedLanguage
        transcript = recording.transcript
        status = recording.status
        translationEnabled = recording.translationEnabled
        translationTargetLanguage = recording.translationTargetLanguage
        translationStatus = recording.translationStatus
        expectedSpeakerCount = recording.expectedSpeakerCount
        cues = recording.cues.map(\.value)
        tokens = recording.orderedTokens.map(\.value)
        translatedCues = recording.translatedCues.map(\.value)
        markers = recording.markers.map(\.value)
        speakerProfiles = recording.orderedSpeakerProfiles.map(\.value)
        speakerTurns = recording.orderedSpeakerTurns.map(\.value)
    }
}

enum RecordingRecoveryStore {
    private static let filename = "recording-recovery.json"

    static func write(_ snapshot: RecordingRecoverySnapshot) throws {
        let url = try sidecarURL(id: snapshot.id)
        let encoder = JSONEncoder()
        try encoder.encode(snapshot).write(to: url, options: .atomic)
    }

    static func remove(id: UUID) throws {
        let url = try sidecarURL(id: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    static func loadAll() throws -> [RecordingRecoverySnapshot] {
        let root = try recordingsRoot()
        let directories = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let decoder = JSONDecoder()
        return directories.compactMap { directory in
            let url = directory.appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(RecordingRecoverySnapshot.self, from: data)
        }
    }

    private static func sidecarURL(id: UUID) throws -> URL {
        try recordingsRoot()
            .appendingPathComponent(id.uuidString, isDirectory: true)
            .appendingPathComponent(filename)
    }

    private static func recordingsRoot() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = base.appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
