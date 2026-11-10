import XCTest
@testable import AIRecorder

final class SpeakerAlignmentTests: XCTestCase {
    func testAggregatesMultipleTurnsForTheSameSpeaker() {
        let turns = [
            SpeakerTurnValue(speakerID: "S1", startTime: 0, endTime: 2, confidence: 0.9),
            SpeakerTurnValue(speakerID: "S1", startTime: 2.1, endTime: 4, confidence: 0.8),
            SpeakerTurnValue(speakerID: "S2", startTime: 4, endTime: 5.5, confidence: 0.95)
        ]

        XCTAssertEqual(
            SpeakerAlignmentService.bestSpeakerID(startTime: 0, endTime: 6, turns: turns),
            "S1"
        )
    }

    func testSplitsCueAtSpeakerBoundaryUsingTokenTimings() {
        let cue = TranscriptionCueValue(
            index: 0,
            startTime: 0,
            endTime: 4,
            text: "Hello there Good morning",
            confidence: 0.9
        )
        let tokens = [
            AppTokenTiming(token: "▁Hello", startTime: 0, endTime: 1, confidence: 0.9),
            AppTokenTiming(token: "▁there", startTime: 1, endTime: 2, confidence: 0.9),
            AppTokenTiming(token: "▁Good", startTime: 2, endTime: 3, confidence: 0.9),
            AppTokenTiming(token: "▁morning", startTime: 3, endTime: 4, confidence: 0.9)
        ]
        let turns = [
            SpeakerTurnValue(speakerID: "S1", startTime: 0, endTime: 2, confidence: 0.9),
            SpeakerTurnValue(speakerID: "S2", startTime: 2, endTime: 4, confidence: 0.9)
        ]

        let result = SpeakerAlignmentService.align(cues: [cue], tokens: tokens, turns: turns)

        XCTAssertEqual(result.cues.map(\.value.text), ["Hello there", "Good morning"])
        XCTAssertEqual(result.cues.map(\.value.speakerID), ["S1", "S2"])
        XCTAssertEqual(result.sourceIndexRanges[0], 0...1)
    }

    func testRejectsTinyOverlapOnLongCue() {
        let turns = [
            SpeakerTurnValue(speakerID: "S1", startTime: 0, endTime: 0.1, confidence: 0.9)
        ]

        XCTAssertNil(
            SpeakerAlignmentService.bestSpeakerID(startTime: 0, endTime: 8, turns: turns)
        )
    }

    func testRejectsLowQualityAssignment() {
        let turns = [
            SpeakerTurnValue(speakerID: "S1", startTime: 0, endTime: 2, confidence: 0.05)
        ]

        XCTAssertNil(
            SpeakerAlignmentService.bestSpeakerID(startTime: 0, endTime: 2, turns: turns)
        )
    }
}
