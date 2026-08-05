import Foundation
import SwiftData

@Model
final class Recording {
    @Attribute(.unique) var id: UUID
    var title: String
    var createdAt: Date
    var duration: TimeInterval
    var audioRelativePath: String
    var sourceRaw: String
    var engineRaw: String
    var requestedLanguageRaw: String
    var detectedLanguage: String?
    var transcript: String
    var statusRaw: String
    var translationEnabled: Bool = false
    var translationTargetLanguage: String?
    var translationStatusRaw: String = RecordingTranslationStatus.none.rawValue
    @Relationship(deleteRule: .cascade, inverse: \TranscriptCue.recording)
    var cues: [TranscriptCue]
    @Relationship(deleteRule: .cascade, inverse: \TranslatedSubtitleCue.recording)
    var translatedCues: [TranslatedSubtitleCue]

    init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = .now,
        duration: TimeInterval = 0,
        audioRelativePath: String,
        source: RecordingSource,
        engine: TranscriptionEngineKind,
        requestedLanguage: TranscriptionLanguage,
        detectedLanguage: String? = nil,
        transcript: String = "",
        status: RecordingStatus = .recording,
        translationEnabled: Bool = false,
        translationTargetLanguage: String? = nil,
        translationStatus: RecordingTranslationStatus = .none,
        cues: [TranscriptCue] = [],
        translatedCues: [TranslatedSubtitleCue] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.duration = duration
        self.audioRelativePath = audioRelativePath
        self.sourceRaw = source.rawValue
        self.engineRaw = engine.rawValue
        self.requestedLanguageRaw = requestedLanguage.rawValue
        self.detectedLanguage = detectedLanguage
        self.transcript = transcript
        self.statusRaw = status.rawValue
        self.translationEnabled = translationEnabled
        self.translationTargetLanguage = translationTargetLanguage
        self.translationStatusRaw = translationStatus.rawValue
        self.cues = cues
        self.translatedCues = translatedCues
    }

    var source: RecordingSource { RecordingSource(rawValue: sourceRaw) ?? .microphone }
    var engine: TranscriptionEngineKind { TranscriptionEngineKind(rawValue: engineRaw) ?? .nemotron }
    var requestedLanguage: TranscriptionLanguage { TranscriptionLanguage(rawValue: requestedLanguageRaw) ?? .automatic }
    var status: RecordingStatus {
        get { RecordingStatus(rawValue: statusRaw) ?? .failed }
        set { statusRaw = newValue.rawValue }
    }
    var translationStatus: RecordingTranslationStatus {
        get { RecordingTranslationStatus(rawValue: translationStatusRaw) ?? .none }
        set { translationStatusRaw = newValue.rawValue }
    }

    var orderedCues: [TranscriptCue] { cues.sorted { $0.index < $1.index } }
    var orderedTranslatedCues: [TranslatedSubtitleCue] { translatedCues.sorted { $0.index < $1.index } }
}

@Model
final class TranslatedSubtitleCue {
    @Attribute(.unique) var id: UUID
    var index: Int
    var startTime: TimeInterval
    var endTime: TimeInterval
    var sourceStartIndex: Int
    var sourceEndIndex: Int
    var text: String
    var recording: Recording?

    init(id: UUID = UUID(), value: TranslatedSubtitleCueValue) {
        self.id = id
        self.index = value.index
        self.startTime = value.startTime
        self.endTime = value.endTime
        self.sourceStartIndex = value.sourceStartIndex
        self.sourceEndIndex = value.sourceEndIndex
        self.text = value.text
    }
}

@Model
final class TranscriptCue {
    @Attribute(.unique) var id: UUID
    var index: Int
    var startTime: TimeInterval
    var endTime: TimeInterval
    var text: String
    var confidence: Float
    var translatedText: String?
    var recording: Recording?

    init(id: UUID = UUID(), value: TranscriptionCueValue, translatedText: String? = nil) {
        self.id = id
        self.index = value.index
        self.startTime = value.startTime
        self.endTime = value.endTime
        self.text = value.text
        self.confidence = value.confidence
        self.translatedText = translatedText
    }

    var value: TranscriptionCueValue {
        .init(index: index, startTime: startTime, endTime: endTime, text: text, confidence: confidence)
    }
}
