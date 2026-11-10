import Foundation

enum RecordingExportKind: String, CaseIterable, Identifiable, Sendable {
    case audio
    case transcriptText
    case transcriptSRT
    case transcriptVTT
    case translationText
    case translationSRT
    case translationVTT
    case bilingualText
    case bilingualSRT
    case bilingualVTT
    case archiveJSON

    var id: String { rawValue }

    var title: String {
        switch self {
        case .audio: AppLocalization.string("Audio original")
        case .transcriptText: AppLocalization.string("Transcripción · TXT")
        case .transcriptSRT: AppLocalization.string("Transcripción · SRT")
        case .transcriptVTT: AppLocalization.string("Transcripción · VTT")
        case .translationText: AppLocalization.string("Traducción · TXT")
        case .translationSRT: AppLocalization.string("Traducción · SRT")
        case .translationVTT: AppLocalization.string("Traducción · VTT")
        case .bilingualText: AppLocalization.string("Original + traducción · TXT")
        case .bilingualSRT: AppLocalization.string("Original + traducción · SRT")
        case .bilingualVTT: AppLocalization.string("Original + traducción · VTT")
        case .archiveJSON: AppLocalization.string("Datos · JSON")
        }
    }
}

struct RecordingExportSnapshot: Sendable {
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
    let translationEnabled: Bool
    let translationTargetLanguage: String?
    let translationStatus: RecordingTranslationStatus
    let expectedSpeakerCount: Int?
    let originalCues: [TranscriptionCueValue]
    let tokens: [AppTokenTiming]
    let translatedCues: [TranslatedSubtitleCueValue]
    let markers: [RecordingMarkerValue]
    let speakerProfiles: [SpeakerProfileValue]
    let speakerTurns: [SpeakerTurnValue]
    let speakerNames: [String: String]

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
        translationEnabled = recording.translationEnabled
        translationTargetLanguage = recording.translationTargetLanguage
        translationStatus = recording.translationStatus
        expectedSpeakerCount = recording.expectedSpeakerCount
        originalCues = recording.orderedCues.map(\.value)
        tokens = recording.orderedTokens.map(\.value)
        markers = recording.orderedMarkers.map(\.value)
        speakerProfiles = recording.orderedSpeakerProfiles.map(\.value)
        speakerTurns = recording.orderedSpeakerTurns.map(\.value)
        speakerNames = Dictionary(uniqueKeysWithValues: recording.speakerProfiles.map {
            ($0.speakerID, $0.name ?? SpeakerLabelFormatter.displayName(for: $0.speakerID))
        })
        if recording.orderedTranslatedCues.isEmpty {
            translatedCues = recording.orderedCues.enumerated().compactMap { offset, cue in
                guard let text = cue.translatedText, !text.isEmpty else { return nil }
                return .init(
                    index: offset,
                    startTime: cue.startTime,
                    endTime: cue.endTime,
                    sourceStartIndex: cue.index,
                    sourceEndIndex: cue.index,
                    text: text
                )
            }
        } else {
            translatedCues = recording.orderedTranslatedCues.map(\.value)
        }
    }

    var translationText: String {
        translatedCues.map {
            SubtitleExporter.labeledTranslatedText(
                $0,
                original: originalCues,
                speakerNames: speakerNames
            )
        }.joined(separator: "\n\n")
    }

    var transcriptText: String {
        guard originalCues.contains(where: { $0.speakerID != nil }) else { return transcript }
        return originalCues.map {
            SubtitleExporter.labeledOriginalText($0, speakerNames: speakerNames)
        }.joined(separator: "\n\n")
    }
}

