# Joubako

## Async networking, finally built for Nim.

**Axios-style flow. Native `await`. Typed failures. ARC and ORC.**

Joubako is the native async transport client for Nim. It replaces transport
plumbing with clear application code—and keeps that code in control when the
network fails, stalls, redirects, retries, or sends more data than promised.

Write requests in a straight line. Launch independent work together. Chain
callbacks without callback hell. Stream large bodies without retaining them.
Carry the same lifecycle and error model across HTTP, WebSockets, local IPC,
and in-process calls.

## Write less plumbing. Ship stronger clients.

- **Read async code like synchronous code.** Standard Nim `await`. No custom
  runtime. No custom await operator.
- **Own every operational failure.** Transport, timeout, cancellation, HTTP,
  size, and codec failures become typed `JResult.Err` values.
- **Compose without callback hell.** Use `then`, `catch`, `finally`, and `all`
  when event-driven code fits better than sequential awaits.
- **Survive real networks.** Verified TLS, bounded streaming and decompression,
  safe redirects, proxies, retry, circuit breakers, rate limits, and bulkheads
  are built in.
- **Keep memory behavior predictable.** Joubako is tested with ARC and ORC and
  hammered under Valgrind on success and failure paths under both models.
- **Use one model everywhere.** Typed JSON, JSON-RPC 2.0, CBOR, Protocol
  Buffers, four gRPC call shapes, pluggable codecs, NIF/BIF, typed GraphQL,
  bounded streaming uploads, WebSockets, Unix-domain IPC, and in-process transports all speak
  the same request, result, cancellation, and deadline language.

From a single GET to a resilient native service client, Joubako keeps the code
clear and the network under control.

## Name and pronunciation

**Joubako** is pronounced **“JOH-bah-koh”**—`jōbako` in romanized Japanese,
or **じょうばこ（状箱）** in Japanese.

A joubako is a small box for carrying letters, including letters entrusted to
a messenger. This Joubako carries application requests and responses across
process and network boundaries: typed, protected, and delivered to their
destination.

## Architecture and dependencies

