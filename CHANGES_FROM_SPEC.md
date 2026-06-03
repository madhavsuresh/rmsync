# Deviations from the original design prompt

**Status:** historical implementation notes. Some sections describe
pre-explicit-sync daemon behavior and are not current operational
documentation. For current behavior, use `README.md`, `docs/USAGE.md`,
and `docs/LLM_CONTEXT.md`: sync mutations are explicit through
`rmsync pull`, `rmsync diff`, `rmsync accept`, `rmsync push`, and
`rmsync force-push`.

These are deliberate changes made during scaffolding. Each addresses a
specific issue identified in spec review. If you're reading the original
prompt and the code disagrees, the code is the source of truth.

## State schema

**Spec:** `last_pull_md_hash` and `last_push_md_hash` as separate columns.
**Here:** single `last_synced_md_hash` updated after every successful pull
*and* every successful push.

Reason: with two hashes, the conflict-detection rule
`L = sha256(local) != last_push_md_hash` evaluated TRUE for every doc that
had been pulled but never edited locally — because `last_push_md_hash` was
either NULL or referred to an old push. One unified hash makes the
"unchanged since last sync" check correct in both directions.

Added columns: `error_state TEXT NULL` ('parse_failed' | 'push_validation_failed'
| NULL) so a single bad document parks itself instead of crashing the worker
loop.

## Page-break sentinel

**Spec:** split multi-page notebooks on `^---$`.
**Here:** split on `^<!-- rmsync:page-break -->$`.

Reason: `---` is a valid Markdown horizontal rule. Users will write it for
legitimate reasons and get phantom page splits. The HTML-comment sentinel
is invisible in rendered Markdown and unique to us.

## Strategy A formatting policy

**Spec:** ambiguous about whether pulled formatting (`# `, `- `, `**bold**`)
survives a push under `native_plain`.
**Here:** explicit. `native_plain` pushes the file content verbatim as plain
text. `# Heading` becomes literal `# Heading` text on the tablet. Pulled
formatting prefixes are lost on the next push cycle.

The pull side still emits formatted Markdown so the local file is pleasant
to read and edit. Users who want round-trip formatting must opt into
`native_formatted` (and accept the experimental writer warning).

## No IPC layer

**Spec:** `ipc.py` exposing a Unix-socket server for CLI subcommands.
**Here:** dropped. The CLI reads SQLite in `?mode=ro` and uses sentinel
files (`paused`, `resync.<doc_id>`) to signal the daemon.

Reason: `pause` was already sentinel-based per spec; the rest only need to
read state or trigger a behavior the daemon polls for. A socket server adds
a process surface, lifecycle bugs, and test infrastructure for no real gain.

## No standalone PID lockfile

**Spec:** mentioned a "launchd PID lockfile" without a defined role.
**Here:** removed. launchd enforces single-instance via the agent label.

## Echo fence is seeded before the watcher starts

**Spec:** echo fence is populated when the worker writes a file. In a fresh
sync, the watcher would be running before any worker writes existed, so the
initial pull's N file creates would all fire spurious push events.
**Here:** the watcher starts *after* the initial reconciliation pull
completes. The `LocalWatcher.start()` call is sequenced after
`SyncEngine.initial_reconcile()` in `daemon.py`.

The hash check in the push path remains the load-bearing defense; the fence
is an optimization to keep the queue clean.

## Initial sync caps rmapi concurrency

**Spec:** worker pool of 3 × `RMAPI_CONCURRENT=20` default = up to 60
concurrent reMarkable requests during initial pull.
**Here:** during `initial_reconcile`, `RMAPI_CONCURRENT=5` is forced via
env var on the subprocess. After initial sync, the value is restored.

## Atomic local writes

