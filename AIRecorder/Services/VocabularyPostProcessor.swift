import Foundation

enum VocabularyPostProcessor {
    static func apply(_ text: String, entries: [CustomVocabularyEntry]) -> String {
        guard !text.isEmpty, !entries.isEmpty else { return text }
        let replacements = entries.flatMap { entry in entry.aliases.map { (alias: $0, preferred: entry.preferred) } }
            .filter { !$0.alias.isEmpty && !$0.preferred.isEmpty }
            .sorted { $0.alias.count > $1.alias.count }
        return replacements.reduce(text) { result, replacement in
            let pattern = "(?<![\\p{L}\\p{N}])\(NSRegularExpression.escapedPattern(for: replacement.alias))(?![\\p{L}\\p{N}])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return result }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            return regex.stringByReplacingMatches(in: result, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: replacement.preferred))
        }
    }
    static func apply(to cue: TranscriptionCueValue, entries: [CustomVocabularyEntry]) -> TranscriptionCueValue {
        .init(index: cue.index, startTime: cue.startTime, endTime: cue.endTime, text: apply(cue.text, entries: entries), confidence: cue.confidence, speakerID: cue.speakerID)
    }
    static func apply(to result: TranscriptionResult, entries: [CustomVocabularyEntry]) -> TranscriptionResult {
        let cues = result.cues.map { apply(to: $0, entries: entries) }
        let text = cues.isEmpty ? apply(result.text, entries: entries) : cues.map(\.text).joined(separator: " ").cleanedTranscriptSpacing
        return .init(text: text, detectedLanguage: result.detectedLanguage, tokens: result.tokens, cues: cues)
    }
}
