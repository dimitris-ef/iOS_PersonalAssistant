import AssistantAI
import AssistantDomain
import Foundation
import XCTest

@testable import AIProviderLocal
@testable import AIProviderLocalLlama

/// Splitting a prompt across several `llama_decode` calls.
///
/// ## The bug these are about
///
/// A real device rejected a real prompt:
///
/// ```
/// n_tokens is 1241 but n_batch is 128
/// ```
///
/// The batch really was too large. What was wrong was the belief that a prompt
/// has to fit in one batch at all — `n_batch` bounds a single decode, and a
/// long prompt is supposed to arrive in several. So the arithmetic that decides
/// which tokens go in which call, and at which positions, is now a value type
/// with no llama.cpp in it, and these tests are the reason it is.
///
/// They matter more than usual because the failure they guard against is
/// silent. A position that resets at a chunk boundary produces a model that has
/// read the prompt in the wrong order and answers confidently anyway; there is
/// no crash and no error code, just a worse reply that nobody can trace back.
final class PromptDecodeChunkPlanTests: XCTestCase {

    private func plan(
        tokens: Int,
        nBatch: Int = 128,
        nUBatch: Int = 64,
        basePosition: Int = 0
    ) -> PromptDecodePlan {
        PromptDecodeChunkPlanner.plan(
            tokenCount: tokens,
            basePosition: basePosition,
            nBatch: nBatch,
            nUBatch: nUBatch
        )
    }

    // MARK: Chunk size

    /// Section 3 and 43. `n_batch` is the logical limit; `n_ubatch` is what
    /// llama.cpp splits that into internally, and splitting again here would
    /// double the number of calls to no purpose.
    func testTheChunkSizeIsTheLogicalBatchNotTheMicroBatch() {
        XCTAssertEqual(PromptDecodeChunkPlanner.chunkSize(nBatch: 128, nUBatch: 64), 128)
        XCTAssertEqual(PromptDecodeChunkPlanner.chunkSize(nBatch: 128, nUBatch: 32), 128)
        XCTAssertEqual(PromptDecodeChunkPlanner.chunkSize(nBatch: 512, nUBatch: 512), 512)
    }

    /// A context always reports an `n_batch`, so this is a fallback that should
    /// never fire — but reaching for a real number the context gave beats
    /// reaching for a constant.
    func testAMissingBatchLimitFallsBackToTheMicroBatch() {
        XCTAssertEqual(PromptDecodeChunkPlanner.chunkSize(nBatch: 0, nUBatch: 64), 64)
        XCTAssertEqual(
            PromptDecodeChunkPlanner.chunkSize(nBatch: 0, nUBatch: 0),
            PromptDecodeChunkPlanner.fallbackChunkSize
        )
    }

    // MARK: The shapes

    /// Section 44.
    func testAPromptSmallerThanTheBatchIsOneChunk() {
        let plan = plan(tokens: 64)
        XCTAssertEqual(plan.chunks.count, 1)
        XCTAssertEqual(plan.chunks[0].tokenCount, 64)
        XCTAssertEqual(plan.chunks[0].positionStart, 0)
        XCTAssertEqual(plan.chunks[0].positionEndInclusive, 63)
        XCTAssertTrue(plan.chunks[0].isFinalPromptChunk)
        XCTAssertEqual(plan.chunks[0].logitsTrueCount, 1)
    }

    /// Section 45. The off-by-one that would produce a trailing empty batch —
    /// which `llama_decode` documents as `-1, invalid input batch`.
    func testAPromptExactlyTheBatchSizeIsOneChunkWithNoEmptyTail() {
        let plan = plan(tokens: 128)
        XCTAssertEqual(plan.chunks.count, 1)
        XCTAssertEqual(plan.chunks[0].tokenCount, 128)
        XCTAssertTrue(plan.chunks.allSatisfy { $0.tokenCount > 0 })
    }

    /// Section 46.
    func testOneTokenOverTheBatchSizeIsTwoChunks() {
        let plan = plan(tokens: 129)
        XCTAssertEqual(plan.chunks.count, 2)
        XCTAssertEqual(plan.chunks[0].tokenCount, 128)
        XCTAssertEqual(plan.chunks[1].tokenCount, 1)
        XCTAssertEqual(plan.chunks[0].positionStart, 0)
        XCTAssertEqual(plan.chunks[0].positionEndInclusive, 127)
        XCTAssertEqual(plan.chunks[1].positionStart, 128)
        XCTAssertEqual(plan.chunks[1].positionEndInclusive, 128)
        XCTAssertFalse(plan.chunks[0].isFinalPromptChunk)
        XCTAssertTrue(plan.chunks[1].isFinalPromptChunk)
    }

