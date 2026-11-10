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

    func testCapitalizationAndPunctuationCorrectionsRemainStable() {
        var segmenter = LivePhraseSegmenter()
        _ = segmenter.consume("hola mundo.")
        XCTAssertEqual(segmenter.consume("Hola mundo! siguiente"), ["Hola mundo!"])
    }

    func testUpdateReturnsPhrasesAndProvisionalFromOnePass() {
        var segmenter = LivePhraseSegmenter()
        _ = segmenter.update("Primera frase.")
        let update = segmenter.update("Primera frase. Texto pendiente")
        XCTAssertEqual(update.phrases, ["Primera frase."])
        XCTAssertEqual(update.provisional, "Texto pendiente")
        XCTAssertEqual(segmenter.provisional(from: "Primera frase. Texto pendiente"), "Texto pendiente")
    }

    func testBoundedStreamGateStopsAfterFirstOverflow() async {
        let pair = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let gate = BoundedAsyncStreamGate(continuation: pair.continuation)

        XCTAssertEqual(gate.yield(1), .accepted)
        XCTAssertEqual(gate.yield(2), .overflow)
        XCTAssertTrue(gate.didOverflow)
        XCTAssertEqual(gate.yield(3), .terminated)

        var iterator = pair.stream.makeAsyncIterator()
        let first = await iterator.next()
        let end = await iterator.next()
        XCTAssertEqual(first, 1)
        XCTAssertNil(end)
    }
}
