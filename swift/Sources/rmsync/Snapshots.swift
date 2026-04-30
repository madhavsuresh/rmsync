import Foundation

/// Per-doc snapshot history. Captures the on-disk content of a
/// tracked Markdown file at every push (about-to-go-up bytes) and
/// every cloud-pull-overwrite (about-to-be-clobbered bytes), so
/// the user can answer "what did this look like an hour ago?"
/// without digging through state dirs or third-party tools.
///
/// Storage layout (one directory per ``doc_id`` so a
/// ``rmsync relocate`` doesn't orphan history):
///
/// ```
/// <stateDir>/backups/
///   <doc-id>/
///     20260429T221408000Z.md       # bytes verbatim
///     20260429T221408000Z.json     # sidecar metadata
/// ```
///
/// Sidecar JSON exists so ``list`` can render a word-count column
/// without re-reading every snapshot. Computed once at snapshot
/// time, cheap to deserialize.
///
/// Design constraints:
///
///   - **Doc-id keyed, not path-keyed.** ``rmsync relocate``
///     rewrites every row's ``local_path`` but doc-id is stable.
///   - **Flat copies, not diffs.** Disk usage is bounded by
///     ``cfg.backupSnapshotsToKeep`` × file size. Restoration is
///     a `cp`. Diff defers to POSIX ``diff(1)``.
///   - **Pure Foundation.** Cross-platform; identical behavior on
///     macOS and Linux.
///   - **Daemon-independent helpers.** Worker integrates via the
///     ``take``/``prune`` calls; CLI subcommands integrate via
///     ``list``/``read``/``unifiedDiff``. No actor coupling.
enum Snapshots {
    /// One snapshot, surfaced by ``list`` and accepted by
    /// ``read`` / ``unifiedDiff``. The two URLs point at the
    /// content and sidecar files respectively; both are guaranteed
    /// to exist on disk when the entry is returned by ``list``.
    struct Entry: Sendable, Equatable {
        var docID: String
        var stamp: String
        var cause: String
        var recordedAt: Date
        var wordCount: Int
        var byteCount: Int
        var sha256: String
        var contentURL: URL
        var sidecarURL: URL
    }

    /// Persisted shape of the sidecar. Same field names as
    /// ``Entry`` minus the URL wiring (which is recovered from the
    /// directory layout).
    private struct Sidecar: Codable {
        var cause: String
        var recorded_at: String
        var word_count: Int
        var byte_count: Int
        var sha256: String
    }

    /// Causes recognized by the snapshot system. String-typed for
    /// forward-compat (a future "manual" cause from
    /// ``rmsync snapshot create`` won't break older readers).
    enum Cause {
        static let push = "push"
        static let pullOverwrite = "pull_overwrite"
    }

    /// Take a snapshot of ``content`` for ``docID``. Creates
    /// ``<backupDir>/<doc-id>/<utc-stamp>.{md,json}``.
    /// Idempotent within the same millisecond stamp — re-calling
    /// ``take`` on the exact same instant skips writing if a
    /// snapshot already exists for that stamp (hash-equal content
    /// only — different content would be a logic error and we
    /// throw).
    @discardableResult
    static func take(
        content: String,
        docID: String,
        cause: String,
        in cfg: Config,
        now: Date = Date()
    ) throws -> Entry {
        let docDir = directory(for: docID, in: cfg)
        try FileManager.default.createDirectory(
            at: docDir, withIntermediateDirectories: true
        )

        let stamp = stampString(now)
        let contentURL = docDir.appendingPathComponent("\(stamp).md")
        let sidecarURL = docDir.appendingPathComponent("\(stamp).json")
        let sha = PathUtilities.sha256(content)

        // Idempotency: same stamp, same hash → no-op (return the
        // existing entry). Same stamp, different hash → throw;
        // that's a bug in the caller (back-to-back takes within
        // the same millisecond with different content).
        if FileManager.default.fileExists(atPath: sidecarURL.path) {
            let existing = try readSidecar(sidecarURL)
            if existing.sha256 == sha {
                return Entry(
                    docID: docID,
                    stamp: stamp,
                    cause: existing.cause,
                    recordedAt: parseStamp(stamp) ?? now,
                    wordCount: existing.word_count,
                    byteCount: existing.byte_count,
                    sha256: existing.sha256,
                    contentURL: contentURL,
                    sidecarURL: sidecarURL
                )
            }
            throw SnapshotError.sameStampDifferentContent(stamp)
        }

        let words = content.split(
            whereSeparator: { $0.isWhitespace || $0.isNewline }
        ).count
        let bytes = content.utf8.count
        let sidecar = Sidecar(
            cause: cause,
            recorded_at: ISO8601.now(),
            word_count: words,
            byte_count: bytes,
            sha256: sha
        )

        try content.write(to: contentURL, atomically: true, encoding: .utf8)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(sidecar).write(to: sidecarURL)

        return Entry(
            docID: docID,
            stamp: stamp,
            cause: cause,
            recordedAt: now,
            wordCount: words,
            byteCount: bytes,
            sha256: sha,
            contentURL: contentURL,
            sidecarURL: sidecarURL
        )
    }

