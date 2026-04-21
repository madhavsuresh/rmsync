import Foundation
import Testing
@testable import rmsync

/// Covers the "state.db says unresolved but user deleted the
/// .conflict file" case that used to leave the menubar stuck on a
/// stale conflict count. Paired with the ``refreshBus`` change in
/// DaemonScaffold that runs this reconciliation on every status
/// refresh.
///
/// We exercise the decision primitive (``Conflict.hasUnresolvedConflictFile``)
/// plus a State-backed end-to-end flow mirroring what ``refreshBus``
/// does, without spinning up the full daemon scaffold.
@Suite("Conflict state auto-reconcile")
struct ConflictReconcileTests {

    private func makeTmpDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rmsync-conflict-reconcile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - primitive

    @Test("hasUnresolvedConflictFile returns true iff .conflict exists")
    func primitivePresenceCheck() throws {
        let dir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let md = dir.appendingPathComponent("note.md")
        try "body\n".write(to: md, atomically: true, encoding: .utf8)
        #expect(!Conflict.hasUnresolvedConflictFile(at: md))

        let conflictMarker = Conflict.conflictPath(for: md)
        try "marker\n".write(to: conflictMarker, atomically: true, encoding: .utf8)
        #expect(Conflict.hasUnresolvedConflictFile(at: md))

        try FileManager.default.removeItem(at: conflictMarker)
        #expect(!Conflict.hasUnresolvedConflictFile(at: md))
    }

    // MARK: - end-to-end (State + Conflict)

    @Test("refreshBus-shaped reconcile clears stale state when marker is gone")
    func reconcileClearsStaleState() async throws {
        let dir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let state = try State(path: dir.appendingPathComponent("state.db"))
        let mdPath = dir.appendingPathComponent("note.md").path
        try "body\n".write(
            to: URL(fileURLWithPath: mdPath),
            atomically: true, encoding: .utf8
        )

        // Simulate: doc tracked, previously pushed, conflict was declared
        // at some earlier point (hence unresolved in state.db), but the
        // user has since deleted the marker file.
        let doc = Document(
            docID: "test-doc-1",
            parentID: "",
            docType: "DocumentType",
            title: "note",
            remotePath: "/rmsync-test/note",
            localPath: mdPath,
            remoteVersion: 1,
            remoteModified: "",
            lastSyncedMDHash: PathUtilities.sha256("body\n"),
            pageIDs: []
        )
        try await state.upsert(doc)
        try await state.setConflict(docID: "test-doc-1", state: "unresolved")

        // Sanity: state.db says unresolved, no marker file exists.
        let preDocs = try await state.allDocuments()
        #expect(preDocs.first?.conflictState == "unresolved")
        #expect(!Conflict.hasUnresolvedConflictFile(at: URL(fileURLWithPath: mdPath)))

        // Mirror refreshBus's reconciliation loop.
        for d in preDocs where d.conflictState == "unresolved" {
            let p = URL(fileURLWithPath: d.localPath)
            if !Conflict.hasUnresolvedConflictFile(at: p) {
                try? await state.setConflict(docID: d.docID, state: nil)
            }
        }

        // After reconcile: state should be cleared.
        let postDocs = try await state.allDocuments()
        #expect(postDocs.first?.conflictState == nil)
    }

    @Test("reconcile leaves state alone when marker file still present")
    func reconcileLeavesLivConflictsAlone() async throws {
        let dir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let state = try State(path: dir.appendingPathComponent("state.db"))
        let md = dir.appendingPathComponent("note.md")
        try "body\n".write(to: md, atomically: true, encoding: .utf8)
        try "<<<<<<< marker\n".write(
            to: Conflict.conflictPath(for: md),
            atomically: true, encoding: .utf8
        )

        let doc = Document(
            docID: "live-conflict-1",
            parentID: "",
            docType: "DocumentType",
            title: "note",
            remotePath: "/rmsync-test/note",
            localPath: md.path,
            remoteVersion: 1,
            remoteModified: "",
            lastSyncedMDHash: PathUtilities.sha256("body\n"),
            pageIDs: []
        )
        try await state.upsert(doc)
        try await state.setConflict(docID: "live-conflict-1", state: "unresolved")

        let preDocs = try await state.allDocuments()
        for d in preDocs where d.conflictState == "unresolved" {
            let p = URL(fileURLWithPath: d.localPath)
            if !Conflict.hasUnresolvedConflictFile(at: p) {
                try? await state.setConflict(docID: d.docID, state: nil)
            }
        }

        // Marker was still present → state should remain unresolved.
        let postDocs = try await state.allDocuments()
        #expect(postDocs.first?.conflictState == "unresolved")
    }

    @Test("reconcile handles the mixed case (some live, some stale)")
    func reconcileMixed() async throws {
        let dir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let state = try State(path: dir.appendingPathComponent("state.db"))

        // Doc A: live conflict (marker file present → stays unresolved)
        let mdA = dir.appendingPathComponent("a.md")
        try "a\n".write(to: mdA, atomically: true, encoding: .utf8)
        try "marker\n".write(
            to: Conflict.conflictPath(for: mdA),
            atomically: true, encoding: .utf8
        )

        // Doc B: stale conflict (no marker file → should clear)
        let mdB = dir.appendingPathComponent("b.md")
        try "b\n".write(to: mdB, atomically: true, encoding: .utf8)

        for (id, path) in [("doc-a", mdA.path), ("doc-b", mdB.path)] {
            let doc = Document(
                docID: id, parentID: "", docType: "DocumentType",
                title: id, remotePath: "/x/\(id)", localPath: path,
                remoteVersion: 1, remoteModified: "",
                lastSyncedMDHash: PathUtilities.sha256("x\n"), pageIDs: []
            )
            try await state.upsert(doc)
            try await state.setConflict(docID: id, state: "unresolved")
        }

        let preDocs = try await state.allDocuments()
        for d in preDocs where d.conflictState == "unresolved" {
            let p = URL(fileURLWithPath: d.localPath)
            if !Conflict.hasUnresolvedConflictFile(at: p) {
                try? await state.setConflict(docID: d.docID, state: nil)
            }
        }

        let postDocs = try await state.allDocuments()
        let byID = Dictionary(uniqueKeysWithValues: postDocs.map { ($0.docID, $0) })
        #expect(byID["doc-a"]?.conflictState == "unresolved")
        #expect(byID["doc-b"]?.conflictState == nil)
    }
}
