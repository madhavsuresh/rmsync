import Foundation

/// Single source of truth for this binary's version string.
///
/// The literal ``"dev"`` is intentional: local ``swift build`` produces
/// a binary that self-identifies as ``dev``, which is honest for
/// uncommitted / untagged work.
///
/// Homebrew installs rewrite this literal before building — see the
/// ``inreplace`` block in ``Formula/rmsync.rb``. ``rmsync-menubar``
/// carries a parallel copy of this file; both files share the same
/// ``"dev"`` literal so a single ``inreplace`` call covers both
/// targets.
enum Version {
    static let current: String = "dev"
}
