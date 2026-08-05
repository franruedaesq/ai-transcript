import Foundation
import Observation

@MainActor
@Observable
final class AppSettings {
    private enum Keys {
        static let engine = "transcription.engine"
        static let language = "transcription.language"
        static let nemotronPrepared = "model.nemotronPrepared"
        static let translationEnabled = "translation.enabled"
        static let translationTarget = "translation.target"
    }

    var engine: TranscriptionEngineKind {
        didSet {
            UserDefaults.standard.set(engine.rawValue, forKey: Keys.engine)
            if engine == .appleSpeech, language == .automatic {
                language = Locale.current.language.languageCode?.identifier == "en" ? .english : .spanish
            }
        }
    }
    var language: TranscriptionLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: Keys.language) }
    }
    var nemotronPrepared: Bool {
        didSet { UserDefaults.standard.set(nemotronPrepared, forKey: Keys.nemotronPrepared) }
    }
    var translationEnabled: Bool {
        didSet { UserDefaults.standard.set(translationEnabled, forKey: Keys.translationEnabled) }
    }
    var translationTargetLanguage: String {
        didSet { UserDefaults.standard.set(translationTargetLanguage, forKey: Keys.translationTarget) }
    }

    init() {
        engine = TranscriptionEngineKind(rawValue: UserDefaults.standard.string(forKey: Keys.engine) ?? "") ?? .nemotron
        let storedLanguage = TranscriptionLanguage(rawValue: UserDefaults.standard.string(forKey: Keys.language) ?? "") ?? .automatic
        language = storedLanguage
        nemotronPrepared = UserDefaults.standard.bool(forKey: Keys.nemotronPrepared)
        translationEnabled = UserDefaults.standard.bool(forKey: Keys.translationEnabled)
        translationTargetLanguage = UserDefaults.standard.string(forKey: Keys.translationTarget)
            ?? Self.defaultTranslationTarget(for: storedLanguage)
        if engine == .appleSpeech, language == .automatic {
            language = Locale.current.language.languageCode?.identifier == "en" ? .english : .spanish
        }
    }

    static func defaultTranslationTarget(for language: TranscriptionLanguage) -> String {
        switch language {
        case .spanish: "en"
        case .english: "es"
        case .german: "en"
        case .automatic:
            Locale.current.language.languageCode?.identifier == "en" ? "es" : "en"
        }
    }
}
