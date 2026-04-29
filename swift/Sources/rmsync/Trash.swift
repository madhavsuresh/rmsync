import Foundation

/// Soft-delete buffer for the rename / delete propagation feature.
///
/// Every destructive cloud-driven action (local-delete, cloud-delete,
/// rename) parks the on-disk file under
/// ``<syncDir>/.rmsync-trash/<utc-iso-stamp>/<rel-path>`` before doing
/// anything irreversible. The user can audit and undo via
/// ``rmsync trash list / restore``; ``Reconcile.pruneTrash`` removes
/// stamps older than ``deletion.trash_retention_days`` (default 30).
///
/// Design constraints:
///
///   - **No database.** Trash state lives entirely on disk so a
///     stale or corrupt ``state.db`` can't lose recoverable data.
///     The directory layout *is* the index.
///   - **Idempotent.** Re-trashing the same path is a no-op
///     (`alreadyTrashed`). Re-running ``moveIn`` after a partial
///     failure leaves the world in a consistent state.
///   - **Filtered out of the watcher.** ``WatcherFilter.shouldIgnore``
///     already drops every event under ``.rmsync-trash``; that's
///     the load-bearing reason this lives inside ``syncDir`` and
///     not somewhere external — the watcher already knows to leave
///     it alone, and a user browsing their sync dir can find it.
///   - **Pure Foundation.** Cross-platform; identical behavior on
///     macOS and Linux. No Cocoa-specific APIs.
enum Trash {
    /// One trashed file as surfaced by ``Trash.list``. ``stamp`` is
    /// the UTC ISO timestamp that names the per-deletion subfolder;
    /// ``relPath`` is the original location relative to ``syncDir``.
    /// ``absoluteURL`` points at where the file currently sits inside
    /// the trash tree, ready to be passed to ``Trash.restore``.
    struct Entry: Sendable, Equatable {
        var stamp: String
        var relPath: String
        var absoluteURL: URL
        var trashedAt: Date
    }

    /// Outcome of ``moveIn``. Callers surface this via the worker log.
    enum MoveResult: Sendable, Equatable {
        /// File was at ``source`` and is now under
        /// ``trashedAt``. ``stamp`` is the directory name.
        case moved(stamp: String, trashedAt: URL)
        /// ``source`` doesn't exist on disk. Caller treats this as
        /// "the file is already gone, just clear the row" — typical
        /// for the cloud-delete-arriving-after-local-delete path.
        case sourceMissing
        /// A previous ``moveIn`` already parked this exact path under
        /// the same stamp; we left it alone. Distinct from
        /// ``moved`` so the caller's log makes sense on retry.
        case alreadyTrashed(stamp: String, trashedAt: URL)
    }

    static let trashDirName = ".rmsync-trash"

    /// Move ``source`` (which must live under ``syncDir``) into the
    /// trash. Generates a fresh per-deletion stamp on every call so
    /// concurrent deletes don't collide; if the same path was trashed
    /// less than a second ago the original copy is preserved (we
    /// don't overwrite previously-trashed content, ever).
    @discardableResult
    static func moveIn(
        _ source: URL,
        syncDir: URL,
        now: Date = Date()
    ) throws -> MoveResult {
        let fm = FileManager.default
        guard let rel = PathUtilities.resolvedRelativePath(from: syncDir, to: source)
        else {
            throw TrashError.notInsideSyncDir(source.path)
        }
        let relString = rel.joined(separator: "/")

        guard fm.fileExists(atPath: source.path) else {
            return .sourceMissing
        }

        // Same-stamp idempotency: if this exact (stamp, relPath) is
        // already populated, we treat the call as a no-op. The
        // caller-supplied ``now`` makes this testable without
        // mocking the clock globally.
        let stamp = stampString(now)
        let stampDir = trashRoot(syncDir).appendingPathComponent(stamp, isDirectory: true)
        let dest = stampDir.appendingPathComponent(relString)

        if fm.fileExists(atPath: dest.path) {
            return .alreadyTrashed(stamp: stamp, trashedAt: dest)
        }

        try fm.createDirectory(
            at: dest.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fm.moveItem(at: source, to: dest)
        return .moved(stamp: stamp, trashedAt: dest)
    }

    /// Walk the trash tree and report every parked file in
    /// chronological order (oldest first). Cheap; trash is expected
    /// to stay small relative to the sync dir.
    static func list(syncDir: URL) throws -> [Entry] {
        let fm = FileManager.default
        let root = trashRoot(syncDir)
        guard fm.fileExists(atPath: root.path) else { return [] }

        let stamps = try fm.contentsOfDirectory(atPath: root.path).sorted()
        var entries: [Entry] = []
        for stamp in stamps {
            let stampDir = root.appendingPathComponent(stamp, isDirectory: true)
            // Skip any stray non-directory junk; the layout is strict.
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: stampDir.path, isDirectory: &isDir),
                  isDir.boolValue else { continue }
            let trashedAt = parseStamp(stamp) ?? Date.distantPast

            // Recurse into the per-stamp subtree to recover the full
            // relative path. We use FileManager.enumerator for the
            // platform-portable DFS; .skipsHiddenFiles is off on
            // purpose because trashed files might themselves be
            // dotfiles (rare, but the watcher filter wouldn't have
            // emitted them so it's defensive).
            //
            // Resolve symlinks in the stamp dir before stripping its
            // prefix from each entry. macOS tempdirs return resolved
            // paths from the enumerator (``/private/var/...``) while
            // our constructed URL is the unresolved form
            // (``/var/...``). Without this normalization the prefix
            // strip fails and ``relPath`` ends up bizarre.
            let resolvedStamp = stampDir.resolvingSymlinksInPath().path + "/"
            guard let walker = fm.enumerator(
                at: stampDir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: []
            ) else { continue }
            for case let url as URL in walker {
                let isReg = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?
                    .isRegularFile ?? false
                guard isReg else { continue }
                let resolved = url.resolvingSymlinksInPath().path
                let rel: String
                if resolved.hasPrefix(resolvedStamp) {
                    rel = String(resolved.dropFirst(resolvedStamp.count))
                } else {
                    // Fallback: best-effort split on the stamp
                    // directory name.
                    rel = url.lastPathComponent
                }
                entries.append(Entry(
                    stamp: stamp,
                    relPath: rel,
                    absoluteURL: url,
                    trashedAt: trashedAt
                ))
            }
        }
        return entries
    }

