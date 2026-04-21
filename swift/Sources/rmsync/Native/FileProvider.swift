import Darwin
import Foundation

/// Detect macOS File Provider *dataless placeholders* — files that
/// appear in the filesystem namespace with their original size but
/// have no actual bytes locally cached. Dropbox, iCloud Drive,
/// OneDrive, Google Drive, and Box all produce these when the
/// provider evicts a file to reclaim disk.
///
/// Reading a dataless file with ``String(contentsOf:)`` on macOS is
/// *supposed* to block and trigger File Provider materialization,
/// but in practice it often returns zero bytes without surfacing an
/// error — either because the provider extension isn't responding,
/// the system is under memory/disk pressure, or the provider has
/// simply decided to hand us an empty placeholder read. That's the
/// failure mode that used to wipe ``attacks.md`` / ``rs2.md``
/// before the push guard existed.
///
/// The most reliable cross-provider signal, verified on APFS against
/// actual Dropbox-evicted files: ``st_size > 0 && st_blocks == 0``.
/// The kernel reports the logical size (what the file *would* be if
/// materialized) but allocates zero physical blocks. A fully-local
/// file always has ``st_blocks > 0``; a genuinely empty file has
/// ``st_size == 0``. Neither case overlaps with the dataless
/// signature.
///
/// We also publish a helper that recognises whether a file is
/// *managed* by a known cloud provider at all (via xattr sniffing),
/// so the daemon can tune error messaging appropriately.
enum FileProvider {

    /// Classification of a local file's File Provider state. Used
    /// by the push path to decide whether an "empty local read" is
    /// an honest user-cleared file or a dataless placeholder that
    /// we must not push to the cloud.
    enum Status: Equatable, Sendable {
        /// Regular local file with physical bytes on disk. Read it
        /// normally. This is the common case.
        case local

        /// Dataless placeholder: file exists in the namespace with a
        /// non-zero logical size, but zero physical blocks are
        /// allocated. Reading will likely return empty or partial
        /// bytes without surfacing a proper I/O error. The daemon
        /// must NOT push this file's content to the cloud.
        case dataless(logicalSize: Int, provider: Provider?)

        /// Genuinely empty local file (``st_size == 0``). The user
        /// intentionally has nothing here; fine to push.
        case empty

        /// File doesn't exist or couldn't be stat'd.
        case missing

        var isDataless: Bool {
            if case .dataless = self { return true }
            return false
        }
    }

    /// Known cloud-storage File Provider extensions we recognise by
    /// xattr namespace. Used only for more specific error messages;
    /// the dataless detection itself is provider-agnostic.
    enum Provider: String, Sendable {
        case dropbox = "Dropbox"
        case iCloud = "iCloud Drive"
        case oneDrive = "OneDrive"
        case googleDrive = "Google Drive"
        case appleFileProvider = "macOS File Provider"
    }

    /// Classify a file. Static; no state, cheap to call per-push.
    static func status(of url: URL) -> Status {
        // Disambiguate ``stat`` (the struct type) from ``stat(2)`` (the
        // libc function) explicitly — Swift's type-vs-function overload
        // resolution trips on ``Darwin.stat()`` alone.
        var buf: stat = stat()
        let rc = url.path.withCString { cPath -> Int32 in
            stat(cPath, &buf)
        }
        guard rc == 0 else {
            return .missing
        }
        let size = Int(buf.st_size)
        let blocks = Int(buf.st_blocks)

        if size == 0 {
            return .empty
        }

        // The dataless signature: non-zero logical size, zero physical
        // blocks allocated. Verified against Dropbox-evicted files on
        // APFS (macOS 14+). If this ever produces false positives on
        // exotic filesystems, tighten with the provider xattr check
        // below — but on user-facing macOS setups we've never seen
        // ``st_blocks == 0 && st_size > 0`` outside File Provider.
        if blocks == 0 {
            return .dataless(logicalSize: size, provider: detectProvider(at: url))
        }

        return .local
    }

    /// Best-effort: which provider "owns" this file? Based on the
    /// xattr namespace that appears on managed files. Dropbox writes
    /// ``com.dropbox.*``; Apple's File Provider framework (and thus
    /// iCloud, OneDrive, Google Drive, Box on modern macOS) writes
    /// ``com.apple.fileprovider.*``. ``nil`` means we don't recognise
    /// it — still treat as dataless if blocks==0, just no
    /// provider-specific messaging.
    static func detectProvider(at url: URL) -> Provider? {
        let names = listXattrNames(at: url.path)
        if names.contains(where: { $0.hasPrefix("com.dropbox.") }) {
            return .dropbox
        }
        if names.contains(where: { $0.hasPrefix("com.apple.fileprovider.") }) {
            // Disambiguate between iCloud and the generic FP framework
            // by path if we can. iCloud files live under
            // ``/Library/Mobile Documents/``; everything else is
            // third-party via ``/Library/CloudStorage/…``.
            if url.path.contains("/Library/Mobile Documents/") {
                return .iCloud
            }
            if url.path.contains("/OneDrive") {
                return .oneDrive
            }
            if url.path.contains("/GoogleDrive") {
                return .googleDrive
            }
            return .appleFileProvider
        }
        return nil
    }

    // MARK: - internals

    /// Wraps ``listxattr`` to return every xattr name on a path.
    /// Empty array if the path has no xattrs or doesn't exist.
    private static func listXattrNames(at path: String) -> [String] {
        // First call with NULL/0 to get the required buffer size,
        // then again with a real buffer. XATTR_SHOWCOMPRESSION=0
        // because we want the full (non-compressed) listing.
        let needed = path.withCString { cPath in
            Darwin.listxattr(cPath, nil, 0, 0)
        }
        guard needed > 0 else { return [] }

        var buf = [CChar](repeating: 0, count: Int(needed))
        let actual = path.withCString { cPath -> ssize_t in
            buf.withUnsafeMutableBufferPointer { bp in
                Darwin.listxattr(cPath, bp.baseAddress, bp.count, 0)
            }
        }
        guard actual > 0 else { return [] }

        // listxattr returns a NUL-delimited sequence of names.
        var names: [String] = []
        var start = 0
        for i in 0..<Int(actual) where buf[i] == 0 {
            let bytes = buf[start..<i].map { UInt8(bitPattern: $0) }
            if let name = String(bytes: bytes, encoding: .utf8), !name.isEmpty {
                names.append(name)
            }
            start = i + 1
        }
        return names
    }
}
