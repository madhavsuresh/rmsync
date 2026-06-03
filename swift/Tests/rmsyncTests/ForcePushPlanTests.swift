import Foundation
import Testing
@testable import rmsync

@Suite("Explicit force-push planner")
struct ForcePushPlanTests {
    @Test("local-tree plan creates overwrites deletes and skips unchanged docs")
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

    @Test("rename pair plans remote move instead of delete create")
    func renamePlansMove() {
        let hash = PathUtilities.sha256("same\n")
        let items = ExplicitSync.forcePushPlanItems(
            remoteEntries: [entry("old.md", hash: hash)],
            localFiles: [localFile("new.md", hash)],
            renames: [ExplicitSync.ForcePushRename(oldPath: "old.md", newPath: "new.md")]
        )

        #expect(items.count == 1)
        #expect(items[0].action == .moveRemote)
        #expect(items[0].sourceRelativePath == "old.md")
        #expect(items[0].relativePath == "new.md")
        #expect(items[0].remotePath == "/Writing/old")
        #expect(items[0].destinationRemotePath == "/Writing/new")
    }

    @Test("folder move derives nested destination path")
    func folderMovePlansMove() {
        let hash = PathUtilities.sha256("same\n")
        let items = ExplicitSync.forcePushPlanItems(
            remoteEntries: [entry("old/place.md", hash: hash)],
            localFiles: [localFile("new/place.md", hash)],
            renames: [ExplicitSync.ForcePushRename(oldPath: "old/place.md", newPath: "new/place.md")]
        )

        #expect(items.count == 1)
        #expect(items[0].action == .moveRemote)
        #expect(items[0].remotePath == "/Writing/old/place")
        #expect(items[0].destinationRemotePath == "/Writing/new/place")
    }

    @Test("rename with changed content plans move and overwrite")
    func renameWithEditPlansMoveAndOverwrite() {
        let items = ExplicitSync.forcePushPlanItems(
            remoteEntries: [entry("old.md", hash: PathUtilities.sha256("remote\n"))],
            localFiles: [localFile("new.md", PathUtilities.sha256("local\n"))],
            renames: [ExplicitSync.ForcePushRename(oldPath: "old.md", newPath: "new.md")]
        )

        #expect(items.count == 1)
        #expect(items[0].action == .moveAndOverwriteRemote)
        #expect(items[0].sourceRelativePath == "old.md")
        #expect(items[0].destinationRemotePath == "/Writing/new")
    }

    @Test("rename destination collision is refused without deleting source")
    func renameDestinationCollisionRefusesMove() {
        let items = ExplicitSync.forcePushPlanItems(
            remoteEntries: [
                entry("old.md", hash: PathUtilities.sha256("old remote\n")),
                entry("new.md", hash: PathUtilities.sha256("existing remote\n")),
            ],
            localFiles: [localFile("new.md", PathUtilities.sha256("local\n"))],
            renames: [ExplicitSync.ForcePushRename(oldPath: "old.md", newPath: "new.md")]
        )

        #expect(items.count == 1)
        #expect(items[0].action == .error)
        #expect(items[0].sourceRelativePath == "old.md")
        #expect(items[0].relativePath == "new.md")
        #expect(items[0].error == "rename destination already exists on cloud")
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
            remoteTabletHash: hash,
            localHashAtPull: nil,
            baselineHash: nil,
            pageIDs: ["page-\(rel)"],
            error: error
        )
    }
}
