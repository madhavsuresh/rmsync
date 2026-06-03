import Testing
@testable import rmsync

/// Throttle detection has to be conservative because false positives
/// surface as "rmapi throttled" doctor failures on totally healthy
/// installs — the user can't tell their setup apart from a real
/// throttle. The pre-2026-04-27 patterns matched bare /\b429\b/,
/// /\b503\b/, and /(?i)rate.{0,5}limit/, all of which collide with
/// document-list output (UUID segments, doc names, banner text).
///
/// These tests pin both directions: real throttle markers detected,
/// benign content not.
@Suite("Cloud throttle detection")
struct CloudThrottleDetectionTests {
    // MARK: - real throttle messages should match

    @Test("HTTP 429 in error context is detected")
    func detectsHTTP429() {
        #expect(Cloud.isThrottled("Error: HTTP 429: Too Many Requests"))
        #expect(Cloud.isThrottled("HTTP/2 429"))
        #expect(Cloud.isThrottled("status: 429"))
        #expect(Cloud.isThrottled("Status 429 — slow down"))
    }

    @Test("HTTP 503 in error context is detected")
    func detectsHTTP503() {
        #expect(Cloud.isThrottled("Error: HTTP 503: Service Unavailable"))
        #expect(Cloud.isThrottled("status: 503"))
    }

    @Test("'too many requests' phrase is detected")
    func detectsTooManyRequests() {
        #expect(Cloud.isThrottled("Too Many Requests"))
        #expect(Cloud.isThrottled("got: too many requests, retry later"))
    }

    @Test("'rate limit' family is detected")
    func detectsRateLimit() {
        #expect(Cloud.isThrottled("rate limit exceeded"))
        #expect(Cloud.isThrottled("rate-limited by upstream"))
        #expect(Cloud.isThrottled("rate-limiting active"))
        #expect(Cloud.isThrottled("RATE LIMIT EXCEEDED"))
    }

    @Test("'throttled' / 'throttling' family is detected")
    func detectsThrottle() {
        #expect(Cloud.isThrottled("request was throttled"))
        #expect(Cloud.isThrottled("throttling in effect"))
        #expect(Cloud.isThrottled("THROTTLED"))
    }

    // MARK: - benign content must NOT match

    @Test("UUIDs containing 429/503 substrings don't false-positive")
    func uuidsAreClean() {
        // UUID segments are hyphen-bounded. Pre-fix patterns of /\b429\b/
        // matched ``-429-`` as word-bounded. Bug reported 2026-04-27.
        #expect(!Cloud.isThrottled("[f] doc-uuid-429-abc"))
        #expect(!Cloud.isThrottled("/sync/notes/abc-503-def"))
        #expect(!Cloud.isThrottled("71acc84c-8a2f-4a40-bfa5-014ed8078d1a"))
        #expect(!Cloud.isThrottled("12345-429-67890-503-abcde"))
    }

    @Test("doc names containing 429/503 numbers don't false-positive")
    func docNamesAreClean() {
        #expect(!Cloud.isThrottled("[f] /sync/notes/Page 429.md"))
        #expect(!Cloud.isThrottled("[f] /sync/notes/Issue 503"))
        #expect(!Cloud.isThrottled("[d] /Quick sheets/notes-429-final"))
    }

    @Test("English text mentioning 'rate' or 'limit' separately is clean")
    func englishIsClean() {
        // The old loose /(?i)rate.{0,5}limit/ matched these.
        #expect(!Cloud.isThrottled("interest rate at 5% with no limit"))
        #expect(!Cloud.isThrottled("rate of inflation, limit on spending"))
        #expect(!Cloud.isThrottled("first-rate poetry has its limits"))
        #expect(!Cloud.isThrottled("the credit limit and tax rate"))
    }

    @Test("typical rmapi `find /` output is clean")
    func findOutputIsClean() {
        // Sample of what `rmapi find /` actually emits in shell mode.
        let output = """
        [d] /sync/notes
        [d] /Quick sheets
        [d] /Trash
        [f] /Quick sheets/My day
        [f] /sync/notes/Random thoughts
        [f] /sync/notes/Issue 429
        [f] /sync/notes/abc-503-doc
        """
        #expect(!Cloud.isThrottled(output))
    }
}
