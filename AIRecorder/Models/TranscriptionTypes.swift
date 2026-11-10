import Foundation

enum TranscriptionEngineKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case nemotron
    case appleSpeech

    var id: String { rawValue }
    var displayName: String {
        AppLocalization.string(self == .nemotron ? "Nemotron 3.5" : "Apple Speech")
    }
}

enum TranscriptionLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case spanish
    case english
    case german

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: AppLocalization.string("Automático")
        case .spanish: AppLocalization.string("Español")
        case .english: AppLocalization.string("Inglés")
        case .german: AppLocalization.string("Alemán")
        }
    }

    var nemotronCode: String {
        switch self {
        case .automatic: "auto"
        case .spanish: "es-ES"
        case .english: "en-US"
        case .german: "de-DE"
        }
    }

    var translationSourceCode: String? {
        switch self {
        case .automatic: nil
        case .spanish: "es"
        case .english: "en"
        case .german: "de"
        }
    }

    var locale: Locale {
        switch self {
        case .automatic: Locale.current.language.languageCode?.identifier == "en" ? Locale(identifier: "en-US") : Locale(identifier: "es-ES")
        case .spanish: Locale(identifier: "es-ES")
        case .english: Locale(identifier: "en-US")
        case .german: Locale(identifier: "de-DE")
        }
    }
}

enum RecordingSource: String, Codable, Sendable {
    case microphone
    case imported
}

enum RecordingStatus: String, Codable, Sendable {
    case recording
    case paused
    case processing
    case saved
    case interrupted
    case failed
}

enum RecordingTranslationStatus: String, Codable, Sendable {
    case none
    case complete
    case partial
    case failed
}

enum SubtitleTranslationState: String, Codable, Sendable {
    case waiting
    case translating
    case provisional
    case final
    case failed
}

struct LiveTranslationBlock: Identifiable, Equatable, Sendable {
    let id: UUID
    var sourceText: String
    var translatedText: String?
    var state: SubtitleTranslationState
    var generation: Int
    var startTime: TimeInterval?
    var endTime: TimeInterval?

    init(
        id: UUID = UUID(),
        sourceText: String,
        translatedText: String? = nil,
        state: SubtitleTranslationState = .waiting,
        generation: Int = 0,
        startTime: TimeInterval? = nil,
        endTime: TimeInterval? = nil
    ) {
        self.id = id
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.state = state
        self.generation = generation
        self.startTime = startTime
        self.endTime = endTime
    }
}

struct LiveTranscriptBlock: Identifiable, Equatable, Sendable {
    let id: UUID
    let text: String

    init(id: UUID = UUID(), text: String) {
        self.id = id
        self.text = text
    }
}

struct TranslatedSubtitleCueValue: Codable, Equatable, Sendable {
    let index: Int
    let startTime: TimeInterval
    let endTime: TimeInterval
    let sourceStartIndex: Int
    let sourceEndIndex: Int
    let text: String
    let needsRetranslation: Bool

    init(index: Int, startTime: TimeInterval, endTime: TimeInterval, sourceStartIndex: Int, sourceEndIndex: Int, text: String, needsRetranslation: Bool = false) {
        self.index = index; self.startTime = startTime; self.endTime = endTime
        self.sourceStartIndex = sourceStartIndex; self.sourceEndIndex = sourceEndIndex
        self.text = text; self.needsRetranslation = needsRetranslation
    }

    private enum CodingKeys: String, CodingKey { case index, startTime, endTime, sourceStartIndex, sourceEndIndex, text, needsRetranslation }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        index = try values.decode(Int.self, forKey: .index)
        startTime = try values.decode(TimeInterval.self, forKey: .startTime)
        endTime = try values.decode(TimeInterval.self, forKey: .endTime)
        sourceStartIndex = try values.decode(Int.self, forKey: .sourceStartIndex)
        sourceEndIndex = try values.decode(Int.self, forKey: .sourceEndIndex)
        text = try values.decode(String.self, forKey: .text)
        needsRetranslation = try values.decodeIfPresent(Bool.self, forKey: .needsRetranslation) ?? false
    }
}

struct RecordingMarkerValue: Codable, Hashable, Sendable { let id: UUID; let time: TimeInterval; let title: String; let createdAt: Date }

struct CustomVocabularyEntry: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var preferred: String
    var aliases: [String]
    init(id: UUID = UUID(), preferred: String, aliases: [String] = []) {
        self.id = id
        self.preferred = preferred.trimmingCharacters(in: .whitespacesAndNewlines)
        self.aliases = aliases.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

enum RecordingSessionState: Equatable, Sendable {
    case idle
    case preparing
    case recording
    case paused
    case finalizing
    case failed(String)
}

enum ModelPreparationState: Equatable, Sendable {
    case idle
    case checking
    case downloading(Double)
    case loading
    case ready
    case failed(String)

    var progress: Double? {
        if case .downloading(let value) = self { return value }
        return nil
    }

    var isBusy: Bool {
        switch self {
        case .checking, .downloading, .loading: true
        default: false
        }
    }

    var label: String {
        switch self {
        case .idle: AppLocalization.string("Modelo no cargado")
        case .checking: AppLocalization.string("Comprobando el modelo…")
        case .downloading: AppLocalization.string("Descargando el modelo…")
        case .loading: AppLocalization.string("Cargando Nemotron en memoria…")
        case .ready: AppLocalization.string("Nemotron está listo")
        case .failed(let message): message
        }
    }
}

struct AppTokenTiming: Codable, Hashable, Sendable {
    let token: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let confidence: Float
}

struct TranscriptionCueValue: Codable, Hashable, Sendable {
    let index: Int
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
    let confidence: Float
    let speakerID: String?

    init(index: Int, startTime: TimeInterval, endTime: TimeInterval, text: String, confidence: Float, speakerID: String? = nil) {
        self.index = index
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.confidence = confidence
        self.speakerID = speakerID
    }
}

struct TranscriptionResult: Sendable {
    let text: String
    let detectedLanguage: String?
    let tokens: [AppTokenTiming]
    let cues: [TranscriptionCueValue]
}

enum TranscriptionEvent: Sendable {
    case preparing
    case modelProgress(Double, String)
    case modelState(ModelPreparationState)
    case ready
    case partial(String)
    case finalized(TranscriptionCueValue)
    case languageDetected(String)
    case failed(String)
}

enum AppError: LocalizedError, Sendable {
    case microphonePermissionDenied
    case modelUnavailable(String)
    case unsupportedAudio
    case recordingAudioUnavailable
    case invalidState
    case appleSpeechUnavailable
    case translationUnavailable(String)
    case transcriptionBacklog

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied: AppLocalization.string("No se concedió acceso al micrófono.")
        case .modelUnavailable(let message): message
        case .unsupportedAudio: AppLocalization.string("El archivo no contiene audio compatible.")
        case .recordingAudioUnavailable: AppLocalization.string("El audio de esta grabación no se puede abrir. La transcripción sigue disponible.")
        case .invalidState: AppLocalization.string("La operación no es válida en el estado actual.")
        case .appleSpeechUnavailable: AppLocalization.string("Apple SpeechTranscriber no está disponible para este dispositivo o idioma.")
        case .translationUnavailable(let message): message
        case .transcriptionBacklog: AppLocalization.string("La transcripción en vivo no pudo seguir el ritmo del audio. El audio original se conserva y se verificará al finalizar.")
        }
    }
}