    /// Section 25 and 47. The exact case the device reported.
    func testTheReportedTwelveHundredTokenPromptSplitsIntoTenChunks() {
        let plan = plan(tokens: 1241)
        XCTAssertEqual(plan.chunks.count, 10)
        XCTAssertEqual(
            plan.chunks.map(\.tokenCount),
            [128, 128, 128, 128, 128, 128, 128, 128, 128, 89]
        )
        // Section 67: every token, exactly once.
        XCTAssertEqual(plan.decodedTokenCount, 1241)
        XCTAssertEqual(plan.chunks.map(\.tokenCount).reduce(0, +), 1241)
    }

    /// Section 26.
    func testTheReportedPromptsPositionsRunUnbrokenFromZero() {
        let plan = plan(tokens: 1241)
        XCTAssertEqual(plan.chunks.first?.positionStart, 0)
        XCTAssertEqual(plan.chunks[8].positionStart, 1024)
        XCTAssertEqual(plan.chunks[8].positionEndInclusive, 1151)
        XCTAssertEqual(plan.chunks[9].positionStart, 1152)
        XCTAssertEqual(plan.chunks[9].positionEndInclusive, 1240)
        XCTAssertEqual(plan.nextPosition, 1241)
    }

    // MARK: The invariants

    /// Section 48. The one that would fail silently: a gap leaves the model a
    /// prompt with a hole in it, and an overlap decodes a token twice at two
    /// positions. Neither produces an error.
    func testPositionsAreContiguousAcrossEveryChunkBoundary() {
        for tokenCount in [1, 2, 127, 128, 129, 255, 256, 500, 1241, 2047] {
            let plan = plan(tokens: tokenCount)
            for (previous, next) in zip(plan.chunks, plan.chunks.dropFirst()) {
                XCTAssertEqual(
                    next.positionStart,
                    previous.positionEndInclusive + 1,
                    "gap or overlap after chunk \(previous.index) of \(tokenCount)"
                )
            }
            XCTAssertEqual(plan.chunks.last?.positionEndInclusive, tokenCount - 1)
        }
    }

    /// Section 66. Half-open ranges, so no token is the last of one chunk and
    /// the first of the next.
    func testTokenRangesAreHalfOpenAndDoNotDuplicate() {
        let plan = plan(tokens: 300)
        XCTAssertEqual(plan.chunks.map(\.tokenStart), [0, 128, 256])
        XCTAssertEqual(plan.chunks.map(\.tokenEndExclusive), [128, 256, 300])
        for (previous, next) in zip(plan.chunks, plan.chunks.dropFirst()) {
            XCTAssertEqual(next.tokenStart, previous.tokenEndExclusive)
        }
    }

    /// Section 67, over a wide range rather than one example.
    func testEveryPlanDecodesExactlyTheTokensItWasGiven() {
        for tokenCount in [1, 5, 63, 64, 128, 129, 130, 511, 1241, 4096] {
            for nBatch in [1, 8, 32, 128, 512] {
                let plan = plan(tokens: tokenCount, nBatch: nBatch, nUBatch: min(nBatch, 64))
                XCTAssertEqual(
                    plan.decodedTokenCount, tokenCount,
                    "tokens=\(tokenCount) nBatch=\(nBatch)"
                )
                XCTAssertTrue(
                    plan.chunks.allSatisfy { $0.tokenCount <= nBatch },
                    "a chunk exceeded n_batch at tokens=\(tokenCount) nBatch=\(nBatch)"
                )
                XCTAssertTrue(plan.chunks.allSatisfy { $0.tokenCount > 0 })
            }
        }
    }

