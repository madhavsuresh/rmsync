import Foundation
import Testing
@testable import rmsync

/// Regression tests for the ``history list`` table-row padding.
///
/// **Why this exists.** v0.2.20 shipped with `String(format:
/// "%-26s", swiftString)` for the table layout. ``%s`` in the
/// printf-style format used by NSString expects a C
/// ``const char *``; a bridged Swift String comes through as an
/// object pointer that ``%s`` reads as a char buffer, leading to
/// a segfault the moment a tracked doc had snapshots. The bug
/// went uncaught because no test exercised the printing path
/// against a populated state DB.
///
/// The fix replaced ``String(format:)`` with hand-rolled
/// ``History.padR``/``padL`` helpers. These tests pin those
/// helpers' contract so a future "let's go back to printf" PR
/// fails at build time rather than at runtime.
@Suite("history formatting helpers (no-segfault regression)")
struct HistoryFormattingTests {
    @Test("padR pads short string with trailing spaces")
    func padRBasic() {
        #expect(History.padR("hi", 5) == "hi   ")
    }

    @Test("padR is a no-op when string is already wider")
    func padROverflow() {
        #expect(History.padR("verylong", 4) == "verylong")
    }

    @Test("padL pads short string with leading spaces")
    func padLBasic() {
        #expect(History.padL("42", 6) == "    42")
    }

    @Test("padL is a no-op when string is already wider")
    func padLOverflow() {
        #expect(History.padL("12345", 3) == "12345")
    }

    @Test("both helpers handle width 0 / negative")
    func zeroWidth() {
        #expect(History.padR("abc", 0) == "abc")
        #expect(History.padL("abc", -3) == "abc")
    }
}
