// Extended attributes are macOS-specific in this codebase. Linux does
// have xattrs (in the ``user.`` namespace), but the metadata we apply
// here — Spotlight kMDItem* keys, Finder color tags, FinderInfo
// flags — only mean anything to the macOS Finder/Spotlight UI. The
// Linux daemon runs in Docker without a Finder, so we provide a
// no-op stub at the bottom of this file rather than re-implementing.
#if os(macOS)
import Darwin
import Foundation

/// Extended attributes applied to every pulled ``.md`` so Finder and
/// Spotlight treat it as coming from the reMarkable cloud.
///
/// Port of ``src/rm_sync/native/macos.py`` (the ``apply_metadata`` +
/// ``read_doc_id`` portions). The Python version used ``ctypes`` to call
/// into libc's ``setxattr`` directly. Swift has no public Foundation
/// wrapper for xattrs, so we go through libc the same way — just via
/// ``Darwin`` rather than ``ctypes``.
enum Xattrs {
    /// Fields encoded as xattrs on every pulled .md. All optional; we
    /// skip any whose value is empty/nil.
    struct FileMetadata: Sendable {
        var docID: String?
        var remotePath: String?
        var remoteModified: String?
        var pageIDs: [String] = []
    }

    // MARK: - attribute names (match the Python port byte-for-byte)

    static let whereFroms = "com.apple.metadata:kMDItemWhereFroms"
    static let kind = "com.apple.metadata:kMDItemKind"
    static let userTags = "com.apple.metadata:_kMDItemUserTags"
    static let finderInfo = "com.apple.FinderInfo"
    static let docIDKey = "rmsync.doc_id"
    static let remotePathKey = "rmsync.remote_path"
    static let remoteModifiedKey = "rmsync.remote_modified"
    static let pageIDsKey = "rmsync.page_ids"

    /// Finder tag colour IDs: 0=none, 1=grey, 2=green, 3=purple, 4=blue,
    /// 5=yellow, 6=red, 7=orange. Yellow to match the Python port.
    static let tagName = "reMarkable"
    static let tagColour = 5

    // MARK: - public API

    /// Stamp the xattr set onto ``path``. Best-effort; logs on failure.
    /// Called right after a successful pull, while the worker holds the
    /// per-doc lock.
    static func apply(_ meta: FileMetadata, to path: URL) {
        do {
            try setWhereFroms(path: path, meta: meta)
            try setKind(path: path)
            try setTag(path: path, name: tagName, colour: tagColour)
            if let id = meta.docID, !id.isEmpty {
                try setPlain(path: path, name: docIDKey, value: id)
            }
            if let rp = meta.remotePath, !rp.isEmpty {
                try setPlain(path: path, name: remotePathKey, value: rp)
            }
            if let rm = meta.remoteModified, !rm.isEmpty {
                try setPlain(path: path, name: remoteModifiedKey, value: rm)
            }
            if !meta.pageIDs.isEmpty,
               let data = try? JSONSerialization.data(withJSONObject: meta.pageIDs),
               let str = String(data: data, encoding: .utf8) {
                try setPlain(path: path, name: pageIDsKey, value: str)
            }
        } catch {
            Logger.shared.debug(
                "xattr apply failed",
                meta: ["path": path.path, "error": "\(error)"]
            )
        }
    }

    /// Return the ``rmsync.doc_id`` xattr if set. Handy for "which
    /// reMarkable doc is this .md, even if I renamed it?".
    static func readDocID(at path: URL) -> String? {
        guard let data = try? getRaw(path: path, name: docIDKey) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - setxattr helpers (internal but visible to tests)

    static func setRaw(path: URL, name: String, value: Data) throws {
        let rc = value.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Int32 in
            Darwin.setxattr(
                path.path, name, buf.baseAddress, buf.count,
                /* position */ 0,
                /* options  */ 0  // follow symlinks
            )
        }
        if rc != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    static func getRaw(path: URL, name: String) throws -> Data {
        // Probe size, then read.
        let size = Darwin.getxattr(path.path, name, nil, 0, 0, 0)
        if size < 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var buf = Data(count: size)
        let n = buf.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Int in
            Darwin.getxattr(path.path, name, raw.baseAddress, size, 0, 0)
        }
        if n < 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return buf.prefix(n)
    }

    // MARK: - private

    private static func setPlain(path: URL, name: String, value: String) throws {
        try setRaw(path: path, name: name, value: Data(value.utf8))
    }

    /// ``kMDItemWhereFroms`` is a binary plist array of strings. Finder's
    /// Get Info panel surfaces the first/second pair as "Where from".
    private static func setWhereFroms(path: URL, meta: FileMetadata) throws {
        var entries: [String] = ["reMarkable Cloud"]
        if let rp = meta.remotePath, !rp.isEmpty {
            entries.append(rp)
        }
        let data = try PropertyListSerialization.data(
            fromPropertyList: entries, format: .binary, options: 0
        )
        try setRaw(path: path, name: whereFroms, value: data)
    }

    private static func setKind(path: URL) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: "reMarkable Notebook", format: .binary, options: 0
        )
        try setRaw(path: path, name: kind, value: data)
    }

    /// Finder user tags are a bplist array of ``"<name>\n<colour>"`` strings.
    private static func setTag(path: URL, name: String, colour: Int) throws {
        let entry = "\(name)\n\(colour)"
        let data = try PropertyListSerialization.data(
            fromPropertyList: [entry], format: .binary, options: 0
        )
        try setRaw(path: path, name: userTags, value: data)
    }
}

#elseif os(Linux)

// Linux stub: pulled-file metadata is a Finder/Spotlight feature with
// no useful Linux equivalent. The daemon code calls into ``Xattrs``
// without conditional guards, so we provide just the public surface
// (``apply`` and ``readDocID``) as no-ops here. ``setRaw`` / ``getRaw``
// are NOT exposed because their only caller (FolderIcon) is also
// macOS-only.
import Foundation

enum Xattrs {
    struct FileMetadata: Sendable {
        var docID: String?
        var remotePath: String?
        var remoteModified: String?
        var pageIDs: [String] = []
    }

    /// No-op on Linux. The daemon still calls this after every pull,
    /// but Spotlight kMDItem* / Finder tags don't exist outside macOS.
    static func apply(_ meta: FileMetadata, to path: URL) {
        // Could write rmsync.* under the Linux ``user.`` namespace
        // (libc ``setxattr`` works there), but it's invisible without
        // Finder integration so deferred.
        _ = (meta, path)
    }

    /// Always returns nil on Linux. Explicit push looks up by path
    /// in state.db instead, which is the same fallback the macOS
    /// path uses when the xattr is missing.
    static func readDocID(at path: URL) -> String? {
        _ = path
        return nil
    }
}

#endif
