import Foundation
import Testing
@testable import rmsync

/// Unit tests for ``Trash``. Pure FileManager — no daemon, no GRDB —
/// so each case sets up a fresh ``syncDir`` under the system tempdir
/// and tears down at the end. Stamp generation is fed an explicit
/// ``Date`` per call so we can place files in named subfolders
/// without racing the wall clock.
@Suite("Trash (soft-delete)")
struct TrashTests {
    // MARK: - moveIn

    @Test("moveIn parks the source under .rmsync-trash/<stamp>/<rel>")
    func moveInBasic() async throws {
        let dir = try tempSyncDir()
        let f = dir.appendingPathComponent("note.md")
        try "hello".write(to: f, atomically: true, encoding: .utf8)

        let result = try Trash.moveIn(f, syncDir: dir, now: fixedDate(0))

        guard case .moved(let stamp, let trashedAt) = result else {
            Issue.record("expected .moved, got \(result)"); return
        }
        #expect(stamp == "20260101T000000000Z")
        #expect(trashedAt.path.contains(".rmsync-trash/20260101T000000000Z/note.md"))
        #expect(!FileManager.default.fileExists(atPath: f.path))
        #expect(FileManager.default.fileExists(atPath: trashedAt.path))
    }

    @Test("moveIn preserves nested directory structure")
    func moveInNested() async throws {
        let dir = try tempSyncDir()
        let nested = dir.appendingPathComponent("folder/sub")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let f = nested.appendingPathComponent("note.md")
        try "x".write(to: f, atomically: true, encoding: .utf8)

        let result = try Trash.moveIn(f, syncDir: dir, now: fixedDate(0))
        guard case .moved(_, let trashedAt) = result else {
            Issue.record("expected .moved"); return
        }
        let entries = try Trash.list(syncDir: dir)
        #expect(entries.count == 1)
        #expect(entries.first?.relPath == "folder/sub/note.md")
        #expect(trashedAt.path.hasSuffix("folder/sub/note.md"))
    }

    @Test("moveIn on missing source returns .sourceMissing")
    func moveInMissing() async throws {
        let dir = try tempSyncDir()
        let f = dir.appendingPathComponent("ghost.md")
        let result = try Trash.moveIn(f, syncDir: dir)
        #expect(result == .sourceMissing)
    }

    @Test("moveIn refuses paths outside sync_dir")
    func moveInOutside() async throws {
        let dir = try tempSyncDir()
        let outside = dir.deletingLastPathComponent()
            .appendingPathComponent("escaped.md")
        try "evil".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }

