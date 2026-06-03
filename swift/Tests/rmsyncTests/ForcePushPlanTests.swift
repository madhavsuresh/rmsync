import Foundation
import Testing
@testable import rmsync

@Suite("Explicit force-push planner")
struct ForcePushPlanTests {
    @Test("server-wins plan creates overwrites deletes and skips unchanged docs")
    func classifiesWholeTreePlan() {
        let same = PathUtilities.sha256("same\n")
        let local = [
            localFile("same.md", same),
            localFile("changed.md", PathUtilities.sha256("local\n")),
            localFile("new.md", PathUtilities.sha256("new\n")),
        ]
        let remote = [
            entry("same.md", hash: same),
            entry("changed.md", hash: PathUtilities.sha256("remote\n")),
            entry("remote-only.md", hash: PathUtilities.sha256("remote only\n")),
        ]

        let items = ExplicitSync.forcePushPlanItems(
            remoteEntries: remote,
            localFiles: local
        )
        let actions = Dictionary(uniqueKeysWithValues: items.map {
            ($0.relativePath, $0.action)
        })

        #expect(actions["same.md"] == .unchanged)
        #expect(actions["changed.md"] == .overwriteRemote)
        #expect(actions["new.md"] == .createRemote)
        #expect(actions["remote-only.md"] == .deleteRemote)
    }

    @Test("remote snapshot errors are refused even when a local file has the same path")
    func remoteErrorsWinOverLocalOverwrite() {
        let items = ExplicitSync.forcePushPlanItems(
            remoteEntries: [
                entry("broken.md", kind: .error, hash: nil, error: "download failed"),
            ],
            localFiles: [
                localFile("broken.md", PathUtilities.sha256("local\n")),
            ]
        )

        #expect(items.count == 1)
        #expect(items[0].action == .error)
        #expect(items[0].error == "download failed")
    }

    @Test("tracked local deletes from staged pull are not remote docs to delete")
    func ignoresSyntheticDeletedEntries() {
        let items = ExplicitSync.forcePushPlanItems(
            remoteEntries: [
                entry("already-gone.md", kind: .deleted, hash: nil),
            ],
            localFiles: []
        )

        #expect(items.isEmpty)
    }

    private func localFile(_ rel: String, _ hash: String) -> ExplicitSync.LocalFile {
        ExplicitSync.LocalFile(
            url: URL(fileURLWithPath: "/sync/\(rel)"),
            relativePath: rel,
            hash: hash
        )
    }

    private func entry(
        _ rel: String,
        kind: ExplicitSync.ChangeKind = .modified,
        hash: String?,
        error: String? = nil
    ) -> ExplicitSync.Entry {
        let stem = rel.hasSuffix(".md") ? String(rel.dropLast(3)) : rel
        return ExplicitSync.Entry(
            kind: kind,
            docID: "doc-\(rel)",
            remotePath: "/Writing/\(stem)",
            localPath: "/sync/\(rel)",
            relativePath: rel,
            stagedPath: hash == nil ? nil : "files/\(rel)",
            remoteModified: "2026-06-03T00:00:00Z",
            remoteVersion: 7,
            remoteHash: hash,
            localHashAtPull: nil,
            baselineHash: nil,
            pageIDs: ["page-\(rel)"],
            error: error
        )
    }
}
