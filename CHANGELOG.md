# Changelog

All notable changes to Joubako are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.2] - 2026-08-14

### Added

- Reproducible sequential and 32-request concurrent HTTP/1.1 POST benchmarks
  using a validated 1 KiB echo payload, plus workload and connection-mode
  selectors for focused comparisons.
- ARC and ORC HTTP/1.1 lifecycle probes in the sanitizer and Valgrind suites.
- A controlled v0.2.2 benchmark update that publishes both Joubako's
  sequential advantage and its remaining concurrent deficit against Chronos
  v4.4.0 persistent connections.

### Changed

- Reduced common-path request and response copies by moving owned requests
  through the built-in HTTP transport and consuming internally owned completed
  Futures without exposing a custom await operation to applications.
- Lazily allocate empty header tables, avoid redundant parsed-header
  normalization, parse Content-Length once, cache invariant transport headers,
  and bypass retry/interceptor orchestration when those features are unused.
- Reworked timeout scheduling and connection-pool bookkeeping to reduce
  per-request Future, callback, and sequence overhead while retaining bounded
  deadlines, cancellation, redirects, streaming limits, and custom transport
  compatibility.
- Increased the default retained HTTP/1.1 idle connections from 8 to 32 so
  ordinary 32-request batches do not close and recreate 24 connections after
  every batch.
- Clarified that the default HTTP/1.1 transport deliberately builds on Nim's
  standard `asyncdispatch` and `httpclient` stack, while the explicitly
  selected HTTP/2 transport uses the libcurl binding and system runtime.

### Fixed

- Made active HTTP cancellation close the owned connection through a private
  per-exchange relay. This avoids callback replacement in Nim's shared
  `Future or` combinator and keeps cancellation prompt on Windows as well as
  Linux and macOS without adding overhead to requests that use no token. The
  close path also handles the connect/cancel race before older Nim releases
  mark an accepted socket as connected.

### Performance

- On the documented loopback host, v0.2.2 under ARC reached 8,478.5 sequential
  and 20,875.0 concurrent GET operations per second. It was 2.0% faster than
  Chronos persistent sequentially and 18.1% slower at 32-request concurrency.
- Under ORC, v0.2.2 reached 8,298.5 sequential and 20,557.7 concurrent GET
  operations per second. It was 3.0% faster sequentially and 17.7% slower at
  32-request concurrency. These narrow loopback results are not universal
  performance claims.

## [0.2.1] - 2026-08-12

### Added

- A reproducible HTTP/1.1 comparison benchmark for Joubako v0.2.0 and Chronos
  v4.4.0, covering default and connection-reusing configurations under ARC
  and ORC with sequential and 32-request concurrent workloads.
- Published methodology, environment, limitations, complete results, and
  optimization targets derived from three independent benchmark runs.

## [0.2.0] - 2026-08-12

### Added

- First-class ORC support across the complete test suite, TLS/mTLS/SOCKS5h
  integration, hardening probes, real-network E2E scenarios, and Valgrind leak
  checks while retaining ARC as the default memory manager.
- Incremental file-backed multipart uploads over HTTP/2, including bounded
  wire-size validation, progress, cancellation, transmitted filename privacy,
  and correct replay or body removal across redirects.
- Typed long-lived GraphQL operations over `graphql-transport-ws`, including
  verified subprotocol negotiation, connection parameters, extensions,
  ping/pong, bounded messages, cancellation, typed streamed results, terminal
  GraphQL errors, and explicit completion.
- Validated resumable file downloads using Range, Content-Range, identity
  encoding, and optional If-Range validators, with offset-aware progress.
- Cross-platform AddressSanitizer CI for ARC and ORC on Linux, macOS,
  and Windows, with Windows explicitly using Clang ASan and LeakSanitizer
  enabled only on Linux.
- UndefinedBehaviorSanitizer and multi-threaded ThreadSanitizer probes on Linux
  and macOS, plus Linux standalone LeakSanitizer, all covering ARC and ORC;
  Linux also retains integrated ASan leak detection and Valgrind, while macOS
  and Windows do not claim leak detection.
- NIFKit v0.4.0 typed Nim-value HTTP helpers over BIF v5 and typed data profile
  v2, including bounded `NifBytes`, strict compatibility defaults, logical
  codec error paths, and explicit finite network limits for bytes, depth,
  tokens, pools, strings, indexes, containers, fields, and tracked references.
- Named NIF policies with method, exact-path, and longest-prefix routing so
  uploads and ordinary API calls can use different transport and codec
  budgets without changing NIFKit's policy-free defaults.
- Typed `postNifMultipart` uploads with zero-configuration recommended limits
  for BIF metadata, streamed files, and complete multipart wire size; HTTP/2
  additionally accounts file reads and total upload progress at runtime and
  fails closed when that guarantee is required but unavailable.

### Fixed

- File streaming helpers now disable internal transport retry so a failure
  after bytes reach disk cannot duplicate the same response bytes.

## [0.1.1] - 2026-08-03

### Added

- Runnable Express, NestJS, Flask, FastAPI, Laravel, Prologue, and nim-basolato
  integration demos sharing one typed Joubako client and API contract.
- A cross-framework live scenario covering typed JSON, JSON request encoding,
  custom headers, `201` creation, `422` validation, and typed `404` failures.

### Changed

- Changed the Joubako project license from MIT to Apache License 2.0. Releases
  through `v0.1.0` remain available under their original MIT terms.

## [0.1.0] - 2026-08-02

### Added

- Result-valued asynchronous request APIs using Nim's standard `await`.
- Promise-style synchronous and asynchronous `then`, `catch`, and `finally`
  composition, plus heterogeneous two-operation `all`.
- HTTP and HTTPS with verified TLS defaults, configurable trust, mutual TLS,
  proxies, bounded keep-alive reuse, redirects, cancellation, and independent
  connection, read, and total deadlines.
- Bounded streaming response consumption, file downloads, upload/download
  progress, and gzip/deflate decompression.
- Typed JSON, URL-encoded form, buffered and file-backed multipart, pluggable
  synchronous/asynchronous codecs, and NIFKit v0.2 NIF/BIF integration.
- FlowBrigade-backed retry, circuit breaker, token-bucket rate limiting, and
  bulkhead guards.
- Bounded opt-in cookie storage, authentication helpers, Unix-domain IPC,
  WebSocket, in-process, and deterministic fault-injection transports.
- Linux, macOS, and Windows CI; deterministic fuzz and soak probes; and ARC
  allocation lifecycle checks under Valgrind.

### Security

- Response limits are enforced while bytes are read and while compressed data
  is expanded, rather than after an unbounded body has been allocated.
- Cross-origin redirects remove authorization, cookie, proxy authorization,
  and host headers.
- URLs, headers, multipart metadata, proxy configuration, WebSocket frames,
  IPC frames, and NIF/BIF inputs are validated with finite limits.

### Known limitations

- Unix-domain IPC is available only on POSIX systems.
- HTTPS and WSS require compilation with `-d:ssl`.
- NIFKit v0.2 converts NIF text to and from BIF v5. Typed Nim-value NIF
  serialization remains deferred until NIFKit publishes that API.
- Nim 2.2's standard async transport can retain small failed-Future and
  exception allocations on some TLS-verification and SOCKS-authentication
  failure paths under ARC. Joubako's deterministic Result and fault probes
  remain leak-free; secure integration tests keep the upstream behavior
  visible.
