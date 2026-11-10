import Foundation
import NaturalLanguage

enum SpokenLanguageResolver {
    static func canonicalCode(_ rawValue: String) -> String? {
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalized == "english" || normalized.hasPrefix("en-") || normalized == "en" {
            return "en"
        }
        if normalized == "spanish" || normalized == "español"
            || normalized.hasPrefix("es-") || normalized == "es"
        {
            return "es"
        }
        if normalized == "german" || normalized == "deutsch" || normalized == "alemán"
            || normalized.hasPrefix("de-") || normalized == "de"
        {
            return "de"
        }
        return nil
    }

    static func detect(in text: String, minimumConfidence: Double = 0.55) -> String? {
        // A few thousand characters are enough for language recognition. Keeping
        // the sample bounded prevents long transcripts from stalling a view render.
        let sample = String(text.prefix(4_096))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard sample.count >= 8, sample.split(whereSeparator: \.isWhitespace).count >= 2 else {
            return nil
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.languageHints = [.english: 0.34, .spanish: 0.33, .german: 0.33]
        recognizer.processString(sample)
        let candidates = recognizer.languageHypotheses(withMaximum: 2)
        let supported = candidates
            .filter { $0.key == .english || $0.key == .spanish || $0.key == .german }
            .max { $0.value < $1.value }
        guard let supported, supported.value >= minimumConfidence else { return nil }
        switch supported.key {
        case .english: return "en"
        case .spanish: return "es"
        case .german: return "de"
        default: return nil
        }
    }
}

struct StableSpokenLanguageDetector: Sendable {
    private var candidate: String?
    private var matchingObservations = 0
    private(set) var resolved: String?
    let requiredMatches: Int

    init(requiredMatches: Int = 3) { self.requiredMatches = max(1, requiredMatches) }

    mutating func observe(_ rawValue: String?) -> String? {
        guard resolved == nil, let rawValue, let language = SpokenLanguageResolver.canonicalCode(rawValue) else { return resolved }
        if candidate == language { matchingObservations += 1 } else { candidate = language; matchingObservations = 1 }
        if matchingObservations >= requiredMatches { resolved = language }
        return resolved
    }

    mutating func reset() { candidate = nil; matchingObservations = 0; resolved = nil }
}
