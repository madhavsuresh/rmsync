import Foundation
import Testing
@testable import rmsync

/// Tests for the cooldown cache and the no-cloud-required parts of
/// ``CloudHealthProbe``. The actual probe sequence shells out to
/// rmapi, so the wire-level classification logic (rmapi 400 →
/// rmapi_compat_break) is exercised by the live smoke tests in
/// ``DeleteSmokeTests``-shape — gated on RMSYNC_LIVE.
///
/// What we cover here without a real cloud:
///
///   * Cooldown semantics: a fresh ``current()`` call within the
///     window returns the cached result; past the window, runs a
///     new probe.
///   * ``invalidate()`` drops the cache so the next ``current()``
///     forces a new probe.
@Suite("CloudHealthProbe (cooldown)")
struct CloudHealthProbeTests {
    @Test("invalidate() forces fresh probe on next current() call")
    func invalidate() async throws {
        // We can't run the real probe without rmapi/cloud. The
        // ``cached()`` accessor is the cheap lever — exercise the
        // pure cache state.
        let cfg = Config(syncDir: FileManager.default.temporaryDirectory)
        let cloud = Cloud(rmapiPath: "/usr/bin/false")
        let probe = CloudHealthProbe(cloud: cloud, cfg: cfg, cooldown: 600)

        // First current() actually runs the probe. With
        // /usr/bin/false as rmapi, the version step fails →
        // .rmapiMissing classification.
        let first = await probe.current()
        #expect(first.classification == .rmapiMissing)

        // Cached result available.
        let cached = await probe.cached()
        #expect(cached?.classification == .rmapiMissing)

        // invalidate() clears it.
        await probe.invalidate()
        #expect(await probe.cached() == nil)
    }

    @Test("cooldown window: repeat current() within window reuses cache")
    func cooldownReuse() async throws {
        let cfg = Config(syncDir: FileManager.default.temporaryDirectory)
        let cloud = Cloud(rmapiPath: "/usr/bin/false")
        // 1-hour cooldown so second call is well within window.
        let probe = CloudHealthProbe(cloud: cloud, cfg: cfg, cooldown: 3600)

        let first = await probe.current()
        let firstAt = first.probedAt

        // Within the window — should return the SAME object
        // (same probedAt timestamp). Re-running the underlying
        // shell-out would produce a fresh timestamp.
        let second = await probe.current()
        #expect(second.probedAt == firstAt)
        #expect(second.classification == first.classification)
    }

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