actor RecordingExportService {
    static let shared = RecordingExportService()

    func prepare(_ kind: RecordingExportKind, snapshot: RecordingExportSnapshot) async throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIRecorderExports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let baseName = Self.safeFilename(snapshot.title)

        switch kind {
        case .audio:
            let source = try await StorageService.shared.resolvePlayableAudio(
                relativePath: snapshot.audioRelativePath,
                id: snapshot.id
            )
            let ext = source.pathExtension.isEmpty ? "m4a" : source.pathExtension
            let destination = directory.appendingPathComponent("\(baseName).\(ext)")
            try Self.replaceItem(at: destination, withCopyOf: source)
            return destination
        case .transcriptText:
            return try Self.write(snapshot.transcriptText, named: "\(baseName)-transcripcion.txt", in: directory)
        case .transcriptSRT:
            return try Self.write(
                SubtitleExporter.srt(original: snapshot.originalCues, speakerNames: snapshot.speakerNames),
                named: "\(baseName)-transcripcion.srt",
                in: directory
            )
        case .transcriptVTT:
            return try Self.write(SubtitleExporter.vtt(original: snapshot.originalCues, speakerNames: snapshot.speakerNames), named: "\(baseName)-transcripcion.vtt", in: directory)
        case .translationText:
            return try Self.write(snapshot.translationText, named: "\(baseName)-traduccion.txt", in: directory)
        case .translationSRT:
            return try Self.write(
                SubtitleExporter.srt(translated: snapshot.translatedCues, original: snapshot.originalCues, speakerNames: snapshot.speakerNames),
                named: "\(baseName)-traduccion.srt",
                in: directory
            )
        case .translationVTT:
            return try Self.write(SubtitleExporter.vtt(translated: snapshot.translatedCues, original: snapshot.originalCues, speakerNames: snapshot.speakerNames), named: "\(baseName)-traduccion.vtt", in: directory)
        case .bilingualText:
            return try Self.write(
                SubtitleExporter.bilingualText(
                    original: snapshot.originalCues,
                    translated: snapshot.translatedCues,
                    speakerNames: snapshot.speakerNames
                ),
                named: "\(baseName)-bilingue.txt",
                in: directory
            )
        case .bilingualSRT:
            return try Self.write(
                SubtitleExporter.bilingualSRT(
                    original: snapshot.originalCues,
                    translated: snapshot.translatedCues,
                    speakerNames: snapshot.speakerNames
                ),
                named: "\(baseName)-bilingue.srt",
                in: directory
            )
        case .bilingualVTT:
            return try Self.write(SubtitleExporter.bilingualVTT(original: snapshot.originalCues, translated: snapshot.translatedCues, speakerNames: snapshot.speakerNames), named: "\(baseName)-bilingue.vtt", in: directory)
        case .archiveJSON:
            let sourceURL = try await StorageService.shared.resolvePlayableAudio(
                relativePath: snapshot.audioRelativePath,
                id: snapshot.id
            )
            let ext = sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension
            let archive = PortableRecordingArchive(schemaVersion: 3, title: snapshot.title, transcript: snapshot.transcript, originalCues: snapshot.originalCues, tokens: snapshot.tokens, translatedCues: snapshot.translatedCues, createdAt: snapshot.createdAt, duration: snapshot.duration, source: snapshot.source, engine: snapshot.engine, requestedLanguage: snapshot.requestedLanguage, detectedLanguage: snapshot.detectedLanguage, translationEnabled: snapshot.translationEnabled, translationTargetLanguage: snapshot.translationTargetLanguage, translationStatus: snapshot.translationStatus, expectedSpeakerCount: snapshot.expectedSpeakerCount, audioFilename: "\(baseName).\(ext)", markers: snapshot.markers, speakerProfiles: snapshot.speakerProfiles, speakerTurns: snapshot.speakerTurns)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let url = directory.appendingPathComponent("\(baseName)-datos.json")
            try encoder.encode(archive).write(to: url, options: .atomic)
            return url
        }
    }

    func prepareMany(_ kinds: [RecordingExportKind], snapshot: RecordingExportSnapshot) async throws -> [URL] {
        var urls: [URL] = []
        for kind in kinds {
            urls.append(try await prepare(kind, snapshot: snapshot))
        }
        return urls
    }

    private static func safeFilename(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = value.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Grabacion" : String(cleaned.prefix(80))
    }

    private static func write(_ text: String, named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(text.utf8).write(to: url, options: .atomic)
        return url
    }

    private static func replaceItem(at destination: URL, withCopyOf source: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }
}

