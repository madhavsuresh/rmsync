// Tiny shim layer for POSIX symbols whose Swift-importable types
// differ between Darwin and Glibc.
//
// ``SOCK_STREAM`` is the canonical example: Darwin imports it as a
// plain ``Int32`` literal while Glibc imports it as a member of an
// ``__socket_type`` enum. The 3-arg ``socket(2)`` call needs an
// ``Int32`` for the type parameter, so on Linux we have to coerce
// through ``.rawValue``.
//
// Lives inside the ``IPC`` directory because the only callers are
// the IPC-server / client / tests, but it's fine to grow this file
// if other POSIX divergences turn up.

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if os(Linux)
/// Linux: ``SOCK_STREAM`` is a ``__socket_type`` enum; raw value is
/// the same numeric constant POSIX defines (1).
let SOCK_STREAM_I32: Int32 = Int32(SOCK_STREAM.rawValue)
#else
/// Darwin: ``SOCK_STREAM`` is already ``Int32`` — assignment is a
/// no-op type-wise; the named constant just keeps callsites
/// platform-agnostic.
let SOCK_STREAM_I32: Int32 = SOCK_STREAM
#endif
