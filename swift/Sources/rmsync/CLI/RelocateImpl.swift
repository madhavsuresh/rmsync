import Foundation

/// Implementation of ``rmsync relocate <new>``.
///
/// Port of the Python ``cli.py:relocate`` command plus its helpers.
/// Responsibilities, in order:
///
///   1. Stop the launchd agent if it's running (idempotent).
///   2. Move every entry under the old ``sync_dir`` to ``new``.
///   3. Rewrite every ``documents.local_path`` row whose prefix matches
///      the old path.
///   4. Overwrite the ``sync_dir`` line in ``config.toml`` in place,
///      preserving surrounding comments and key order.
///   5. Restart the agent unless ``keepStopped`` is true.
///
/// Designed to be safe to re-run: if the daemon is already stopped or
/// the old sync_dir is already gone, the corresponding step is a no-op.
enum RelocateImpl {
    struct Outcome: Sendable {
        var movedEntries: Int
        var stateRowsRewritten: Int
        var configUpdated: Bool
        var restarted: Bool
    }

    enum RelocateError: Error, CustomStringConvertible, Sendable {
        case targetNotEmpty(URL)
        case configLoadFailed(String)
        case configMissing(URL)

        var description: String {
            switch self {
            case .targetNotEmpty(let url):
                return "\(url.path) already contains .md files. Pass --force to merge."
            case .configLoadFailed(let s):
                return "config load failed: \(s)"
            case .configMissing(let url):
                return "config file not found at \(url.path)"
            }
        }
    }

    static func run(
        newSyncDir: URL,
        force: Bool,
        keepStopped: Bool
    ) async throws -> Outcome {
        let cfg: Config
        do {
            cfg = try Config.load()
        } catch {
            throw RelocateError.configLoadFailed("\(error)")
        }

        let old = cfg.syncDir.resolvingSymlinksInPath()
        let new = newSyncDir.resolvingSymlinksInPath()

        if new == old {
            print("sync_dir is already \(new.path); nothing to do.")
            return Outcome(
                movedEntries: 0, stateRowsRewritten: 0,
                configUpdated: false, restarted: false
            )
        }

        if FileManager.default.fileExists(atPath: new.path),
           try containsMDFiles(new), !force {
            throw RelocateError.targetNotEmpty(new)
        }

        // 1. Stop daemon (idempotent).
        let wasRunning = Launchd.stop()
        if wasRunning { print("  stopped launchd agent") }

        // 2. Move the tree.
        let movedEntries = try moveTree(from: old, to: new)
        print("  moved \(old.path) -> \(new.path)")

        // 3. Rewrite state DB.
        let rewritten = try await rewriteState(oldBase: old, newBase: new)
        if rewritten > 0 {
            print("  rewrote \(rewritten) state row(s)")
        }

        // 4. Rewrite config.
        let configPath = Paths.configPath
        guard FileManager.default.fileExists(atPath: configPath.path) else {
            throw RelocateError.configMissing(configPath)
        }
        try rewriteConfigSyncDir(configPath: configPath, newPath: new)
        print("  config.toml updated (\(configPath.path))")

        // 5. Restart agent unless told otherwise.
        var restarted = false
        if !keepStopped {
            let r = Launchd.start()
            restarted = r.ok
            if r.ok {
                print("  started launchd agent")
            } else {
                print("  agent did not start: \(r.error ?? "unknown")")
            }
        } else {
            print("\nAgent left stopped. Restart with:")
            print("  launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.user.rmsync.plist")
        }

        return Outcome(
            movedEntries: movedEntries,
            stateRowsRewritten: rewritten,
            configUpdated: true,
            restarted: restarted
        )
    }

    // MARK: - move

    private static func containsMDFiles(_ dir: URL) throws -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: nil
        ) else { return false }
        for case let url as URL in enumerator {
            if url.pathExtension == "md" { return true }
        }
        return false
    }

    /// Move every top-level entry from ``old`` into ``new``. Merges when
    /// ``new`` already exists by moving entries one at a time and
    /// skipping collisions. Returns the count of entries actually moved.
    private static func moveTree(from old: URL, to new: URL) throws -> Int {
        let fm = FileManager.default
        try fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard fm.fileExists(atPath: old.path) else {
            try fm.createDirectory(at: new, withIntermediateDirectories: true)
            return 0
        }
        if !fm.fileExists(atPath: new.path) {
            try fm.moveItem(at: old, to: new)
            return 1
        }
        // Merge path.
        var moved = 0
        let children = try fm.contentsOfDirectory(atPath: old.path)
        for name in children {
            let src = old.appendingPathComponent(name)
            let dst = new.appendingPathComponent(name)
            if fm.fileExists(atPath: dst.path) {
                print("  skipping (already exists): \(dst.path)")
                continue
            }
            try fm.moveItem(at: src, to: dst)
            moved += 1
        }
        try? fm.removeItem(at: old)
        return moved
    }

    // MARK: - state rewrite

    /// Rewrite every ``documents.local_path`` whose prefix matches the
    /// old base. Matches the Python implementation's behaviour exactly.
    private static func rewriteState(oldBase: URL, newBase: URL) async throws -> Int {
        guard FileManager.default.fileExists(atPath: Paths.stateDBPath.path) else {
            return 0
        }
        let state = try State(path: Paths.stateDBPath)
        let docs = try await state.allDocuments()
        let oldPrefix = oldBase.path + "/"
        let newPrefix = newBase.path + "/"
        var rewritten = 0
        for var doc in docs {
            if doc.localPath.hasPrefix(oldPrefix) {
                doc.localPath = newPrefix + doc.localPath.dropFirst(oldPrefix.count)
            } else if doc.localPath == oldBase.path {
                doc.localPath = newBase.path
            } else {
                continue
            }
            try await state.upsert(doc)
            rewritten += 1
        }
        return rewritten
    }

    // MARK: - config rewrite

    /// Replace the ``sync_dir = "..."`` line. Preserves everything else
    /// (comments, whitespace, key order). If the key isn't present we
    /// append it — matches the Python behaviour.
    private static func rewriteConfigSyncDir(
        configPath: URL, newPath: URL
    ) throws {
        var text = try String(contentsOf: configPath, encoding: .utf8)
        let pattern = /^(\s*sync_dir\s*=\s*)"[^"]*"/.anchorsMatchLineEndings()
        if text.contains(pattern) {
            text.replace(pattern) { match in
                match.output.1 + "\"\(newPath.path)\""
            }
        } else {
            if !text.hasSuffix("\n") { text += "\n" }
            text += "sync_dir = \"\(newPath.path)\"\n"
        }
        try text.write(to: configPath, atomically: true, encoding: .utf8)
    }
}