    /// Every snapshot for ``docID`` in chronological order
    /// (oldest first). Reads the sidecars but not the content
    /// files — cheap. Missing-or-malformed sidecars are skipped
    /// with a warn log so a partially-corrupted dir still yields
    /// usable history.
    static func list(docID: String, in cfg: Config) throws -> [Entry] {
        let fm = FileManager.default
        let docDir = directory(for: docID, in: cfg)
        guard fm.fileExists(atPath: docDir.path) else { return [] }

        var entries: [Entry] = []
        let names = try fm.contentsOfDirectory(atPath: docDir.path).sorted()
        for name in names where name.hasSuffix(".json") {
            let stamp = String(name.dropLast(".json".count))
            let sidecarURL = docDir.appendingPathComponent(name)
            let contentURL = docDir.appendingPathComponent("\(stamp).md")
            guard fm.fileExists(atPath: contentURL.path) else {
                Logger.shared.warn(
                    "snapshot sidecar without content; skipping",
                    meta: ["doc_id": docID, "stamp": stamp]
                )
                continue
            }
            let sidecar: Sidecar
            do {
                sidecar = try readSidecar(sidecarURL)
            } catch {
                Logger.shared.warn(
                    "snapshot sidecar unreadable; skipping",
                    meta: ["doc_id": docID, "stamp": stamp, "error": "\(error)"]
                )
                continue
            }
            entries.append(Entry(
                docID: docID,
                stamp: stamp,
                cause: sidecar.cause,
                recordedAt: parseStamp(stamp) ?? Date.distantPast,
                wordCount: sidecar.word_count,
                byteCount: sidecar.byte_count,
                sha256: sidecar.sha256,
                contentURL: contentURL,
                sidecarURL: sidecarURL
            ))
        }
        return entries
    }

    /// Drop the oldest snapshots for ``docID`` until at most
    /// ``keep`` remain. Returns the number removed. ``keep == 0``
    /// removes nothing — interpreted as "keep forever". Negative
    /// ``keep`` is the same as zero.
    @discardableResult
    static func prune(
        docID: String, keep: Int, in cfg: Config
    ) throws -> Int {
        guard keep > 0 else { return 0 }
        let entries = try list(docID: docID, in: cfg)
        guard entries.count > keep else { return 0 }
        let drop = entries.prefix(entries.count - keep)
        let fm = FileManager.default
        var removed = 0
        for e in drop {
            do {
                try fm.removeItem(at: e.contentURL)
                try fm.removeItem(at: e.sidecarURL)
                removed += 1
            } catch {
                Logger.shared.warn(
                    "snapshot prune: removal failed",
                    meta: [
                        "doc_id": docID,
                        "stamp": e.stamp,
                        "error": "\(error)",
                    ]
                )
            }
        }
        return removed
    }

    /// Read the snapshot's content as UTF-8 text. Used by the
    /// ``history restore`` path to rehydrate the file.
    static func read(_ entry: Entry) throws -> String {
        try String(contentsOf: entry.contentURL, encoding: .utf8)
    }

