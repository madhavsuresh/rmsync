import Foundation

/// Unit of work enqueued from the poller / watcher / startup reconcile.
/// Ports ``src/rm_sync/jobs.py``.
struct Job: Sendable, Equatable {
    enum Kind: String, Sendable { case pull, push, deleteRemote, deleteLocal, renameRemote }

    let kind: Kind
    /// reMarkable doc ID, when known. New-doc pushes arrive with nil.
    let docID: String?
    /// For PULL/RENAME this carries the remote path. For PUSH it's the
    /// local path we're sending up. For the delete kinds it's whichever
    /// path is relevant to the kind.
    let hint: String
}
