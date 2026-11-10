import XCTest
@testable import AIRecorder

final class TranslationPolicyTests: XCTestCase {
    func testAutomaticPreparesSpanishAndEnglish() {
        XCTAssertEqual(
            TranslationPolicy.requiredPairs(spokenLanguage: .automatic, target: "de"),
            [.init(source: "es", target: "de"), .init(source: "en", target: "de")]
        )
    }

    func testAutomaticExcludesSameLanguagePair() {
        XCTAssertEqual(
            TranslationPolicy.requiredPairs(spokenLanguage: .automatic, target: "en-US"),
            [.init(source: "es", target: "en"), .init(source: "de", target: "en")]
        )
    }

    func testGermanUsesGermanTranslationPair() {
        XCTAssertEqual(
            TranslationPolicy.requiredPairs(spokenLanguage: .german, target: "es"),
            [.init(source: "de", target: "es")]
        )
    }

    func testLatestMailboxCoalescesObsoleteUpdates() {
        var mailbox = LatestValueMailbox<String>()
        mailbox.submit("primera")
        mailbox.submit("corregida")
        mailbox.submit("versión más reciente")

        XCTAssertEqual(mailbox.take(), "versión más reciente")
        XCTAssertTrue(mailbox.isEmpty)
    }

    func testExplicitSameLanguageNeedsNoPair() {
        XCTAssertTrue(
            TranslationPolicy.requiredPairs(spokenLanguage: .spanish, target: "es-MX").isEmpty
        )
    }

    func testContextualGroupsPreferSentenceBoundariesWithMoreContext() {
        let cues = (0..<5).map {
            TranscriptionCueValue(
                index: $0,
                startTime: Double($0),
                endTime: Double($0 + 1),
                text: "Frase \($0).",
                confidence: 1
            )
        }

        let groups = ContextualTranslationGrouper.groups(from: cues)

        XCTAssertEqual(groups.map(\.count), [4, 1])
        XCTAssertEqual(groups.flatMap { $0 }.map(\.index), [0, 1, 2, 3, 4])
    }

    func testContextualValueSpansEverySourceCueInTheGroup() throws {
        let group = [
            TranscriptionCueValue(index: 4, startTime: 3, endTime: 5, text: "Uno.", confidence: 1),
            TranscriptionCueValue(index: 5, startTime: 5, endTime: 8, text: "Dos.", confidence: 1)
        ]

        let value = try XCTUnwrap(ContextualTranslationGrouper.value(
            for: group,
            translatedText: "One. Two.",
            index: 2
        ))

        XCTAssertEqual(value.index, 2)
        XCTAssertEqual(value.startTime, 3)
        XCTAssertEqual(value.endTime, 8)
        XCTAssertEqual(value.sourceStartIndex, 4)
        XCTAssertEqual(value.sourceEndIndex, 5)
    }
}
