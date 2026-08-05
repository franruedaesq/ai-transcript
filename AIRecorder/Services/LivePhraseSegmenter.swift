import Foundation

struct LivePhraseSegmenter: Sendable {
    private(set) var committedWordCount = 0
    private var previousWords: [String] = []

    mutating func consume(_ partial: String) -> [String] {
        let words = Self.words(in: partial)
        defer { previousWords = words }
        guard words.count > committedWordCount else { return [] }

        let stableCount = Self.commonPrefixCount(previousWords, words)
        guard stableCount > committedWordCount else { return [] }

        var phrases: [String] = []
        while committedWordCount < stableCount {
            let stable = Array(words[committedWordCount..<stableCount])
            let punctuationEnd = stable.firstIndex(where: Self.endsPhrase).map { $0 + 1 }
            let length = punctuationEnd ?? (stable.count >= 14 ? 14 : 0)
            guard length > 0 else { break }
            phrases.append(stable.prefix(length).joined(separator: " "))
            committedWordCount += length
        }
        return phrases
    }

    func provisional(from partial: String) -> String {
        let words = Self.words(in: partial)
        guard committedWordCount < words.count else { return "" }
        return words.dropFirst(committedWordCount).joined(separator: " ")
    }

    mutating func reset() {
        committedWordCount = 0
        previousWords = []
    }

    private static func words(in text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func commonPrefixCount(_ lhs: [String], _ rhs: [String]) -> Int {
        var index = 0
        while index < min(lhs.count, rhs.count), lhs[index] == rhs[index] { index += 1 }
        return index
    }

    private static func endsPhrase(_ word: String) -> Bool {
        word.last.map { ".?!".contains($0) } ?? false
    }
}
