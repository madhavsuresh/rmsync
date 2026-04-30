# Homebrew formula for ddvk/rmapi (the Go binary rmsync shells out to).
#
# Lives in this tap so we can pin a specific rmapi version that we've
# end-to-end tested against rmsync. The upstream io41/tap formula has
# repeatedly lagged behind cloud-side API changes — most recently the
# 2026-04 schema-v4 rollout that broke every put on rmapi <0.0.32 with
# HTTP 400 (see ddvk/rmapi#58, rmsync v0.2.23 release notes).
#
# This formula installs prebuilt binaries from ddvk's GitHub releases.
# We don't build from source because:
#   - the upstream Go module needs network at build time for some deps;
#   - prebuilt darwin/arm64 + darwin/x86_64 zips are published on every
#     ddvk release and have stable, predictable URLs;
#   - sha256-pinning the zips keeps supply-chain provenance honest.
#
# Bumping versions:
#   1. Update `version` below.
#   2. Update both `sha256` values from the new release's macOS zips.
#      Compute via:
#        curl -sL https://github.com/ddvk/rmapi/releases/download/vX.Y.Z/rmapi-macos-arm64.zip | shasum -a 256
#        curl -sL https://github.com/ddvk/rmapi/releases/download/vX.Y.Z/rmapi-macos-intel.zip | shasum -a 256
#   3. Commit to the tap repo.
#
# A scheduled workflow in the tap repo
# (`.github/workflows/rmapi-bump.yml`) automates steps 1–3 by polling
# ddvk/rmapi's latest tag once a day and opening a PR when a new
# release ships. Manual bumps remain valid for emergencies.

class Rmapi < Formula
  desc "Go CLI for the reMarkable cloud (used by rmsync)"
  homepage "https://github.com/ddvk/rmapi"
  version "0.0.32"
  license "MIT"

  on_macos do
    on_arm do
      url "https://github.com/ddvk/rmapi/releases/download/v#{version}/rmapi-macos-arm64.zip"
      sha256 "839dc2f1c78ee9457f61b920a99b4aad1d2e97f24f6aad52a2eab9f501eb7682"
    end
    on_intel do
      url "https://github.com/ddvk/rmapi/releases/download/v#{version}/rmapi-macos-intel.zip"
      sha256 "60f2506903303cc25a4af1716b314c6ba56c10789082abcf6a5c8a11cfd586f2"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/ddvk/rmapi/releases/download/v#{version}/rmapi-linux-arm64.tar.gz"
      sha256 "6e5ced303da31989786c5bf6abd933202c046576722a3fe0d89e2fa50e0ea102"
    end
    on_intel do
      url "https://github.com/ddvk/rmapi/releases/download/v#{version}/rmapi-linux-amd64.tar.gz"
      sha256 "088f02260c06164801463f28fc636af82743763ded9dc5085bd58fd3b417b93b"
    end
  end

  # Conflicts with the upstream io41/tap formula. Both ship the same
  # `rmapi` binary; brew refuses to install both. Existing users on
  # io41/tap need to ``brew uninstall io41/tap/rmapi`` first.
  conflicts_with "io41/tap/rmapi", because: "both install the same `rmapi` binary"

  def install
    # The zip extracts a single file named ``rmapi``. tar.gz on Linux
    # does the same. Either way the binary lands in the cwd; we just
    # move it to bin.
    bin.install "rmapi"
  end

  test do
    # ``rmapi version`` exits 0 even without auth, prints a version
    # string. Verifies the binary loads its dynamic libraries cleanly
    # and the ``version`` subcommand parses.
    out = shell_output("#{bin}/rmapi version")
    assert_match(/v?\d+\.\d+\.\d+/, out)
  end
end
