import Testing
@testable import AIRecorder

struct CueBuilderTests {
    @Test func splitsAtPunctuation() {
        let tokens = [
            AppTokenTiming(token: "▁Hola", startTime: 0, endTime: 0.3, confidence: 0.9),
            AppTokenTiming(token: "▁mundo", startTime: 0.4, endTime: 0.8, confidence: 0.8),
            AppTokenTiming(token: ".", startTime: 0.8, endTime: 0.9, confidence: 0.9),
            AppTokenTiming(token: "▁Adiós", startTime: 1.2, endTime: 1.6, confidence: 0.95),
            AppTokenTiming(token: ".", startTime: 1.6, endTime: 1.7, confidence: 0.9)
        ]
        let cues = CueBuilder.build(from: tokens)
        #expect(cues.count == 2)
        #expect(cues[0].text == "Hola mundo.")
        #expect(cues[1].startTime >= cues[0].endTime)
    }

    @Test func forcesAReasonableMaximumLength() {
        let tokens = (0..<16).map { index in
            AppTokenTiming(token: "▁palabra", startTime: Double(index) * 0.2, endTime: Double(index) * 0.2 + 0.15, confidence: 1)
        }
        #expect(CueBuilder.build(from: tokens).count == 2)
    }

    @Test func preservesStandaloneWordBoundaryTokens() {
        let tokens = [
            AppTokenTiming(token: "▁Hello", startTime: 0, endTime: 0.2, confidence: 1),
            AppTokenTiming(token: "▁", startTime: 0.2, endTime: 0.25, confidence: 1),
            AppTokenTiming(token: "world", startTime: 0.25, endTime: 0.5, confidence: 1),
            AppTokenTiming(token: "▁again", startTime: 0.5, endTime: 0.8, confidence: 1),
            AppTokenTiming(token: ".", startTime: 0.8, endTime: 0.9, confidence: 1)
        ]

        let cues = CueBuilder.build(from: tokens)

        #expect(cues.map(\.text) == ["Hello world again."])
    }
}