    /// Section 49. The parameter exists so a caller that starts reusing a
    /// prefix cannot silently write a second run of tokens over positions that
    /// already hold something.
    func testANonZeroBasePositionShiftsEveryChunk() {
        let plan = plan(tokens: 129, basePosition: 500)
        XCTAssertEqual(plan.chunks[0].positionStart, 500)
        XCTAssertEqual(plan.chunks[0].positionEndInclusive, 627)
        XCTAssertEqual(plan.chunks[1].positionStart, 628)
        XCTAssertEqual(plan.chunks[1].positionEndInclusive, 628)
        XCTAssertEqual(plan.nextPosition, 629)
        // Token indices are indices into the prompt and do not move with the
        // base. Conflating the two is how a chunk reads the wrong tokens.
        XCTAssertEqual(plan.chunks[0].tokenStart, 0)
        XCTAssertEqual(plan.chunks[1].tokenStart, 128)
    }

    // MARK: Logits

    /// Sections 15, 16 and 50. The whole prompt asks for exactly one
    /// distribution, on its very last token.
    func testOnlyTheFinalChunkRequestsLogits() {
        let plan = plan(tokens: 1241)
        let intermediate = plan.chunks.dropLast()
        XCTAssertEqual(intermediate.count, 9)
        for chunk in intermediate {
            XCTAssertEqual(chunk.logitsTrueCount, 0, "chunk \(chunk.index) asked for logits")
            XCTAssertFalse(chunk.isFinalPromptChunk)
        }
        let last = plan.chunks[9]
        XCTAssertEqual(last.logitsTrueCount, 1)
        XCTAssertTrue(last.isFinalPromptChunk)
        // Section 16: that flag belongs to the prompt's final token.
        XCTAssertEqual(last.tokenEndExclusive - 1, 1240)
        XCTAssertEqual(last.positionEndInclusive, 1240)
    }

    /// The policy the batch builder applies, kept in step with the plan.
    func testTheLogitsPolicyAgreesWithTheChunkPlan() {
        XCTAssertEqual(LlamaBatchLogitsPolicy.none.expectedLogitsTrueCount(tokenCount: 128), 0)
        XCTAssertEqual(
            LlamaBatchLogitsPolicy.lastTokenOnly.expectedLogitsTrueCount(tokenCount: 89), 1
        )
        XCTAssertEqual(
            LlamaBatchLogitsPolicy.everyToken.expectedLogitsTrueCount(tokenCount: 4), 4
        )
    }

    /// Section 15 again, from the validator's side: an intermediate chunk that
    /// asks for nothing must not be rejected as malformed, and a final one that
    /// asks for nothing still must be.
    func testTheValidatorAcceptsAnIntermediateChunkWithNoLogits() {
        let intermediate = LocalDecodeBatchDescriptor(
            nTokens: 128,
            tokenBufferCount: 128,
            allocatedCapacity: 128,
            contextBatchLimit: 128,
            contextSize: 2048,
            positionCount: 128,
            firstPosition: 0,
            lastPosition: 127,
            sequenceCount: 128,
            logitsCount: 128,
            logitsTrueCount: 0
        )
        XCTAssertNil(
            LocalDecodeBatchValidator.validate(intermediate, expectsLogits: false)
        )
        XCTAssertEqual(
            LocalDecodeBatchValidator.validate(intermediate, expectsLogits: true)?.symbol,
            "noLogitsRequested"
        )
    }

    // MARK: Refusals

    /// Section 64. An empty prompt produces no chunks at all, so a zero-token
    /// batch can never be built from a plan.
    func testAnEmptyPromptPlansNoChunks() {
        let plan = plan(tokens: 0)
        XCTAssertTrue(plan.chunks.isEmpty)
        XCTAssertEqual(plan.decodedTokenCount, 0)
        XCTAssertEqual(plan.nextPosition, 0)
    }

    /// Section 18. Restated as a property over the plan, because it is the
    /// invariant the native call depends on.
    func testNoChunkEverExceedsTheBatchLimit() {
        let plan = plan(tokens: 1241, nBatch: 128, nUBatch: 64)
        XCTAssertTrue(plan.chunks.allSatisfy { $0.tokenCount <= 128 })
        XCTAssertEqual(plan.chunkSize, 128)
    }