    /// Move a previously-trashed entry back to ``syncDir``. The
    /// daemon's watcher will pick it up as a new file on its next
    /// tick and re-push it to the cloud. If a file already exists at
    /// the destination we refuse the restore — surfacing the
    /// collision is more useful than silently overwriting.
    static func restore(
        _ entry: Entry,
        syncDir: URL
    ) throws -> URL {
        let fm = FileManager.default
        let dest = syncDir.appendingPathComponent(entry.relPath)
        if fm.fileExists(atPath: dest.path) {
            throw TrashError.restoreCollision(dest.path)
        }
        try fm.createDirectory(
            at: dest.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fm.moveItem(at: entry.absoluteURL, to: dest)

        // Best-effort: prune the now-empty per-stamp subfolder so
        // ``list`` doesn't keep showing a phantom stamp. We don't
        // care if this fails — the next prune pass will mop up.
        let stampDir = trashRoot(syncDir)
            .appendingPathComponent(entry.stamp, isDirectory: true)
        removeIfEmpty(stampDir)

        return dest
    }

    /// Hard-delete every per-stamp subfolder older than
    /// ``cutoff``. Called from ``Reconcile.pruneTrash`` at startup
    /// and (eventually) on a periodic timer. Conservative: only
    /// removes entire stamp directories whose timestamp is older
    /// than the cutoff, so a freshly-trashed file inside an old
    /// stamp can never happen (each ``moveIn`` mints a new stamp).
    @discardableResult
    static func prune(syncDir: URL, olderThan cutoff: Date) throws -> Int {
        let fm = FileManager.default
        let root = trashRoot(syncDir)
        guard fm.fileExists(atPath: root.path) else { return 0 }

        var removed = 0
        for stamp in try fm.contentsOfDirectory(atPath: root.path) {
            guard let ts = parseStamp(stamp) else { continue }
            guard ts < cutoff else { continue }
            let dir = root.appendingPathComponent(stamp, isDirectory: true)
            do {
                try fm.removeItem(at: dir)
                removed += 1
            } catch {
                Logger.shared.warn(
                    "trash prune: removal failed",
                    meta: ["dir": dir.path, "error": "\(error)"]
                )
            }
        }
        return removed
    }

    // MARK: - helpers

    static func trashRoot(_ syncDir: URL) -> URL {
        syncDir.appendingPathComponent(trashDirName, isDirectory: true)
    }

    /// UTC ISO timestamp suitable for a directory name (no colons,
    /// because some filesystems / sync clients still misbehave on
    /// them). Format: ``YYYYMMDDTHHMMSSmmmZ``.
    static func stampString(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd'T'HHmmssSSS'Z'"
        return f.string(from: date)
    }

    private static func parseStamp(_ s: String) -> Date? {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd'T'HHmmssSSS'Z'"
        return f.date(from: s)
    }

    private static func removeIfEmpty(_ dir: URL) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: dir.path),
              contents.isEmpty else { return }
        try? fm.removeItem(at: dir)
    }
}

/// Errors surfaced by the ``Trash`` API. All are recoverable and
/// caught by the worker — none of these should ever propagate to
/// the caller of an IPC command.
enum TrashError: Error, CustomStringConvertible {
    case notInsideSyncDir(String)
    case restoreCollision(String)

    var description: String {
        switch self {
        case .notInsideSyncDir(let p):
            return "trash: refusing to move \(p) — not inside sync_dir"
        case .restoreCollision(let p):
            return "trash: refusing to restore — \(p) already exists"
        }
    }
}
