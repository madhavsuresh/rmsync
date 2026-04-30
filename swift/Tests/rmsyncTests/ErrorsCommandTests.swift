import Foundation
import Testing
@testable import rmsync

/// Unit tests for the formatting helpers on the v0.2.30
/// ``rmsync errors`` subcommand. The end-to-end IO path
/// (state.db → grouped output) is harder to unit-test cleanly
/// because it prints to stdout — covered by manual smoke tests
/// + the empty-case happy path. The fragile bits worth pinning
/// in unit tests are the small string transforms.
@Suite("rmsync errors (formatting helpers)")
struct ErrorsCommandTests {
    // MARK: - softWrap

    @Test("softWrap leaves short strings as a single line")
    func wrapShort() {
        #expect(Errors.softWrap("hello world", width: 70) == ["hello world"])
    }

    @Test("softWrap breaks on whitespace at the width boundary")
    func wrapBoundary() {
        // 70-char target; should break before going over.
        let line = "this is a long sentence that should wrap somewhere "
                 + "around the seventy character boundary cleanly"
        let wrapped = Errors.softWrap(line, width: 30)
        // Every line ≤ 30 chars (greedy doesn't over-fill).
        for l in wrapped { #expect(l.count <= 30) }
        // No content lost.
        #expect(wrapped.joined(separator: " ") == line.trimmingCharacters(in: .whitespaces))
    }

    @Test("softWrap doesn't break a single word longer than width")
    func wrapLongWord() {
        // A word longer than width gets its own line (we don't
        // hyphen-break). Acceptable degenerate case.
        let result = Errors.softWrap(
            "alpha-beta-gamma-delta-epsilon-zeta-eta", width: 10
        )
        #expect(result == ["alpha-beta-gamma-delta-epsilon-zeta-eta"])
    }

    // MARK: - shortISO

    @Test("shortISO drops millisecond fraction")
    func isoStripMs() {
        #expect(Errors.shortISO("2026-04-30T11:38:07.998Z") == "2026-04-30T11:38:07Z")
    }

    @Test("shortISO no-ops when no fraction present")
    func isoNoFraction() {
        #expect(Errors.shortISO("2026-04-30T11:38:07Z") == "2026-04-30T11:38:07Z")
    }

    @Test("shortISO handles unexpected shapes by passing through")
    func isoUnexpected() {
        // Non-ISO input: don't crash, just return as-is. The CLI
        // surfaces this in user-facing output so a permissive
        // fallback is better than a force-unwrap.
        #expect(Errors.shortISO("not an iso string") == "not an iso string")
        #expect(Errors.shortISO("") == "")
    }
}
