# Homebrew formula for rmsync.
#
# This file lives in the main repo for reference and testing
# (`brew install --build-from-source ./Formula/rmsync.rb` from inside
# a clone). For the public tap, copy this file into the tap repo —
# see docs/HOMEBREW.md for the full setup.
#
# Bumping versions:
#   1. Push a new `vX.Y.Z` tag on this repo.
#   2. Update `url` below to point at the new tag's source tarball.
#   3. Run `brew fetch --build-from-source rmsync` and copy the SHA
#      reported after "Already downloaded" into `sha256`.
#   4. Commit to the tap repo.
#
# Or, if you set up the GitHub Actions workflow in
# `.github/workflows/release.yml`, step 2–3 are done for you on tag push.

class Rmsync < Formula
  desc "Bidirectional macOS ↔ reMarkable tablet Markdown sync daemon"
  homepage "https://github.com/madhavsuresh/rmsync"
  url "https://github.com/madhavsuresh/rmsync/archive/refs/tags/v0.2.22.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"
  head "https://github.com/madhavsuresh/rmsync.git", branch: "main"

  # Brew audit expects a specific dep order: build-time deps first,
  # then runtime formula deps, then OS constraints.

  # Swift 6+ lives in Xcode 16. Command-line tools work too but brew
  # can't enforce that distinction.
  depends_on xcode: ["16.0", :build]

  # rmapi is required at runtime; we shell out to it for all cloud access.
  # io41/tap maintains a recent formula for the Go binary.
  depends_on "io41/tap/rmapi"

  depends_on macos: :ventura

  def install
    cd "swift" do
      # Bake the Homebrew-known version into both targets' Version.swift
      # before compilation. The source file ships with ``"dev"`` as a
      # placeholder for local ``swift build`` users; brew installs
      # produce binaries that self-identify as the tag version at
      # ``rmsync --version`` and on the menu bar's version line.
      #
      # The pattern is anchored on ``let current`` (rather than the
      # bare ``"dev"`` literal) so doc-comment mentions of ``"dev"``
      # aren't rewritten. inreplace errors out if the literal isn't
      # present, which is the check we want — a future refactor that
      # renames ``current`` will fail loudly here instead of shipping
      # a mystery-version binary.
      %w[Sources/rmsync/Version.swift Sources/rmsync-menubar/Version.swift].each do |path|
        inreplace path,
                  'static let current: String = "dev"',
                  "static let current: String = \"#{version}\""
      end

      system "swift", "build",
             "--disable-sandbox",
             "-c", "release",
             "--arch", "arm64",
             "--arch", "x86_64"

      # Universal-binary output lives under .build/apple for multi-arch
      # builds; SPM switches layouts silently based on --arch flags.
      release = if Dir[".build/apple/Products/Release/*"].any?
        ".build/apple/Products/Release"
      else
        ".build/release"
      end

      bin.install "#{release}/rmsync"
      bin.install "#{release}/rmsync-menubar"
    end

    # Ship plist templates, assets, and docs so the post-install helper
    # can render real plists into ~/Library/LaunchAgents.
    pkgshare.install "scripts"
    pkgshare.install "assets"
    doc.install Dir["docs/*.md"]
    doc.install "README.md"

    # Render a tiny helper that installs the two launchd agents. We
    # generate it here so it has the right opt_bin path baked in.
    (bin/"rmsync-install-agents").write agent_installer_script
    chmod 0755, bin/"rmsync-install-agents"

    # Paired uninstaller — matches what uninstall.sh does, minus the
    # source-tree cleanup that doesn't apply to brew installs.
    (bin/"rmsync-uninstall-agents").write agent_uninstaller_script
    chmod 0755, bin/"rmsync-uninstall-agents"
  end

  def post_install
    # After an upgrade the new binary sits at
    # ``#{opt_bin}/rmsync``, but launchd holds the OLD binary mmap'd
    # in memory because the process never exits — ``KeepAlive`` only
    # restarts on crash. Users would keep running the previous
    # version's code indefinitely (we hit this at v0.2.0 → v0.2.4
    # and it silently masked a data-loss fix). Kick both agents if
    # they're bootstrapped so the new binary gets loaded.
    #
    # Fresh installs: neither label is bootstrapped yet — the
    # ``launchctl print`` guard no-ops cleanly. Users finish setup
    # via ``rmsync-install-agents`` as usual.
    uid = Process.uid.to_s
    %w[com.user.rmsync com.user.rmsync.menubar].each do |label|
      domain = "gui/#{uid}/#{label}"
      # ``launchctl print`` exits 0 iff the label is bootstrapped.
      # We don't care about the printed payload — only the exit code.
      next unless quiet_system "/bin/launchctl", "print", domain

      # ``-k`` sends SIGTERM (fallback SIGKILL after 5s), then
      # bootstraps the label again. Same PID label; new process,
      # new exec → new on-disk binary gets loaded.
      quiet_system "/bin/launchctl", "kickstart", "-k", domain
    end
  end

  def caveats
    <<~EOS
      rmsync ships a sync daemon and a separate menu bar app. Neither
      is started by `brew install` — you finish setup in three steps:

        1. Authenticate rmapi (one-time per Mac):
             rmapi
           Paste the 8-char code from
             https://my.remarkable.com/device/desktop/connect

        2. Install and boot both launchd agents:
             rmsync-install-agents

        3. Verify:
             rmsync doctor
             rmsync status

      The default sync dir is ~/rmsync-writing. Move it anywhere
      (iCloud, Dropbox, a git repo) with:
          rmsync relocate ~/path/to/new/dir

      To tear down later — ORDER MATTERS:
          rmsync-uninstall-agents    # first, while the helper still exists
          brew uninstall rmsync      # then this
      If you reverse the order, launchd will keep trying to relaunch a
      deleted binary. Recover by removing the plists manually from
      ~/Library/LaunchAgents/.

      Full operational guide:
          #{doc}/USAGE.md

      Single-file context for LLM help:
          #{doc}/LLM_CONTEXT.md
    EOS
  end

  test do
    # `--help` exits 0 on argument-parser-based CLIs and prints a
    # subcommand list. Enough to prove the binary loads its dynamic
    # libraries cleanly.
    help = shell_output("#{bin}/rmsync --help")
    assert_match "status", help
    assert_match "doctor", help
    assert_match "relocate", help

    # Menu bar is a GUI binary — running it would open a NSStatusItem
    # in a sandboxed brew test shell. Just check the file is executable.
    assert_predicate bin/"rmsync-menubar", :executable?
  end

  private

  # --- helpers --------------------------------------------------------

  # Renders a shell script that generates both plists with correct
  # paths and bootstraps them via launchctl. Idempotent; safe to re-run.
  def agent_installer_script
    <<~SH
      #!/bin/sh
      # Generated by the rmsync Homebrew formula. Writes both launchd
      # agent plists into ~/Library/LaunchAgents and bootstraps them.
      set -eu

      DAEMON_BIN="#{opt_bin}/rmsync"
      MENUBAR_BIN="#{opt_bin}/rmsync-menubar"
      TEMPLATES="#{pkgshare}/scripts"
      LA="$HOME/Library/LaunchAgents"
      UID_NUM=$(id -u)

      mkdir -p "$LA" \\
               "$HOME/Library/Logs/rmsync" \\
               "$HOME/Library/Application Support/rmsync" \\
               "$HOME/.config/rmsync" \\
               "$HOME/rmsync-writing"

      # Seed a default config if missing. Mirrors install.sh's block so
      # source-install and brew-install converge on the same defaults.
      if [ ! -f "$HOME/.config/rmsync/config.toml" ]; then
        echo "Writing default config to $HOME/.config/rmsync/config.toml"
        cat > "$HOME/.config/rmsync/config.toml" <<TOML
      # rmsync configuration. Restart the daemon after edits:
      #   rmsync restart

      sync_dir      = "$HOME/rmsync-writing"
      remote_folder = "Writing"

      worker_pool_size               = 3
      poll_interval_seconds          = 30
      poll_active_interval_seconds   = 15
      poll_idle_interval_seconds     = 120
      debounce_seconds               = 2.0
      echo_fence_seconds             = 5.0
      retry_max_attempts             = 3

      # native_plain: plain text only (recommended)
      # native_formatted: experimental, not fully implemented
      # pdf: read-only on tablet, not fully implemented
      push_strategy = "native_plain"

      backup_snapshots_to_keep = 30
      dry_run                  = false

      [log]
      level = "INFO"   # DEBUG | INFO | WARNING | ERROR

      # Optional: drop-folder for sending PDFs / EPUBs to the tablet.
      # Drop a file into ``local_dir``, the daemon pushes it to
      # ``remote_folder`` on the cloud, then (by default) removes it
      # from local. Uncomment to enable.
      # [inbox]
      # local_dir         = "$HOME/rmsync-writing/_inbox"
      # remote_folder     = "Inbox"
      # delete_after_push = true

      # Optional: web dashboard at http://127.0.0.1:7878.
      # [web]
      # enabled    = true
      # bind_addr  = "127.0.0.1"
      # port       = 7878

      # Optional: rename / move / delete propagation. OFF by default.
      # When enabled, deletes and renames propagate both ways. Local
      # files soft-delete into <sync_dir>/.rmsync-trash first;
      # 'rmsync trash list / restore' recovers them. The bulk-delete
      # brake caps the blast radius of an accidental 'rm -rf'.
      # [deletion]
      # enable_propagation         = false
      # trash_retention_days       = 30
      # bulk_delete_threshold      = 0.5
      # bulk_delete_window_seconds = 30
      TOML
        echo "  Edit it if you want sync_dir somewhere other than ~/rmsync-writing"
        echo "  (or run 'rmsync relocate <new-path>' after the daemon comes up)."
      fi

      render() {
        # $1 template, $2 destination, $3 binary path
        sed -e "s|__HOME__|$HOME|g" \\
            -e "s|__RMSYNC_BIN__|$3|g" \\
            -e "s|__MENUBAR_BIN__|$3|g" \\
            "$1" > "$2"
      }

      render "$TEMPLATES/com.user.rmsync.swift.plist.template" \\
             "$LA/com.user.rmsync.plist" "$DAEMON_BIN"
      render "$TEMPLATES/com.user.rmsync.menubar.plist.template" \\
             "$LA/com.user.rmsync.menubar.plist" "$MENUBAR_BIN"

      # bootout-then-bootstrap, with a tiny retry loop to dodge the
      # launchd teardown race.
      boot() {
        label=$1
        launchctl bootout "gui/$UID_NUM/$label" 2>/dev/null || true
        n=0
        while ! launchctl bootstrap "gui/$UID_NUM" "$LA/$label.plist" 2>/dev/null; do
          n=$((n + 1))
          if [ $n -ge 20 ]; then
            echo "failed to bootstrap $label after $n attempts" >&2
            return 1
          fi
          sleep 0.25
        done
      }
      boot com.user.rmsync
      boot com.user.rmsync.menubar

      echo "rmsync agents installed and started."
      echo "Next: rmsync doctor"
    SH
  end

  def agent_uninstaller_script
    <<~SH
      #!/bin/sh
      # Stops both agents and removes their plists. Leaves your state,
      # config, logs, and synced files untouched.
      set -eu

      LA="$HOME/Library/LaunchAgents"
      UID_NUM=$(id -u)

      for label in com.user.rmsync com.user.rmsync.menubar; do
        launchctl bootout "gui/$UID_NUM/$label" 2>/dev/null || true
        rm -f "$LA/$label.plist"
      done

      echo "rmsync agents removed."
      echo "State/config/logs are still at:"
      echo "  ~/.config/rmsync/"
      echo "  ~/Library/Application Support/rmsync/"
      echo "  ~/Library/Logs/rmsync/"
      echo "Delete those manually if you want a full wipe."
    SH
  end
end
