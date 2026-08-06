import Foundation
import Observation

#if canImport(Translation)
@preconcurrency import Translation
#endif

struct TranslationPair: Hashable, Sendable {
    let source: String
    let target: String
}

struct TranslationLanguageOption: Identifiable, Hashable, Sendable {
    let code: String
    let displayName: String
    var id: String { code }
}

struct LatestValueMailbox<Value: Sendable>: Sendable {
    private(set) var pending: Value?

    var isEmpty: Bool { pending == nil }

    mutating func submit(_ value: Value) {
        pending = value
    }

    mutating func take() -> Value? {
        defer { pending = nil }
        return pending
    }
}

enum TranslationAvailabilityState: Equatable, Sendable {
    case checking
    case ready
    case needsDownload([TranslationPair])
    case unsupported(String)
    case unavailable(String)
    case failed(String)

    var isReady: Bool { self == .ready }
}

enum TranslationPolicy {
    static func requiredPairs(
        spokenLanguage: TranscriptionLanguage,
        target: String
    ) -> [TranslationPair] {
        let sources: [String]
        switch spokenLanguage {
        case .automatic: sources = ["es", "en", "de"]
        case .spanish: sources = ["es"]
        case .english: sources = ["en"]
        case .german: sources = ["de"]
        }
        return sources
            .filter { !sameLanguage($0, target) }
            .map { TranslationPair(source: $0, target: normalizedCode(target)) }
    }

    static func normalizedCode(_ code: String) -> String {
        if let canonical = SpokenLanguageResolver.canonicalCode(code) { return canonical }
        return code.split(separator: "-").first.map(String.init)?.lowercased() ?? code.lowercased()
    }

    static func sameLanguage(_ lhs: String, _ rhs: String) -> Bool {
        normalizedCode(lhs) == normalizedCode(rhs)
    }

    static func displayName(for code: String) -> String {
        Locale.current.localizedString(forLanguageCode: normalizedCode(code))?
            .capitalized(with: Locale.current) ?? code
    }
}

@MainActor
@Observable
final class TranslationAvailabilityController {
    var state: TranslationAvailabilityState = .checking
    var supportedTargets: [TranslationLanguageOption] = [
        .init(code: "en", displayName: TranslationPolicy.displayName(for: "en")),
        .init(code: "es", displayName: TranslationPolicy.displayName(for: "es")),
        .init(code: "de", displayName: TranslationPolicy.displayName(for: "de"))
    ]

    func refresh(settings: AppSettings) async {
        let limitedTargetCodes = ["es", "en", "de"]
        if !limitedTargetCodes.contains(TranslationPolicy.normalizedCode(settings.translationTargetLanguage)) {
            settings.translationTargetLanguage = AppSettings.defaultTranslationTarget(for: settings.language)
        }
        #if targetEnvironment(simulator)
        state = .unavailable("La traducción de Apple requiere un iPhone o iPad real.")
        #elseif canImport(Translation)
        state = .checking
        let availability = LanguageAvailability()
        let languages = await availability.supportedLanguages
        let supportedCodes = Set(languages.compactMap { language -> String? in
            guard let code = language.languageCode?.identifier else { return nil }
            return TranslationPolicy.normalizedCode(code)
        })
        supportedTargets = limitedTargetCodes.compactMap { code in
            guard supportedCodes.contains(code) else { return nil }
            return TranslationLanguageOption(code: code, displayName: TranslationPolicy.displayName(for: code))
        }

        let pairs = TranslationPolicy.requiredPairs(
            spokenLanguage: settings.language,
            target: settings.translationTargetLanguage
        )
        guard !pairs.isEmpty else {
            state = .unsupported("El idioma hablado y el idioma de traducción son iguales.")
            settings.translationEnabled = false
            return
        }

        var missing: [TranslationPair] = []
        for pair in pairs {
            let status = await availability.status(
                from: Locale.Language(identifier: pair.source),
                to: Locale.Language(identifier: pair.target)
            )
            switch status {
            case .installed: break
            case .supported: missing.append(pair)
            case .unsupported:
                state = .unsupported("Apple Translation no admite uno de los pares seleccionados.")
                settings.translationEnabled = false
                return
            @unknown default:
                state = .failed("iOS devolvió un estado de traducción desconocido.")
                settings.translationEnabled = false
                return
            }
        }
        state = missing.isEmpty ? .ready : .needsDownload(missing)
        #else
        state = .unavailable("Translation no está disponible en esta plataforma.")
        #endif
    }
}

@MainActor
final class SubtitleTranslationController {
    #if canImport(Translation) && !targetEnvironment(simulator)
    private var sessions: [TranslationSessionKey: TranslationSession] = [:]
    #endif

    enum Quality: Sendable {
        case lowLatency
        case highFidelity
    }

    func translate(
        _ text: String,
        source: String,
        target: String,
        quality: Quality = .lowLatency
    ) async throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        guard !TranslationPolicy.sameLanguage(source, target) else { return text }
        #if canImport(Translation) && !targetEnvironment(simulator)
        let pair = TranslationPair(
            source: TranslationPolicy.normalizedCode(source),
            target: TranslationPolicy.normalizedCode(target)
        )
        let session: TranslationSession
        let cacheKey = TranslationSessionKey(pair: pair, quality: quality)
        if let cached = sessions[cacheKey] {
            session = cached
        } else {
            if #available(iOS 26.4, *) {
                session = TranslationSession(
                    installedSource: Locale.Language(identifier: pair.source),
                    target: Locale.Language(identifier: pair.target),
                    preferredStrategy: quality == .highFidelity ? .highFidelity : .lowLatency
                )
            } else {
                session = TranslationSession(
                    installedSource: Locale.Language(identifier: pair.source),
                    target: Locale.Language(identifier: pair.target)
                )
            }
            sessions[cacheKey] = session
        }
        return try await session.translate(text).targetText
        #else
        throw AppError.translationUnavailable("La traducción requiere un dispositivo real.")
        #endif
    }

    func reset() {
        #if canImport(Translation) && !targetEnvironment(simulator)
        if #available(iOS 26.0, *) { sessions.values.forEach { $0.cancel() } }
        sessions.removeAll()
        #endif
    }
}

private struct TranslationSessionKey: Hashable {
    let pair: TranslationPair
    let qualityName: String

    init(pair: TranslationPair, quality: SubtitleTranslationController.Quality) {
        self.pair = pair
        qualityName = quality == .highFidelity ? "highFidelity" : "lowLatency"
    }
}

enum ContextualTranslationGrouper {
    static func groups(
        from cues: [TranscriptionCueValue],
        maximumPhrases: Int = 2
    ) -> [[TranscriptionCueValue]] {
        guard maximumPhrases > 0 else { return [] }
        let ordered = cues.sorted { $0.index < $1.index }
        return stride(from: 0, to: ordered.count, by: maximumPhrases).map { start in
            Array(ordered[start..<min(start + maximumPhrases, ordered.count)])
        }
    }

    static func value(
        for group: [TranscriptionCueValue],
        translatedText: String,
        index: Int
    ) -> TranslatedSubtitleCueValue? {
        guard let first = group.first, let last = group.last else { return nil }
        return .init(
            index: index,
            startTime: first.startTime,
            endTime: last.endTime,
            sourceStartIndex: first.index,
            sourceEndIndex: last.index,
            text: translatedText
        )
    }
}

private extension Array {
    func uniqued<Key: Hashable>(by keyPath: KeyPath<Element, Key>) -> [Element] {
        var seen = Set<Key>()
        return filter { seen.insert($0[keyPath: keyPath]).inserted }
    }
}
