// Linux-only thin Swift wrapper around the inotify syscalls. Used by
// ``INotifyWatcher`` to subscribe to filesystem-change events on
// ``sync_dir``. Wrapped in ``#if os(Linux)`` because Glibc isn't
// available on macOS, and inotify itself is a Linux kernel feature
// with no kqueue / FSEvents equivalent.
//
// Why a wrapper rather than calling Glibc directly from the watcher:
// the inotify event buffer is a packed sequence of variable-length
// records (``struct inotify_event`` has a flex array member ``name[]``
// of up to ``len`` bytes), which is awkward to express in Swift. We
// pull the parsing into one place so the watcher can iterate
// ``[Event]`` like any other source.

#if os(Linux)
import Glibc
import Foundation

/// Single decoded inotify event. The ``mask`` is the bitwise-or of
/// IN_* constants from ``sys/inotify.h``; the watcher consults
/// ``Mask`` (below) for the bits it cares about.
struct InotifyEvent: Sendable {
    let wd: Int32
    let mask: UInt32
    let cookie: UInt32
    let name: String
}

/// Symbolic IN_* mask values. Glibc exposes them as ``CInt`` macros;
/// we mirror them here as ``UInt32`` for Swift bitfield ergonomics.
/// Definitions tracked from ``include/uapi/linux/inotify.h`` (kernel)
/// — stable since Linux 2.6.
enum InotifyMask {
    static let access:        UInt32 = 0x0000_0001
    static let modify:        UInt32 = 0x0000_0002
    static let attrib:        UInt32 = 0x0000_0004
    static let closeWrite:    UInt32 = 0x0000_0008
    static let closeNoWrite:  UInt32 = 0x0000_0010
    static let open:          UInt32 = 0x0000_0020
    static let movedFrom:     UInt32 = 0x0000_0040
    static let movedTo:       UInt32 = 0x0000_0080
    static let create:        UInt32 = 0x0000_0100
    static let delete:        UInt32 = 0x0000_0200
    static let deleteSelf:    UInt32 = 0x0000_0400
    static let moveSelf:      UInt32 = 0x0000_0800
    static let unmount:       UInt32 = 0x0000_2000
    static let qOverflow:     UInt32 = 0x0000_4000
    static let ignored:       UInt32 = 0x0000_8000
    static let isDir:         UInt32 = 0x4000_0000

    /// Mask used by the watcher when calling ``inotify_add_watch``.
    /// Captures the events we translate into push/delete/rename and
    /// the self-events we use to keep our ``wd → URL`` map tidy.
    /// ``IN_DONT_FOLLOW`` (0x02000000) prevents inotify from
    /// auto-following symlinks — important because the daemon's
    /// path-containment check (``PathUtilities.resolvedRelativePath``)
    /// already canonicalises symlinks; double-handling here would
    /// emit events for paths that don't even live under sync_dir.
    static let watcherMask: UInt32 =
        modify | create | delete |
        movedFrom | movedTo |
        moveSelf | deleteSelf |
        0x0200_0000  // IN_DONT_FOLLOW
}

enum INotifyError: Error, CustomStringConvertible {
    case initFailed(errno: Int32)
    case addWatchFailed(path: String, errno: Int32)
    case readFailed(errno: Int32)

    var description: String {
        switch self {
        case .initFailed(let e):
            return "inotify_init1 failed: errno=\(e)"
        case .addWatchFailed(let p, let e):
            return "inotify_add_watch(\(p)) failed: errno=\(e)"
        case .readFailed(let e):
            return "inotify read failed: errno=\(e)"
        }
    }
}

/// Owns the inotify fd and exposes add/remove/read primitives. NOT
/// Sendable on purpose — the fd is a single resource and the
/// watcher confines all calls to its event-handling DispatchSource.
final class INotify {
    /// Linux kernel default for ``fs.inotify.max_user_watches`` is
    /// 8192. Big sync trees blow through this; the daemon logs a
    /// warning at startup if the watch count gets close.
    static let recommendedMaxWatches: Int = 8192

    let fd: Int32

