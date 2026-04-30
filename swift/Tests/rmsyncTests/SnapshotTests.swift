import Foundation
import Testing
@testable import rmsync

/// Unit tests for ``Snapshots``. Pure FileManager + the
/// occasional shell-out to ``/usr/bin/diff``; each case sets up a
/// fresh ``stateDir`` via ``RM_SYNC_STATE_DIR`` env override so
/// parallel test runs don't collide.
@Suite("Snapshots (history)")
struct SnapshotTests {
    // MARK: - take

    @Test("take parks content + sidecar with expected metadata")
    func takeBasic() async throws {
        let cfg = try makeCfg()
        let entry = try Snapshots.take(
            content: "hello world\nline two",
            docID: "doc-a",
            cause: Snapshots.Cause.push,
            in: cfg,
            now: fixedDate(0)
        )
        #expect(entry.cause == "push")
        #expect(entry.wordCount == 4)
        #expect(entry.byteCount == "hello world\nline two".utf8.count)
        #expect(FileManager.default.fileExists(atPath: entry.contentURL.path))
        #expect(FileManager.default.fileExists(atPath: entry.sidecarURL.path))

        // Round-trip the bytes verbatim.
        let read = try Snapshots.read(entry)
        #expect(read == "hello world\nline two")
    }

    @Test("take is idempotent for same-stamp same-content")
    func takeIdempotent() async throws {
        let cfg = try makeCfg()
        let now = fixedDate(0)
        let first = try Snapshots.take(
            content: "x", docID: "doc-a", cause: "push", in: cfg, now: now
        )
        let second = try Snapshots.take(
            content: "x", docID: "doc-a", cause: "push", in: cfg, now: now
        )
        #expect(first == second)
        // List shows one entry.
        let listed = try Snapshots.list(docID: "doc-a", in: cfg)
        #expect(listed.count == 1)
    }

    @Test("take throws on same-stamp different-content")
    func takeStampCollision() async throws {
        let cfg = try makeCfg()
        let now = fixedDate(0)
        _ = try Snapshots.take(
            content: "v1", docID: "doc-a", cause: "push", in: cfg, now: now
        )
        do {
            _ = try Snapshots.take(
                content: "v2", docID: "doc-a", cause: "push", in: cfg, now: now
            )
            Issue.record("expected throw")
        } catch let err as SnapshotError {
            if case .sameStampDifferentContent = err { /* ok */ } else {
                Issue.record("wrong error: \(err)")
            }
        }
    }

    // MARK: - list

    @Test("list returns empty for an unknown doc")
    func listEmpty() async throws {
        let cfg = try makeCfg()
        let entries = try Snapshots.list(docID: "nope", in: cfg)
        #expect(entries.isEmpty)
    }

    @Test("list orders chronologically and parses sidecars")
    func listOrder() async throws {
        let cfg = try makeCfg()
        _ = try Snapshots.take(
            content: "first", docID: "doc-a", cause: "push",
            in: cfg, now: fixedDate(0)
        )
        _ = try Snapshots.take(
            content: "second", docID: "doc-a", cause: "pull_overwrite",
            in: cfg, now: fixedDate(60)
        )
        _ = try Snapshots.take(
            content: "third", docID: "doc-a", cause: "push",
            in: cfg, now: fixedDate(120)
        )
        let entries = try Snapshots.list(docID: "doc-a", in: cfg)
        #expect(entries.count == 3)
        #expect(entries[0].cause == "push")
        #expect(entries[1].cause == "pull_overwrite")
        #expect(entries[2].cause == "push")
        #expect(entries[0].recordedAt < entries[1].recordedAt)
        #expect(entries[1].recordedAt < entries[2].recordedAt)
    }

    @Test("list isolates per-doc directories")
    func listIsolation() async throws {
        let cfg = try makeCfg()
        _ = try Snapshots.take(
            content: "a", docID: "doc-a", cause: "push",
            in: cfg, now: fixedDate(0)
        )
        _ = try Snapshots.take(
            content: "b", docID: "doc-b", cause: "push",
            in: cfg, now: fixedDate(0)
        )
        let aEntries = try Snapshots.list(docID: "doc-a", in: cfg)
        let bEntries = try Snapshots.list(docID: "doc-b", in: cfg)
        #expect(aEntries.count == 1)
        #expect(bEntries.count == 1)
        #expect(aEntries.first?.contentURL != bEntries.first?.contentURL)
    }

    // MARK: - prune

