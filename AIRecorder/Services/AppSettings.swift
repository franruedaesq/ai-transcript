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
        static let translationLanguages = "translation.languages"
        static let customVocabulary = "transcription.customVocabulary"
    }

    var engine: TranscriptionEngineKind {
        didSet {
            UserDefaults.standard.set(engine.rawValue, forKey: Keys.engine)
            if engine == .appleSpeech, language == .automatic {
                language = Self.explicitSpeechLanguageForCurrentLocale()
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
    var translationLanguageCodes: [String] {
        didSet { UserDefaults.standard.set(translationLanguageCodes, forKey: Keys.translationLanguages) }
    }
    var customVocabulary: [CustomVocabularyEntry] { didSet { persistCustomVocabulary() } }

    init() {
        engine = TranscriptionEngineKind(rawValue: UserDefaults.standard.string(forKey: Keys.engine) ?? "") ?? .nemotron
        let storedLanguage = TranscriptionLanguage(rawValue: UserDefaults.standard.string(forKey: Keys.language) ?? "") ?? .automatic
        language = storedLanguage
        nemotronPrepared = UserDefaults.standard.bool(forKey: Keys.nemotronPrepared)
        translationEnabled = UserDefaults.standard.bool(forKey: Keys.translationEnabled)
        let storedTranslationTarget = UserDefaults.standard.string(forKey: Keys.translationTarget)
            ?? Self.defaultTranslationTarget(for: storedLanguage)
        translationTargetLanguage = storedTranslationTarget
        let storedTranslationLanguages = UserDefaults.standard.stringArray(forKey: Keys.translationLanguages)
            ?? ["en", "es", "de"]
        translationLanguageCodes = Self.normalizedTranslationLanguages(
            storedTranslationLanguages + [storedTranslationTarget]
        )
        if let data = UserDefaults.standard.data(forKey: Keys.customVocabulary), let value = try? JSONDecoder().decode([CustomVocabularyEntry].self, from: data) {
            customVocabulary = value
        } else { customVocabulary = [] }
        if engine == .appleSpeech, language == .automatic {
            language = Self.explicitSpeechLanguageForCurrentLocale()
        }
    }

    func addTranslationLanguage(_ code: String) {
        translationLanguageCodes = Self.normalizedTranslationLanguages(
            translationLanguageCodes + [code]
        )
    }

    func removeTranslationLanguage(_ code: String) {
        let normalized = TranslationPolicy.normalizedCode(code)
        let remaining = translationLanguageCodes.filter {
            !TranslationPolicy.sameLanguage($0, normalized)
        }
        guard !remaining.isEmpty else { return }
        translationLanguageCodes = remaining
        if TranslationPolicy.sameLanguage(translationTargetLanguage, normalized) {
            translationTargetLanguage = remaining[0]
            translationEnabled = false
        }
    }

    private static func normalizedTranslationLanguages(_ codes: [String]) -> [String] {
        var seen = Set<String>()
        return codes.compactMap { value in
            let code = TranslationPolicy.normalizedCode(value)
            guard !code.isEmpty, seen.insert(code).inserted else { return nil }
            return code
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

    private static func explicitSpeechLanguageForCurrentLocale() -> TranscriptionLanguage {
        switch Locale.current.language.languageCode?.identifier {
        case "es": .spanish
        case "de": .german
        default: .english
        }
    }

    var vocabularyHints: [String] { Array(customVocabulary.map(\.preferred).filter { !$0.isEmpty }.prefix(100)) }
    func addVocabularyEntry(preferred: String, aliases: [String]) {
        let clean = preferred.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !customVocabulary.contains(where: { $0.preferred.localizedCaseInsensitiveCompare(clean) == .orderedSame }) else { return }
        customVocabulary.append(.init(preferred: clean, aliases: aliases))
    }
    func updateVocabularyEntry(id: UUID, preferred: String, aliases: [String]) {
        guard let index = customVocabulary.firstIndex(where: { $0.id == id }) else { return }
        let clean = preferred.trimmingCharacters(in: .whitespacesAndNewlines); guard !clean.isEmpty else { return }
        customVocabulary[index] = .init(id: id, preferred: clean, aliases: aliases)
    }
    func removeVocabularyEntry(id: UUID) { customVocabulary.removeAll { $0.id == id } }
    private func persistCustomVocabulary() { guard let data = try? JSONEncoder().encode(customVocabulary) else { return }; UserDefaults.standard.set(data, forKey: Keys.customVocabulary) }
}
