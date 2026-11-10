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
        let locale = AppLocalization.locale
        return locale.localizedString(forLanguageCode: normalizedCode(code))?
            .capitalized(with: locale) ?? code
    }
}

@MainActor
@Observable
final class TranslationAvailabilityController {
    var state: TranslationAvailabilityState = .checking
    var allSupportedTargets: [TranslationLanguageOption] = []
    var supportedTargets: [TranslationLanguageOption] = [
        .init(code: "en", displayName: TranslationPolicy.displayName(for: "en")),
        .init(code: "es", displayName: TranslationPolicy.displayName(for: "es")),
        .init(code: "de", displayName: TranslationPolicy.displayName(for: "de"))
    ]

    func refresh(settings: AppSettings) async {
        let selectedCodes = settings.translationLanguageCodes
        supportedTargets = selectedCodes.map {
            TranslationLanguageOption(code: $0, displayName: TranslationPolicy.displayName(for: $0))
        }
        if !selectedCodes.contains(where: {
            TranslationPolicy.sameLanguage($0, settings.translationTargetLanguage)
        }), let first = selectedCodes.first {
            settings.translationTargetLanguage = first
            settings.translationEnabled = false
        }
        #if targetEnvironment(simulator)
        state = .unavailable(AppLocalization.string("La traducción de Apple requiere un iPhone o iPad real."))
        #elseif canImport(Translation)
        state = .checking
        let availability = LanguageAvailability()
        let languages = await availability.supportedLanguages
        let supportedCodes = Set(languages.compactMap { language -> String? in
            guard let code = language.languageCode?.identifier else { return nil }
            return TranslationPolicy.normalizedCode(code)
        })
        allSupportedTargets = supportedCodes
            .map { TranslationLanguageOption(code: $0, displayName: TranslationPolicy.displayName(for: $0)) }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        supportedTargets = selectedCodes.compactMap { code in
            allSupportedTargets.first { TranslationPolicy.sameLanguage($0.code, code) }
        }

        let pairs = TranslationPolicy.requiredPairs(
            spokenLanguage: settings.language,
            target: settings.translationTargetLanguage
        )
        guard !pairs.isEmpty else {
            state = .unsupported(AppLocalization.string("El idioma hablado y el idioma de traducción son iguales."))
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
                state = .unsupported(AppLocalization.string("Apple Translation no admite uno de los pares seleccionados."))
                settings.translationEnabled = false
                return
            @unknown default:
                state = .failed(AppLocalization.string("iOS devolvió un estado de traducción desconocido."))
                settings.translationEnabled = false
                return
            }
        }
        state = missing.isEmpty ? .ready : .needsDownload(missing)
        #else
        state = .unavailable(AppLocalization.string("Translation no está disponible en esta plataforma."))
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
        let session = translationSession(source: source, target: target, quality: quality)
        return try await session.translate(text).targetText
        #else
        throw AppError.translationUnavailable(AppLocalization.string("La traducción requiere un dispositivo real."))
        #endif
    }

    func translateBatch(
        _ texts: [String],
        source: String,
        target: String,
        quality: Quality = .lowLatency
    ) async -> [Int: String] {
        guard !TranslationPolicy.sameLanguage(source, target) else {
            return Dictionary(uniqueKeysWithValues: texts.enumerated().map { ($0.offset, $0.element) })
        }
        #if canImport(Translation) && !targetEnvironment(simulator)
        let session = translationSession(source: source, target: target, quality: quality)
        let requests = texts.enumerated().compactMap { index, text -> TranslationSession.Request? in
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return .init(sourceText: text, clientIdentifier: String(index))
        }
        guard !requests.isEmpty else { return [:] }
        var translated: [Int: String] = [:]
        do {
            for try await response in session.translate(batch: requests) {
                guard let identifier = response.clientIdentifier, let index = Int(identifier) else { continue }
                translated[index] = response.targetText
            }
        } catch {
            // Preserve any completed responses. The caller retries only the
            // missing groups, retaining the previous partial-success behavior.
        }
        return translated
        #else
        return [:]
        #endif
    }

    #if canImport(Translation) && !targetEnvironment(simulator)
    private func translationSession(
        source: String,
        target: String,
        quality: Quality
    ) -> TranslationSession {
        let pair = TranslationPair(
            source: TranslationPolicy.normalizedCode(source),
            target: TranslationPolicy.normalizedCode(target)
        )
        let cacheKey = TranslationSessionKey(pair: pair, quality: quality)
        if let cached = sessions[cacheKey] { return cached }

        let session: TranslationSession
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
        return session
    }
    #endif

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
        maximumPhrases: Int = 4,
        maximumWords: Int = 55,
        maximumCharacters: Int = 360,
        maximumDuration: TimeInterval = 20
    ) -> [[TranscriptionCueValue]] {
        guard maximumPhrases > 0 else { return [] }
        let ordered = cues.sorted { $0.index < $1.index }
        var result: [[TranscriptionCueValue]] = []
        var current: [TranscriptionCueValue] = []
        func words(_ values: [TranscriptionCueValue]) -> Int { values.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count } }
        func characters(_ values: [TranscriptionCueValue]) -> Int { values.reduce(0) { $0 + $1.text.count } }
        func duration(_ values: [TranscriptionCueValue]) -> TimeInterval { guard let first = values.first, let last = values.last else { return 0 }; return max(0, last.endTime - first.startTime) }
        func endsSentence(_ value: TranscriptionCueValue) -> Bool { value.text.trimmingCharacters(in: .whitespacesAndNewlines).last.map { ".?!".contains($0) } ?? false }
        for cue in ordered {
            let candidate = current + [cue]
            if !current.isEmpty && (candidate.count > maximumPhrases || words(candidate) > maximumWords || characters(candidate) > maximumCharacters || duration(candidate) > maximumDuration) {
                result.append(current); current = [cue]
            } else { current.append(cue) }
            if current.count >= 2 && words(current) >= 18 && endsSentence(cue) { result.append(current); current = [] }
        }
        if !current.isEmpty { result.append(current) }
        return result
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
