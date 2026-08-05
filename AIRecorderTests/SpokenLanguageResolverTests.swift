import XCTest
@testable import AIRecorder

final class SpokenLanguageResolverTests: XCTestCase {
    func testCanonicalizesNemotronAndFriendlyNames() {
        XCTAssertEqual(SpokenLanguageResolver.canonicalCode("en-US"), "en")
        XCTAssertEqual(SpokenLanguageResolver.canonicalCode("English"), "en")
        XCTAssertEqual(SpokenLanguageResolver.canonicalCode("es-ES"), "es")
        XCTAssertEqual(SpokenLanguageResolver.canonicalCode("Español"), "es")
    }

    func testRecognizesFirstStableEnglishPhrase() {
        XCTAssertEqual(
            SpokenLanguageResolver.detect(in: "This is the first complete sentence spoken in English."),
            "en"
        )
    }

    func testRecognizesFirstStableSpanishPhrase() {
        XCTAssertEqual(
            SpokenLanguageResolver.detect(in: "Esta es la primera frase completa pronunciada en español."),
            "es"
        )
    }

    func testRecognizesFirstStableGermanPhrase() {
        XCTAssertEqual(
            SpokenLanguageResolver.detect(in: "Morgen fahre ich mit dem Zug nach Berlin."),
            "de"
        )
    }

    func testRejectsSamplesThatAreTooShort() {
        XCTAssertNil(SpokenLanguageResolver.detect(in: "Hello"))
    }
}
