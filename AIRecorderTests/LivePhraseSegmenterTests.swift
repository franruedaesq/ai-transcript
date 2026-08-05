import XCTest
@testable import AIRecorder

final class LivePhraseSegmenterTests: XCTestCase {
    func testCommitsStablePunctuatedPhraseOnlyOnce() {
        var segmenter = LivePhraseSegmenter()
        XCTAssertTrue(segmenter.consume("Hola mundo.").isEmpty)
        XCTAssertEqual(segmenter.consume("Hola mundo. Cómo estás"), ["Hola mundo."])
        XCTAssertTrue(segmenter.consume("Hola mundo. Cómo estás hoy").isEmpty)
        XCTAssertEqual(segmenter.provisional(from: "Hola mundo. Cómo estás hoy"), "Cómo estás hoy")
    }

    func testForcesStableFourteenWordPhrase() {
        var segmenter = LivePhraseSegmenter()
        let fourteen = (1...14).map { "palabra\($0)" }.joined(separator: " ")
        XCTAssertTrue(segmenter.consume(fourteen).isEmpty)
        XCTAssertEqual(segmenter.consume(fourteen + " siguiente"), [fourteen])
    }

    func testCorrectionDoesNotDuplicateCommittedWords() {
        var segmenter = LivePhraseSegmenter()
        _ = segmenter.consume("Esta frase termina.")
        XCTAssertEqual(segmenter.consume("Esta frase termina. Otra"), ["Esta frase termina."])
        XCTAssertTrue(segmenter.consume("Esta frase termina. Otra versión").isEmpty)
    }
}
