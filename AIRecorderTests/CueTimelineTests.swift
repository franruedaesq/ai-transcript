import Testing
@testable import AIRecorder

struct CueTimelineTests {
    private let cues = [
        TranscriptionCueValue(index: 0, startTime: 0, endTime: 1, text: "Uno", confidence: 1),
        TranscriptionCueValue(index: 1, startTime: 1.1, endTime: 2, text: "Dos", confidence: 1),
        TranscriptionCueValue(index: 2, startTime: 2.1, endTime: 3, text: "Tres", confidence: 1)
    ]

    @Test func findsActiveCue() {
        #expect(CueTimeline.activeIndex(at: 1.5, cues: cues) == 1)
        #expect(CueTimeline.activeIndex(at: 2.7, cues: cues) == 2)
    }

    @Test func returnsNilInGaps() {
        #expect(CueTimeline.activeIndex(at: 1.05, cues: cues) == nil)
        #expect(CueTimeline.activeIndex(at: 4, cues: cues) == nil)
    }
}