        do {
            _ = try Trash.moveIn(outside, syncDir: dir)
            Issue.record("expected throw")
        } catch let err as TrashError {
            if case .notInsideSyncDir = err { /* ok */ } else {
                Issue.record("wrong error: \(err)")
            }
        }
    }

    @Test("moveIn is idempotent for same-stamp re-trash")
    func moveInIdempotent() async throws {
        let dir = try tempSyncDir()
        let stamp = fixedDate(0)
        // Pre-seed a previously-trashed file at the exact target path
        // so that a re-attempt with the same stamp finds it.
        let trashedRoot = Trash.trashRoot(dir)
            .appendingPathComponent(Trash.stampString(stamp), isDirectory: true)
        try FileManager.default.createDirectory(
            at: trashedRoot, withIntermediateDirectories: true
        )
        try "previous".write(
            to: trashedRoot.appendingPathComponent("note.md"),
            atomically: true, encoding: .utf8
        )
        // Now create a new local file at the same relpath.
        let f = dir.appendingPathComponent("note.md")
        try "current".write(to: f, atomically: true, encoding: .utf8)

        let result = try Trash.moveIn(f, syncDir: dir, now: stamp)
        guard case .alreadyTrashed = result else {
            Issue.record("expected .alreadyTrashed, got \(result)"); return
        }
        // Source untouched — we don't overwrite trashed copies.
        #expect(FileManager.default.fileExists(atPath: f.path))
        let contents = try String(
            contentsOf: trashedRoot.appendingPathComponent("note.md"),
            encoding: .utf8
        )
        #expect(contents == "previous")
    }

    // MARK: - list

    @Test("list returns empty when no trash dir exists")
    func listEmpty() async throws {
        let dir = try tempSyncDir()
        let entries = try Trash.list(syncDir: dir)
        #expect(entries.isEmpty)
    }

    @Test("list orders entries by stamp ascending")
    func listOrder() async throws {
        let dir = try tempSyncDir()
        let early = dir.appendingPathComponent("a.md")
        let late = dir.appendingPathComponent("b.md")
        try "1".write(to: early, atomically: true, encoding: .utf8)
        try "2".write(to: late, atomically: true, encoding: .utf8)

        _ = try Trash.moveIn(early, syncDir: dir, now: fixedDate(0))
        _ = try Trash.moveIn(late, syncDir: dir, now: fixedDate(120))

        let entries = try Trash.list(syncDir: dir)
        #expect(entries.count == 2)
        #expect(entries[0].relPath == "a.md")
        #expect(entries[1].relPath == "b.md")
        #expect(entries[0].trashedAt < entries[1].trashedAt)
    }

    // MARK: - restore

    @Test("restore returns the file to sync_dir")
    func restoreBasic() async throws {
        let dir = try tempSyncDir()
        let f = dir.appendingPathComponent("note.md")
        try "payload".write(to: f, atomically: true, encoding: .utf8)
        _ = try Trash.moveIn(f, syncDir: dir, now: fixedDate(0))

        let entry = try Trash.list(syncDir: dir).first!
        let restored = try Trash.restore(entry, syncDir: dir)
        #expect(restored.path == f.path)
        #expect(FileManager.default.fileExists(atPath: f.path))
        let contents = try String(contentsOf: f, encoding: .utf8)
        #expect(contents == "payload")
        // Empty stamp dir should be gone.
        let stampDir = Trash.trashRoot(dir).appendingPathComponent(entry.stamp)
        #expect(!FileManager.default.fileExists(atPath: stampDir.path))
    }

    @Test("restore refuses to overwrite an existing file")
    func restoreCollision() async throws {
        let dir = try tempSyncDir()
        let f = dir.appendingPathComponent("note.md")
        try "v1".write(to: f, atomically: true, encoding: .utf8)
        _ = try Trash.moveIn(f, syncDir: dir, now: fixedDate(0))
        // Recreate the file (e.g., user re-typed it from memory).
        try "v2".write(to: f, atomically: true, encoding: .utf8)
        let entry = try Trash.list(syncDir: dir).first!

        do {
            _ = try Trash.restore(entry, syncDir: dir)
            Issue.record("expected collision throw")
        } catch let err as TrashError {
            if case .restoreCollision = err { /* ok */ } else {
                Issue.record("wrong error: \(err)")
            }
        }
    }

    // MARK: - prune

    @Test("prune removes only stamps older than cutoff")
    func pruneOldOnly() async throws {
        let dir = try tempSyncDir()
        let stale = dir.appendingPathComponent("stale.md")
        let fresh = dir.appendingPathComponent("fresh.md")
        try "1".write(to: stale, atomically: true, encoding: .utf8)
        try "2".write(to: fresh, atomically: true, encoding: .utf8)
        _ = try Trash.moveIn(stale, syncDir: dir, now: fixedDate(0))
        _ = try Trash.moveIn(fresh, syncDir: dir, now: fixedDate(86_400 * 10))

        // Cutoff at day 5: stale (day 0) gone, fresh (day 10) stays.
        let removed = try Trash.prune(syncDir: dir, olderThan: fixedDate(86_400 * 5))
        #expect(removed == 1)
        let entries = try Trash.list(syncDir: dir)
        #expect(entries.count == 1)
        #expect(entries.first?.relPath == "fresh.md")
    }

    @Test("prune ignores stamps with unparseable names")
    func pruneIgnoresJunk() async throws {
        let dir = try tempSyncDir()
        let junk = Trash.trashRoot(dir).appendingPathComponent("not-a-stamp")
        try FileManager.default.createDirectory(at: junk, withIntermediateDirectories: true)
        try "x".write(
            to: junk.appendingPathComponent("z.md"),
            atomically: true, encoding: .utf8
        )

        let removed = try Trash.prune(syncDir: dir, olderThan: Date())
        #expect(removed == 0)
        #expect(FileManager.default.fileExists(atPath: junk.path))
    }

    // MARK: - schema v5 round-trip

    // MARK: - CLI integration (smoke)

    @Test("trash list/restore command path produces expected entries")
    func cliBasicFlow() async throws {
        let dir = try tempSyncDir()
        // Park two files via the public API; the CLI surfaces the
        // same Trash.list / Trash.restore calls we test here.
        let a = dir.appendingPathComponent("a.md")
        let b = dir.appendingPathComponent("nest/b.md")
        try FileManager.default.createDirectory(
            at: b.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "1".write(to: a, atomically: true, encoding: .utf8)
        try "2".write(to: b, atomically: true, encoding: .utf8)
        _ = try Trash.moveIn(a, syncDir: dir, now: fixedDate(0))
        _ = try Trash.moveIn(b, syncDir: dir, now: fixedDate(60))

        let listed = try Trash.list(syncDir: dir)
        #expect(listed.count == 2)

        // Simulate ``rmsync trash restore --all``.
        for e in listed {
            _ = try Trash.restore(e, syncDir: dir)
        }
        // Both files restored.
        #expect(FileManager.default.fileExists(atPath: a.path))
        #expect(FileManager.default.fileExists(atPath: b.path))
        // Trash now empty.
        #expect(try Trash.list(syncDir: dir).isEmpty)
    }

    @Test("Document round-trips pending_op through GRDB")
    func documentPendingOpRoundTrip() async throws {
        let dir = try tempSyncDir()
        let state = try State(path: dir.appendingPathComponent("state.db"))
        try await state.upsert(Document(
            docID: "abc",
            pendingOp: "pending_delete"
        ))
        var loaded = try await state.get(docID: "abc")
        #expect(loaded?.pendingOp == "pending_delete")

        try await state.setPendingOp(docID: "abc", op: nil)
        loaded = try await state.get(docID: "abc")
        #expect(loaded?.pendingOp == nil)

        try await state.setPendingOp(docID: "abc", op: "pending_rename")
        let pending = try await state.pendingOpDocs()
        #expect(pending.count == 1)
        #expect(pending.first?.pendingOp == "pending_rename")
    }

    // MARK: - helpers

    private func tempSyncDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rmsync-trash-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Fixed UTC starting at 2026-01-01T00:00:00Z, plus ``offset``
    /// seconds. Lets us put files in deterministic stamp folders.
    private func fixedDate(_ offset: TimeInterval) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        let base = f.date(from: "2026-01-01T00:00:00Z")!
        return base.addingTimeInterval(offset)
    }
}
