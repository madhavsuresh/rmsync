# Shipping rmsync via Homebrew

You do this once, per-release. The short version:

1. **Create a tap repo.** `github.com/<you>/homebrew-rmsync`.
2. **Copy `Formula/rmsync.rb`** from this repo into the tap repo.
3. **Tag a release** here (`git tag v0.2.0 && git push origin v0.2.0`).
4. **Update `url` and `sha256`** in the tap's formula to match the tag.
5. **Users install with** `brew install <you>/rmsync/rmsync`.

The `release.yml` GitHub Action automates steps 3–4 once you've set up
a token. This doc explains the pieces.

---

## 1. Create the tap repository

Tap repos follow a strict naming convention. For `brew install
<you>/rmsync/rmsync` to resolve, the tap repo MUST be named
`homebrew-rmsync` under your GitHub user or org. Brew strips the
`homebrew-` prefix when printing.

```sh
gh repo create <you>/homebrew-rmsync --public --clone --description "Homebrew tap for rmsync"
cd homebrew-rmsync
mkdir Formula
cp ../rmsync/Formula/rmsync.rb Formula/
git add Formula/rmsync.rb
git commit -m "Initial formula for rmsync v0.2.0"
git push
```

That's the entire tap. No other files required (a `README.md`
explaining what the tap is for is polite but optional).

## 2. Replace placeholders in the formula

The formula has three `<GH_USER>` placeholders and a dummy `sha256`.
Search and replace once before first release:

```sh
# inside the tap repo
GH_USER=your-github-username
sed -i '' "s|<GH_USER>|$GH_USER|g" Formula/rmsync.rb
```

The `sha256` you fill in the next step, after tagging.

## 3. Tag a release on the main repo

```sh
# inside the main rmsync repo
git tag -a v0.2.0 -m "Initial Homebrew-compatible release"
git push origin v0.2.0
```

GitHub auto-generates a source tarball at:

```
https://github.com/<you>/rmsync/archive/refs/tags/v0.2.0.tar.gz
```

## 4. Compute the SHA and update the formula

```sh
curl -sL https://github.com/<you>/rmsync/archive/refs/tags/v0.2.0.tar.gz \
  | shasum -a 256
# prints:  <sha256>  -
```

Paste that SHA into the tap's `Formula/rmsync.rb` `sha256` line,
commit, push:

```sh
cd ~/src/homebrew-rmsync
$EDITOR Formula/rmsync.rb  # paste the SHA
git commit -am "rmsync v0.2.0"
git push
```

## 5. Test the install locally

```sh
brew tap <you>/rmsync
brew install --build-from-source rmsync
rmsync --version
rmsync-install-agents
rmsync doctor
```

If any of those fail, iterate on the formula and do a `brew reinstall
rmsync` until clean.

For full uninstall during iteration:

```sh
rmsync-uninstall-agents
brew uninstall rmsync
```

---

## Automating releases (optional)

`.github/workflows/release.yml` in this repo runs on every `v*` tag
push and:

1. Builds a universal release binary on `macos-14`.
2. Runs the non-live test suite.
3. Creates a GitHub Release with a pre-built tarball attached.
4. Opens a PR on the tap repo that bumps `url` + `sha256`.

Step 4 needs a secret. In the main repo's Settings → Secrets and
variables → Actions, add:

| Name | Value |
|---|---|
| `TAP_REPO_TOKEN` | A fine-grained PAT with Contents:write and Pull requests:write on the `<you>/homebrew-rmsync` repo |

Without the secret, the workflow skips the bump-formula job silently
— you do steps 4 manually each release.

### Creating the PAT

```
GitHub → Settings → Developer settings → Personal access tokens
  → Fine-grained tokens → Generate new token
    Resource owner: <you>
    Repository access: Only select repositories → homebrew-rmsync
    Repository permissions:
      Contents: Read and write
      Pull requests: Read and write
```

Copy the token into `TAP_REPO_TOKEN` on the main repo. Don't reuse it
for anything else.

---

## Handling the menu bar + daemon

Homebrew is oriented around one daemon per formula (via the `service
do` block). rmsync ships two agents (daemon + menu bar), so the
formula does neither automatically — both are installed by the
`rmsync-install-agents` helper after `brew install`.

Why not use `brew services start rmsync`?

- `brew services` writes a plist with label `homebrew.mxcl.rmsync`,
  whereas the daemon, CLI, and menu bar app all expect the label
  `com.user.rmsync`. `rmsync start/stop/restart` would all break.
