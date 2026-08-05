import Foundation

enum TranscriptionEngineKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case nemotron
    case appleSpeech

    var id: String { rawValue }
    var displayName: String { self == .nemotron ? "Nemotron 3.5" : "Apple Speech" }
}

enum TranscriptionLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case spanish
    case english
    case german

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: "Automático"
        case .spanish: "Español"
        case .english: "English"
        case .german: "Deutsch"
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

struct TranslatedSubtitleCueValue: Equatable, Sendable {
    let index: Int
    let startTime: TimeInterval
    let endTime: TimeInterval
    let sourceStartIndex: Int
    let sourceEndIndex: Int
    let text: String
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
        case .idle: "Modelo no cargado"
        case .checking: "Comprobando el modelo…"
        case .downloading: "Descargando el modelo…"
        case .loading: "Cargando Nemotron en memoria…"
        case .ready: "Nemotron está listo"
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
    case invalidState
    case appleSpeechUnavailable
    case translationUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied: "No se concedió acceso al micrófono."
        case .modelUnavailable(let message): message
        case .unsupportedAudio: "El archivo no contiene audio compatible."
        case .invalidState: "La operación no es válida en el estado actual."
        case .appleSpeechUnavailable: "Apple SpeechTranscriber no está disponible para este dispositivo o idioma."
        case .translationUnavailable(let message): message
        }
    }
}
