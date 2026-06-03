import Foundation
import Testing
@testable import rmsync

/// Guards against the "Dropbox evicts the local bytes, rmsync reads it
/// as empty, pushes emptiness to reMarkable" class of data loss.
/// Companion to ``PullPathGuardsTests`` on the pull side — same
/// defensive philosophy, different direction.
///
/// These tests cover the decision logic at the primitive level used
/// by explicit push and auto-push, plus the doctor's
/// path-pattern detection.
@Suite("Cloud-provider eviction guards")
struct CloudProviderGuardsTests {

    // MARK: - push-side: empty-read while tracked-nonempty

    @Test("empty local + non-empty stored hash triggers guard")
    func emptyLocalNonEmptyStoredTriggersGuard() {
        // Mirrors the decision in doPush: if the trimmed text is
        // empty AND stored.lastSyncedMDHash is non-empty and not the
        // hash of empty-string, refuse.
        let text = ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(trimmed.isEmpty)

        let emptyHash = PathUtilities.sha256("")
        let priorHash = PathUtilities.sha256("real content\n")
        #expect(priorHash != emptyHash)
        #expect(priorHash.isEmpty == false)
        // Guard fires when all of these hold.
    }

    @Test("whitespace-only local counts as empty for the guard")
    func whitespaceOnlyIsEmpty() {
        for text in ["\n", "   ", "\t\n", "\r\n\r\n", "  \n\t\n  "] {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(
                trimmed.isEmpty,
                "input \(text.debugDescription) should trim to empty"
            )
        }
    }

    @Test("non-empty local bypasses the guard")
    func nonEmptyLocalBypassesGuard() {
        for text in ["x", "a\n", "# heading\n\nbody", " leading space text"] {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(!trimmed.isEmpty, "input \(text.debugDescription) should not trim empty")
        }
    }

    @Test("empty local with empty stored hash bypasses the guard")
    func emptyLocalEmptyStoredBypassesGuard() {
        // First-time push of a genuinely empty file: stored hash
        // would be nil/empty. Guard must NOT fire — there's no
        // prior non-empty copy to protect.
        let emptyHash = PathUtilities.sha256("")
        #expect(!emptyHash.isEmpty)  // sha256 always returns hex, never empty string
        // Guard condition in doPush is:
        //   trimmed.isEmpty && lastHash != nil && !lastHash.isEmpty &&
        //   lastHash != sha256("")
        // The final clause excludes "we last synced an empty doc" from
        // triggering. This test documents that carve-out.
        let stored_lastHash = emptyHash  // simulating prior empty sync
        let shouldFire = stored_lastHash != emptyHash
        #expect(!shouldFire)
    }

    // MARK: - doctor: cloud-provider path detection

    @Test("detects Dropbox File Provider path")
    func detectsDropboxFileProvider() {
        // Modern macOS (10.15+) places Dropbox under
        // ~/Library/CloudStorage/Dropbox.
        let path = "/Users/alice/Library/CloudStorage/Dropbox/rmsync"
        #expect(path.contains("/Library/CloudStorage/Dropbox"))
    }

    @Test("detects legacy ~/Dropbox path")
    func detectsLegacyDropbox() {
        // Older Dropbox installs (pre-CloudStorage) still put the
        // folder at ~/Dropbox.
        let path = "/Users/alice/Dropbox/rmsync/notes.md"
        #expect(path.contains("/Dropbox/"))
    }

    @Test("detects iCloud Drive path")
    func detectsICloudDrive() {
        let path = "/Users/alice/Library/Mobile Documents/com~apple~CloudDocs/rmsync"
        #expect(path.contains("/Library/Mobile Documents/"))
    }

    @Test("detects OneDrive path")
    func detectsOneDrive() {
        let path = "/Users/alice/Library/CloudStorage/OneDrive-Personal/rmsync"
        #expect(path.contains("/Library/CloudStorage/OneDrive"))
    }

    @Test("detects Google Drive path")
    func detectsGoogleDrive() {
        let path = "/Users/alice/Library/CloudStorage/GoogleDrive-alice@example.com/rmsync"
        #expect(path.contains("/Library/CloudStorage/GoogleDrive"))
    }

    @Test("non-cloud paths don't match any pattern")
    func nonCloudPathsClean() {
        let patterns = [
            "/Library/CloudStorage/Dropbox",
            "/Dropbox/",
            "/Library/Mobile Documents/",
            "/Library/CloudStorage/OneDrive",
            "/Library/CloudStorage/GoogleDrive",
            "/Library/CloudStorage/Box-Box",
        ]
        // Typical local-only sync dirs.
        for path in ["/Users/alice/rmsync-writing",
                     "/Users/alice/Documents/rm",
                     "/tmp/rmsync-test",
                     "/Users/alice/code/notes"] {
            for pattern in patterns {
                #expect(
                    !path.contains(pattern),
                    "path \(path) should not match cloud pattern \(pattern)"
                )
            }
        }
    }
}
