import PersonalMemory
import XCTest
@testable import PersonalMemoryApple

/// A smoke test for the real encoder, and nothing more.
///
/// ## What is deliberately not asserted
///
/// Any particular number. Apple's sentence embeddings are a model, they change
/// between OS versions, and Simulator behaviour is not identical to a device's.
/// A test that pinned a cosine value would be a test that fails when Apple ships
/// an improvement — which is the worst kind of red build, because the correct
/// response to it is to change the test.
///
/// So this asserts only the contract the rest of the app relies on: that the
/// encoder either produces a usable vector or throws, that it never produces a
/// vector of the wrong shape, and that when a model *is* present the ordering it
/// gives is the sane one. Everything about ranking quality is tested against the
/// deterministic encoder, where an assertion means something.
final class AppleSemanticEncoderTests: XCTestCase {

    func testTheEncoderReportsWhetherItCanWork() async {
        let encoder = AppleNaturalLanguageEncoder()
        // Either answer is correct. What matters is that asking is cheap and
        // does not crash on a platform with no NaturalLanguage at all.
        _ = await encoder.isAvailable
    }

    func testEmptyTextIsRefusedRatherThanEncodedAsNothing() async {
        let encoder = AppleNaturalLanguageEncoder()
        do {
            _ = try await encoder.embedding(for: "   ")
            XCTFail("empty text should not produce a vector")
        } catch {
            XCTAssertEqual(error as? SemanticEncodingError, .emptyText)
        }
    }

    /// The property the cache depends on: a vector is only ever compared with
    /// another from the same encoder and version.
    func testTheEncoderIdentityIsStable() {
        XCTAssertEqual(
            AppleNaturalLanguageEncoder().identity,
            AppleNaturalLanguageEncoder().identity
        )
        XCTAssertNotEqual(
            AppleNaturalLanguageEncoder().identity,
            LexiconSemanticEncoder().identity
        )
    }

    func testAVectorIsUnitLengthAndNonEmptyWhenOneIsProduced() async throws {
        let encoder = AppleNaturalLanguageEncoder()
        guard await encoder.isAvailable else {
            throw XCTSkip("no sentence embedding model on this platform")
        }

        guard let vector = try? await encoder.embedding(for: "My commute to work takes half an hour")
        else {
            throw XCTSkip("the framework declined this text on this platform")
        }

        XCTAssertGreaterThan(vector.dimension, 0)
        XCTAssertEqual(vector.similarity(to: vector), 1.0, accuracy: 0.001)
    }

    /// Ordering, not magnitude. If a real model is present, two sentences about
    /// getting to work should be closer to each other than either is to a
    /// sentence about cameras — and if that is not true, the encoder is not
    /// worth preferring over the lexicon one.
    func testRelatedTextIsCloserThanUnrelatedText() async throws {
        let encoder = AppleNaturalLanguageEncoder()
        guard await encoder.isAvailable else {
            throw XCTSkip("no sentence embedding model on this platform")
        }

        guard
            let commute = try? await encoder.embedding(
                for: "It takes me thirty minutes to drive to work"
            ),
            let travel = try? await encoder.embedding(for: "How long is my journey to the office"),
            let camera = try? await encoder.embedding(for: "I prefer Sony cameras for photography")
        else {
            throw XCTSkip("the framework declined one of these on this platform")
        }

        XCTAssertGreaterThan(
            commute.similarity(to: travel),
            commute.similarity(to: camera)
        )
    }

    // MARK: Resolution

    /// Never nothing. A device with no Apple model still gets the lexicon
    /// encoder, because falling back to lexical ranking for the life of the app
    /// would be strictly worse at no saving.
    func testTheResolverAlwaysReturnsAnEncoder() async {
        let encoder = SemanticEncoderResolver.best()
        let vector = try? await encoder.embedding(for: "My commute takes half an hour")
        XCTAssertNotNil(vector)
    }
}
