import Foundation

/// Conflict marker file management. Mirrors ``src/rm_sync/conflict.py``.
///
/// When both sides of a doc have changed since the last sync, the worker
/// writes ``<file>.md.conflict`` next to the live ``<file>.md`` with
/// git-style markers and refuses to touch the live file until the user
/// resolves the conflict manually (edit the live file, delete the
/// ``.conflict`` file, daemon picks up the change on its next cycle).
enum Conflict {
    static func conflictPath(for md: URL) -> URL {
        md.appendingPathExtension("conflict")
    }

    static func hasUnresolvedConflictFile(at md: URL) -> Bool {
        FileManager.default.fileExists(atPath: conflictPath(for: md).path)
    }

    /// Write the ``.conflict`` file. ``base`` is the last-synced content
    /// when available; we fall back to the literal "(no common ancestor)"
    /// string the Python version used.
    static func write(
        md: URL,
        local: String,
        remote: String,
        base: String? = nil
    ) throws -> URL {
        let effectiveBase = base ?? "(no common ancestor recorded)"
        let body =
            "<<<<<<< local\n"
            + local
            + (local.hasSuffix("\n") ? "" : "\n")
            + "||||||| base\n"
            + effectiveBase
            + (effectiveBase.hasSuffix("\n") ? "" : "\n")
            + "=======\n"
            + remote
            + (remote.hasSuffix("\n") ? "" : "\n")
            + ">>>>>>> remote\n"
        let out = conflictPath(for: md)
        try PathUtilities.atomicWriteText(body, to: out)
        return out
    }
}