- `brew services` only manages one label per formula. There's no clean
  way to start the menu bar app from the same formula.

The cost: two lines in the caveats (`rmsync-install-agents` and
`rmsync doctor`). Acceptable.

---

## Updating to a new version

On the main repo:

```sh
git tag -a v0.3.0 -m "..."
git push origin v0.3.0
```

If you configured the PAT, the Action opens a PR on the tap repo.
Review and merge. Users `brew upgrade rmsync`.

Without the PAT, update the tap manually:

```sh
cd ~/src/homebrew-rmsync
sed -i '' 's/v0.2.0/v0.3.0/g' Formula/rmsync.rb
# new sha:
curl -sL https://github.com/<you>/rmsync/archive/refs/tags/v0.3.0.tar.gz \
  | shasum -a 256
$EDITOR Formula/rmsync.rb   # paste new sha256
git commit -am "rmsync v0.3.0"
git push
```

---

## Developing against the brew install

If you're using the brew-installed daemon day-to-day but still editing
source in this repo, every change has to round-trip through
`origin/main` — `brew install --HEAD` clones the remote, not your
working tree. `scripts/dev-reinstall.sh` wraps the full loop:

```sh
./scripts/dev-reinstall.sh -m "Tweak the watcher debounce"
```

That expands to:

1. `git add -A && git commit -m "…"` — if you have uncommitted changes
   (`-m` is required in that case; ignored otherwise).
2. `git push` — only if `origin/main` is behind HEAD.
3. `brew upgrade --fetch-HEAD madhavsuresh/rmsync/rmsync` — refetches
   origin/main and rebuilds. Falls back to `brew uninstall + install`
   if upgrade bails out.
4. `launchctl kickstart -k gui/<uid>/com.user.rmsync` plus the same
   for `com.user.rmsync.menubar` so both agents reload the new binary.
5. `rmsync status` — quick sanity check that the daemon came up.

Useful flags:

| Flag | Effect |
|---|---|
| `--no-push` | Assume the commit is already on `origin/main` (you pushed manually). Just run the brew + launchctl steps. |
| `--skip-brew` | Commit + push only; don't touch brew or launchd. |
| `-y` | Non-interactive. |

Pre-flight: refuses to run from a non-`main` branch (brew's HEAD
install tracks `origin/main`, so iterating from another branch is a
footgun). Refuses if rmsync isn't brew-installed or the tap is
missing, with the commands to fix.

### When NOT to use this

For tight edit loops — fast typing cycles, experimenting with a
feature — the push-through-origin flow is too slow. Switch to dev
mode instead:

```sh
rmsync-uninstall-agents    # point launchd away from the brew binary
./install.sh               # rebuild + boot from ~/code/rmsync/...
```

Now `swift build -c release && rmsync restart` is your loop. Every
edit is live in under 10 seconds. Switch back to the brew path when
you're done with `rmsync-install-agents` (brew stays installed the
whole time; only the launchd plists point different places). See
`docs/USAGE.md` for the dev-install details.

---

## Testing the formula without publishing

Modern Homebrew refuses to install from a bare `.rb` file — every
formula must live under a tap. For local iteration, make a **local
tap** and symlink the formula into it:

```sh
# one-time setup
brew tap-new madhavsuresh/rmsync
ln -sf "$PWD/Formula/rmsync.rb" \
       "$(brew --repo madhavsuresh/rmsync)/Formula/rmsync.rb"

# iterate:
$EDITOR Formula/rmsync.rb
brew reinstall --build-from-source madhavsuresh/rmsync/rmsync
rmsync-install-agents
rmsync doctor
```

The symlink means edits in your checkout show up immediately — no copy
needed between iterations. `brew uninstall` + `brew untap` when you're
done.

Note: while `sha256` in the formula still points at `0000…` /
whatever the placeholder is, `brew install` will fail the checksum
check on the tagged tarball. Work around it one of two ways:

- **Add `head "https://github.com/<you>/rmsync.git"`** (already in
  the formula) and install with `--HEAD`:
    ```sh
    brew install --HEAD madhavsuresh/rmsync/rmsync
    ```
  This clones the main branch at install time, ignoring `url`/`sha256`.

- **Tag a real release** and bump the SHA. See the "Handling a new
  version" section above.

`--HEAD` is the fastest path for iterating on the formula itself.
