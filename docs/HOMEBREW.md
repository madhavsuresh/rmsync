# Shipping rm-sync via Homebrew

You do this once, per-release. The short version:

1. **Create a tap repo.** `github.com/<you>/homebrew-rm-sync`.
2. **Copy `Formula/rm-sync.rb`** from this repo into the tap repo.
3. **Tag a release** here (`git tag v0.2.0 && git push origin v0.2.0`).
4. **Update `url` and `sha256`** in the tap's formula to match the tag.
5. **Users install with** `brew install <you>/rm-sync/rm-sync`.

The `release.yml` GitHub Action automates steps 3–4 once you've set up
a token. This doc explains the pieces.

---

## 1. Create the tap repository

Tap repos follow a strict naming convention. For `brew install
<you>/rm-sync/rm-sync` to resolve, the tap repo MUST be named
`homebrew-rm-sync` under your GitHub user or org. Brew strips the
`homebrew-` prefix when printing.

```sh
gh repo create <you>/homebrew-rm-sync --public --clone --description "Homebrew tap for rm-sync"
cd homebrew-rm-sync
mkdir Formula
cp ../rm-sync/Formula/rm-sync.rb Formula/
git add Formula/rm-sync.rb
git commit -m "Initial formula for rm-sync v0.2.0"
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
sed -i '' "s|<GH_USER>|$GH_USER|g" Formula/rm-sync.rb
```

The `sha256` you fill in the next step, after tagging.

## 3. Tag a release on the main repo

```sh
# inside the main rm-sync repo
git tag -a v0.2.0 -m "Initial Homebrew-compatible release"
git push origin v0.2.0
```

GitHub auto-generates a source tarball at:

```
https://github.com/<you>/rm-sync/archive/refs/tags/v0.2.0.tar.gz
```

## 4. Compute the SHA and update the formula

```sh
curl -sL https://github.com/<you>/rm-sync/archive/refs/tags/v0.2.0.tar.gz \
  | shasum -a 256
# prints:  <sha256>  -
```

Paste that SHA into the tap's `Formula/rm-sync.rb` `sha256` line,
commit, push:

```sh
cd ~/src/homebrew-rm-sync
$EDITOR Formula/rm-sync.rb  # paste the SHA
git commit -am "rm-sync v0.2.0"
git push
```

## 5. Test the install locally

```sh
brew tap <you>/rm-sync
brew install --build-from-source rm-sync
rmsync --version
rm-sync-install-agents
rmsync doctor
```

If any of those fail, iterate on the formula and do a `brew reinstall
rm-sync` until clean.

For full uninstall during iteration:

```sh
rm-sync-uninstall-agents
brew uninstall rm-sync
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
| `TAP_REPO_TOKEN` | A fine-grained PAT with Contents:write and Pull requests:write on the `<you>/homebrew-rm-sync` repo |

Without the secret, the workflow skips the bump-formula job silently
— you do steps 4 manually each release.

### Creating the PAT

```
GitHub → Settings → Developer settings → Personal access tokens
  → Fine-grained tokens → Generate new token
    Resource owner: <you>
    Repository access: Only select repositories → homebrew-rm-sync
    Repository permissions:
      Contents: Read and write
      Pull requests: Read and write
```

Copy the token into `TAP_REPO_TOKEN` on the main repo. Don't reuse it
for anything else.

---

## Handling the menu bar + daemon

Homebrew is oriented around one daemon per formula (via the `service
do` block). rm-sync ships two agents (daemon + menu bar), so the
formula does neither automatically — both are installed by the
`rm-sync-install-agents` helper after `brew install`.

Why not use `brew services start rm-sync`?

- `brew services` writes a plist with label `homebrew.mxcl.rm-sync`,
  whereas the daemon, CLI, and menu bar app all expect the label
  `com.user.rmsync`. `rmsync start/stop/restart` would all break.
- `brew services` only manages one label per formula. There's no clean
  way to start the menu bar app from the same formula.

The cost: two lines in the caveats (`rm-sync-install-agents` and
`rmsync doctor`). Acceptable.

---

## Updating to a new version

On the main repo:

```sh
git tag -a v0.3.0 -m "..."
git push origin v0.3.0
```

If you configured the PAT, the Action opens a PR on the tap repo.
Review and merge. Users `brew upgrade rm-sync`.

Without the PAT, update the tap manually:

```sh
cd ~/src/homebrew-rm-sync
sed -i '' 's/v0.2.0/v0.3.0/g' Formula/rm-sync.rb
# new sha:
curl -sL https://github.com/<you>/rm-sync/archive/refs/tags/v0.3.0.tar.gz \
  | shasum -a 256
$EDITOR Formula/rm-sync.rb   # paste new sha256
git commit -am "rm-sync v0.3.0"
git push
```

---

## Testing the formula without publishing

Modern Homebrew refuses to install from a bare `.rb` file — every
formula must live under a tap. For local iteration, make a **local
tap** and symlink the formula into it:

```sh
# one-time setup
brew tap-new madhavsuresh/rm-sync
ln -sf "$PWD/Formula/rm-sync.rb" \
       "$(brew --repo madhavsuresh/rm-sync)/Formula/rm-sync.rb"

# iterate:
$EDITOR Formula/rm-sync.rb
brew reinstall --build-from-source madhavsuresh/rm-sync/rm-sync
rm-sync-install-agents
rmsync doctor
```

The symlink means edits in your checkout show up immediately — no copy
needed between iterations. `brew uninstall` + `brew untap` when you're
done.

Note: while `sha256` in the formula still points at `0000…` /
whatever the placeholder is, `brew install` will fail the checksum
check on the tagged tarball. Work around it one of two ways:

- **Add `head "https://github.com/<you>/rm-sync.git"`** (already in
  the formula) and install with `--HEAD`:
    ```sh
    brew install --HEAD madhavsuresh/rm-sync/rm-sync
    ```
  This clones the main branch at install time, ignoring `url`/`sha256`.

- **Tag a real release** and bump the SHA. See the "Handling a new
  version" section above.

`--HEAD` is the fastest path for iterating on the formula itself.