    init() throws {
        // O_NONBLOCK + O_CLOEXEC. inotify_init1 takes the same flag
        // bits as ``open``. Non-blocking so the DispatchSourceRead
        // can drain without stalling the dispatch worker; CLOEXEC so
        // we don't leak the fd into rmapi subprocesses.
        let fd = inotify_init1(Int32(O_NONBLOCK | O_CLOEXEC))
        guard fd >= 0 else {
            throw INotifyError.initFailed(errno: errno)
        }
        self.fd = fd
    }

    deinit {
        close(fd)
    }

    /// Add a watch on ``path`` with the given mask. Returns the
    /// kernel-assigned watch descriptor; the watcher maps these back
    /// to URLs in its own dictionary.
    func addWatch(path: String, mask: UInt32 = InotifyMask.watcherMask) throws -> Int32 {
        let wd = path.withCString { cPath in
            inotify_add_watch(fd, cPath, mask)
        }
        guard wd >= 0 else {
            throw INotifyError.addWatchFailed(path: path, errno: errno)
        }
        return wd
    }

    /// Remove a watch by descriptor. Idempotent; returns rather than
    /// throwing on EINVAL because the kernel can drop watches on its
    /// own (e.g. on file deletion) and we shouldn't crash if a stale
    /// wd shows up.
    func removeWatch(wd: Int32) {
        _ = inotify_rm_watch(fd, wd)
    }

    /// Read whatever events are queued. Returns an empty array when
    /// the fd would block (no events available). Throws only on real
    /// read failures (EBADF, EFAULT, etc.).
    ///
    /// Buffer size: 16 kB holds ~512 average events. The kernel will
    /// emit ``IN_Q_OVERFLOW`` if the per-fd queue fills before
    /// readers drain it; the watcher recovers by full-rescanning.
    func readEvents(bufferSize: Int = 16 * 1024) throws -> [InotifyEvent] {
        var buf = [UInt8](repeating: 0, count: bufferSize)
        let n = buf.withUnsafeMutableBufferPointer { bp -> Int in
            read(fd, bp.baseAddress, bp.count)
        }
        if n < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK { return [] }
            throw INotifyError.readFailed(errno: errno)
        }
        if n == 0 { return [] }

        // Walk the buffer: each record starts with a 16-byte fixed
        // header followed by ``len`` name bytes (NUL-padded; ``len``
        // may be 0 for events on the watched dir itself).
        var events: [InotifyEvent] = []
        var offset = 0
        let headerSize = 16
        while offset + headerSize <= n {
            let wd = buf.withUnsafeBufferPointer { bp -> Int32 in
                bp.baseAddress!.advanced(by: offset)
                    .withMemoryRebound(to: Int32.self, capacity: 1) { $0.pointee }
            }
            let mask = buf.withUnsafeBufferPointer { bp -> UInt32 in
                bp.baseAddress!.advanced(by: offset + 4)
                    .withMemoryRebound(to: UInt32.self, capacity: 1) { $0.pointee }
            }
            let cookie = buf.withUnsafeBufferPointer { bp -> UInt32 in
                bp.baseAddress!.advanced(by: offset + 8)
                    .withMemoryRebound(to: UInt32.self, capacity: 1) { $0.pointee }
            }
            let len = buf.withUnsafeBufferPointer { bp -> UInt32 in
                bp.baseAddress!.advanced(by: offset + 12)
                    .withMemoryRebound(to: UInt32.self, capacity: 1) { $0.pointee }
            }

            let nameStart = offset + headerSize
            let nameEnd = nameStart + Int(len)
            guard nameEnd <= n else { break }

            // Names are NUL-padded to a multiple of 8; trim trailing NULs.
            let nameSlice = buf[nameStart..<nameEnd]
            let nameBytes = nameSlice.prefix { $0 != 0 }
            let name = String(decoding: nameBytes, as: UTF8.self)

            events.append(InotifyEvent(wd: wd, mask: mask, cookie: cookie, name: name))
            offset = nameEnd
        }
        return events
    }
}

#endif