Joubako depends on FlowBrigade 0.5 or newer for generic resilience mechanisms
such as asynchronous retry, backoff, deadlines, circuit breakers, rate limits,
and bulkheads. HTTP-specific retry classification remains Joubako's
responsibility. Joubako builds bounded streaming gzip and deflate decoding on
nim-zlib 0.2 or newer and its bundled zlib implementation. The optional
HTTP/2 transport uses the libcurl Nim bindings and a system libcurl build with
HTTP/2 support; libcurl commonly delegates framing and HPACK to nghttp2.
GraphQL executable documents are validated with the maintained
`status-im/nim-graphql` parser; Joubako owns the typed builder, HTTP envelope,
response decoding, limits, and Result boundary.
RFC 8949 CBOR encoding and bounded decoding are provided by
`vacp2p/nim-cbor-serialization`; Joubako supplies strict message framing,
HTTP media-type handling, transport limits, and structured errors.
Protocol Buffers schema validation, proto2/proto3/Edition wire encoding, and
compile-time `.proto` type generation are provided by
`status-im/nim-protobuf-serialization`; Joubako supplies the HTTP and Result
boundary.
Third-party attribution is collected in
[`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md).

## Getting started

Joubako requires Nim 2.2 or newer and supports both ARC and ORC. Install it
and its declared dependencies through Nimble:

```sh
nimble install joubako
```

Then import the public entry point:

```nim
import std/asyncdispatch
import joubako

proc main() {.async.} =
  let api = newClient(newHttpTransport(), "https://api.example.com/")
  let response = await api.get("health")
  if response.isErr:
    echo response.error.msg
  else:
    echo response.value.status

waitFor main()
```

Compile and run Joubako applications with ARC and TLS enabled:

```sh
nim c -r --mm:arc -d:ssl app.nim
```

This is the recommended build command for normal Joubako applications.
`-d:ssl` enables HTTPS and WSS capability; it does not force plaintext HTTP
requests to use TLS. Keeping it enabled means the same binary can use HTTP,
HTTPS, WS, and WSS without changing its build configuration.

ORC is supported by the same public API. Select it explicitly when the
application benefits from cycle collection:

```sh
nim c -r --mm:orc -d:ssl app.nim
```

For a deliberately TLS-free target without OpenSSL, use the minimal build:

```sh
nim c -r --mm:arc app.nim
```

Plain HTTP, Unix IPC, in-process transport, codecs, and the common request API
remain available without `-d:ssl`. The example above is available as
[`examples/basic.nim`](examples/basic.nim).

For complete client-and-server examples, see the
[`examples/frameworks`](examples/frameworks/README.md) demos. One shared
Joubako client calls equivalent APIs implemented with **Express, NestJS,
Flask, FastAPI, Laravel, Prologue, and nim-basolato**. The same client is
verified through real HTTP communication across Node.js, TypeScript, Python,
PHP, and Nim—including typed JSON, custom headers, validation, and HTTP error
handling.

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

Source checkouts must include the pinned GraphQL parser submodule. Clone with
`git clone --recurse-submodules`, or initialize an existing checkout with:

```sh
git submodule update --init --recursive
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
- HTTP/2 multiplexing, connection reuse, bounded request and response
  streaming, file-backed multipart uploads, redirects, and cancellation through the
  optional libcurl transport;
- bounded streaming gzip and deflate response decoding;
- bounded Server-Sent Events parsing with backpressure, cancellation,
  reconnection, and Last-Event-ID continuity;
- `then`, `catch`, `finally`, and `all` composition over the same Result-valued
  `Future`;
- typed JSON encoding and decoding;
- JSON-RPC 2.0 calls, notifications, and mixed batches over HTTP, plus
  response-bearing calls and batches over one-shot WebSocket;
- typed, backpressured NDJSON and RFC 7464 JSON Text Sequence streaming;
- typed RFC 8949 CBOR requests and responses with strict framing and bounded
  parsing;
- typed Protocol Buffers binary requests and responses with compile-time
  `.proto` schema generation and strict media-type validation;
- native gRPC unary, client-streaming, server-streaming, and bidirectional
  calls over HTTP/2, with backpressure, completion trailers, deadlines,
  metadata, and structured status errors;
- typed GraphQL query, mutation, subscription, variable, directive, and
  fragment construction with parsed executable-document validation;
- percent-encoded query parameters, including repeated names;
- synchronous or asynchronous request/response interceptors;
- HTTP-aware retry using FlowBrigade backoff, deadlines, asynchronous waiting,
  and observer primitives;
- structured transport, timeout, cancellation, status, size, and codec errors;
- default and per-request headers, total deadlines, and body-size limits;
- separate connection/header and body-read timeouts;
- redirect credential stripping and optional host allowlists;
- FlowBrigade circuit-breaker, rate-limit, and bulkhead guards;
- OpenTelemetry-compatible HTTP CLIENT spans and W3C trace-context
  propagation without a mandatory telemetry SDK;
- bounded private HTTP caching with freshness, Vary, conditional
  revalidation, and pluggable storage;
- URL-encoded forms, multipart bodies, authentication helpers, and progress
  callbacks;
- pluggable per-request codecs;
- Unix domain socket, WebSocket, and in-process transports.

## HTTP/2

Use `Http2Transport` when the peer is expected to negotiate HTTP/2:

```nim
let api = newClient(newHttp2Transport(), "https://api.example.com/")
let outcome = await api.get("health")
```

The runtime libcurl must include HTTP/2 support; verify it with `curl -V` and
look for `HTTP2` in the feature list. Joubako rejects a connection that falls
back to HTTP/1.1 instead of silently changing protocol. Linux distributions
and macOS package managers normally provide libcurl as a system package. On
Windows, place an HTTP/2-capable `libcurl.dll` and its runtime dependencies
beside the application executable or on `PATH`.

Clear-text HTTP/2 uses prior knowledge and is disabled by default. Enable it
only for a controlled h2c endpoint:

```nim
let transport = newHttp2Transport(allowH2c = true)
```

Keep one transport alive and call `await transport.close()` during orderly
shutdown. A shared transport reuses connections and multiplexes concurrent
requests over the same HTTP/2 connection.

Stream a request body without materializing it in one large string. `send`
waits when the bounded producer queue is full; `finish` sends HTTP/2
end-of-stream and waits for the response:

```nim
let upload = api.openUpload(
  rmPost,
  "objects",
  maxBufferedBytes = 256 * 1024
)

while not source.atEnd:
  let sent = await upload.send(source.readChunk())
  if sent.isErr:
    return sent.error

let response = await upload.finish()
```

Streaming bodies are single-use, so Joubako rejects retry policies and
redirect replay instead of risking duplicate or truncated uploads. Total
`maxRequestBytes`, cancellation, timeout, and upload progress policy still
apply. This producer API currently requires `Http2Transport`; buffered and
file-backed multipart uploads remain available on HTTP/1.1.

## ARC and ORC memory models

Joubako's complete suite, secure-transport integration tests, hardening probes,
real-network E2E tests, and Valgrind leak probes run with both Nim memory
managers. The repository `config.nims` selects `--mm:arc` as the default;
passing `--mm:orc` explicitly overrides it without changing the Joubako API.

ARC deliberately does not collect reference cycles. Callbacks and interceptors
that outlive a request therefore must not capture the same async frame or owner
object that stores them. Put mutable callback state in a separate `ref object`
and create the callback outside the owning async procedure when necessary.
ORC adds cycle collection to ARC, but Joubako does not rely on cycles for
correctness. The leak probes follow the cycle-free pattern and fail if owned
allocations remain at process exit under either memory manager.

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

Asynchronous `then`, `catch`, and `finally` callbacks return another
`Future[JResult[T]]`. The chain waits for and flattens that Future, so recovery
and cleanup can perform non-blocking work without nesting callbacks:

```nim
let outcome = await api.getJson("users/42", User)
  .catch(proc(error: ref JoubakoError): Future[JResult[User]] =
    cachedUserAsync(error)
  )
  .finally(proc(): Future[JResult[void]] =
    stopLoadingAsync()
  )
```

An asynchronous callback that raises, returns an error Result, or incorrectly
returns a nil Future completes the outer chain with `JResult.Err`; it does not
create an unobserved failed Future.

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

## JSON-RPC 2.0

JSON-RPC method calls return typed results while keeping protocol-level method
errors distinct from transport, HTTP, limit, and decoding failures:

```nim
type Sum = object
  total: int

let outcome = await api.callJsonRpc(
  "rpc", "sum", %*[2, 3], Sum, jsonRpcId("sum-1")
)
if outcome.isErr:
  echo outcome.error.msg                 # network/HTTP/codec failure
elif outcome.value.isError:
  echo outcome.value.error.code          # JSON-RPC method error
else:
  echo outcome.value.result.total
```

Notifications deliberately omit `id` and require an empty protocol response:

```nim
let sent = await api.notifyJsonRpc("rpc", "audit", %*{"event": "login"})
```

Mixed batches accept responses in any order, match every response by its
string or integer ID, and reject duplicate, unknown, or missing IDs:

```nim
let replies = await api.sendJsonRpcBatch("rpc", [
  jsonRpcCall("user.get", jsonRpcId(1), %*{"id": 42}),
  jsonRpcNotification("audit", %*{"event": "lookup"}),
  jsonRpcCall("health", jsonRpcId("health"))
])
```

The same call API works over the one-request/one-response WebSocket transport
by constructing the client with `newWebSocketTransport()`. Long-lived,
multiplexed JSON-RPC sessions are intentionally not implied by this helper.
Request `maxResponseBytes`, cancellation, deadlines, host allowlists, retries,
and other Joubako policies continue to apply at the transport layer.

## NDJSON and JSON Text Sequences

Process large or unbounded JSON responses one typed record at a time without
retaining the complete response body:

```nim
type Event = object
  id: int
  message: string

let streamed = await api.getNdjsonAsync(
  "events",
  Event,
  proc(event: Event): Future[void] {.async.} =
    await persist(event)       # backpressure pauses the next network read
)
```

Use `getNdjsonAsync` and `getJsonSequenceAsync` for asynchronous handlers, or
the variants without `Async` for synchronous handlers. `postNdjson` and
`postJsonSequence` encode a sequence request and stream the sequence response;
asynchronous handler variants are available with the `Async` suffix.

The incremental parsers handle records split across arbitrary transport
chunks, enforce a per-record byte limit before unbounded accumulation, require
UTF-8, and fail closed on malformed records. NDJSON accepts LF and CRLF and
ignores empty lines by default; both choices are configurable. Its required
final LF is strict by default. JSON Text Sequences use the RFC 7464 RS/JSON/LF
wire format and detect possibly truncated top-level numbers. Malformed-record
recovery is available only through the explicit `skipInvalidRecords` option.

NDJSON uses `application/x-ndjson`; the registered JSON Text Sequence media
type is `application/json-seq`. See the
[NDJSON 1.0 specification](https://github.com/ndjson/ndjson-spec) and
[RFC 7464](https://www.rfc-editor.org/rfc/rfc7464.html).

## CBOR

Send compact binary RFC 8949 payloads without giving up Joubako's typed Result
and transport policy:

```nim
type
  Command = object
    id: uint64
    payload: seq[byte]

  Reply = object
    accepted: bool

let outcome = await api.postCbor(
  "commands",
  Command(id: 42, payload: @[0'u8, 1, 255]),
  Reply
)
if outcome.isOk and outcome.value.accepted:
  echo "accepted"
```

`postCbor`, `putCbor`, `patchCbor`, `sendCbor`, and `getCbor` use
`application/cbor` and preserve arbitrary binary bytes. A caller-provided
Content-Type or Accept header takes precedence; `application/*+cbor` responses
are accepted. Present incompatible response media types fail closed, while
requiring the header itself is configurable for compatibility with simple
servers.

`CborCodecOptions` exposes nesting, array, map, text, byte-string, and bignum
parser limits, a payload-size bound, and strict trailing-data rejection. The
normal Joubako request/response byte limits, status handling, retry,
cancellation, deadlines, and host policy still apply before decoding. Direct
`encodeCborPayload` and `decodeCborPayload` helpers use the same boundaries.
See [RFC 8949](https://www.rfc-editor.org/rfc/rfc8949.html).

## Protocol Buffers

Declare a proto3 schema directly in Nim and send its compact binary wire form:

```nim
type
  Command {.proto3.} = object
    id {.fieldNumber: 1, pint.}: uint64
    payload {.fieldNumber: 2.}: seq[byte]

  Reply {.proto3.} = object
    accepted {.fieldNumber: 1.}: bool

let outcome = await api.postProtobuf(
  "commands",
  Command(id: 42, payload: @[0'u8, 1, 255]),
  Reply
)
```

Existing proto3 schema files can generate the equivalent Nim types at compile
time without a separate `protoc` step:

```nim
from protobuf_serialization/proto_parser import import_proto3
import_proto3 "messages.proto3"
```

`postProtobuf`, `putProtobuf`, `patchProtobuf`, `sendProtobuf`, and
`getProtobuf` use the standard `application/protobuf` binary media type.
Common legacy media types can be accepted for existing services or disabled
for standard-only endpoints. Invalid binary `encoding`, `charset`, and
unversioned wire-format parameters fail closed.

The direct encode/decode helpers and HTTP codec enforce a payload bound in
addition to Joubako's streaming request/response limits. Schema validation,
required proto2 fields, packed values, nested messages, oneof, and unknown
field handling come from the maintained serialization dependency. Because the
Protobuf wire format is not self-delimiting, one HTTP body represents one
message; concatenated messages are interpreted using Protobuf's normal merge
semantics. See the official
[Protobuf overview](https://protobuf.dev/overview/) and
[MIME type rules](https://protobuf.dev/reference/protobuf/mime-types/).

## gRPC

Call a Protobuf service directly through Joubako's multiplexed HTTP/2
transport. The service and method become the canonical `/Service/Method` path:

```nim
let transport = newHttp2Transport()
let api = newClient(transport, "https://api.example.com")

let reply = await api.grpcUnary(
  "example.v1.Greeter",
  "SayHello",
  HelloRequest(name: "Nim"),
  HelloReply
)
```

Use `grpcUnaryCall` when successful response headers, completion trailers, or
the parsed completion status are needed alongside the decoded message.

Server streams use an awaited handler, so downstream work applies
backpressure instead of accumulating decoded messages:

```nim
let completed = await api.grpcServerStream(
  "example.v1.Events",
  "Watch",
  WatchRequest(topic: "releases"),
  Event,
  proc(event: Event): Future[void] {.async.} =
    await persist(event)
)
```

Client streams expose the same bounded `send`/`finish` lifecycle:

```nim
let stream = api.openGrpcClientStream(
  "example.v1.Metrics", "Collect", Metric, Summary
)
for metric in metrics:
  let sent = await stream.send(metric)
  if sent.isErr:
    return sent.error
let summary = await stream.finish()
```

For full duplex traffic, `openGrpcBidiStream` accepts an awaited response
handler. Request and response messages then advance independently while both
directions retain bounded backpressure:

```nim
let stream = api.openGrpcBidiStream(
  "example.v1.Chat", "Connect", ClientMessage, ServerMessage,
  proc(message: ServerMessage): Future[void] {.async.} =
    await inbox.store(message)
)
discard await stream.send(ClientMessage(text: "hello"))
let completed = await stream.finish()
```

Joubako emits the standard five-byte gRPC message envelope,
`application/grpc+proto`, `te: trailers`, and a deadline-derived
`grpc-timeout`. It validates negotiated HTTP/2, final `grpc-status`, message
counts and sizes, response media types, percent-encoded status messages, and
binary metadata. Non-OK statuses remain structured as `jeRpcStatus`, with
`grpcStatus`, `grpcMessage`, `grpcDetails`, and final metadata available from
the error.

Unary, client-streaming, server-streaming, and bidirectional RPCs are
supported. Per-message gzip compression is negotiated independently from HTTP
content encoding and works with every call shape:

```nim
var grpcOptions = defaultGrpcOptions()
grpcOptions.requestEncoding = geGzip
grpcOptions.acceptedEncodings = {geIdentity, geGzip}

let reply = await api.grpcUnary(
  "example.v1.Greeter",
  "SayHello",
  HelloRequest(name: "Nim"),
  HelloReply,
  grpcOptions = grpcOptions
)
```

`maxFrameBytes` bounds compressed wire bytes before buffering a complete
message, while `maxMessageBytes` bounds the expanded Protobuf payload during
decompression. Unknown, duplicate, unadvertised, corrupt, truncated, and
trailing-data encodings fail as structured errors. See the official
[gRPC over HTTP/2 protocol](https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-HTTP2.md).

## GraphQL

Build an executable document from typed values, then send it through the same
Joubako client, transport policy, limits, cancellation, and ARC/ORC-safe Result
boundary used by every other request:

```nim
import std/[asyncdispatch, json, options]
import joubako

type
  User = object
    id*: string
    name*: string

  UserData = object
    user*: User

proc main() {.async.} =
  let api = newClient(newHttpTransport(), "https://api.example.com/")
  let document = gqlQuery(
    "User",
    variables = [gqlVariableDefinition("id", "ID!")],
    selection = [gqlField(
      "user",
      arguments = [gqlArgument("id", gqlVariable("id"))],
      selection = [gqlField("id"), gqlField("name")]
    )]
  )

  let outcome = await api.executeGraphql(
    "graphql", document, UserData, %*{"id": "42"}
  )
  if outcome.isErr:
    echo outcome.error.msg
  elif outcome.value.hasErrors:
    echo outcome.value.errors[0].message
  elif outcome.value.data.isSome:
    echo outcome.value.data.get.user.name

waitFor main()
```

Names, type references, values, nesting, fragments, directives, duplicate
definitions, and the final executable syntax are validated before dispatch.
Multiple builder operations require a matching `operationName`. GraphQL
responses preserve partial typed `data`, structured `errors`, error paths and
locations, and `extensions` together instead of discarding useful partial
results.

For generated documents or migration code, `gqlSource` accepts a raw GraphQL
executable document while retaining parser validation and the standard request
and response envelope:

```nim
let document = gqlSource("query Health { health }")
let outcome = await api.executeGraphql("graphql", document, HealthData)
```

Long-lived operations use the modern `graphql-transport-ws` protocol directly.
Joubako verifies WebSocket subprotocol negotiation, waits for
`connection_ack`, answers application-level `ping` messages, bounds every
protocol message, and turns `next`, `error`, and `complete` into the same typed
GraphQL response model used by HTTP:

```nim
let document = gqlSubscription(
  "Notifications",
  selection = [gqlField(
    "notification",
    selection = [gqlField("id"), gqlField("message")]
  )]
)

var subscriptionOptions = defaultGraphqlSubscriptionOptions()
subscriptionOptions.cancellation = newCancellationToken()

let opened = await openGraphqlSubscription(
  "wss://api.example.com/graphql",
  document,
  NotificationData,
  connectionParams = %*{"accessToken": accessToken},
  options = subscriptionOptions
)

if opened.isErr:
  echo opened.error.msg
else:
  let subscription = opened.value
  while true:
    let event = await subscription.next()
    if event.isErr:
      echo event.error.msg
      break
    if event.value.isNone:
      break
    if event.value.get.hasErrors:
      echo event.value.get.errors[0].message
    elif event.value.get.data.isSome:
      echo event.value.get.data.get.notification.message
  discard await subscription.close()
```

HTTP upgrade headers and `connectionParams` are separate authentication
channels. Cancellation immediately closes an active receive and consumes its
pending Future. One `GraphqlSubscription` owns one WebSocket connection and
one operation, making completion and resource ownership explicit; callers can
open independent subscriptions concurrently with `allFutures` when needed.

NIFKit v0.2 integration accepts NIF text at the API boundary, transmits BIF v5
binary data, and decodes successful responses to canonical NIF text:

```nim
let created = await api.postNif(
  "/records",
  "(record title \"NIF\" -5 12u)"
)
if created.isErr:
  echo created.error.codecCode, " at byte ", created.error.codecOffset
else:
  echo created.value
```

`getNif`, `sendNif`, `postNif`, `putNif`, and `patchNif` use the provisional
`application/x-nif-bif` media type unless the caller supplies `Content-Type`.
Both conversion directions use finite NIFKit limits. They can be tightened
independently:

```nim
var nifOptions = defaultNifCodecOptions()
nifOptions.encodeLimits.maxInputBytes = 256 * 1024
nifOptions.decodeLimits.maxNestingDepth = 64

let response = await api.getNif("/records/7", codecOptions = nifOptions)
```

Malformed data, unsupported BIF versions, and input, output, nesting, token,
pool, string, and index limits become `jeCodec` with a machine-readable
`codecCode`. `codecOffset` is `-1` when NIFKit cannot identify a byte position.
NIFKit v0.2 does not yet implement its proposed typed Nim-value serializer, so
this API intentionally works with NIF text rather than pretending to provide
JSON-style object mapping.

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

## OpenTelemetry

`useOpenTelemetry` creates one HTTP CLIENT span for each logical Joubako
request, including all of its retry attempts. It injects a W3C `traceparent`,
continues valid parent context, preserves `tracestate`, and reports stable HTTP
semantic attributes such as `http.request.method`, `url.full`,
`server.address`, `server.port`, `http.response.status_code`, and `error.type`.

```nim
api.useOpenTelemetry(proc(span: OpenTelemetrySpan) =
  telemetryQueue.add span
)

let outcome = await api.get("/users/42")
```

The observer is the adapter boundary for an application-selected
OpenTelemetry SDK or OTLP exporter. Observer failures are isolated from the
request result. `span.semanticAttributes()` returns typed key/value entries,
while `attemptCount` and `retryCount` expose Joubako-specific resilience data.

For safety, URL userinfo and fragments are never recorded, and query strings
are excluded by default. Applications that have reviewed their query data may
enable them explicitly:

```nim
var telemetryOptions = defaultOpenTelemetryOptions()
telemetryOptions.captureQuery = true
api.useOpenTelemetry(exportSpan, telemetryOptions)
```

Call `clearOpenTelemetry()` to remove instrumentation and propagation from a
client.

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

### Server-Sent Events

`subscribeSse` validates `text/event-stream` before delivering the first body
chunk, parses events across arbitrary transport chunk boundaries, and applies
backpressure by awaiting asynchronous handlers. It supports comments,
multi-line `data`, event names, IDs, UTF-8 BOMs, CR/LF variants, server-provided
`retry` delays, bounded event sizes, cancellation, and `Last-Event-ID` on
reconnect.

```nim
var requestOptions = defaultRequestOptions()
requestOptions.timeoutMs = -1
requestOptions.cancellation = newCancellationToken()

let subscription = await api.subscribeSse(
  "/notifications",
  proc(event: ServerSentEvent): Future[void] {.async.} =
    echo event.event, ": ", event.data
  requestOptions = requestOptions
)

if subscription.isErr:
  echo subscription.error.msg
```

`defaultSseOptions()` reconnects until cancellation or an HTTP `204` response.
Set `maxReconnects` to zero for a one-shot stream or to a finite count for a
bounded subscription. A successful response with any content type other than
`text/event-stream` is rejected before its body is delivered as events.

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

Resume an existing partial file with a validated byte-range response. Preserve
the original response's ETag or Last-Modified value and pass it as `ifRange`
to prevent bytes from different revisions being combined:

```nim
let resumed = await api.resumeDownloadToFile(
  "exports/current",
  "/var/tmp/current-export.bin",
  ifRange = "\"export-revision-42\""
)
```

Joubako appends only after the peer returns HTTP `206`, identity encoding, and
a `Content-Range` beginning at the current file size. An ignored Range,
changed representation returned as `200`, malformed range, or transformed
body fails without modifying the existing partial file. File downloads use a
single transport attempt because retrying after streamed bytes have reached a
file can duplicate data; call `resumeDownloadToFile` again to continue safely.

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

### HTTP cache

Wrap a transport with `CachingTransport` to enable a bounded private cache.
The standard memory store is LRU-bounded by entry count, total bytes, and
per-entry bytes; applications can implement `HttpCacheStore` to use a file,
database, or platform cache instead.

```nim
let cache = newMemoryHttpCache(
  maxEntries = 256,
  maxBytes = 64 * 1024 * 1024
)
let transport = newCachingTransport(newHttpTransport(), cache)
let api = newClient(transport, "https://api.example.com/")

let response = await api.get("catalog")
if response.isOk and response.value.fromCache:
  echo "served without a network round trip"
```

The cache honors `Cache-Control: max-age`, `no-cache`, `no-store`, and
`only-if-cached`, plus `Age`, `Date`, `Expires`, `ETag`, `Last-Modified`, and
`Vary`. A `304 Not Modified` response refreshes cached metadata while retaining
the bounded body. Successful unsafe methods invalidate their request target
and same-origin `Location` or `Content-Location` targets.

Streaming and Range requests bypass caching. Requests containing
`Authorization` or `Cookie`, transports with an internal Cookie jar, and
responses containing `Set-Cookie` also bypass it by default. A private
application that deliberately partitions its cache by user may opt in through
`HttpCacheOptions`; the default never persists those personalized responses.
Cache-store failures are isolated from network results.

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
origin. Joubako configures OpenSSL hostname or IP-address verification for each
new pooled connection, in addition to validating the certificate chain.

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
`formFilePath` lets both HTTP/1.1 and HTTP/2 transports open and send the file
incrementally:

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
until the returned Future completes. HTTP/2 uploads retain the transmitted
filename rather than exposing the local path, can be replayed across 307/308
redirects, and remain cancellable while in progress. File-backed multipart is
HTTP-specific; IPC, WebSocket, and in-process transports reject it explicitly.

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

For a non-GraphQL long-lived connection, use `connectWebSocket`, `sendText`,
`receiveMessage`, and `close` directly. `connectWebSocket` also accepts an
explicit `subprotocol` and rejects a successful upgrade unless the server
selects it.

## Test

```sh
nimble test
nimble testOrc
nimble testSsl
nimble testSslOrc
```

Deterministic hardening targets are separate from the fast unit suite:

```sh
nimble fuzz
nimble fuzzOrc
nimble soak
nimble soakOrc
nimble e2eHost
nimble e2eHostOrc
nimble e2e
nimble e2eOrc
```

`fuzz` generates malformed Cookie, proxy-bypass, retry-date, query, gzip, and
deflate inputs from a fixed seed so CI failures are reproducible. Override
`JOUBAKO_FUZZ_ITERATIONS` to increase its default 10,000 iterations. `soak`
mixes successful typed serialization, retryable status responses, transport
disconnects, and bounded Cookie churn for 20,000 logical operations; use
`JOUBAKO_SOAK_ITERATIONS` for longer local runs.

`e2eHost` runs the same HTTP scenarios against independent Python backend and
redirect processes over real loopback TCP, so the transport can be validated
without Docker. `e2e` additionally builds a clean Nim/Joubako client container and sends real requests over
a Docker Compose network to independent backend and redirect containers. It
checks typed JSON, repeated query/header values, binary bodies, gzip, chunked
streaming, retry, cross-origin credential stripping, cookies, multipart,
file downloads, response limits, NIF/BIF, concurrent requests, and timeout
behavior without using the in-process transport or host loopback server. See
[`tests/e2e/README.md`](tests/e2e/README.md) for the topology and complete
scenario list.

`FaultInjectingTransport` provides deterministic scripted `transport`,
`timeout`, HTTP-status, delay, and pass-through steps for application tests.
It composes with normal retry, deadline, circuit-breaker, and cancellation
behavior without requiring a real network failure.

The HTTP integration test binds only to a local loopback socket.
`testSsl` performs real loopback TLS and mTLS handshakes and exercises an
authenticated SOCKS5h proxy without contacting the public network.
The IPC tests use a temporary Unix domain socket on POSIX systems.
CI runs ARC and ORC suites on Linux, macOS, and Windows with Nim 2.2.0 and the
current stable Nim release. Linux additionally builds both SSL configurations
and runs both secure-transport integration suites.

The allocation lifecycle probes run under Valgrind with ARC and ORC plus
`-d:useMalloc`, so Nim allocations are visible to Memcheck:

```sh
nimble leak
nimble leakOrc
```

It fails on definite, indirect, or possible leaks and exercises repeated
successful requests, typed JSON decoding, Promise callbacks, interceptors,
FlowBrigade-backed guards, structured HTTP and transport failures, `all`, and
discarded callback chains. Public request failures cross an internal settling
boundary and become `JResult.Err`, so the error-path probe also finishes with
zero definite, indirect, and possible loss under ARC and ORC without broad
Valgrind suppressions. ORC keeps its cycle-registration buffer reachable until
process exit; this is reported separately from lost memory. A dedicated
fault-injection probe additionally repeats retry recovery from transport and
HTTP failures.

AddressSanitizer probes exercise deterministic malformed codec, compression,
and gRPC inputs plus repeated asynchronous Result, callback, and file-streaming
lifecycles under both ARC and ORC:

```sh
ASAN_OPTIONS=detect_leaks=1:halt_on_error=1:abort_on_error=1 nimble asan
ASAN_OPTIONS=detect_leaks=1:halt_on_error=1:abort_on_error=1 nimble asanOrc
```

CI runs these probes with GCC ASan on Linux and Clang ASan on macOS and
Windows; the Windows build explicitly passes Nim's `--cc:clang` and does not
use MSVC ASan. LeakSanitizer is enabled only on Linux. The macOS and Windows
jobs explicitly use
`ASAN_OPTIONS=detect_leaks=0`; they still fail on AddressSanitizer findings
such as out-of-bounds access, use-after-free, and double-free. Valgrind remains
the separate Linux allocation-leak gate.

## Benchmark

```sh
nimble benchmark
nimble benchmarkNetwork
nimble benchmarkNetworkOrc
```

The local benchmark reports request construction/dispatch, typed JSON decode,
Promise callback dispatch, and one-failure retry overhead separately from
network latency. `benchmarkNetwork` starts the same local Node.js HTTP/2 peer
used by the interoperability tests and separately measures sequential HTTP/2,
multiplexed concurrent HTTP/2, bounded streaming upload throughput, unary
gRPC, and gzip-compressed unary gRPC. It requires Node.js and an HTTP/2-capable
system libcurl and never contacts the public network. The ARC and ORC tasks
run the same workload.

The network workload can be scaled and emitted as JSON Lines for repeatable
release measurements:

```sh
JOUBAKO_NETWORK_BENCH_ITERATIONS=1000 \
JOUBAKO_NETWORK_BENCH_CONCURRENCY=64 \
JOUBAKO_NETWORK_BENCH_UPLOAD_BYTES=4194304 \
JOUBAKO_NETWORK_BENCH_FORMAT=jsonl \
nimble benchmarkNetwork
```

Network benchmark results are descriptive measurements of the current host,
not pass/fail thresholds. The HTTP/2 and gRPC integration suites remain the
correctness gate. A checked-in [reference ARC/ORC run](docs/network-benchmark.md)
documents the exact workload and host environment.

## License

Joubako is licensed under the
[Apache License 2.0](LICENSE). Third-party components retain their respective
licenses as documented in
[`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md).
