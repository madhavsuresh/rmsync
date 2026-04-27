# Testing rmsync

Three layers, in increasing cost:

| Layer | Catches | Effort |
|---|---|---|
| Unit + offline integration tests (`swift test`) | Logic errors, regression of fixed bugs | Free, runs on every CI push |
| Live-cloud smoke test against a dedicated test account | Push/pull roundtrip breaks, rmapi compat issues | One-time secret setup; runs on every push to main |
| **`scripts/fresh-install-test.sh`** on dev's own Mac | Missing seeded state, install-helper gaps | 90s per run |
| Guest-user macOS account install | TCC permissions, Finder integration, FSEvents on a stranger's tree | 5–10 minutes per attempt |

If a bug surfaces on a tester's fresh install but not on yours, it's
almost always something that depends on accumulated state — your
config exists, your TCC permissions are granted, your daemon was
already running. Layers 3 and 4 are how you catch those before
shipping.

---

## Layer 1: offline tests

```sh
cd swift && swift test --no-parallel
```

Runs on every PR + every push to main via `.github/workflows/ci.yml`.
105+ tests covering archive packing, conflict marker generation, file
provider detection, IPC, page codec roundtrip, path utilities,
relocate, state DB schema migration, watcher ignore rules.

What this DOESN'T cover: anything that actually shells out to `rmapi`.
For that, you need…

---

## Layer 2: live-cloud smoke test

The test suite contains `CloudSmokeTests` and `PushSmokeTests` —
both gated behind `RMSYNC_LIVE=1` because they write probe documents
to a real reMarkable cloud account. Locally:

```sh
cd swift
RMSYNC_LIVE=1 swift test --no-parallel --filter '(?i)(cloud|push)'
```

Probe docs go into `/rmsync-test` and are cleaned up before each
test exits. Don't point this at your personal reMarkable account —
the suite assumes it owns the `/rmsync-test` folder and may delete
its contents.

### CI live-smoke setup (one-time)

The CI live-smoke job in `.github/workflows/ci.yml` runs the same
suite on every push to main, against a reMarkable account whose
auth token is stored as a repo secret.

**Decision: which account?**

In theory you'd use a "test" reMarkable account separate from your
personal one, but in practice reMarkable's auth flow only issues
codes for accounts bound to an activated tablet. You can't make a
codeless test account without owning a second tablet. The realistic
choice for most users:

**Use your personal account.** The risk profile for a personal repo:

- The secret is encrypted at rest in GitHub Actions and only decoded
  inside ephemeral runners.
- The workflow reads the conf, runs auth verification (without
  echoing the email — see workflow comments), and runs the live
  smoke tests against `/rmsync-test/` only.
- If the secret somehow did leak, the consequence is rmapi-level
  access to your reMarkable cloud — same blast radius as if your
  laptop were stolen with rmapi already authed. Rotate by
  disconnecting the desktop client at
  https://my.remarkable.com/list/desktop and re-authing.

Tests intentionally only touch `/rmsync-test/` (well-isolated from
your real `/Writing/` tree) and clean up after themselves.

**The one-line setup:**

```sh
base64 -i "$HOME/Library/Application Support/rmapi/rmapi.conf" \
  | gh secret set TEST_RMAPI_CONFIG --repo madhavsuresh/rmsync
```

(Path note: rmapi on macOS stores its config at
`~/Library/Application Support/rmapi/rmapi.conf` — the Go-native
`os.UserConfigDir()` location. On Linux it lives at
`~/.config/rmapi/rmapi.conf`. The CI workflow seeds both locations
on the runner so it works either way.)

That's it. Your existing already-authed `rmapi.conf` becomes the
CI test fixture.

**Verifying**

On the next push to main, the `live-smoke` job runs. Look for:

- Job skipped with notice "TEST_RMAPI_CONFIG not configured" → secret
  isn't seeing your value, double-check you saved it.
- Job fails at the auth verification step → token is invalid; rotate.
- Job passes → live cloud smoke is now active.

### Rotating the token

If the token invalidates (you disconnect the desktop client, or
reMarkable issues a security-driven invalidation), reauth locally
and refresh the secret:

```sh
rmapi   # reauth interactively
base64 -i "$HOME/Library/Application Support/rmapi/rmapi.conf" \
  | gh secret set TEST_RMAPI_CONFIG --repo madhavsuresh/rmsync
```

---

## Layer 3: fresh-install-test.sh

