import Foundation

/// Unit of work enqueued from the poller / watcher / startup reconcile.
/// Ports ``src/rm_sync/jobs.py``.
struct Job: Sendable, Equatable {
    enum Kind: String, Sendable {
        case pull, push, deleteRemote, deleteLocal, renameRemote
        /// The cloud poller noticed a tracked doc whose remote_path
        /// has changed. The worker moves the local file to the new
        /// path (after seeding the echo fence so the resulting
        /// watcher event for the move is suppressed) and updates
        /// state.db. Symmetric counterpart to ``renameRemote``.
        case renameLocal
        /// User created a directory inside ``sync_dir``. Worker
        /// mirrors it on the cloud via ``cloud.mkdir``. ``hint`` is
        /// the absolute local directory path; the worker derives
        /// the cloud-side path via
        /// ``PathUtilities.localToRemoteParentChain``. Non-
        /// destructive — runs unconditionally even when
        /// ``deletion.enable_propagation`` is false.
        case mkdirRemote
        /// User removed an empty directory inside ``sync_dir``.
        /// Worker mirrors the removal on the cloud via
        /// ``cloud.rm``, but only after a defensive empty-on-cloud
        /// check (so a partially-propagated cascade doesn't
        /// trash docs whose deletes are still in flight).
        /// Destructive — gated on ``deletion.enable_propagation``.
        case rmdirRemote
        /// Push a non-Markdown file (PDF / EPUB) from the configured
        /// inbox directory to ``inbox.remote_folder`` on the cloud.
        /// Distinct from ``push`` because it bypasses the Markdown
        /// pipeline (no rmdoc packing, no state.db tracking, no
        /// echo-fence concerns) and goes directly to ``rmapi put``.
        case pushInbox
    }

    let kind: Kind
    /// reMarkable doc ID, when known. New-doc pushes arrive with nil.
    let docID: String?
    /// For PULL/RENAME this carries the remote path. For PUSH it's the
    /// local path we're sending up. For the delete kinds it's whichever
    /// path is relevant to the kind. For PUSH_INBOX it's the local PDF /
    /// EPUB path.
    let hint: String
}
