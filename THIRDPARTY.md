# Third-party components

rmsync is MIT-licensed (see [LICENSE](LICENSE)). It bundles one
third-party source tree in-repo, depends on three Swift packages fetched
by SwiftPM at build time, and invokes one external binary at runtime.
Every piece is covered by a permissive or weakly-copyleft license
compatible with MIT redistribution.

## In-repo (vendored source)

### `swift/Sources/RMScene/`
- **Upstream**: [github.com/ricklupton/rmscene-swift](https://github.com/ricklupton/rmscene-swift)
  (a Swift port of [rmscene](https://github.com/ricklupton/rmscene), the
  reference implementation of the reMarkable v6 `.rm` CRDT codec)
- **Author**: Rick Lupton
- **License**: MIT
- **License text**: [swift/Sources/RMScene/LICENSE](swift/Sources/RMScene/LICENSE)

The files in that directory are vendored verbatim. The upstream MIT
notice is preserved alongside the code. Do not edit those files in a way
that changes the licensing story without updating the upstream notice.

## Swift package dependencies (resolved at build)

These are pulled by SwiftPM from their canonical locations; no source
is redistributed in this repo. Users who build from source (including
via `brew install`) pull them transitively.

| Package | Version constraint | License | Upstream |
|---|---|---|---|
| `swift-argument-parser` | `from: 1.4.0` | Apache-2.0 | [apple/swift-argument-parser](https://github.com/apple/swift-argument-parser) |
| `GRDB.swift` | `from: 7.0.0` | MIT | [groue/GRDB.swift](https://github.com/groue/GRDB.swift) |
| `TOMLDecoder` | `from: 0.2.2` | MIT | [dduan/TOMLDecoder](https://github.com/dduan/TOMLDecoder) |

See `swift/Package.resolved` for pinned versions at any given tag.

## Runtime dependency (not redistributed)

### `rmapi`
- **Upstream**: [github.com/ddvk/rmapi](https://github.com/ddvk/rmapi)
- **Author**: Claudio "ddvk" (and contributors)
- **License**: **AGPL-3.0**
- **How rmsync uses it**: rmsync shells out to the `rmapi` binary via
  `Subprocess.run(executablePath: "rmapi", ...)` for every cloud read
  and write. rmsync does not link to rmapi's source, does not embed
  rmapi's binary, and does not redistribute either.

### Why AGPL-3.0 does not copyleft rmsync

AGPL-3.0's copyleft reaches a work only when that work **combines**
(links or statically embeds) AGPL code, or modifies and distributes it.
Invoking a separately-installed binary via `subprocess` is the textbook
definition of *aggregation* — the FSF's own guidance
([gnu.org/licenses/gpl-faq](https://www.gnu.org/licenses/gpl-faq.html#MereAggregation))
treats "two programs, one pipe or subprocess invocation between them"
as independent works.

Users install `rmapi` separately (typically `brew install io41/tap/rmapi`,
as recommended by rmsync's Formula and `rmsync doctor`). Anything they
do with rmapi itself — modify, redistribute, etc. — is governed by
AGPL-3.0. Anything they do with rmsync is governed by MIT.

If you are uncomfortable with AGPL-3.0 runtime dependencies for your own
downstream reasons, the rmsync source is structured so that the `Cloud`
layer is the sole rmapi consumer: swap it for any other implementation
that speaks the same protocol and you've fully detached from AGPL.

## Summary for redistributors

You can fork, modify, bundle, or resell rmsync under MIT terms so long as:

1. The top-level [LICENSE](LICENSE) is included (MIT attribution to
   Madhav Suresh).
2. [swift/Sources/RMScene/LICENSE](swift/Sources/RMScene/LICENSE) is
   preserved if you keep the vendored code (MIT attribution to Rick
   Lupton).
3. You do not bundle `rmapi` binaries or source alongside the
   redistribution unless you accept AGPL-3.0 for that bundled copy. Tell
   users to install rmapi themselves (the rmsync Formula does this via
   `depends_on "io41/tap/rmapi"`).

Nothing else is restricted.
