import Foundation

enum CueBuilder {
    static func build(from tokens: [AppTokenTiming]) -> [TranscriptionCueValue] {
        let words = timedWords(from: tokens)
        guard !words.isEmpty else { return [] }

        var result: [TranscriptionCueValue] = []
        var current: [TimedWord] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let previousEnd = result.last?.endTime ?? 0
            let start = max(previousEnd, first.startTime)
            let end = max(start + 0.08, last.endTime)
            result.append(.init(
                index: result.count,
                startTime: start,
                endTime: end,
                text: current.map(\.text).joined(separator: " ").cleanedTranscriptSpacing,
                confidence: current.map(\.confidence).reduce(0, +) / Float(current.count)
            ))
            current.removeAll(keepingCapacity: true)
        }

        for word in words {
            current.append(word)
            let duration = (current.last?.endTime ?? 0) - (current.first?.startTime ?? 0)
            if word.text.last.map({ ".?!".contains($0) }) == true || current.count >= 14 || duration >= 8 {
                flush()
            }
        }
        flush()
        return result
    }

    static func normalized(_ cues: [TranscriptionCueValue]) -> [TranscriptionCueValue] {
        var lastEnd: TimeInterval = 0
        return cues.sorted { $0.startTime < $1.startTime }.enumerated().map { index, cue in
            let start = max(lastEnd, cue.startTime)
            let end = max(start + 0.08, cue.endTime)
            lastEnd = end
            return .init(index: index, startTime: start, endTime: end, text: cue.text, confidence: cue.confidence)
        }
    }

    struct TimedWord: Equatable, Sendable {
        var text: String
        var startTime: TimeInterval
        var endTime: TimeInterval
        var confidence: Float
        var tokenCount: Int
    }

    static func timedWords(from tokens: [AppTokenTiming]) -> [TimedWord] {
        var words: [TimedWord] = []
        var hasPendingWordBoundary = false
        for token in tokens where !token.token.isEmpty {
            let raw = token.token
            let beginsWord = raw.hasPrefix("▁") || raw.hasPrefix(" ")
            let cleaned = raw.replacingOccurrences(of: "▁", with: " ").trimmingCharacters(in: .whitespaces)
            guard !cleaned.isEmpty else {
                // Nemotron can emit the SentencePiece boundary as its own
                // token. Preserve it so the following sub-token starts a new
                // word instead of being appended to the previous one.
                if beginsWord { hasPendingWordBoundary = true }
                continue
            }
            if beginsWord || hasPendingWordBoundary || words.isEmpty {
                words.append(.init(text: cleaned, startTime: token.startTime, endTime: token.endTime, confidence: token.confidence, tokenCount: 1))
            } else {
                var last = words.removeLast()
                if cleaned.first.map({ $0.isPunctuation }) == true {
                    last.text += cleaned
                } else {
                    last.text += cleaned
                }
                last.endTime = max(last.endTime, token.endTime)
                last.confidence = ((last.confidence * Float(last.tokenCount)) + token.confidence) / Float(last.tokenCount + 1)
                last.tokenCount += 1
                words.append(last)
            }
            hasPendingWordBoundary = false
        }
        return words
    }
}

extension String {
    var cleanedTranscriptSpacing: String {
        replacingOccurrences(of: " ,", with: ",")
            .replacingOccurrences(of: " .", with: ".")
            .replacingOccurrences(of: " ?", with: "?")
            .replacingOccurrences(of: " !", with: "!")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