    /// Section 51. The decode loop walks this array, so "strictly sequential"
    /// is a property of the plan rather than of the loop — and it is the plan
    /// that can be checked without a model.
    func testChunksArePlannedInStrictDecodeOrder() {
        let plan = plan(tokens: 1241)
        XCTAssertEqual(plan.chunks.map(\.index), Array(0..<10))
        for (previous, next) in zip(plan.chunks, plan.chunks.dropFirst()) {
            XCTAssertEqual(next.index, previous.index + 1)
            XCTAssertGreaterThan(next.tokenStart, previous.tokenStart)
            XCTAssertGreaterThan(next.positionStart, previous.positionStart)
        }
        // Exactly one chunk is the last, whatever the length.
        XCTAssertEqual(plan.chunks.filter(\.isFinalPromptChunk).count, 1)
        XCTAssertEqual(plan.chunks.last?.isFinalPromptChunk, true)
    }

    // MARK: Failure reporting

    /// Sections 28 and 29. The user gets a sentence; the log gets the index,
    /// the range and the code.
    func testAFailedChunkNamesItselfInTheDiagnosticButNotToTheUser() {
        let failure = PromptPrefillFailure(
            chunkIndex: 3,
            chunkCount: 10,
            tokenStart: 384,
            tokenEndInclusive: 511,
            result: LocalDecodeResult(returnCode: -1)
        )
        XCTAssertTrue(failure.diagnosticDescription.contains("chunk 4/10"))
        XCTAssertTrue(failure.diagnosticDescription.contains("384...511"))
        XCTAssertTrue(failure.diagnosticDescription.contains("invalidBatch"))
        XCTAssertEqual(
            failure.userDescription, "The local model failed while processing the prompt."
        )
    }

    /// The one failure the user can act on keeps its own words rather than
    /// being flattened into the generic sentence.
    func testAFullContextStillExplainsItself() {
        let failure = PromptPrefillFailure(
            chunkIndex: 9, chunkCount: 10, tokenStart: 1152, tokenEndInclusive: 1240,
            result: .noKVSlot
        )
        XCTAssertTrue(failure.userDescription.contains("context"))
        XCTAssertNotEqual(
            failure.userDescription, "The local model failed while processing the prompt."
        )
    }

    // MARK: Privacy

    /// Section 57. Chunk metadata is counts and ranges. There is no path from a
    /// token to its text here — the planner never sees the tokens at all, only
    /// how many there are.
    func testChunkMetadataCarriesOnlyNumbers() {
        let plan = plan(tokens: 1241)
        for chunk in plan.chunks {
            for (key, value) in chunk.metadata().values {
                switch value {
                case .int, .int64, .double, .bool:
                    continue
                case .text(let text):
                    XCTFail("chunk metadata \(key.rawValue) carried text: \(text)")
                }
            }
        }
        for (key, value) in plan.metadata().values {
            if case .text(let text) = value {
                XCTFail("plan metadata \(key.rawValue) carried text: \(text)")
            }
        }
    }

    /// The metadata a device report is read from, spot-checked against the
    /// worked example in section 32.
    func testTheChunkMetadataMatchesTheWorkedExample() {
        let plan = plan(tokens: 1241)
        let first = plan.chunks[0].metadata()
        XCTAssertEqual(first[.chunkIndex], .int(0))
        XCTAssertEqual(first[.chunkCount], .int(10))
        XCTAssertEqual(first[.chunkTokenCount], .int(128))
        XCTAssertEqual(first[.tokenStart], .int(0))
        XCTAssertEqual(first[.tokenEndInclusive], .int(127))
        XCTAssertEqual(first[.firstPosition], .int(0))
        XCTAssertEqual(first[.lastPosition], .int(127))
        XCTAssertEqual(first[.logitsTrueCount], .int(0))
        XCTAssertEqual(first[.isFinalPromptChunk], .bool(false))

        let last = plan.chunks[9].metadata()
        XCTAssertEqual(last[.chunkIndex], .int(9))
        XCTAssertEqual(last[.chunkTokenCount], .int(89))
        XCTAssertEqual(last[.tokenStart], .int(1152))
        XCTAssertEqual(last[.tokenEndInclusive], .int(1240))
        XCTAssertEqual(last[.logitsTrueCount], .int(1))
        XCTAssertEqual(last[.isFinalPromptChunk], .bool(true))

        let summary = plan.metadata()
        XCTAssertEqual(summary[.promptTokenCount], .int(1241))
        XCTAssertEqual(summary[.plannedChunks], .int(10))
        XCTAssertEqual(summary[.chunkSize], .int(128))
        XCTAssertEqual(summary[.basePosition], .int(0))
    }
}
