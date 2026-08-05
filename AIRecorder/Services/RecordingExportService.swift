import Foundation

enum RecordingExportKind: String, CaseIterable, Identifiable, Sendable {
    case audio
    case transcriptText
    case transcriptSRT
    case translationText
    case translationSRT
    case bilingualText
    case bilingualSRT

    var id: String { rawValue }

    var title: String {
        switch self {
        case .audio: "Audio original"
        case .transcriptText: "Transcripción · TXT"
        case .transcriptSRT: "Transcripción · SRT"
        case .translationText: "Traducción · TXT"
        case .translationSRT: "Traducción · SRT"
        case .bilingualText: "Original + traducción · TXT"
        case .bilingualSRT: "Original + traducción · SRT"
        }
    }
}

struct RecordingExportSnapshot: Sendable {
    let title: String
    let audioRelativePath: String
    let transcript: String
    let originalCues: [TranscriptionCueValue]
    let translatedCues: [TranslatedSubtitleCueValue]

    @MainActor
    init(recording: Recording) {
        title = recording.title
        audioRelativePath = recording.audioRelativePath
        transcript = recording.transcript
        originalCues = recording.orderedCues.map(\.value)
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
            translatedCues = recording.orderedTranslatedCues.map {
                .init(
                    index: $0.index,
                    startTime: $0.startTime,
                    endTime: $0.endTime,
                    sourceStartIndex: $0.sourceStartIndex,
                    sourceEndIndex: $0.sourceEndIndex,
                    text: $0.text
                )
            }
        }
    }

    var translationText: String {
        translatedCues.map(\.text).joined(separator: "\n\n")
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
            let source = try await StorageService.shared.resolve(relativePath: snapshot.audioRelativePath)
            let ext = source.pathExtension.isEmpty ? "m4a" : source.pathExtension
            let destination = directory.appendingPathComponent("\(baseName).\(ext)")
            try Self.replaceItem(at: destination, withCopyOf: source)
            return destination
        case .transcriptText:
            return try Self.write(snapshot.transcript, named: "\(baseName)-transcripcion.txt", in: directory)
        case .transcriptSRT:
            return try Self.write(
                SubtitleExporter.srt(original: snapshot.originalCues),
                named: "\(baseName)-transcripcion.srt",
                in: directory
            )
        case .translationText:
            return try Self.write(snapshot.translationText, named: "\(baseName)-traduccion.txt", in: directory)
        case .translationSRT:
            return try Self.write(
                SubtitleExporter.srt(translated: snapshot.translatedCues),
                named: "\(baseName)-traduccion.srt",
                in: directory
            )
        case .bilingualText:
            return try Self.write(
                SubtitleExporter.bilingualText(
                    original: snapshot.originalCues,
                    translated: snapshot.translatedCues
                ),
                named: "\(baseName)-bilingue.txt",
                in: directory
            )
        case .bilingualSRT:
            return try Self.write(
                SubtitleExporter.bilingualSRT(
                    original: snapshot.originalCues,
                    translated: snapshot.translatedCues
                ),
                named: "\(baseName)-bilingue.srt",
                in: directory
            )
        }
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

enum SubtitleExporter {
    static func srt(original cues: [TranscriptionCueValue]) -> String {
        cues.sorted { $0.index < $1.index }.enumerated().map { offset, cue in
            entry(index: offset + 1, start: cue.startTime, end: cue.endTime, text: cue.text)
        }.joined(separator: "\n\n")
    }

    static func srt(translated cues: [TranslatedSubtitleCueValue]) -> String {
        cues.sorted { $0.index < $1.index }.enumerated().map { offset, cue in
            entry(index: offset + 1, start: cue.startTime, end: cue.endTime, text: cue.text)
        }.joined(separator: "\n\n")
    }

    static func bilingualText(
        original: [TranscriptionCueValue],
        translated: [TranslatedSubtitleCueValue]
    ) -> String {
        translated.sorted { $0.index < $1.index }.map { translation in
            let source = sourceText(for: translation, original: original)
            return "[\(displayTimestamp(translation.startTime))]\n\(source)\n\(translation.text)"
        }.joined(separator: "\n\n")
    }

    static func bilingualSRT(
        original: [TranscriptionCueValue],
        translated: [TranslatedSubtitleCueValue]
    ) -> String {
        translated.sorted { $0.index < $1.index }.enumerated().map { offset, translation in
            let source = sourceText(for: translation, original: original)
            return entry(
                index: offset + 1,
                start: translation.startTime,
                end: translation.endTime,
                text: "\(source)\n\(translation.text)"
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
        "\(index)\n\(srtTimestamp(start)) --> \(srtTimestamp(max(start, end)))\n\(text)"
    }

    private static func srtTimestamp(_ value: TimeInterval) -> String {
        let milliseconds = max(0, Int((value * 1_000).rounded()))
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds / 60_000) % 60
        let seconds = (milliseconds / 1_000) % 60
        let remainder = milliseconds % 1_000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, seconds, remainder)
    }

    private static func displayTimestamp(_ value: TimeInterval) -> String {
        let seconds = max(0, Int(value.rounded(.down)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
