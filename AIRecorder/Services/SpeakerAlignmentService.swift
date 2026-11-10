import Foundation
import SwiftData

struct SpeakerAlignedCue: Equatable, Sendable {
    let sourceIndex: Int
    let value: TranscriptionCueValue
}

struct SpeakerAlignmentResult: Sendable {
    let cues: [SpeakerAlignedCue]
    let sourceIndexRanges: [Int: ClosedRange<Int>]
}

enum SpeakerAlignmentService {
    private struct WordPlacement {
        let text: String
        let startTime: TimeInterval
        let endTime: TimeInterval
        var speakerID: String?
    }

    static func align(
        cues: [TranscriptionCueValue],
        tokens: [AppTokenTiming],
        turns: [SpeakerTurnValue]
    ) -> SpeakerAlignmentResult {
        let timedWords = CueBuilder.timedWords(from: tokens)
        var aligned: [SpeakerAlignedCue] = []
        var sourceRanges: [Int: ClosedRange<Int>] = [:]

        for cue in cues.sorted(by: { $0.index < $1.index }) {
            let firstIndex = aligned.count
            let pieces = split(cue: cue, timedWords: timedWords, turns: turns)
            aligned.append(contentsOf: pieces.map { .init(sourceIndex: cue.index, value: $0) })
            if aligned.count > firstIndex {
                sourceRanges[cue.index] = firstIndex...(aligned.count - 1)
            }
        }

        let normalized = aligned.enumerated().map { index, cue in
            SpeakerAlignedCue(
                sourceIndex: cue.sourceIndex,
                value: .init(
                    index: index,
                    startTime: cue.value.startTime,
                    endTime: cue.value.endTime,
                    text: cue.value.text,
                    confidence: cue.value.confidence,
                    speakerID: cue.value.speakerID
                )
            )
        }
        return .init(cues: normalized, sourceIndexRanges: sourceRanges)
    }

    static func bestSpeakerID(
        startTime: TimeInterval,
        endTime: TimeInterval,
        turns: [SpeakerTurnValue]
    ) -> String? {
        let duration = max(0.08, endTime - startTime)
        let overlapping = turns.compactMap { turn -> (String, TimeInterval, Float)? in
            let overlap = max(0, min(endTime, turn.endTime) - max(startTime, turn.startTime))
            return overlap > 0 ? (turn.speakerID, overlap, turn.confidence) : nil
        }
        guard !overlapping.isEmpty else { return nil }

        let grouped = Dictionary(grouping: overlapping, by: \.0).mapValues { entries in
            let total = entries.reduce(0) { $0 + $1.1 }
            let quality = entries.reduce(0) { $0 + Float($1.1) * $1.2 } / Float(max(0.001, total))
            return (overlap: total, quality: quality)
        }
        guard let best = grouped.max(by: {
            if abs($0.value.overlap - $1.value.overlap) < 0.01 {
                return $0.value.quality < $1.value.quality
            }
            return $0.value.overlap < $1.value.overlap
        }) else { return nil }

        let coverage = best.value.overlap / duration
        guard best.value.overlap >= 0.08, coverage >= 0.2, best.value.quality >= 0.15 else {
            return nil
        }
        return best.key
    }

