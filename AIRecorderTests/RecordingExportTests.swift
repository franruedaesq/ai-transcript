import XCTest
@testable import AIRecorder

final class RecordingExportTests: XCTestCase {
    private let original = [
        TranscriptionCueValue(index: 0, startTime: 4.12, endTime: 6.85, text: "Hola.", confidence: 1),
        TranscriptionCueValue(index: 1, startTime: 6.85, endTime: 9.4, text: "¿Cómo estás?", confidence: 1)
    ]

    private let translated = [
        TranslatedSubtitleCueValue(
            index: 0,
            startTime: 4.12,
            endTime: 9.4,
            sourceStartIndex: 0,
            sourceEndIndex: 1,
            text: "Hello. How are you?"
        )
    ]

    func testOriginalSRTUsesOneBasedIndexesAndMilliseconds() {
        let text = SubtitleExporter.srt(original: original)
        XCTAssertTrue(text.contains("1\n00:00:04,120 --> 00:00:06,850\nHola."))
        XCTAssertTrue(text.contains("2\n00:00:06,850 --> 00:00:09,400\n¿Cómo estás?"))
    }

    func testBilingualSRTUsesTranslationRangeAndMatchingOriginalCues() {
        XCTAssertEqual(
            SubtitleExporter.bilingualSRT(original: original, translated: translated),
            "1\n00:00:04,120 --> 00:00:09,400\nHola. ¿Cómo estás?\nHello. How are you?"
        )
    }

    func testVTTUsesHeaderPeriodSeparatorAndNonZeroDuration() {
        let cue = TranscriptionCueValue(index: 0, startTime: 2, endTime: 2, text: "Hola", confidence: 1)
        XCTAssertEqual(
            SubtitleExporter.vtt(original: [cue]),
            "WEBVTT\n\n00:00:02.000 --> 00:00:02.080\nHola\n"
        )
    }

    func testSpeakerNamesAreIncludedInTranscriptExports() {
        let cue = TranscriptionCueValue(
            index: 0,
            startTime: 0,
            endTime: 1,
            text: "Hello",
            confidence: 1,
            speakerID: "S1"
        )

        XCTAssertTrue(
            SubtitleExporter.srt(original: [cue], speakerNames: ["S1": "Alex"])
                .contains("Alex: Hello")
        )
        XCTAssertTrue(
            SubtitleExporter.vtt(original: [cue], speakerNames: ["S1": "Alex"])
                .contains("Alex: Hello")
        )
    }
}
