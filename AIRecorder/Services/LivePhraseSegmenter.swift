import Foundation

struct LivePhraseSegmenter: Sendable {
    private(set) var committedWordCount = 0
    private var previousWords: [String] = []
    private var currentProvisional = ""
    private var lastPartial = ""

    mutating func consume(_ partial: String) -> [String] {
        update(partial).phrases
    }

    mutating func update(_ partial: String) -> LivePhraseUpdate {
        let words = Self.words(in: partial)
        guard words.count > committedWordCount else {
            return store(.init(phrases: [], provisional: ""), partial: partial, words: words)
        }

        let stableCount = Self.commonPrefixCount(previousWords, words)
        guard stableCount > committedWordCount else {
            let provisional = words.dropFirst(committedWordCount).joined(separator: " ")
            return store(.init(phrases: [], provisional: provisional), partial: partial, words: words)
        }

        var phrases: [String] = []
        while committedWordCount < stableCount {
            let stable = Array(words[committedWordCount..<stableCount])
            let punctuationEnd = stable.firstIndex(where: Self.endsPhrase).map { $0 + 1 }
            let length = punctuationEnd ?? (stable.count >= 14 ? 14 : 0)
            guard length > 0 else { break }
            phrases.append(stable.prefix(length).joined(separator: " "))
            committedWordCount += length
        }
        let provisional = committedWordCount < words.count
            ? words.dropFirst(committedWordCount).joined(separator: " ")
            : ""
        return store(.init(phrases: phrases, provisional: provisional), partial: partial, words: words)
    }

    func provisional(from partial: String) -> String {
        guard partial != lastPartial else { return currentProvisional }
        let words = Self.words(in: partial)
        guard committedWordCount < words.count else { return "" }
        return words.dropFirst(committedWordCount).joined(separator: " ")
    }

    mutating func reset() {
        committedWordCount = 0
        previousWords = []
        currentProvisional = ""
        lastPartial = ""
    }

    private mutating func store(
        _ update: LivePhraseUpdate,
        partial: String,
        words: [String]
    ) -> LivePhraseUpdate {
        previousWords = words
        lastPartial = partial
        currentProvisional = update.provisional
        return update
    }

    private static func words(in text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func commonPrefixCount(_ lhs: [String], _ rhs: [String]) -> Int {
        var index = 0
        while index < min(lhs.count, rhs.count), normalized(lhs[index]) == normalized(rhs[index]) { index += 1 }
        return index
    }

    private static func normalized(_ word: String) -> String {
        word
            .trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
            .lowercased()
    }

    private static func endsPhrase(_ word: String) -> Bool {
        word.last.map { ".?!".contains($0) } ?? false
    }
}

struct LivePhraseUpdate: Equatable, Sendable {
    let phrases: [String]
    let provisional: String
}