    private static func split(
        cue: TranscriptionCueValue,
        timedWords: [CueBuilder.TimedWord],
        turns: [SpeakerTurnValue]
    ) -> [TranscriptionCueValue] {
        let textWords = cue.text.split(whereSeparator: \.isWhitespace).map(String.init)
        let cueTimedWords = timedWords.filter {
            min(cue.endTime, $0.endTime) - max(cue.startTime, $0.startTime) > 0
        }
        guard textWords.count > 1, cueTimedWords.count > 1 else {
            return [cueWithSpeaker(cue, speakerID: bestSpeakerID(
                startTime: cue.startTime,
                endTime: cue.endTime,
                turns: turns
            ))]
        }

        var placements = textWords.enumerated().map { index, text in
            let timedIndex = min(
                cueTimedWords.count - 1,
                index * cueTimedWords.count / textWords.count
            )
            let timed = cueTimedWords[timedIndex]
            return WordPlacement(
                text: text,
                startTime: max(cue.startTime, timed.startTime),
                endTime: min(cue.endTime, max(timed.startTime + 0.08, timed.endTime)),
                speakerID: bestSpeakerID(
                    startTime: timed.startTime,
                    endTime: timed.endTime,
                    turns: turns
                )
            )
        }
        smoothSpeakerAssignments(&placements)

        var result: [TranscriptionCueValue] = []
        var current: [WordPlacement] = []
        for placement in placements {
            if let currentSpeaker = current.first?.speakerID,
               currentSpeaker != placement.speakerID {
                result.append(makeCue(from: current, source: cue))
                current.removeAll(keepingCapacity: true)
            } else if !current.isEmpty, current.first?.speakerID == nil, placement.speakerID != nil {
                result.append(makeCue(from: current, source: cue))
                current.removeAll(keepingCapacity: true)
            }
            current.append(placement)
        }
        if !current.isEmpty { result.append(makeCue(from: current, source: cue)) }
        return result
    }

    private static func smoothSpeakerAssignments(_ placements: inout [WordPlacement]) {
        guard placements.count >= 3 else { return }
        for index in 1..<(placements.count - 1) {
            let previous = placements[index - 1].speakerID
            let next = placements[index + 1].speakerID
            if previous == next, previous != nil,
               placements[index].speakerID != previous,
               placements[index].endTime - placements[index].startTime < 0.4 {
                placements[index].speakerID = previous
            } else if placements[index].speakerID == nil, previous == next {
                placements[index].speakerID = previous
            }
        }
    }

    private static func cueWithSpeaker(
        _ cue: TranscriptionCueValue,
        speakerID: String?
    ) -> TranscriptionCueValue {
        .init(
            index: cue.index,
            startTime: cue.startTime,
            endTime: cue.endTime,
            text: cue.text,
            confidence: cue.confidence,
            speakerID: speakerID
        )
    }

    private static func makeCue(
        from placements: [WordPlacement],
        source: TranscriptionCueValue
    ) -> TranscriptionCueValue {
        .init(
            index: source.index,
            startTime: placements.first?.startTime ?? source.startTime,
            endTime: max(
                (placements.first?.startTime ?? source.startTime) + 0.08,
                placements.last?.endTime ?? source.endTime
            ),
            text: placements.map(\.text).joined(separator: " ").cleanedTranscriptSpacing,
            confidence: source.confidence,
            speakerID: placements.first?.speakerID
        )
    }
}

@MainActor
enum SpeakerPersistenceService {
    static func replaceDiarization(
        on recording: Recording,
        with turns: [SpeakerTurnValue],
        context: ModelContext
    ) throws {
        let existingProfiles = Dictionary(
            uniqueKeysWithValues: recording.speakerProfiles.map { ($0.speakerID, $0) }
        )
        recording.speakerTurns.forEach(context.delete)
        recording.speakerTurns.removeAll()

        for value in turns.sorted(by: { $0.startTime < $1.startTime }) {
            let turn = SpeakerTurn(value: value)
            turn.recording = recording
            recording.speakerTurns.append(turn)
        }

        let speakerIDs = Array(Set(turns.map(\.speakerID))).sorted(by: speakerSort)
        for profile in recording.speakerProfiles where !speakerIDs.contains(profile.speakerID) {
            context.delete(profile)
        }
        recording.speakerProfiles.removeAll { !speakerIDs.contains($0.speakerID) }
        for (index, speakerID) in speakerIDs.enumerated() where existingProfiles[speakerID] == nil {
            let profile = SpeakerProfile(speakerID: speakerID, colorIndex: index)
            profile.recording = recording
            recording.speakerProfiles.append(profile)
        }

        try realign(recording: recording, context: context)
    }