    @Test("prune drops oldest beyond keep")
    func prune() async throws {
        let cfg = try makeCfg()
        for i in 0..<5 {
            _ = try Snapshots.take(
                content: "v\(i)", docID: "doc-a", cause: "push",
                in: cfg, now: fixedDate(TimeInterval(i * 60))
            )
        }
        // Keep 2 — drop oldest 3.
        let removed = try Snapshots.prune(docID: "doc-a", keep: 2, in: cfg)
        #expect(removed == 3)
        let remaining = try Snapshots.list(docID: "doc-a", in: cfg)
        #expect(remaining.count == 2)
        // The two newest survive.
        let contents = try remaining.map(Snapshots.read)
        #expect(contents == ["v3", "v4"])
    }

    @Test("prune is a no-op when at-or-under the keep cap")
    func pruneNoop() async throws {
        let cfg = try makeCfg()
        for i in 0..<3 {
            _ = try Snapshots.take(
                content: "v\(i)", docID: "doc-a", cause: "push",
                in: cfg, now: fixedDate(TimeInterval(i * 60))
            )
        }
        let removed = try Snapshots.prune(docID: "doc-a", keep: 5, in: cfg)
        #expect(removed == 0)
        #expect(try Snapshots.list(docID: "doc-a", in: cfg).count == 3)
    }

    @Test("prune with keep <= 0 keeps everything")
    func pruneZeroKeepsAll() async throws {
        let cfg = try makeCfg()
        for i in 0..<3 {
            _ = try Snapshots.take(
                content: "v\(i)", docID: "doc-a", cause: "push",
                in: cfg, now: fixedDate(TimeInterval(i * 60))
            )
        }
        #expect(try Snapshots.prune(docID: "doc-a", keep: 0, in: cfg) == 0)
        #expect(try Snapshots.prune(docID: "doc-a", keep: -1, in: cfg) == 0)
        #expect(try Snapshots.list(docID: "doc-a", in: cfg).count == 3)
    }

    // MARK: - find

    @Test("find resolves exact stamp")
    func findExact() async throws {
        let cfg = try makeCfg()
        let taken = try Snapshots.take(
            content: "hi", docID: "doc-a", cause: "push",
            in: cfg, now: fixedDate(0)
        )
        let found = try Snapshots.find(
            docID: "doc-a", stamp: taken.stamp, in: cfg
        )
        #expect(found?.stamp == taken.stamp)
    }

    @Test("find accepts ISO timestamp form pasted by user")
    func findISO() async throws {
        let cfg = try makeCfg()
        _ = try Snapshots.take(
            content: "hi", docID: "doc-a", cause: "push",
            in: cfg, now: fixedDate(0)
        )
        // The user paste form: "2026-01-01T00:00:00Z"
        let found = try Snapshots.find(
            docID: "doc-a", stamp: "2026-01-01T00:00:00Z", in: cfg
        )
        #expect(found != nil)
    }

    // MARK: - unifiedDiff

    @Test("unifiedDiff returns POSIX -u shape when files differ")
    func diffShape() async throws {
        let cfg = try makeCfg()
        let entry = try Snapshots.take(
            content: "hello\nworld\n", docID: "doc-a",
            cause: "push", in: cfg, now: fixedDate(0)
        )
        let cur = entry.contentURL.deletingLastPathComponent()
            .appendingPathComponent("current.md")
        try "hello\nworld!\n".write(to: cur, atomically: true, encoding: .utf8)

        let diff = try Snapshots.unifiedDiff(entry, vs: cur)
        #expect(diff.contains("---"))
        #expect(diff.contains("+++"))
        #expect(diff.contains("-world"))
        #expect(diff.contains("+world!"))
    }

    @Test("unifiedDiff returns empty string when files match")
    func diffNoChange() async throws {
        let cfg = try makeCfg()
        let entry = try Snapshots.take(
            content: "hello\n", docID: "doc-a", cause: "push",
            in: cfg, now: fixedDate(0)
        )
        let diff = try Snapshots.unifiedDiff(entry, vs: entry.contentURL)
        #expect(diff.isEmpty)
    }

    // MARK: - helpers

    private func makeCfg() throws -> Config {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rmsync-snapshot-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Drive Paths.stateDir via env override so backups go
        // under our isolated temp dir. Stays scoped to this
        // process; the env value is whatever we set last.
        setenv("RM_SYNC_STATE_DIR", dir.path, 1)
        return Config(syncDir: dir, backupSnapshotsToKeep: 5)
    }

    /// Fixed UTC starting at 2026-01-01T00:00:00Z plus offset seconds.
    private func fixedDate(_ offset: TimeInterval) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        let base = f.date(from: "2026-01-01T00:00:00Z")!
        return base.addingTimeInterval(offset)
    }
}
