import Foundation

/// Menubar-app version string. Parallel copy of
/// ``swift/Sources/rmsync/Version.swift`` — kept in this target because
/// SPM executable targets can't share source files directly without
/// promoting to a library. The Homebrew formula's single ``inreplace``
/// rewrites both files in one pass because they share the ``"dev"``
/// literal.
enum Version {
    static let current: String = "dev"
}
