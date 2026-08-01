# Implementation Status

This file maps the delivery order in `vision.md` to the current implementation.

| Area | Status | Notes |
| --- | --- | --- |
| Common request/response/error contracts | Complete | `Future[JResult[T]]`, bounded HTTP error response snapshots without request secrets, attempt counts, cancellation, deadlines, limits, synchronous and backpressured asynchronous progress consumers |
| FlowBrigade resilience | Complete | Async retry, circuit breaker, token-bucket rate limit, bulkhead |
| HTTP(S) and JSON | Complete | Verified TLS chain and hostname/IP by default, custom CA/mTLS/cipher configuration, HTTP/SOCKS proxy selection with environment and NO_PROXY rules, keep-alive reuse keyed by origin and proxy, bounded idle pool, bounded gzip/deflate decoding, bounded opt-in cookie jar across redirects, streaming limit checks, redirects, typed JSON |
| Typed query, headers, body APIs | Complete | Configurable JSON policies, synchronous/asynchronous pluggable codecs with response-aware decoding, URL-encoded form, buffered multipart, file-backed streaming multipart, raw bytes-as-string |
| Promise-style composition | Complete | Result-aware `then`, typed `catch`, `finally`, heterogeneous two-operation `all` |
| NIF/BIF through NIFKit | Deferred | Deliberately postponed |
| Local IPC | Complete on POSIX | Unix domain sockets with a bounded framed protocol |
| In-process transport | Complete | Deterministic handler transport |
| WebSocket | Complete | One-shot transport plus long-lived connection primitives |
| Cross-platform CI | Complete | Linux, macOS, Windows; Nim 2.2.0 and stable |
| Native allocation leak probe | Complete | Valgrind, ARC, `-d:useMalloc`, zero bytes at exit on success and error paths |
| Memory model | Complete | Public failures settle into values; project builds and tests with deterministic ARC |
| Hardening | Complete | Scripted fault transport, deterministic structured-input fuzzing, mixed retry/codec/cookie soak test, and dedicated fault-path Valgrind coverage |

## Security contracts

- TLS certificate-chain and hostname/IP validation remain enabled by default.
- Custom CA roots, environment trust, mutual TLS identity, and cipher policy
  are explicit per-transport settings; disabling verification is never implicit.
- Total, connection/header, and per-body-read timeouts are independent.
- Cancellation closes active HTTP, IPC, and WebSocket sockets.
- Response limits are enforced while consuming transport data, including
  during decompression rather than after an expanded body is allocated.
- Cross-origin redirects remove credentials.
- Exact and explicit wildcard host allowlists are supported.
- WebSocket upgrade acceptance and server frame masking rules are validated.

## Upstream runtime constraint

Nim 2.2's standard `asyncnet`/`httpclient` can retain small failed-Future and
exception allocations after TLS verification or SOCKS authentication failures
under ARC. Joubako settles its public Future into `JResult` and explicitly owns
and frees every OpenSSL context, but it cannot clear Futures retained inside
the standard-library transport. The deterministic Joubako error probes remain
zero-leak; the real secure-transport integration suite keeps this upstream
failure-path behavior visible until Nim fixes it or the transport is replaced.

## Deferred

Only NIF/BIF codec support and its NIF-specific decoding limits are deferred.
The generic codec boundary is present so NIFKit can be added without changing
the request API.
