import Foundation

/// Install a custom Finder icon on the sync folder.
///
/// Port of ``src/rm_sync/native/macos.py:ensure_folder_icon``. Apple's
/// documented layout:
///
///   <folder>/Icon?             the literal filename 'Icon\\r'
///   <folder>/Icon?   xattr     com.apple.FinderInfo with kIsInvisible (0x4000)
///   <folder>         xattr     com.apple.FinderInfo with kHasCustomIcon (0x0400)
///
/// The FinderInfo xattr is a 32-byte structure; we only need the flag
/// word at offset 8 (big-endian u16). Everything else stays zero.
///
/// Idempotent: if the sentinel xattr is already present and the
/// ``Icon\r`` file exists, returns without touching disk.
enum FolderIcon {
    private static let folderFlagCustomIcon: UInt16 = 0x0400
    private static let fileFlagInvisible: UInt16 = 0x4000

    /// Install the icon on ``folder``. ``icnsSource`` overrides the
    /// bundled default (``assets/folder-icon.icns``). Does nothing if
    /// the icon is already set or the asset can't be located.
    static func ensure(folder: URL, icnsSource: URL? = nil) {
        do {
            if try alreadySet(folder: folder) { return }
            let src = icnsSource ?? bundledIcon()
            guard let src, FileManager.default.fileExists(atPath: src.path) else {
                Logger.shared.debug(
                    "folder icon asset missing; skipping",
                    meta: ["folder": folder.path]
                )
                return
            }

            let iconFile = folder.appendingPathComponent("Icon\r")
            try? FileManager.default.removeItem(at: iconFile)
            try FileManager.default.copyItem(at: src, to: iconFile)

            try Xattrs.setRaw(
                path: iconFile, name: Xattrs.finderInfo,
                value: finderInfo(flags: fileFlagInvisible)
            )
            try Xattrs.setRaw(
                path: folder, name: Xattrs.finderInfo,
                value: finderInfo(flags: folderFlagCustomIcon)
            )
            Logger.shared.info("folder icon installed", meta: ["folder": folder.path])
        } catch {
            Logger.shared.debug(
                "folder icon setup failed",
                meta: ["folder": folder.path, "error": "\(error)"]
            )
        }
    }

    // MARK: - internals

    private static func alreadySet(folder: URL) throws -> Bool {
        let iconFile = folder.appendingPathComponent("Icon\r")
        guard FileManager.default.fileExists(atPath: iconFile.path) else { return false }
        do {
            let info = try Xattrs.getRaw(path: folder, name: Xattrs.finderInfo)
            guard info.count >= 10 else { return false }
            let flags: UInt16 = (UInt16(info[8]) << 8) | UInt16(info[9])
            return (flags & folderFlagCustomIcon) != 0
        } catch {
            return false
        }
    }

    /// Build the 32-byte FinderInfo structure. Only the flag word at
    /// offset 8 is non-zero.
    private static func finderInfo(flags: UInt16) -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        bytes[8] = UInt8(flags >> 8)
        bytes[9] = UInt8(flags & 0xFF)
        return Data(bytes)
    }

    /// Locate ``assets/folder-icon.icns``. The installed layout puts it
    /// at ``<repo>/assets/folder-icon.icns``; adjust once we ship a
    /// proper app bundle.
    private static func bundledIcon() -> URL? {
        // 1. Check the assets dir alongside the Swift sources (useful
        //    when running ``swift run`` from the repo root).
        let repoCandidate = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Native
            .deletingLastPathComponent()  // rmsync
            .deletingLastPathComponent()  // Sources
            .deletingLastPathComponent()  // swift
            .appendingPathComponent("assets/folder-icon.icns")
        if FileManager.default.fileExists(atPath: repoCandidate.path) {
            return repoCandidate
        }
        // 2. Fall back to ``~/code/rm/assets/folder-icon.icns`` for the
        //    current dev layout. Week 7 (installer) will drop the icns
        //    next to the binary and use that path instead.
        let home = FileManager.default.homeDirectoryForCurrentUser
        let devCandidate = home.appendingPathComponent("code/rm/assets/folder-icon.icns")
        if FileManager.default.fileExists(atPath: devCandidate.path) {
            return devCandidate
        }
        return nil
    }
}
