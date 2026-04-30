import Foundation

/// Stateless classifier that answers "why did this push fail?"
/// from the push error itself — no extra cloud writes.
///
/// **History.** v0.2.25 introduced this as a probe actor that
/// shelled out to ``rmapi version`` → ``rmapi account`` → a
/// ``rmapi mkdir`` canary against a sentinel path. That left
/// ``.rmsync-health-<uuid>`` directories on the cloud whenever
/// the cleanup ``rmapi rm`` couldn't clean up (typically: the
/// same compat break that caused the original failure also
/// blocks the rm). Garbage piled up.
///
/// v0.2.29 simplified: by the time we'd run the probe we've
/// already had a push fail, so we already have evidence of the
/// failure mode in the original error's stderr / Swift error
/// description. Classifying that string is cheap, deterministic,
/// and writes nothing to the cloud.
///
/// Trade-off: pattern matching on stderr is fragile if rmapi
/// changes its error messages. Mitigated by:
///   - Falling through to ``unknown`` for unrecognized patterns
///     (rather than misclassifying as ``ok`` or breaking).
///   - The ``rmapi_compat_break`` arm matches several distinct
///     phrasings of the same underlying issue, so a wording
///     change in one rmapi release won't drop the whole branch.
enum CloudHealthProbe {
    /// Why a cloud operation failed — high-level enough for the
    /// menubar to translate to user-facing text.
    enum Classification: String, Sendable, Equatable {
        /// Operation succeeded — used by the *invalidate* path
        /// (a successful push clears any stale failure
        /// classification).
        case ok = "ok"
        /// rmapi binary missing or won't run. Doctor / install
        /// issue.
        case rmapiMissing = "rmapi_missing"
        /// rmapi can't authenticate against the cloud — token
        /// missing, expired, or revoked. User runs ``rmapi``
        /// interactively to re-authenticate.
        case authBroken = "auth_broken"
        /// rmapi reaches the cloud but the cloud rejects writes
        /// — typically a schema-version mismatch when the cloud
        /// rolls out an API change rmapi hasn't caught up to.
        /// User upgrades rmapi or waits for an upstream fix.
        /// First instance: 2026-04 schema-v4 break
        /// (ddvk/rmapi#58); later instances will look the same
        /// to us but won't necessarily map to that issue.
        case rmapiCompatBreak = "rmapi_compat_break"
        /// Failure pattern not recognised. Surfaced verbatim in
        /// ``cloud_health_detail`` so the user can copy-paste
        /// it to a bug report.
        case unknown = "unknown"
    }

    /// Output of ``classify``. ``classification`` drives menubar
    /// rendering; ``detail`` is the raw error text we want
    /// surfaced in ``rmsync status`` and the diagnostic alert.
    struct Result: Sendable, Equatable {
        let classification: Classification
        let detail: String
    }

    /// Inspect a thrown error's string form and bucket it.
    ///
    /// Pattern catalog (in priority order):
    ///   - "executable not found" / "no such file" with rmapi
    ///     path → ``rmapiMissing``
    ///   - "Refresh token is not set" / "401" / "403" →
    ///     ``authBroken``
    ///   - "request failed with status 4" /
    ///     "failed to upload file" /
    ///     "failed to delete existing file" /
    ///     "failed to create directory" → ``rmapiCompatBreak``
    ///   - everything else → ``unknown``
    static func classify(_ error: Error) -> Result {
        let text = "\(error)"
        let lower = text.lowercased()

        // rmapi binary missing. Subprocess.run would surface
        // this as a posix "no such file or directory" or
        // launchPath-resolution error. Keep both phrasings.
        if lower.contains("executable not found")
            || lower.contains("rmapi: command not found")
            || (lower.contains("no such file or directory")
                && lower.contains("rmapi")) {
            return Result(classification: .rmapiMissing, detail: text)
        }

        // Auth-related. rmapi prints "Refresh token is not set"
        // when the saved token is missing/expired; HTTP 401/403
        // come from the API.
        if lower.contains("refresh token")
            || text.contains("status 401")
            || text.contains("status 403")
            || lower.contains("authorization")
            || lower.contains("authentication") {
            return Result(classification: .authBroken, detail: text)
        }

        // rmapi-vs-cloud compat. Multiple distinct phrasings for
        // what's structurally the same problem (rmapi can't
        // produce a payload the cloud accepts). The 4xx range
        // with the specific failure phrasings catches the
        // current-known patterns; status 4-prefix as a fallback
        // catches future variations.
        if text.contains("request failed with status 4")
            || lower.contains("failed to upload file")
            || lower.contains("failed to delete existing file")
            || lower.contains("failed to create directory") {
            return Result(classification: .rmapiCompatBreak, detail:
                "rmapi can't write to the cloud: \(text). "
                + "This might be an rmapi issue — check "
                + "https://github.com/ddvk/rmapi/issues for known "
                + "problems and recent releases. Files are parked "
                + "safely; no data lost.")
        }

        // Everything else — surface the raw error so the user
        // can paste it into a bug report.
        return Result(classification: .unknown, detail: text)
    }

    /// Convenience used by the worker: classify the error AND
    /// take action at the StateBus level. Returns nothing — the
    /// caller doesn't need the result, only the side-effect of
    /// publishing it.
    static func classifyAndPublish(_ error: Error, on bus: StateBus) async {
        let result = classify(error)
        Logger.shared.info(
            "cloud health classified",
            meta: [
                "classification": result.classification.rawValue,
                "detail": result.detail,
            ]
        )
        await bus.update { s in
            s.cloudHealth = result.classification.rawValue
            s.cloudHealthDetail = result.detail
        }
    }

    /// Clear any cached cloud-health classification. Called from
    /// the worker on a successful push — whatever was broken
    /// evidently isn't anymore. Idempotent.
    static func clear(on bus: StateBus) async {
        await bus.update { s in
            s.cloudHealth = ""
            s.cloudHealthDetail = nil
        }
    }
}