    static func realign(recording: Recording, context: ModelContext) throws {
        let oldCues = recording.orderedCues
        let alignment = SpeakerAlignmentService.align(
            cues: oldCues.map(\.value),
            tokens: recording.orderedTokens.map(\.value),
            turns: recording.orderedSpeakerTurns.map(\.value)
        )
        let legacyTranslations = Dictionary(
            uniqueKeysWithValues: oldCues.compactMap { cue in
                cue.translatedText.map { (cue.index, $0) }
            }
        )

        oldCues.forEach(context.delete)
        recording.cues.removeAll()
        for aligned in alignment.cues {
            let cue = TranscriptCue(value: aligned.value)
            cue.recording = recording
            recording.cues.append(cue)
        }
        recording.transcript = recording.orderedCues.map(\.text).joined(separator: " ").cleanedTranscriptSpacing

        if recording.translatedCues.isEmpty, !legacyTranslations.isEmpty {
            for (oldIndex, text) in legacyTranslations.sorted(by: { $0.key < $1.key }) {
                guard let range = alignment.sourceIndexRanges[oldIndex],
                      let first = recording.cues.first(where: { $0.index == range.lowerBound }),
                      let last = recording.cues.first(where: { $0.index == range.upperBound })
                else { continue }
                let translated = TranslatedSubtitleCue(value: .init(
                    index: recording.translatedCues.count,
                    startTime: first.startTime,
                    endTime: last.endTime,
                    sourceStartIndex: range.lowerBound,
                    sourceEndIndex: range.upperBound,
                    text: text
                ))
                translated.recording = recording
                recording.translatedCues.append(translated)
            }
        } else {
            for translated in recording.translatedCues {
                guard let startRange = alignment.sourceIndexRanges[translated.sourceStartIndex],
                      let endRange = alignment.sourceIndexRanges[translated.sourceEndIndex]
                else { continue }
                translated.sourceStartIndex = startRange.lowerBound
                translated.sourceEndIndex = endRange.upperBound
                translated.startTime = recording.cues.first(where: { $0.index == startRange.lowerBound })?.startTime ?? translated.startTime
                translated.endTime = recording.cues.first(where: { $0.index == endRange.upperBound })?.endTime ?? translated.endTime
            }
        }

        try context.save()
        try RecordingRecoveryStore.write(.init(recording: recording))
    }

    static func rename(
        profile: SpeakerProfile,
        to name: String,
        recording: Recording,
        context: ModelContext
    ) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.name = trimmed.isEmpty ? nil : trimmed
        try context.save()
        try RecordingRecoveryStore.write(.init(recording: recording))
    }

    static func saveNames(
        _ names: [UUID: String],
        recording: Recording,
        context: ModelContext
    ) throws {
        for profile in recording.speakerProfiles {
            guard let name = names[profile.id] else { continue }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            profile.name = trimmed.isEmpty ? nil : trimmed
        }
        try context.save()
        try RecordingRecoveryStore.write(.init(recording: recording))
    }

    static func merge(
        source: SpeakerProfile,
        into target: SpeakerProfile,
        recording: Recording,
        context: ModelContext
    ) throws {
        guard source.id != target.id else { return }
        for turn in recording.speakerTurns where turn.speakerID == source.speakerID {
            turn.speakerID = target.speakerID
        }
        context.delete(source)
        recording.speakerProfiles.removeAll { $0.id == source.id }
        try realign(recording: recording, context: context)
    }

    static func reassign(
        turn: SpeakerTurn,
        to profile: SpeakerProfile,
        recording: Recording,
        context: ModelContext
    ) throws {
        turn.speakerID = profile.speakerID
        try realign(recording: recording, context: context)
    }

    private static func speakerSort(_ lhs: String, _ rhs: String) -> Bool {
        let left = Int(lhs.drop(while: { !$0.isNumber })) ?? Int.max
        let right = Int(rhs.drop(while: { !$0.isNumber })) ?? Int.max
        return left == right ? lhs < rhs : left < right
    }
}
