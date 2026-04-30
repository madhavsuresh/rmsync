import Foundation
import Testing
@testable import rmsync

/// Tests for the v0.2.26 helper ``PathUtilities.remoteParentPrefixes``,
/// which feeds the defensive-mkdir loop on the push retry path.
///
/// The bug we're guarding against: when a doc is parked with
/// ``error_state = "push_failed"``, the row's ``remote_path``
/// promises a cloud location whose intermediate folders may never
/// have been actually created. Phase A's mkdir chain only ran when
/// ``stored == nil``; retries (with ``stored != nil``) skipped it
/// and hit "directory doesn't exist". The fix runs
/// ``remoteParentPrefixes(remoteParent)`` and ``cloud.mkdir`` each
/// prefix idempotently before the put.
@Suite("remoteParentPrefixes (push-retry mkdir chain)")
struct RemoteParentPrefixTests {
    @Test("nested path produces full chain")
    func nested() {
        #expect(PathUtilities.remoteParentPrefixes("/Writing/papers/2026") == [
            "/Writing", "/Writing/papers", "/Writing/papers/2026",
        ])
    }

    @Test("single-segment path returns single-element chain")
    func singleSegment() {
        #expect(PathUtilities.remoteParentPrefixes("/Writing") == ["/Writing"])
    }

    @Test("empty / root path returns empty chain")
    func empty() {
        #expect(PathUtilities.remoteParentPrefixes("") == [])
        #expect(PathUtilities.remoteParentPrefixes("/") == [])
    }

    @Test("trailing slashes don't produce empty trailing segments")
    func trailingSlashes() {
        // omittingEmptySubsequences should mean these collapse.
        #expect(PathUtilities.remoteParentPrefixes("/Writing/foo/")
                == ["/Writing", "/Writing/foo"])
    }
}