```sh
./scripts/fresh-install-test.sh
```

What it does:

1. Stops the running rmsync agents.
2. **Moves** (not deletes) your config, state, logs, and sync_dir to
   `/tmp/rmsync-backup-<timestamp>/`.
3. `brew uninstall rmsync && brew install madhavsuresh/rmsync/rmsync`.
4. Runs `rmsync-install-agents` on the empty machine state.
5. Runs `rmsync doctor` — fails out if anything is ✗.
6. Pushes a probe `.md` file and waits up to 60s for it to appear on
   the cloud via `rmapi find /Writing`.
7. Cleans up the probe doc.
8. Restores your original state from the backup.

If the smoke test fails at any point, the backup is left in place
and the path is printed. Restore manually:

```sh
./scripts/fresh-install-test.sh --restore-from /tmp/rmsync-backup-20260427-153022
```

Useful flags:

- `-y` — non-interactive
- `--no-cloud-test` — skip the cloud probe (faster, less coverage)
- `--no-restore` — leave the fresh install in place; useful for
  reproducing a tester's bug interactively

### What this catches

- Missing seeded state: every change that adds a default file or dir
  to `rmsync-install-agents` should pass after this script.
  Specifically, the v0.2.10 missing-config bug would have failed at
  step 5 (doctor would report sync_dir-or-config missing).
- Helper script regressions: if a future change to the formula's
  `agent_installer_script` skips a directory or boots the wrong
  binary, doctor surfaces it.
- Push path on an empty state.db: the cloud probe in step 6 exercises
  the full local-edit → push → cloud-visible pipeline against a state
  DB the daemon just initialized.

### What this DOESN'T catch

- TCC permissions. The dev's machine has Full Disk Access already
  granted to the daemon (via prior runs); a stranger's wouldn't.
- Login Keychain prompts that fire on first daemon launch.
- iCloud / Dropbox / OneDrive cloud-storage interactions if your
  sync_dir is inside one.
- macOS UI behaviors (Finder folder icon, Notification Center).

For those, see Layer 4.

---

## Layer 4: guest-user macOS account

The gold-standard fresh-install reproduction. About 10 minutes the
first time.

### Setup

1. **Create a test user**:
   `System Settings → Users & Groups → Add User`. Pick "Standard"
   (not Admin) so TCC behavior matches a typical user.

2. **Log out**, log back in as the test user. Don't switch via
   Fast User Switching — `launchctl gui/<uid>` domains differ
   per session-type and you want a real Aqua login session.

3. **Install rmapi auth fresh** for the test user:
   ```sh
   brew install io41/tap/rmapi
   rmapi
   # Use a separate test reMarkable account (same one as
   # TEST_RMAPI_CONFIG, ideally) — don't auth your personal
   # account from a non-admin macOS user.
   ```

4. **Install rmsync**:
   ```sh
   brew install madhavsuresh/rmsync/rmsync
   rmsync-install-agents
   rmsync doctor
   ```

5. **Roundtrip test**:
   - Touch `~/rmsync-writing/probe.md`, write content, save.
   - Wait ~10s.
   - On your tablet, swipe down on the home screen to force sync.
   - Verify the doc appears in the Writing folder.
   - Edit the doc on the tablet.
   - Wait up to 2 minutes for `rmsync sync-now` to pull the change.
   - Verify the local file updated.

### What this catches that Layer 3 doesn't

- TCC prompts: "rmsync wants to access files in Documents" if your
  sync_dir is under one of macOS's protected dirs. This prompt
  blocks the first sync if not granted.
- Login Keychain prompts on first daemon launch.
- Notification permissions.
- Finder integration: does the folder icon show? Does Get Info show
  the rmsync xattr metadata?

### Cleanup

Delete the test user via System Settings → Users & Groups. Confirm
you also want to delete their home directory.

---

## Reproducing a specific tester's bug

When a tester reports a bug, the fastest reproduction path is:

1. Have them run `rmsync logs --diagnose` and paste the output.
2. If the issue is sync-related, also `rmsync doctor` and `rmsync status`.
3. If the bug is fresh-install-related (missing config, wrong default,
   etc.), reproduce locally with `./scripts/fresh-install-test.sh`.
4. If the bug looks TCC- or session-related, reproduce on a
   guest-user account.

Most "works on dev machine, broken on tester" bugs in rmsync's
history have been Layer 3 — accumulated state issues — and can be
reproduced in 90 seconds.
