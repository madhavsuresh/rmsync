import Foundation
import Testing
@testable import rmsync

/// Tests for ``CloudHealthProbe.classify`` — the stateless
/// error-pattern classifier that replaced the canary-write
/// probe in v0.2.29.
///
/// Why this matters: the menubar's "Why is sync broken?" menu
/// reads ``s.cloudHealth`` to decide whether to show
/// "rmapi missing" / "auth broken" / "this might be an rmapi
/// issue". A wrong classification confuses the user. So we pin
/// representative error strings to the buckets they should land
/// in.
@Suite("CloudHealthProbe (stateless classifier)")
struct CloudHealthProbeTests {
    private struct StringError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    // MARK: - rmapi missing

    @Test("subprocess 'no such file' on rmapi → rmapiMissing")
    func rmapiMissing() {
        let err = StringError(message: "subprocess: launchPath /usr/local/bin/rmapi: no such file or directory")
        #expect(CloudHealthProbe.classify(err).classification == .rmapiMissing)
    }

    @Test("'rmapi: command not found' → rmapiMissing")
    func rmapiMissingShellNotFound() {
        let err = StringError(message: "rmapi: command not found")
        #expect(CloudHealthProbe.classify(err).classification == .rmapiMissing)
    }

    // MARK: - auth broken

    @Test("'Refresh token is not set' → authBroken")
    func authRefreshToken() {
        let err = StringError(message: "Error: Refresh token is not set, please run rmapi to authenticate first.")
        #expect(CloudHealthProbe.classify(err).classification == .authBroken)
    }

    @Test("HTTP 401 → authBroken")
    func auth401() {
        let err = StringError(message: "request failed with status 401 unauthorized")
        #expect(CloudHealthProbe.classify(err).classification == .authBroken)
    }

    @Test("HTTP 403 → authBroken")
    func auth403() {
        let err = StringError(message: "request failed with status 403 forbidden")
        #expect(CloudHealthProbe.classify(err).classification == .authBroken)
    }

    // MARK: - rmapi compat break

    @Test("'request failed with status 400' → rmapiCompatBreak")
    func compat400() {
        // The 2026-04 schema-v4 break's error wording.
        let err = StringError(message:
            "rmapi put --force /tmp/foo.rmdoc /Writing exited 1: " +
            "ERROR: Error: failed to upload file [/tmp/foo.rmdoc] " +
            "request failed with status 400")
        let result = CloudHealthProbe.classify(err)
        #expect(result.classification == .rmapiCompatBreak)
        // Detail should include user-actionable text.
        #expect(result.detail.contains("This might be an rmapi issue"))
        #expect(result.detail.contains("github.com/ddvk/rmapi/issues"))
    }

    @Test("'failed to delete existing file' (--force path) → rmapiCompatBreak")
    func compatForceDelete() {
        let err = StringError(message:
            "ERROR: failed to delete existing file: request failed with status 400")
        #expect(CloudHealthProbe.classify(err).classification == .rmapiCompatBreak)
    }

    @Test("'failed to create directory' (mkdir path) → rmapiCompatBreak")
    func compatMkdir() {
        let err = StringError(message:
            "ERROR: failed to create directory request failed with status 400")
        #expect(CloudHealthProbe.classify(err).classification == .rmapiCompatBreak)
    }

    @Test("HTTP 4xx that isn't 401/403 → rmapiCompatBreak")
    func compatGeneric4xx() {
        let err = StringError(message: "request failed with status 422")
        #expect(CloudHealthProbe.classify(err).classification == .rmapiCompatBreak)
    }

    // MARK: - unknown fall-through

    @Test("network timeout → unknown (don't claim rmapi-side fault)")
    func unknownTimeout() {
        // Timeouts could be local network issues, not rmapi.
        // Don't misclassify as compat break.
        let err = StringError(message: "context deadline exceeded")
        let result = CloudHealthProbe.classify(err)
        #expect(result.classification == .unknown)
        // The raw error gets surfaced for bug-reporting.
        #expect(result.detail.contains("context deadline exceeded"))
    }

    @Test("fresh-install rmapi error (TOC-like) → unknown")
    func unknownFreshInstall() {
        let err = StringError(message: "no entries found")
        #expect(CloudHealthProbe.classify(err).classification == .unknown)
    }

    // MARK: - rawValue stability (IPC wire format)

    @Test("classification rawValue stable for IPC wire format")
    func rawValuesStable() {
        // The menubar IPC code matches on raw string values; pin
        // them so a future enum rename doesn't silently break the
        // menubar's diagnostic UI.
        #expect(CloudHealthProbe.Classification.ok.rawValue == "ok")
        #expect(CloudHealthProbe.Classification.rmapiMissing.rawValue == "rmapi_missing")
        #expect(CloudHealthProbe.Classification.authBroken.rawValue == "auth_broken")
        #expect(CloudHealthProbe.Classification.rmapiCompatBreak.rawValue == "rmapi_compat_break")
        #expect(CloudHealthProbe.Classification.unknown.rawValue == "unknown")
    }
}
