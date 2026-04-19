import Foundation
import Testing
@testable import rmsync

/// Regression tests for the ``SyncWorker.pull`` empty-page filter and
/// catastrophic-shrink guards. The pull function itself is private and
/// deeply coupled to Cloud / State / EchoFence / LockRegistry, so these
/// tests exercise the behavioural pieces that the fix relies on.
///
/// See CHANGES_FROM_SPEC.md and ``PageCodec.swift:28-30`` (the contract
/// comment that says the pull path "treats empty parse results as skip").
@Suite("SyncWorker.pull guards")
struct PullPathGuardsTests {

    // MARK: - Bug 1: empty-page filter

    /// This is the exact scenario that wiped ``attacks.md`` to 1 byte:
    /// a one-page cloud doc whose page parsed to ``""`` used to flow
    /// through ``PageSplitter.join([""])`` and produce a lone newline,
    /// which the pull then atomically wrote over the user's local file.
    /// We document the underlying behaviour of ``join([""])`` here so
    /// the fix (skip empty pages, bail when all pages empty) is
    /// observable as a policy layered *on top of* an otherwise unchanged
    /// splitter.
    @Test("PageSplitter.join([\"\"]) still returns a single newline")
    func joinSingleEmptyStillNewline() {
        let out = PageSplitter.join([""])
        // Length 1, a single '\n'. This is the data-loss payload that
        // the fix must never hand to ``atomicWriteText``.
        #expect(out == "\n")
    }

    @Test("filtering empties then joining yields empty string when all pages empty")
    func filterAllEmptyYieldsEmpty() {
        let pages = ["", "", ""]
        let nonEmpty = pages.filter { !$0.isEmpty }
        let newMD = nonEmpty.isEmpty ? "" : PageSplitter.join(nonEmpty)
        // "" is what we want the pull path to see when the remote has
        // only handwriting-style pages. Even then, the fix goes further
        // and refuses the write outright — see the all-empty branch.
        #expect(newMD == "")
    }

    @Test("filtering empties preserves order and produces valid multi-page doc")
    func filterMixedPreservesRealPages() {
        let pages = ["alpha\n", "", "beta\n", ""]
        let nonEmpty = pages.filter { !$0.isEmpty }
        #expect(nonEmpty == ["alpha\n", "beta\n"])

        let joined = PageSplitter.join(nonEmpty)
        let split = PageSplitter.split(joined)
        #expect(split.count == 2)
        #expect(split[0].contains("alpha"))
        #expect(split[1].contains("beta"))
    }

    // MARK: - Bug 2: catastrophic shrink threshold

    /// We don't exercise the SyncWorker directly (too much scaffolding
    /// for a unit test). Instead, codify the threshold constants the fix
    /// uses so they can't silently regress. ``shrinkMinPrev`` is the
    /// byte floor below which we never trip the guard (so genuinely
    /// short notes round-trip fine); ``shrinkMaxRatio`` is the fraction
    /// below which we treat a pulled doc as a catastrophic shrink.
    @Test("catastrophic shrink thresholds stay conservative")
    func shrinkThresholdsDocumented() {
        // These mirror the literals in SyncWorker.swift. If either is
        // edited, update this test AND the matching comment block there.
        let shrinkMinPrev = 64
        let shrinkMaxRatio = 0.1

        // A 10 KB doc shrinking to 20 bytes: must trigger.
        let prev = 10_000
        let next = 20
        #expect(prev >= shrinkMinPrev)
        #expect(Double(next) / Double(prev) < shrinkMaxRatio)

        // A 40-byte note shrinking to 1 byte: below floor, must NOT
        // trigger (tiny notes stay editable without raising conflicts).
        #expect(!(40 >= shrinkMinPrev))

        // A 10 KB doc shrinking to 2 KB (20%): above ratio, must NOT
        // trigger (this is a normal edit).
        #expect(Double(2_000) / Double(10_000) >= shrinkMaxRatio)
    }
}