All `.md` writes go through `paths.atomic_write_text` which writes
`<path>.tmp` and `os.replace`s into place. Prevents the watcher (and the
user's editor) from observing a half-written file.

## Doctor check #10 dropped

**Spec:** "warn if many docs haven't changed `version` in 60 days while
tablet seems active" as a soft subscription check.
**Here:** dropped. Distinguishes poorly between "subscription expired" and
"user doesn't edit old notes" and produces noise. If the cloud is serving
requests, the subscription is fine.

## Trash-restore semantics

If the user moves a file from `.rmsync-trash/` back into `sync_dir`, the
daemon treats it as a brand-new local document and pushes it with a new
UUID. The original (cloud-trashed) document is not re-linked. This is
documented behavior; restoration via the tablet's own trash UI is the
supported path for un-deleting cloud-side.

## §16 open questions — resolved against real cloud

See `scripts/cloud_probe.py` and `scripts/cloud_probe2.py` for the
experiments. Account: user's real reMarkable account, SyncVersion 1.5,
rmapi v0.0.32.

**Q1 — `put --content-only` update semantics: WRONG FLAG.**
The spec's recommended `rmapi put --content-only doc.rmdoc <path>` is
**PDF-only**. rmapi errors: `--content-only can only be used with PDF
files`. The correct flag for .rmdoc updates is `--force`.

- Plain `rmapi put foo.rmdoc /folder` errors with `entry already exists`
  if there is already a doc at that name.
- `rmapi put --force foo.rmdoc /folder` replaces in place. **Document
  UUID is stable** across repeated `--force` updates — verified across 4
  uploads, same ID every time.
- The doc_id we pack into the .rmdoc is honored by the cloud (the cloud
  doesn't rewrite it). This is what makes stable-ID updates possible.
- Content round-trips cleanly: pulling back after 4 updates returned the
  4th version's page text.

Action taken: `Cloud.put(update=True)` maps to `put --force`. Worker
calls `put` without `update` for new docs, with `update=True` for
updates. `SAFE_PUSH_VERIFIED = True` in worker.py.

**Q2 — `Version` field under sync15: NOT USABLE.**
Under sync15 the `Version` field returned by `stat` is **pinned to 0**
on updates. Across 4 `put --force` uploads with different content,
`stat` returned `Version: 0` every time. `ModifiedClient` (RFC3339,
1-second precision) IS monotonic and is the only usable change signal.

Action taken: the poller keys change-detection on `ModifiedClient`, not
`Version`. The state schema's `remote_version` column is retained but
unused for change detection (kept in case a future rmapi version exposes
sync15 content hashes).

**Bonus correction: `rmapi find --json` doesn't exist.**
The spec assumed `find /Writing --json`. rmapi v0.0.32 has no such flag
— `find` and `ls` emit plain `[d]\t<name>` / `[f]\t<name>` text. `stat`
returns JSON on stdout (inside the interactive shell). Cloud.tree() now
drives the walk via `find` text parsing + one `stat` per entry.

**Bonus quirk: `ls <empty-folder>` falls back to root listing.**
Witnessed: `ls /Writing` (empty folder) returned the root's children
instead of an empty listing. `find <empty-folder>` correctly returns
just the folder itself. Cloud.tree() uses `find` exclusively for this
reason; `Cloud.ls()` is kept for interactive debugging but isn't on the
daemon hot path.

## Bugs fixed during first end-to-end run

These were spec-ambiguous or downstream mistakes found while actually
driving the daemon against the real cloud.

**rmapi uses the .rmdoc FILENAME as the cloud doc name, not the packed
``visibleName``.** Worker originally built ``<doc_id>.rmdoc`` in the
temp dir, so every push created a cloud doc named after a random UUID.
Combined with the cascade bug below, this spawned ~20 phantom docs in
the user's Writing folder within a minute. Fixed: archive file is now
named ``<visible_name>.rmdoc``.

**Poller and worker computed different local paths from the same
remote path.** Poller filtered empty segments before stripping the
remote_folder prefix; worker did it in the opposite order. Result: for
``/Writing/foo``, poller computed ``~/rmsync-writing/foo.md`` while
worker computed ``~/rmsync-writing/Writing/foo.md``. The path mismatch
looked like a remote rename on every poll cycle, which triggered a
rename job on every cycle. Fixed: single ``paths.remote_to_local``
helper used by both sides.

**sync15 .content JSON uses ``cPages.pages[].id``, not ``pages[]``.**
``archive.unpack`` only knew the legacy flat shape, so cloud-downloaded
.rmdocs parsed to 0 pages — every pulled file was written as 0 bytes.
Fixed: ``_extract_page_ids`` accepts both shapes.

**FSEvents delivers events for writes done just before Observer start.**
Initial-pull file creates fired as spurious push events in the first
1-2 seconds after the watcher started. The fence is the first line of
defense but its window is bounded. Second line of defense is
``worker._push`` refusing to push from any path outside the sync_dir
root, from a hidden dir (``.rmsync-trash``), or from a path whose
stem looks like a UUID (cascade guard).

**DELETE_LOCAL with unset doc_id used to be silently dropped.** It's
now dispatched to ``_note_local_gone``, which logs at WARNING but does
NOT propagate a deletion to the cloud. Destructive cloud actions
driven by a single unverified watcher event are too risky in v0.1.
Deletes-from-the-tablet (poller-side tombstones) still work.

**Cloud deletions should move local files to ``.rmsync-trash/`` only;
they must not fire further push events.** Walking the trash dir is
already excluded in the watcher's ``_should_ignore``.

**``coverPageNumber: 0`` makes the tablet prepend a blank cover page.**
Set in packer to -1, matching tablet-native notebooks. Partial fix —
see below for the real cause.

**Legacy flat ``pages: [id, ...]`` in ``.content`` causes the tablet
to auto-insert a blank template page.** The real cause of the blank
prepended page. rmapi accepts our uploaded legacy shape and stores it
as-is on the cloud — multiple ``put --force`` updates from the desktop
side all keep ``pageCount: 1`` in legacy format. But when the
**tablet** syncs the doc, it converts to sync15 ``cPages`` and prepends
a ``template: "Blank"`` entry to normalize the structure. Fix: pack
directly in sync15 ``cPages`` shape with ``idx`` fractional-index
values, matching what the tablet expects. Repeated ``--force`` updates
of a sync15-shaped doc stay at ``pageCount: 1`` cloud-side.

**Legacy-pushed docs need to be recreated, not updated.** Any doc the
daemon pushed before the sync15 pack fix has tainted ``cPages`` state
on the cloud that persists across ``--force`` updates. Fix: delete the
cloud doc entirely (``rmapi rm /Writing/<name>``) and re-push fresh.

**Page UUIDs must be REUSED across pushes of the same doc.** Even with
sync15 ``cPages`` shape, generating a new ``page_id`` for each update
causes the cloud to treat each id as a distinct page in the CRDT
history. Result: cPages grows by one entry per push, but only the
latest page has a ``.rm`` file — the rest become ghost entries that the
tablet renders as blank pages. Fix: track ``page_ids`` in the state DB
(schema v2, new JSON column on ``documents``) and reuse them on every
push. Recorded during pull (from rmscene-parsed rmdoc) and on new-doc
push. Verified end-to-end: 3 consecutive daemon-driven pushes of the
same file kept ``pageCount: 1`` and the same page UUID cloud-side.

**CRDT ``author_uuid`` must be stable across pushes of the same install.**
Observed symptom: after daemon pushes, the tablet AND the cloud showed
text like ``eeddiitteedd  ccoonntteenntt  vveerrssiioonn  34`` —
character-by-character interleave of the last two versions. Root cause:
``rmscene.simple_text_document`` generates a new random ``author_uuid``
on every call, but uses a FIXED ``item_id=CrdtId(1, 16)`` for the text
blob. The tablet's CRDT engine saw "two different authors both wrote
something at position (1, 16)" and merged by interleaving. When the
SAME author_uuid is used, the tablet treats each push as "same author
updating its own item" and replaces cleanly. Fix: schema v3 adds a
``settings`` table; worker calls
:py:meth:`State.get_or_create_author_uuid` on first push, persists the
UUID, and threads it through to :py:func:`md_to_rm.page_native_plain`.
Verified: multiple back-to-back pushes (v1 → v2 → "v3 much longer text
here") each fully replaced the prior text cloud-side, no interleave.

## Open after first run (not blocking v0.1)

- rmscene emits noisy WARNING-level logs for block types it doesn't
  fully parse (the pull still succeeds). We suppress the ``rmscene.*``
  loggers to ERROR. If rmscene upgrades and genuinely fails to parse,
  the worker's ``RmParseError`` path catches it.
- The local→remote delete path is intentionally disabled. Re-enable
  once rename-detection (§7 of the original prompt) has a test harness.
- ``config.push_strategy = "native_plain"`` is byte-stable for plain
  content but the cloud's sync15 stores slight metadata decorations
  (``cPages`` structure, modification timestamps) that make exact
  .rmdoc-level round-trip impossible. The MARKDOWN text round-trips
  cleanly; the binary doesn't, which is fine.