struct PortableRecordingArchive: Codable, Sendable {
    let schemaVersion: Int
    let title: String
    let transcript: String
    let originalCues: [TranscriptionCueValue]
    let tokens: [AppTokenTiming]?
    let translatedCues: [TranslatedSubtitleCueValue]
    let createdAt: Date?
    let duration: TimeInterval?
    let source: RecordingSource?
    let engine: TranscriptionEngineKind?
    let requestedLanguage: TranscriptionLanguage?
    let detectedLanguage: String?
    let translationEnabled: Bool?
    let translationTargetLanguage: String?
    let translationStatus: RecordingTranslationStatus?
    let expectedSpeakerCount: Int?
    let audioFilename: String?
    let markers: [RecordingMarkerValue]?
    let speakerProfiles: [SpeakerProfileValue]?
    let speakerTurns: [SpeakerTurnValue]?
}

enum SubtitleExporter {
    static func srt(
        original cues: [TranscriptionCueValue],
        speakerNames: [String: String] = [:]
    ) -> String {
        cues.sorted { $0.index < $1.index }.enumerated().map { offset, cue in
            entry(index: offset + 1, start: cue.startTime, end: cue.endTime, text: labeledOriginalText(cue, speakerNames: speakerNames))
        }.joined(separator: "\n\n")
    }

    static func srt(
        translated cues: [TranslatedSubtitleCueValue],
        original: [TranscriptionCueValue] = [],
        speakerNames: [String: String] = [:]
    ) -> String {
        cues.sorted { $0.index < $1.index }.enumerated().map { offset, cue in
            entry(index: offset + 1, start: cue.startTime, end: cue.endTime, text: labeledTranslatedText(cue, original: original, speakerNames: speakerNames))
        }.joined(separator: "\n\n")
    }

    static func bilingualText(
        original: [TranscriptionCueValue],
        translated: [TranslatedSubtitleCueValue],
        speakerNames: [String: String] = [:]
    ) -> String {
        translated.sorted { $0.index < $1.index }.map { translation in
            let source = sourceText(for: translation, original: original)
            let label = speakerLabel(for: translation, original: original, speakerNames: speakerNames)
            let prefix = label.map { "\($0): " } ?? ""
            return "[\(displayTimestamp(translation.startTime))]\n\(prefix)\(source)\n\(prefix)\(translation.text)"
        }.joined(separator: "\n\n")
    }

    static func bilingualSRT(
        original: [TranscriptionCueValue],
        translated: [TranslatedSubtitleCueValue],
        speakerNames: [String: String] = [:]
    ) -> String {
        translated.sorted { $0.index < $1.index }.enumerated().map { offset, translation in
            let source = sourceText(for: translation, original: original)
            let label = speakerLabel(for: translation, original: original, speakerNames: speakerNames)
            let prefix = label.map { "\($0): " } ?? ""
            return entry(
                index: offset + 1,
                start: translation.startTime,
                end: translation.endTime,
                text: "\(prefix)\(source)\n\(prefix)\(translation.text)"
            )
        }.joined(separator: "\n\n")
    }

    private static func sourceText(
        for translation: TranslatedSubtitleCueValue,
        original: [TranscriptionCueValue]
    ) -> String {
        original
            .filter { $0.index >= translation.sourceStartIndex && $0.index <= translation.sourceEndIndex }
            .sorted { $0.index < $1.index }
            .map(\.text)
            .joined(separator: " ")
    }

    private static func entry(
        index: Int,
        start: TimeInterval,
        end: TimeInterval,
        text: String
    ) -> String {
        "\(index)\n\(srtTimestamp(start)) --> \(srtTimestamp(max(start + 0.08, end)))\n\(text)"
    }

