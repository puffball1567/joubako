# Implementation Status

This file maps the delivery order in `vision.md` to the current implementation.

| Area | Status | Notes |
| --- | --- | --- |
| Common request/response/error contracts | Complete | `Future[JResult[T]]`, structured errors, cancellation, deadlines, limits, synchronous and backpressured asynchronous progress consumers |
| FlowBrigade resilience | Complete | Async retry, circuit breaker, token-bucket rate limit, bulkhead |
| HTTP(S) and JSON | Complete | Keep-alive reuse, bounded idle pool, streaming limit checks, redirects, typed JSON |
| Typed query, headers, body APIs | Complete | JSON, URL-encoded form, multipart, raw bytes-as-string |
| Promise-style composition | Complete | Result-aware `then`, typed `catch`, `finally`, heterogeneous two-operation `all` |
| NIF/BIF through NIFKit | Deferred | Deliberately postponed |
| Local IPC | Complete on POSIX | Unix domain sockets with a bounded framed protocol |
| In-process transport | Complete | Deterministic handler transport |
| WebSocket | Complete | One-shot transport plus long-lived connection primitives |
| Cross-platform CI | Complete | Linux, macOS, Windows; Nim 2.2.0 and stable |
| Native allocation leak probe | Complete | Valgrind, ARC, `-d:useMalloc`, zero bytes at exit on success and error paths |
| Memory model | Complete | Public failures settle into values; project builds and tests with deterministic ARC |

## Security contracts

- TLS certificate validation remains enabled by default.
- Total, connection/header, and per-body-read timeouts are independent.
- Cancellation closes active HTTP, IPC, and WebSocket sockets.
- Response limits are enforced while consuming transport data.
- Cross-origin redirects remove credentials.
- Exact and explicit wildcard host allowlists are supported.
- WebSocket upgrade acceptance and server frame masking rules are validated.

## Deferred

Only NIF/BIF codec support and its NIF-specific decoding limits are deferred.
The generic codec boundary is present so NIFKit can be added without changing
the request API.
