# Joubako

Joubako is a typed, asynchronous transport client for native Nim
applications. It combines the familiar request-client features of libraries
such as Axios with Nim's native `Future` type and a transport-independent
design.

Joubako depends on FlowBrigade 0.5 or newer for generic resilience mechanisms
such as asynchronous retry, backoff, deadlines, circuit breakers, rate limits,
and bulkheads. HTTP-specific retry classification remains Joubako's
responsibility. Joubako builds bounded streaming gzip and deflate decoding on
nim-zlib 0.2 or newer and its bundled zlib implementation.
Third-party attribution is collected in
[`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md).

## Local dependency setup

In this workspace, FlowBrigade is developed in the adjacent `timekeeper`
directory. Register it as a local Nimble dependency before running the Joubako
suite. nim-zlib and its transitive dependencies are resolved through Nimble
unless they are also registered locally:

```sh
nimble develop -a:../timekeeper
nimble setup --offline
nimble test
```

`nimble.develop` and `nimble.paths` contain machine-specific paths and are
therefore ignored by Git. Published or separately checked-out builds resolve
the declared FlowBrigade and nim-zlib Nimble dependencies normally.

Nimble versions using the experimental vnext resolver may need
`nimble --legacy --offline setup` when the active Nim compiler is managed by
Choosenim.

The current implementation includes:

- awaitable HTTP requests returning `Future[JResult[T]]`;
- event-loop-local HTTP keep-alive reuse with a bounded idle pool;
- bounded streaming gzip and deflate response decoding;
- `then`, `catch`, `finally`, and `all` composition over the same Result-valued
  `Future`;
- typed JSON encoding and decoding;
- percent-encoded query parameters, including repeated names;
- synchronous or asynchronous request/response interceptors;
- HTTP-aware retry using FlowBrigade backoff, deadlines, asynchronous waiting,
  and observer primitives;
- structured transport, timeout, cancellation, status, size, and codec errors;
- default and per-request headers, total deadlines, and body-size limits;
- separate connection/header and body-read timeouts;
- redirect credential stripping and optional host allowlists;
- FlowBrigade circuit-breaker, rate-limit, and bulkhead guards;
- URL-encoded forms, multipart bodies, authentication helpers, and progress
  callbacks;
- pluggable per-request codecs;
- Unix domain socket, WebSocket, and in-process transports.

## ARC memory model

Joubako is developed and tested with Nim's deterministic ARC memory manager.
The repository `config.nims` selects `--mm:arc`, and the Valgrind task repeats
that selection explicitly.

ARC deliberately does not collect reference cycles. Callbacks and interceptors
that outlive a request therefore must not capture the same async frame or owner
object that stores them. Put mutable callback state in a separate `ref object`
and create the callback outside the owning async procedure when necessary.
The leak probe follows this pattern and fails if a cycle or another allocation
remains at process exit.

## Await

```nim
import std/asyncdispatch
import joubako

type User = object
  id: int
  name: string

proc loadUser() {.async.} =
  let api = newClient(newHttpTransport(), "https://api.example.com/")
  let outcome = await api.getJson("users/42", User)
  if outcome.isErr:
    echo "request failed: ", outcome.error.msg
    return

  echo outcome.value.name
```

Joubako represents expected request failures as `JResult.Err`, not as failed
Futures. The standard Nim `await` is used unchanged: `await` produces a
`JResult[T]`, and the application checks `isOk` or `isErr` before reading
`value`. Transport, timeout, cancellation, HTTP status, limit, and codec errors
are therefore handled in one explicit path. Programming defects remain outside
this contract.

HTTP status failures retain a bounded response snapshot for diagnostics. The
snapshot intentionally excludes the originating request, so request
credentials and request bodies are not kept alive by the error:

```nim
let outcome = await api.get("users/unknown")
if outcome.isErr:
  let error = outcome.error
  if error.hasResponse:
    echo error.response.status, " ", error.response.statusText
    echo error.response.headers.get("content-type")
    echo error.response.body
  echo "attempts: ", error.attempts
```

`response.body` is subject to `maxResponseBytes`. When response streaming is
enabled, it remains empty because chunks have already been delivered to the
configured consumer. Response headers can contain sensitive server data such
as `Set-Cookie`, so applications should redact them before logging.

Independent operations may start together and be awaited as one Result:

```nim
let combined = await all(
  api.getJson("users/42", User),
  api.getJson("teams/7", Team)
)
if combined.isOk:
  echo combined.value.first.name
  echo combined.value.second.name
```

## Promise-style callbacks

```nim
let request = api.getJson("users/42", User)
  .then(proc(user: User) = render(user))
  .catch(proc(error: ref JoubakoError) = showError(error.msg))
  .finally(proc() = stopLoading())

asyncCheck request
```

`catch` may also recover with a value of the same type:

```nim
let outcome = await api.getJson("users/42", User)
  .catch(proc(error: ref JoubakoError): User = cachedUser())

if outcome.isOk:
  render(outcome.value)
```

## Query and JSON bodies

```nim
let matchesResult = await api.getJson(
  "users",
  [
    (name: "role", value: "editor"),
    (name: "tag", value: "nim"),
    (name: "tag", value: "native")
  ],
  seq[User]
)

if matchesResult.isErr:
  showError(matchesResult.error.msg)
  return
let matches = matchesResult.value

let createdResult = await api.postJson("users", newUser, User)
if createdResult.isOk:
  echo createdResult.value.id
```

Typed JSON helpers are available for `POST`, `PUT`, and `PATCH`.

Serialization is also pluggable. A codec configures exactly one encoder and
one decoder; callbacks may be synchronous or asynchronous, and response-aware
decoders can inspect status and headers:

```nim
let codec = Codec[Command, Reply](
  mediaType: "application/vnd.example.command",
  encodeAsync: proc(value: Command): Future[string] {.async.} =
    return await encodeCommand(value),
  decodeResponse: proc(response: Response): Reply =
    decodeReply(response.body, response.headers.get("x-schema-version"))
)

let reply = await api.sendWithCodec(rmPost, "commands", command, codec)
```

Failed asynchronous callbacks are consumed internally and returned as
`jeCodec`; decoder failures retain a bounded response snapshot. Configuring
multiple encoders or decoders is rejected rather than relying on implicit
precedence.

JSON behavior can be adjusted through `JsonCodecOptions` or a reusable
`jsonCodec[TBody, TResponse]`. This exposes Nim's extra/missing-key and enum
encoding policies while retaining the typed helper API.

## Interceptors

Interceptors run in registration order and may be synchronous or asynchronous.
Registration returns an ID that can later be ejected.

```nim
let authInterceptor = api.useRequestInterceptor(
  proc(request: Request): Request =
    result = request
    result.headers.set("authorization", "Bearer " & accessToken)
)

discard api.useResponseInterceptor(
  proc(response: Response): Future[Response] {.async.} =
    await recordMetrics(response)
    return response
)

discard api.ejectRequestInterceptor(authInterceptor)
```

## Deadlines, cancellation, and limits

The total HTTP deadline covers connection, headers, redirects, and
response-body reading. `connectTimeoutMs` limits connection plus response
headers, while `readTimeoutMs` limits the wait between body chunks.
Cancelling a token during an HTTP request closes the active connection.
Response limits are checked as transport chunks arrive, before each chunk is
appended to the buffered result; they do not depend on a truthful
`Content-Length` header.

```nim
var options = defaultRequestOptions()
options.timeoutMs = 30_000
options.connectTimeoutMs = 5_000
options.readTimeoutMs = 10_000
options.allowedHosts = @["api.example.com", "*.services.example.com"]
options.onDownloadProgress =
  proc(received, total: int64) = echo received, "/", total
```

Set `streamResponse = true` together with `onDownloadChunk` to consume chunks
without retaining them in `Response.body`. For asynchronous file or pipeline
consumers, use `onDownloadChunkAsync`; Joubako awaits each consumer call before
reading the next chunk, providing backpressure. The response byte limit is
still enforced against the cumulative received size.

```nim
var options = defaultRequestOptions()
options.streamResponse = true
options.onDownloadChunkAsync =
  proc(chunk: string): Future[void] {.async.} =
    await destination.write(chunk)

let outcome = await api.get("exports/current", options = options)
```

The file helper configures this streaming path and leaves `Response.body`
empty. A failed download retains the partial file for explicit inspection or
resume handling:

```nim
let outcome = await api.downloadToFile(
  "exports/current",
  "/var/tmp/current-export.bin"
)
if outcome.isErr:
  echo outcome.error.msg
```

Automatic redirects are handled by Joubako. `Authorization`, `Cookie`,
`Proxy-Authorization`, and `Host` are removed whenever a redirect changes
scheme, host, or effective port. Every redirect target is checked against the
request host allowlist.

Native applications can opt into automatic cookie persistence by assigning a
bounded jar to the HTTP transport:

```nim
let jar = newCookieJar()
let transport = newHttpTransport(cookieJar = jar)
let api = newClient(transport, "https://api.example.com/")
```

The jar applies host/domain and path matching, `Secure`, `HttpOnly`,
`SameSite=None`, `Expires`, `Max-Age`, `__Secure-`, and `__Host-` rules. It is
updated at every redirect hop, so a valid redirect cookie can participate in
the next request. Caller-supplied `Cookie` headers take precedence. Limits
default to 4 KiB per `Set-Cookie` field, 180 cookies per domain, and 3,000 total
cookies; oldest entries are evicted first. The jar is intended to remain on the
same event-loop thread as its `HttpTransport`.

Domain matching validates that the response host covers the requested Domain,
but Joubako does not bundle a public-suffix list. Applications accepting
untrusted Domain attributes should enforce their own registrable-domain policy
or use host-only cookies.

TLS peer verification is enabled by default. Custom trust stores and mutual TLS
identity can be configured without replacing the HTTP transport:

```nim
var tls = defaultTlsOptions()
tls.caFile = "/etc/my-app/private-ca.pem"
tls.certFile = "/etc/my-app/client-cert.pem"
tls.keyFile = "/etc/my-app/client-key.pem"

let transport = newHttpTransport(tlsOptions = tls)
```

Set `verifyMode = tvmPeerUseEnvVars` to additionally consult
`SSL_CERT_FILE`/`SSL_CERT_DIR`. TLS 1.2-and-earlier cipher lists and TLS 1.3
cipher suites may be overridden separately with `cipherList` and
`cipherSuites`. `tvmNone` disables peer verification and is provided only for
explicit use in controlled development environments. HTTPS requires compiling
with `-d:ssl`; certificate and key paths are loaded lazily on the first HTTPS
origin.

HTTP and SOCKS proxies can be selected per target scheme, with optional
environment-variable discovery and `NO_PROXY` bypass rules:

```nim
let proxyOptions = ProxyOptions(
  httpProxy: "http://proxy-user:proxy-pass@proxy.example.com:8080",
  httpsProxy: "socks5h://proxy.example.com:1080",
  noProxy: @["localhost", ".internal.example.com", "10.0.0.5:8443"]
)
let transport = newHttpTransport(proxyOptions = proxyOptions)
```

`environmentProxyOptions()` reads lowercase and uppercase `HTTP_PROXY`,
`HTTPS_PROXY`, `ALL_PROXY`, and `NO_PROXY` variants. Lowercase values take
precedence. For CGI safety, uppercase `HTTP_PROXY` is ignored when
`REQUEST_METHOD` is present. Explicit scheme settings take precedence over
`allProxy`; bypass rules are evaluated first. `*`, exact hosts, domain suffixes,
optional ports, and bracketed IPv6 hosts are supported. Proxy credentials must
be URL-encoded when they contain reserved characters.

The older `proxy = newProxy(...)` constructor argument remains supported and
takes precedence over `ProxyOptions` for compatibility.

`HttpTransport` retains up to eight completed keep-alive connections by
default. Concurrent requests never share an active connection; each request
checks out an idle connection or creates a new one. Set
`maxIdleConnections = 0` to disable retention, or call
`closeIdleConnections()` to release currently idle sockets:

```nim
let transport = newHttpTransport(maxIdleConnections = 16)
let api = newClient(transport, "https://api.example.com/")

# Later, when the application becomes idle or shuts down:
transport.closeIdleConnections()
```

## Retry

Retry is explicit opt-in. Joubako classifies HTTP failures and advances the
Result-valued attempts, while FlowBrigade supplies backoff, jitter, deadline,
asynchronous waiting, and observer behavior.

```nim
var options = defaultRequestOptions()
options.timeoutMs = 10_000 # total deadline across attempts and waits
options.retry = defaultHttpRetryOptions() # three attempts by default

let response = await api.get("reports/current", options = options)
if response.isErr:
  echo response.error.msg
```

`GET`, `HEAD`, `PUT`, `DELETE`, and `OPTIONS` are considered idempotent by
default. `POST` and `PATCH` stop after the first failure unless the caller
explicitly declares the operation idempotent:

```nim
options.retry.idempotency = imIdempotent
let response = await api.post(
  "documents",
  replayableBody,
  options = options
)
if response.isErr:
  echo response.error.msg
```

The default retryable statuses are `408`, `425`, `429`, `500`, `502`, `503`,
and `504`; transport and timeout failures are also retryable for idempotent
requests. Cancellation, invalid input, codec failures, body limits, and other
HTTP statuses stop immediately. Both delta-seconds and HTTP-date forms of
`Retry-After` are supported. If every attempt fails, the final error retains
the final HTTP response snapshot and reports the number of attempts performed.

```nim
let token = newCancellationToken()
var options = defaultRequestOptions()
options.timeoutMs = 5_000
options.maxRequestBytes = 2 * 1024 * 1024
options.maxResponseBytes = 8 * 1024 * 1024
options.cancellation = token

let pending = api.get("reports/current", options = options)
token.cancel("selection changed")
```

## Resilience guards

Retry remains per-request. Circuit breaker, rate limiting, and bulkhead limits
are optional client-level guards backed by FlowBrigade:

```nim
import std/times

api.useCircuitBreaker(
  failureThreshold = 5,
  resetAfter = initDuration(seconds = 30)
)
api.useRateLimit(
  rate = 20,
  per = initDuration(seconds = 1),
  burst = 40
)
api.useBulkhead(capacity = 8)
```

Guard rejection uses the structured `jeCircuitOpen`, `jeRateLimited`, and
`jeBulkheadRejected` error kinds.

## Forms, multipart, and authentication

```nim
var headers = initHeaders()
headers.setBearerToken(accessToken)

let session = await api.postForm("sessions", [
  (name: "username", value: username),
  (name: "password", value: password)
], headers)
if session.isErr:
  echo session.error.msg

let upload = await api.postMultipart("documents", [
  formField("title", title),
  formFile("document", "report.pdf", pdfBytes, "application/pdf")
], headers)
if upload.isErr:
  echo upload.error.msg
```

`formFile` is the buffered form for content already in memory. For large files,
`formFilePath` lets the HTTP transport open and send the file incrementally:

```nim
let upload = await api.postMultipart("documents", [
  formField("title", title),
  formFilePath(
    "document",
    "/var/tmp/report.pdf",
    contentType = "application/pdf"
  )
])
```

The multipart boundary and `Content-Length` are generated by the transport;
callers must not set `Content-Type` for a file-backed multipart request. The
complete multipart wire size, including fields and framing, is checked against
`maxRequestBytes` before connecting. The file must remain present and unchanged
until the returned Future completes. File-backed multipart is HTTP-specific;
IPC, WebSocket, and in-process transports reject it explicitly.

`postMultipart`, `putMultipart`, and `patchMultipart` accept both buffered and
file-backed parts.

## Local IPC and WebSocket

`UnixIpcTransport` uses a bounded, length-prefixed protocol. The metadata is
JSON and bodies are Base64 encoded, so binary data is preserved. Applications
own the listening socket and pass accepted peers to `handleIpcConnection`.

```nim
let local = newClient(newUnixIpcTransport("/run/my-app/backend.sock"))
let response = await local.post("/jobs", payload)
if response.isErr:
  echo response.error.msg
```

`WebSocketTransport` performs a standards-based upgrade, masks client frames,
validates `Sec-WebSocket-Accept`, handles ping/close frames, and enforces
message limits. `wss` uses certificate verification and requires compiling
with `-d:ssl`.

```nim
let socketApi = newClient(newWebSocketTransport())
let reply = await socketApi.post("wss://events.example.com/rpc", message)
if reply.isErr:
  echo reply.error.msg
```

For a long-lived connection, use `connectWebSocket`, `sendText`,
`receiveMessage`, and `close` directly.

## Test

```sh
nimble test
```

Deterministic hardening targets are separate from the fast unit suite:

```sh
nimble fuzz
nimble soak
```

`fuzz` generates malformed Cookie, proxy-bypass, retry-date, query, gzip, and
deflate inputs from a fixed seed so CI failures are reproducible. Override
`JOUBAKO_FUZZ_ITERATIONS` to increase its default 10,000 iterations. `soak`
mixes successful typed serialization, retryable status responses, transport
disconnects, and bounded Cookie churn for 20,000 logical operations; use
`JOUBAKO_SOAK_ITERATIONS` for longer local runs.

`FaultInjectingTransport` provides deterministic scripted `transport`,
`timeout`, HTTP-status, delay, and pass-through steps for application tests.
It composes with normal retry, deadline, circuit-breaker, and cancellation
behavior without requiring a real network failure.

The HTTP integration test binds only to a local loopback socket.
The IPC tests use a temporary Unix domain socket on POSIX systems.
CI runs the suite on Linux, macOS, and Windows with Nim 2.2.0 and the current
stable Nim release. Linux additionally builds the SSL configuration and runs
the HTTP integration suite with SSL context initialization enabled.

The allocation lifecycle probe runs under Valgrind with ARC and
`-d:useMalloc`, so Nim allocations are visible to Memcheck:

```sh
nimble leak
```

It fails on definite, indirect, or possible leaks and exercises repeated
successful requests, typed JSON decoding, Promise callbacks, interceptors,
FlowBrigade-backed guards, structured HTTP and transport failures, `all`, and
discarded callback chains. Public request failures cross an internal settling
boundary and become `JResult.Err`, so the error-path probe also finishes with
zero bytes in use under ARC without broad Valgrind suppressions. A dedicated
fault-injection probe additionally repeats retry recovery from transport and
HTTP failures.

## Benchmark

```sh
nimble benchmark
```

The local benchmark reports request construction/dispatch, typed JSON decode,
Promise callback dispatch, and one-failure retry overhead separately from
network latency.