    /// Unified diff between ``entry`` and the current on-disk
    /// content of ``current``. Shells to ``/usr/bin/diff -u``;
    /// returns its stdout verbatim. Exit code 1 (= "files
    /// differ") is normal — we surface the diff text. Exit code
    /// > 1 is a real error.
    ///
    /// We pass the snapshot file directly; the current file is
    /// passed as-is. Both are absolute paths so ``diff``'s output
    /// shows them without confusion.
    static func unifiedDiff(_ entry: Entry, vs current: URL) throws -> String {
        let result = try Self.runDiff(
            args: ["-u", entry.contentURL.path, current.path]
        )
        // diff(1): 0 → identical, 1 → differ, ≥2 → error.
        if result.exitCode == 0 || result.exitCode == 1 {
            return result.stdout
        }
        throw SnapshotError.diffFailed(
            exitCode: result.exitCode, stderr: result.stderr
        )
    }

    /// Look up an entry by stamp. Used by the CLI's
    /// ``--against / --to`` arguments — accepts either the full
    /// stamp (``20260429T221408000Z``) or its ISO form
    /// (``2026-04-29T22:14:08Z``). Falls back to nearest match
    /// if neither form is found verbatim, so users can paste
    /// timestamps from log lines without exact-formatting them.
    static func find(
        docID: String, stamp: String, in cfg: Config
    ) throws -> Entry? {
        let entries = try list(docID: docID, in: cfg)
        let normalized = stamp
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ":", with: "")
        if let exact = entries.first(where: { $0.stamp == normalized }) {
            return exact
        }
        // Nearest-match: parse what we can, find the entry with
        // the closest recordedAt. Only succeeds if the input
        // parses to something sensible.
        if let target = parseFlexible(stamp) {
            return entries.min(by: {
                abs($0.recordedAt.timeIntervalSince(target))
                < abs($1.recordedAt.timeIntervalSince(target))
            })
        }
        return nil
    }

    // MARK: - storage helpers

    static func directory(for docID: String, in cfg: Config) -> URL {
        Paths.backupDir.appendingPathComponent(docID, isDirectory: true)
    }

    /// UTC ISO-ish stamp suitable for filenames. Same shape the
    /// trash system uses (``YYYYMMDDTHHMMSSmmmZ``); colon-free
    /// because some sync clients still misbehave on them.
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

    /// Best-effort parse of any common timestamp shape the user
    /// might paste in: log-line ISO (``2026-04-29T22:14:08.123Z``),
    /// our compact form (``20260429T221408000Z``), or a
    /// no-fraction ISO (``2026-04-29T22:14:08Z``).
    private static func parseFlexible(_ s: String) -> Date? {
        if let d = parseStamp(s) { return d }
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = isoFractional.date(from: s) { return d }
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]
        if let d = isoPlain.date(from: s) { return d }
        return nil
    }

    private static func readSidecar(_ url: URL) throws -> Sidecar {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Sidecar.self, from: data)
    }

    // MARK: - subprocess (diff)

    private struct DiffResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    /// Synchronous wrapper around ``/usr/bin/diff``. We don't
    /// reuse ``Subprocess.run`` here because that's an async
    /// helper and ``unifiedDiff`` needs to be callable from the
    /// CLI subcommand without async ceremony. Diff is a one-shot
    /// fast process; sync execution is fine.
    private static func runDiff(args: [String]) throws -> DiffResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/diff")
        proc.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        return DiffResult(
            exitCode: proc.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }
}

enum SnapshotError: Error, CustomStringConvertible {
    case sameStampDifferentContent(String)
    case diffFailed(exitCode: Int32, stderr: String)

    var description: String {
        switch self {
        case .sameStampDifferentContent(let stamp):
            return "snapshot: stamp \(stamp) already exists with different content"
        case .diffFailed(let code, let stderr):
            return "snapshot: diff(1) failed (exit \(code)): \(stderr)"
        }
    }
}
