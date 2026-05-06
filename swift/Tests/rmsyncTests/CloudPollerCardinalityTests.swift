import Foundation
import Testing
@testable import rmsync

/// Pure-logic tests for ``CloudPoller.shouldRunMissingDetection`` —
/// the gate added in v0.2.37 that refuses delete-detection when the
/// cloud listing returned suspiciously few documents relative to
/// state.db's tracked count. Defends against silent mass-trashing
/// caused by partial rmapi listings that don't surface as thrown
/// errors.
@Suite("CloudPoller cardinality gate")
struct CloudPollerCardinalityTests {
    @Test("trivial libraries (< 5 tracked) bypass the gate")
    func trivialLibraryBypass() {
        // No matter how few we saw, allow detection at small scale.
        // The bulk-delete brake at the worker level is the safety net
        // here; a strict ratio gate would refuse legitimate single-doc
        // deletions out of a 3-4 doc library.
        #expect(CloudPoller.shouldRunMissingDetection(seenCount: 0, trackedCount: 0))
        #expect(CloudPoller.shouldRunMissingDetection(seenCount: 0, trackedCount: 1))
        #expect(CloudPoller.shouldRunMissingDetection(seenCount: 0, trackedCount: 4))
        #expect(CloudPoller.shouldRunMissingDetection(seenCount: 2, trackedCount: 4))
    }

    @Test("70 % floor at the threshold boundary")
    func atSeventyPercent() {
        // 5 tracked × 0.7 = 3 (floor). seenCount 3 → allow.
        #expect(CloudPoller.shouldRunMissingDetection(seenCount: 3, trackedCount: 5))
        // 10 tracked × 0.7 = 7 (floor). seenCount 7 → allow, 6 → refuse.
        #expect(CloudPoller.shouldRunMissingDetection(seenCount: 7, trackedCount: 10))
        #expect(!CloudPoller.shouldRunMissingDetection(seenCount: 6, trackedCount: 10))
    }

    @Test("a 50-doc library missing 20 (60 %) trips the gate")
    func partialListingTripsGate() {
        // 50 × 0.7 = 35 (floor). seenCount 30 < 35 → refuse.
        #expect(!CloudPoller.shouldRunMissingDetection(seenCount: 30, trackedCount: 50))
    }

    @Test("a 50-doc library missing 5 (90 %) passes the gate")
    func legitimateSmallDeletionPasses() {
        // 50 × 0.7 = 35 (floor). seenCount 45 >= 35 → allow.
        // The 5 missing docs go through the normal two-poll-grace
        // path in handleMissing.
        #expect(CloudPoller.shouldRunMissingDetection(seenCount: 45, trackedCount: 50))
    }

    @Test("zero seen against a non-trivial library always refuses")
    func zeroSeenRefuses() {
        // The classic catastrophic case: rmapi returned no results
        // at all but didn't throw. State.db has hundreds of docs.
        // Refusing here is the entire point of the gate.
        #expect(!CloudPoller.shouldRunMissingDetection(seenCount: 0, trackedCount: 100))
        #expect(!CloudPoller.shouldRunMissingDetection(seenCount: 0, trackedCount: 5))
    }

    @Test("seeing more than tracked (cloud has new docs) always allows")
    func cloudHasNewDocs() {
        // Stranger user pushed new docs to the same cloud account, or
        // a cloud-side import added entries we haven't pulled yet.
        // Ratio is > 1.0 — well above the 0.7 floor. Allow.
        #expect(CloudPoller.shouldRunMissingDetection(seenCount: 60, trackedCount: 50))
    }
}
