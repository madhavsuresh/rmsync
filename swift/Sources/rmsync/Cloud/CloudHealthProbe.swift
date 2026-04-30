import Foundation

/// Diagnostic probe that classifies "why is the push pipeline
/// broken?" so the user doesn't have to dig through ``stderr.log``
/// to figure out whether the bug lives in our code, in rmapi, or
/// in the cloud itself.
///
/// Background: v0.2.23 shipped HTTP-400 push-failure parking.
/// That stopped the retry loop, but the menubar still just said
/// "out of sync — N parked errors", giving no signal about
/// **whether retrying ever helps**. The schema-v4 cloud rollout
/// in 2026-04 broke rmapi (even v0.0.32) for new uploads + mkdir
/// + force-replace; until ddvk ships a fix, every retry hits
/// the same 400 and parking accumulates. The user wants to see
/// "rmapi/cloud is broken right now, your files are safe, wait
/// for upstream" rather than guess.
///
/// The probe runs:
///
///   1. ``rmapi version`` — does the binary even exist + run?
///   2. ``rmapi account`` — is auth valid? (succeeds iff a token
///      is on disk; cheap.)
///   3. A tiny ``rmapi mkdir`` against a sentinel path under
///      ``/<remoteFolder>``, followed by ``rmapi rm`` to clean
///      up. This is the canary: if mkdir 400s but account
///      worked, we've isolated the cloud-API-compat break.
///
/// Output: a single ``Classification`` value the daemon broadcasts
/// over IPC. Cached for ``cooldown`` seconds so multiple
/// concurrent push failures don't shell out 5× to rmapi —
/// classify once, reuse.
actor CloudHealthProbe {
    /// Why pushes are failing — high-level enough for the
    /// menubar to translate to user-facing text.
    enum Classification: String, Sendable, Equatable {
        /// All probes passed; failures are per-doc (e.g., the
        /// individual doc's content tripped a server-side
        /// validator) rather than systemic.
        case ok = "ok"
        /// ``rmapi version`` returned non-zero or the binary
        /// is missing. Doctor / install issue.
        case rmapiMissing = "rmapi_missing"
        /// ``rmapi account`` failed. User needs to re-auth via
        /// ``rmapi`` interactively.
        case authBroken = "auth_broken"
        /// ``rmapi version`` and ``account`` succeed but the
        /// mkdir canary fails. rmapi is talking to the cloud
        /// but the cloud rejects writes — typically an
        /// rmapi-vs-cloud-API mismatch when the cloud rolls
        /// out a schema bump that rmapi hasn't caught up to yet.
        /// Files stay parked safely; user upgrades rmapi or
        /// waits for an upstream fix. The 2026-04 schema-v4
        /// break (ddvk/rmapi#58) was the first instance; later
        /// instances will look the same to us but won't
        /// necessarily map to that specific issue.
        case rmapiCompatBreak = "rmapi_compat_break"
        /// Probe sequence didn't reach a classifying answer.
        /// E.g., rmapi version succeeds but auth probe times
        /// out without a clear yes/no.
        case unknown = "unknown"
    }

    /// One probe outcome. ``classification`` is the answer the
    /// menubar consumes; ``detail`` is human-readable text the
    /// daemon logs at info level so an operator can correlate
    /// against rmapi changelogs.
    struct Result: Sendable, Equatable {
        let classification: Classification
        let detail: String
        let probedAt: Date
    }

    private let cloud: Cloud
    private let cfg: Config
    private let cooldown: TimeInterval
    private var lastResult: Result?

    init(cloud: Cloud, cfg: Config, cooldown: TimeInterval = 600) {
        self.cloud = cloud
        self.cfg = cfg
        self.cooldown = cooldown
    }

    /// Look up the most recent classification, running a fresh
    /// probe if no cached result exists or the cached one has
    /// aged past ``cooldown``.
    func current(now: Date = Date()) async -> Result {
        if let cached = lastResult,
           now.timeIntervalSince(cached.probedAt) < cooldown {
            return cached
        }
        let fresh = await runProbe(now: now)
        lastResult = fresh
        return fresh
    }

    /// Force-invalidate the cache (e.g., on a successful push:
    /// whatever was broken evidently isn't anymore, so the next
    /// caller should get a fresh probe rather than the stale
    /// "rmapiCompatBreak" result).
    func invalidate() {
        lastResult = nil
    }

    /// For tests / `rmsync doctor` to read the latest probe
    /// without re-running it.
    func cached() -> Result? { lastResult }

    // MARK: - probe sequence

    private func runProbe(now: Date) async -> Result {
        Logger.shared.info("cloud health probe starting")

        // Step 1: rmapi version. Cheapest call; binary loads its
        // own libraries cleanly and prints a string.
        do {
            _ = try await cloud.version()
        } catch {
            return cache(.rmapiMissing,
                "rmapi binary missing or won't run: \(error)",
                at: now)
        }

        // Step 2: rmapi account. Reads the local auth token and
        // hits one HTTP endpoint. Failure means re-auth needed.
        do {
            _ = try await cloud.account()
        } catch {
            return cache(.authBroken,
                "rmapi account failed (re-auth needed): \(error)",
                at: now)
        }

        // Step 3: mkdir canary. Targets a sentinel name unlikely
        // to collide with user content, under the configured
        // ``remoteFolder`` so we exercise the same cloud subtree
        // that the worker writes to. Cleaned up via ``rm``
        // immediately on success.
        let sentinel = "/\(cfg.remoteFolder)/.rmsync-health-\(UUID().uuidString.prefix(8))"
        do {
            try await cloud.mkdir(sentinel)
        } catch {
            // Generic message — early versions hard-coded a link
            // to ddvk/rmapi#58 (the original schema-v4 break),
            // but future cloud-API rolls will produce the same
            // failure shape without mapping to that specific
            // issue. Point at the rmapi tracker as a whole and
            // let the user see what's currently filed.
            return cache(.rmapiCompatBreak,
                "rmapi can't write to the cloud (mkdir canary at \(sentinel) "
                  + "errored: \(error)). This might be an rmapi issue — "
                  + "check https://github.com/ddvk/rmapi/issues for known "
                  + "problems and recent releases. Files are parked safely; "
                  + "no data lost.",
                at: now)
        }

        // mkdir worked → we're healthy. Best-effort cleanup so
        // the sentinel folder doesn't litter the user's tablet.
        try? await cloud.rm(sentinel)

        return cache(.ok,
            "rmapi version + account + mkdir canary all OK",
            at: now)
    }

    private func cache(
        _ kind: Classification, _ detail: String, at now: Date
    ) -> Result {
        let r = Result(classification: kind, detail: detail, probedAt: now)
        lastResult = r
        Logger.shared.info(
            "cloud health probe complete",
            meta: ["classification": kind.rawValue, "detail": detail]
        )
        return r
    }
}
