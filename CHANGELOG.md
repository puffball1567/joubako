# Changelog

All notable changes to Joubako are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
  and Windows, with LeakSanitizer enabled only on Linux.

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