    private static func srtTimestamp(_ value: TimeInterval) -> String {
        let milliseconds = max(0, Int((value * 1_000).rounded()))
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds / 60_000) % 60
        let seconds = (milliseconds / 1_000) % 60
        let remainder = milliseconds % 1_000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, seconds, remainder)
    }

    static func vtt(original cues: [TranscriptionCueValue], speakerNames: [String: String] = [:]) -> String {
        "WEBVTT\n\n" + cues.sorted { $0.index < $1.index }.map { "\(vttTimestamp($0.startTime)) --> \(vttTimestamp(max($0.startTime + 0.08, $0.endTime)))\n\(labeledOriginalText($0, speakerNames: speakerNames))" }.joined(separator: "\n\n") + "\n"
    }

    static func vtt(translated cues: [TranslatedSubtitleCueValue], original: [TranscriptionCueValue] = [], speakerNames: [String: String] = [:]) -> String {
        "WEBVTT\n\n" + cues.sorted { $0.index < $1.index }.map { "\(vttTimestamp($0.startTime)) --> \(vttTimestamp(max($0.startTime + 0.08, $0.endTime)))\n\(labeledTranslatedText($0, original: original, speakerNames: speakerNames))" }.joined(separator: "\n\n") + "\n"
    }

    static func bilingualVTT(original: [TranscriptionCueValue], translated: [TranslatedSubtitleCueValue], speakerNames: [String: String] = [:]) -> String {
        "WEBVTT\n\n" + translated.sorted { $0.index < $1.index }.map {
            let label = speakerLabel(for: $0, original: original, speakerNames: speakerNames)
            let prefix = label.map { "\($0): " } ?? ""
            return "\(vttTimestamp($0.startTime)) --> \(vttTimestamp(max($0.startTime + 0.08, $0.endTime)))\n\(prefix)\(sourceText(for: $0, original: original))\n\(prefix)\($0.text)"
        }.joined(separator: "\n\n") + "\n"
    }

    static func labeledOriginalText(
        _ cue: TranscriptionCueValue,
        speakerNames: [String: String]
    ) -> String {
        guard let speakerID = cue.speakerID else { return cue.text }
        let name = speakerNames[speakerID] ?? SpeakerLabelFormatter.displayName(for: speakerID)
        return "\(name): \(cue.text)"
    }

    static func labeledTranslatedText(
        _ cue: TranslatedSubtitleCueValue,
        original: [TranscriptionCueValue],
        speakerNames: [String: String]
    ) -> String {
        guard let label = speakerLabel(for: cue, original: original, speakerNames: speakerNames) else {
            return cue.text
        }
        return "\(label): \(cue.text)"
    }

    private static func speakerLabel(
        for translation: TranslatedSubtitleCueValue,
        original: [TranscriptionCueValue],
        speakerNames: [String: String]
    ) -> String? {
        let ids = original
            .filter { $0.index >= translation.sourceStartIndex && $0.index <= translation.sourceEndIndex }
            .compactMap(\.speakerID)
            .reduce(into: [String]()) { result, id in
                if !result.contains(id) { result.append(id) }
            }
        guard !ids.isEmpty else { return nil }
        return ids.map { speakerNames[$0] ?? SpeakerLabelFormatter.displayName(for: $0) }
            .joined(separator: " + ")
    }

    private static func vttTimestamp(_ value: TimeInterval) -> String {
        let milliseconds = max(0, Int((value * 1_000).rounded()))
        return String(format: "%02d:%02d:%02d.%03d", milliseconds / 3_600_000, (milliseconds / 60_000) % 60, (milliseconds / 1_000) % 60, milliseconds % 1_000)
    }

    private static func displayTimestamp(_ value: TimeInterval) -> String {
        let seconds = max(0, Int(value.rounded(.down)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
