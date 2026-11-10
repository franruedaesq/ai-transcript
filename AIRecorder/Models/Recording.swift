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
    var expectedSpeakerCount: Int?
    @Relationship(deleteRule: .cascade, inverse: \TranscriptCue.recording)
    var cues: [TranscriptCue]
    @Relationship(deleteRule: .cascade, inverse: \TranscriptToken.recording)
    var tokens: [TranscriptToken]
    @Relationship(deleteRule: .cascade, inverse: \TranslatedSubtitleCue.recording)
    var translatedCues: [TranslatedSubtitleCue]
    @Relationship(deleteRule: .cascade, inverse: \RecordingMarker.recording)
    var markers: [RecordingMarker]
    @Relationship(deleteRule: .cascade, inverse: \SpeakerProfile.recording)
    var speakerProfiles: [SpeakerProfile]
    @Relationship(deleteRule: .cascade, inverse: \SpeakerTurn.recording)
    var speakerTurns: [SpeakerTurn]

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
        expectedSpeakerCount: Int? = nil,
        cues: [TranscriptCue] = [],
        tokens: [TranscriptToken] = [],
        translatedCues: [TranslatedSubtitleCue] = [],
        markers: [RecordingMarker] = [],
        speakerProfiles: [SpeakerProfile] = [],
        speakerTurns: [SpeakerTurn] = []
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
        self.expectedSpeakerCount = expectedSpeakerCount
        self.cues = cues
        self.tokens = tokens
        self.translatedCues = translatedCues
        self.markers = markers
        self.speakerProfiles = speakerProfiles
        self.speakerTurns = speakerTurns
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
    var orderedTokens: [TranscriptToken] { tokens.sorted { $0.index < $1.index } }
    var orderedTranslatedCues: [TranslatedSubtitleCue] { translatedCues.sorted { $0.index < $1.index } }
    var orderedMarkers: [RecordingMarker] { markers.sorted { $0.time < $1.time } }
    var orderedSpeakerProfiles: [SpeakerProfile] { speakerProfiles.sorted { $0.sortOrder < $1.sortOrder } }
    var orderedSpeakerTurns: [SpeakerTurn] { speakerTurns.sorted { $0.startTime < $1.startTime } }
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
    var needsRetranslation: Bool = false
    var recording: Recording?

    init(id: UUID = UUID(), value: TranslatedSubtitleCueValue) {
        self.id = id
        self.index = value.index
        self.startTime = value.startTime
        self.endTime = value.endTime
        self.sourceStartIndex = value.sourceStartIndex
        self.sourceEndIndex = value.sourceEndIndex
        self.text = value.text
        self.needsRetranslation = value.needsRetranslation
    }

    var value: TranslatedSubtitleCueValue {
        .init(index: index, startTime: startTime, endTime: endTime, sourceStartIndex: sourceStartIndex, sourceEndIndex: sourceEndIndex, text: text, needsRetranslation: needsRetranslation)
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
    var speakerID: String?
    var recording: Recording?

    init(id: UUID = UUID(), value: TranscriptionCueValue, translatedText: String? = nil) {
        self.id = id
        self.index = value.index
        self.startTime = value.startTime
        self.endTime = value.endTime
        self.text = value.text
        self.confidence = value.confidence
        self.translatedText = translatedText
        self.speakerID = value.speakerID
    }

    var value: TranscriptionCueValue {
        .init(index: index, startTime: startTime, endTime: endTime, text: text, confidence: confidence, speakerID: speakerID)
    }
}

@Model
final class RecordingMarker {
    @Attribute(.unique) var id: UUID
    var time: TimeInterval
    var title: String
    var createdAt: Date
    var recording: Recording?

    init(id: UUID = UUID(), time: TimeInterval, title: String, createdAt: Date = .now) {
        self.id = id
        self.time = max(0, time)
        self.title = title
        self.createdAt = createdAt
    }

    var value: RecordingMarkerValue { .init(id: id, time: time, title: title, createdAt: createdAt) }
}
