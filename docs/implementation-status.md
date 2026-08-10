# Implementation Status

This file maps the delivery order in `vision.md` to the current implementation.

| Area | Status | Notes |
| --- | --- | --- |
| Common request/response/error contracts | Complete | `Future[JResult[T]]`, bounded HTTP error response snapshots without request secrets, attempt counts, cancellation, deadlines, limits, synchronous and backpressured asynchronous progress consumers |
| FlowBrigade resilience | Complete | Async retry, circuit breaker, token-bucket rate limit, bulkhead |
| HTTP(S) and JSON | Complete | Verified TLS chain and hostname/IP by default, custom CA/mTLS/cipher configuration, HTTP/SOCKS proxy selection with environment and NO_PROXY rules, keep-alive reuse keyed by origin and proxy, bounded idle pool, bounded gzip/deflate decoding, bounded opt-in cookie jar across redirects, streaming limit checks, redirects, typed JSON |
| Typed query, headers, body APIs | Complete | Configurable JSON policies, synchronous/asynchronous pluggable codecs with response-aware decoding, URL-encoded form, buffered multipart, file-backed streaming multipart over HTTP/1.1 and HTTP/2, bounded incremental request streaming over HTTP/2, raw bytes-as-string |
| JSON-RPC 2.0 | Complete | Typed calls, protocol errors as values, HTTP notifications, reordered mixed batches with strict ID correlation, and response-bearing calls/batches over one-shot WebSocket |
| Streaming JSON records | Complete | Typed NDJSON and RFC 7464 JSON Text Sequence encode/decode, bounded incremental parsing across arbitrary chunks, synchronous/asynchronous backpressure, strict UTF-8 and malformed/truncation handling |
| CBOR | Complete | Typed RFC 8949 encode/decode and HTTP helpers, strict single-item framing, structured offsets, media-type validation, payload/depth/collection/string limits, real binary HTTP integration, ARC/ORC and fuzz/leak coverage |
| Protocol Buffers | Complete | Typed proto2/proto3/Edition binary encode/decode and HTTP helpers, compile-time `.proto` type generation, standard and configurable legacy media types, illegal parameter rejection, payload limits, malformed/unknown/duplicate field coverage, real binary HTTP integration |
| gRPC | Four call shapes complete | Native Protobuf gRPC unary, client-streaming, server-streaming, and bidirectional calls over negotiated HTTP/2; bounded request queues, backpressured response handlers, five-byte incremental framing, completion trailers, deadlines, ASCII/binary metadata, structured status/message/details, strict size/count/media validation, and real h2c integration; message compression remains pending |
| GraphQL client | Complete | Typed query/mutation/subscription builder, variables, aliases, directives, fragments, raw-document escape hatch, nim-graphql executable syntax validation, standard JSON-over-HTTP envelope, and long-lived `graphql-transport-ws` subscriptions with typed partial data and structured errors |
| Promise-style composition | Complete | Result-aware synchronous/asynchronous `then`, typed `catch`, `finally`, heterogeneous two-operation `all`; callback exceptions, failed callback Futures, and nil callback Futures settle as errors |
| NIF/BIF through NIFKit | Complete for NIFKit v0.2 | NIF text request API, BIF v5 wire encoding, canonical NIF response decoding, finite per-direction codec limits, structured error code/offset mapping; typed Nim-value serialization awaits a future NIFKit API |
| Local IPC | Complete on POSIX | Unix domain sockets with a bounded framed protocol |
| In-process transport | Complete | Deterministic handler transport |
| WebSocket | Complete | One-shot transport, long-lived connection primitives, explicit and verified subprotocol negotiation |
| Server-Sent Events | Complete | Bounded incremental parser, synchronous/asynchronous backpressured handlers, content-type validation before body delivery, Last-Event-ID, server retry delay, cancellation, and bounded/unbounded reconnect policy |
| OpenTelemetry | Complete | SDK-neutral HTTP CLIENT spans, W3C traceparent/tracestate continuation and injection, stable HTTP semantic attributes, retry counts, monotonic durations, sensitive URL defaults, and failure-isolated observer adapter |
| Private HTTP cache | Complete | Pluggable store, bounded LRU memory implementation, max-age/Age/Date/Expires freshness, ETag and Last-Modified 304 revalidation, Vary variants, unsafe-method invalidation, and credential-safe defaults |
| Cross-platform CI | Complete | Linux, macOS, Windows; Nim 2.2.0 and stable; ARC and ORC |
| Cross-container E2E | Complete | Clean ARC/ORC Nim/Joubako client container against independent backend and redirect containers; typed JSON, query/header fidelity, binary, gzip, chunked streaming, retry, cross-origin credential stripping, cookies, file upload/download, response limits, NIF/BIF, concurrency, and timeout |
| Native allocation leak probe | Complete | Valgrind, ARC and ORC, `-d:useMalloc`, zero definite/indirect/possible loss across core, transport, codec, resilience, HTTP/2, and repeated GraphQL success/error paths |
| Memory model | Complete | Public failures settle into values; project builds, tests, and runs leak probes with ARC and ORC |
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
- GraphQL WebSocket subscriptions require the negotiated
  `graphql-transport-ws` subprotocol, bound handshake/ack/message sizes, and
  abort pending reads on cancellation or protocol failure.

## Upstream runtime constraint

Nim 2.2's standard `asyncnet`/`httpclient` can retain small failed-Future and
exception allocations after TLS verification or SOCKS authentication failures
under ARC. Joubako settles its public Future into `JResult` and explicitly owns
and frees every OpenSSL context, but it cannot clear Futures retained inside
the standard-library transport. The deterministic Joubako error probes remain
zero-leak; the real secure-transport integration suite keeps this upstream
failure-path behavior visible until Nim fixes it or the transport is replaced.

## Deferred

NIFKit v0.2 deliberately exposes NIF text/BIF conversion rather than its
planned typed Nim-value data profile. Joubako therefore supports the complete
bounded v0.2 wire codec now; typed `toNif`/`fromNif` helpers can be layered onto
the same request API when NIFKit publishes them.
