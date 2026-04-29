// FileProvider.swift's dataless detection is macOS-only. Linux stub
// returns ``.local`` for any non-empty file, so these tests would
// trivially pass without exercising real semantics.
#if os(macOS)
import Foundation
import Testing
@testable import rmsync

/// Covers ``FileProvider.status(of:)`` — the authoritative detector
/// for "is this file a File Provider dataless placeholder?" that the
/// push-side guard relies on. Any regression here would undo the
/// primary data-loss defense against Dropbox / iCloud / OneDrive /
/// Google Drive / Box eviction.
///
/// We can't easily synthesise a real dataless placeholder in a unit
/// test (that would require a real File Provider provider extension
/// evicting our test file), so we exercise the "regular local
/// file", "genuinely empty file", and "missing file" paths, plus the
/// enum value-ops. The dataless path is verified manually against
/// actual evicted files from the user's machine and documented in
/// the source comment.
@Suite("FileProvider placeholder detection")
struct FileProviderDetectionTests {

    private func makeTmpDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rmsync-fileprovider-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("regular local file is classified .local")
    func regularFileIsLocal() throws {
        let dir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("hello.md")
        try "hello world\nmore bytes to ensure blocks > 0\n".write(
            to: f, atomically: true, encoding: .utf8
        )
        let status = FileProvider.status(of: f)
        #expect(status == .local)
        #expect(!status.isDataless)
    }

    @Test("zero-byte file is classified .empty (not dataless)")
    func zeroByteIsEmpty() throws {
        let dir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("empty.md")
        try "".write(to: f, atomically: true, encoding: .utf8)
        let status = FileProvider.status(of: f)
        #expect(status == .empty)
        #expect(!status.isDataless)
    }

    @Test("missing file is classified .missing")
    func missingFile() {
        let bogus = URL(fileURLWithPath: "/tmp/definitely-does-not-exist-\(UUID().uuidString).md")
        let status = FileProvider.status(of: bogus)
        #expect(status == .missing)
        #expect(!status.isDataless)
    }

    @Test("provider detection: unrecognised xattrs return nil")
    func providerNone() throws {
        let dir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("note.md")
        try "content\n".write(to: f, atomically: true, encoding: .utf8)
        // File has no cloud-provider xattrs. detectProvider returns nil,
        // which downstream code maps to a generic "cloud-storage
        // provider" phrase in the notification.
        #expect(FileProvider.detectProvider(at: f) == nil)
    }

    @Test("Status equality works across cases with different payloads")
    func statusEquatable() {
        #expect(FileProvider.Status.local == .local)
        #expect(FileProvider.Status.empty == .empty)
        #expect(FileProvider.Status.missing == .missing)
        #expect(FileProvider.Status.dataless(logicalSize: 100, provider: .dropbox)
                == .dataless(logicalSize: 100, provider: .dropbox))
        #expect(FileProvider.Status.dataless(logicalSize: 100, provider: .dropbox)
                != .dataless(logicalSize: 200, provider: .dropbox))
        #expect(FileProvider.Status.dataless(logicalSize: 100, provider: .dropbox)
                != .dataless(logicalSize: 100, provider: .iCloud))
        #expect(FileProvider.Status.local != .empty)
    }

    @Test("all Provider cases have human-readable names")
    func providerNames() {
        // These strings get inlined into user-visible notifications;
        // regressions in the names would ship confusing banners.
        #expect(FileProvider.Provider.dropbox.rawValue == "Dropbox")
        #expect(FileProvider.Provider.iCloud.rawValue == "iCloud Drive")
        #expect(FileProvider.Provider.oneDrive.rawValue == "OneDrive")
        #expect(FileProvider.Provider.googleDrive.rawValue == "Google Drive")
        #expect(FileProvider.Provider.appleFileProvider.rawValue == "macOS File Provider")
    }

    @Test("isDataless convenience only fires for .dataless case")
    func isDatalessConvenience() {
        #expect(!FileProvider.Status.local.isDataless)
        #expect(!FileProvider.Status.empty.isDataless)
        #expect(!FileProvider.Status.missing.isDataless)
        #expect(FileProvider.Status.dataless(logicalSize: 42, provider: nil).isDataless)
        #expect(FileProvider.Status.dataless(logicalSize: 42, provider: .dropbox).isDataless)
    }
}

#endif

