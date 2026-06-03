import Foundation

/// Atomic-write + path-sanitization helpers.
///
/// Port of ``src/rm_sync/paths.py``. ``atomicWriteText`` is critical for
/// the echo-fence contract: every write goes tmp → ``replaceItem`` so the
/// watcher never sees a half-written file.
enum PathUtilities {
    /// Windows-reserved filenames we escape even on macOS. Same list the
    /// Python code used; keeps sync folders portable.
    private static let windowsReserved: Set<String> = {
        var s: Set<String> = ["CON", "PRN", "AUX", "NUL"]
        for i in 1..<10 { s.insert("COM\(i)"); s.insert("LPT\(i)") }
        return s
    }()

    static func sanitizeSegment(_ name: String) -> String {
        // NFC-normalize first so equivalent unicode forms hash the same.
        var s = (name as NSString).precomposedStringWithCanonicalMapping

        // Replace illegal chars with underscore. Same set as Python:
        // control chars + / \ : ? * < > " |
        let illegal = /[\x{00}-\x{1f}\/\\:?*<>"|]/
        s = s.replacing(illegal, with: "_")

        // Collapse runs of underscores.
        s = s.replacing(/_+/, with: "_")

        // Strip leading/trailing dots and spaces.
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " ."))

        if s.isEmpty { s = "untitled" }
        if windowsReserved.contains(s.uppercased()) {
            s = "_\(s)_"
        }
        if s.count > 200 {
            s = String(s.prefix(200))
        }
        return s
    }

    static func remoteToLocal(remotePath: String, syncDir: URL, remoteFolder: String) -> URL {
        let parts = stripRemoteFolderPrefix(
            remotePath.split(separator: "/").map(String.init),
            remoteFolder: remoteFolder
        )
        let safe = parts.map(sanitizeSegment)
        if safe.isEmpty {
            return syncDir.appendingPathComponent("untitled.md")
        }
        var url = syncDir
        for segment in safe.dropLast() {
            url.appendPathComponent(segment, isDirectory: true)
        }
        url.appendPathComponent(safe.last! + ".md")
        return url
    }

    static func normalizedRemoteFolder(_ remoteFolder: String) -> String {
        remoteFolder
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .joined(separator: "/")
    }

    static func remoteFolderPath(_ remoteFolder: String) -> String {
        let normalized = normalizedRemoteFolder(remoteFolder)
        return normalized.isEmpty ? "/" : "/\(normalized)"
    }

    static func remoteFolderSegments(_ remoteFolder: String) -> [String] {
        normalizedRemoteFolder(remoteFolder)
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
    }

    static func remoteFolderMkdirChain(_ remoteFolder: String) -> [String] {
        var chain: [String] = []
        var prefix = ""
        for segment in remoteFolderSegments(remoteFolder) {
            prefix += "/\(segment)"
            chain.append(prefix)
        }
        return chain
    }

    /// Inverse of ``remoteToLocal`` for the *parent folder* of a
    /// given local file: returns the cloud-side path of the
    /// folder the file should land in, plus the chain of mkdir
    /// prefixes the daemon needs to create on the cloud before
    /// putting the doc.
    ///
    /// For ``<sync_dir>/papers/2026/foo.md`` with
    /// ``remoteFolder = "sync/notes"``:
    /// ```
    ///   parentPath = "/sync/notes/papers/2026"
    ///   mkdirChain = [
    ///     "/sync",
    ///     "/sync/notes",
    ///     "/sync/notes/papers",
    ///     "/sync/notes/papers/2026",
    ///   ]
    /// ```
    /// The caller issues ``cloud.mkdir(_:)`` on each chain entry
    /// (idempotent / errors swallowed via ``try?``) before
    /// ``cloud.put``, then passes ``parentPath`` to ``cloud.put``
    /// as ``remoteParent``.
    ///
    /// Top-level files (no subdirs) get ``parentPath =
    /// "/<remoteFolder>"`` and a single-element chain. Files
    /// outside ``syncDir`` (shouldn't happen — caller's guard
    /// catches it) fall back to the same top-level result.
    static func localToRemoteParentChain(
        localPath: URL, syncDir: URL, remoteFolder: String
    ) -> (parentPath: String, mkdirChain: [String]) {
        let topLevel = remoteFolderPath(remoteFolder)
        var parentSegs: [String] = []
        if let relSegs = resolvedRelativePath(from: syncDir, to: localPath),
           relSegs.count > 1 {
            parentSegs = Array(relSegs.dropLast())
        }
        var prefix = topLevel
        var chain = remoteFolderMkdirChain(remoteFolder)
        for seg in parentSegs {
            prefix = prefix == "/" ? "/\(seg)" : "\(prefix)/\(seg)"
            chain.append(prefix)
        }
        return (parentPath: prefix, mkdirChain: chain)
    }

    /// Resolve symlinks in both paths before checking whether ``target``
    /// stays under ``base``. This closes the case where a symlinked
    /// subdirectory inside the sync tree points outside it.
    static func resolvedRelativePath(from base: URL, to target: URL) -> [String]? {
        let resolvedBase = resolvedPath(base)
        let resolvedTarget = resolvedPath(target)
        let baseComponents = resolvedBase.pathComponents
        let targetComponents = resolvedTarget.pathComponents
        guard targetComponents.count > baseComponents.count,
              Array(targetComponents.prefix(baseComponents.count)) == baseComponents
        else { return nil }
        return Array(targetComponents.dropFirst(baseComponents.count))
    }

    /// Write ``text`` to ``path`` atomically: tmp file + ``replaceItem``.
    /// Matches the Python ``os.replace`` semantics — on POSIX the replace
    /// is rename(2) which is atomic within a filesystem.
    static func atomicWriteText(_ text: String, to path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let tmp = path.deletingLastPathComponent()
            .appendingPathComponent(".\(path.lastPathComponent).\(UUID().uuidString).tmp")
        try text.write(to: tmp, atomically: false, encoding: .utf8)

        // ``replaceItemAt`` handles the case where ``path`` already
        // exists: it atomically swaps tmp into place.
        if FileManager.default.fileExists(atPath: path.path) {
            _ = try FileManager.default.replaceItemAt(path, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: path)
        }
    }

    /// SHA-256 of a UTF-8 string, hex-encoded. Used everywhere the daemon
    /// checks "has this file's content changed since last sync".
    static func sha256(_ text: String) -> String {
        let data = Data(text.utf8)
        return Self.sha256Hex(data)
    }

    static func sha256File(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return Self.sha256Hex(data)
    }

    /// SHA-256 of raw bytes, hex-encoded. Used by pull/push diagnostics
    /// to correlate per-page ``.rm`` bytes across the cloud round-trip.
    static func sha256(bytes: Data) -> String {
        Self.sha256Hex(bytes)
    }

    private static func sha256Hex(_ data: Data) -> String {
        // CryptoKit is available on macOS 10.15+, and we target 13+.
        let digest = _sha256(data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func resolvedPath(_ url: URL) -> URL {
        let fm = FileManager.default
        var cursor = url.standardizedFileURL
        var tail: [String] = []
        while cursor.path != "/" && !fm.fileExists(atPath: cursor.path) {
            tail.append(cursor.lastPathComponent)
            cursor.deleteLastPathComponent()
        }
        var resolved = cursor.resolvingSymlinksInPath()
        for component in tail.reversed() {
            resolved.appendPathComponent(component)
        }
        return resolved
    }

    private static func stripRemoteFolderPrefix(
        _ parts: [String],
        remoteFolder: String
    ) -> [String] {
        let prefix = remoteFolder
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !prefix.isEmpty,
              parts.count >= prefix.count,
              Array(parts.prefix(prefix.count)) == prefix else {
            return parts
        }
        return Array(parts.dropFirst(prefix.count))
    }
}

// CryptoKit import localized to keep the surface clean.
#if canImport(CryptoKit)
import CryptoKit
private func _sha256(_ data: Data) -> [UInt8] {
    Array(SHA256.hash(data: data))
}
#else
import Crypto
private func _sha256(_ data: Data) -> [UInt8] {
    Array(SHA256.hash(data: data))
}
#endif
