# Joubako Vision

## Name

Joubako is named after the Japanese `joubako` (状箱): a small box used to
carry letters, including letters entrusted to a messenger. The name represents
a client that carries application requests and their responses across process
and network boundaries.

## Purpose

Joubako is a transport client for native applications. It provides a concise,
asynchronous API for calling application backends and external services without
coupling that API to a particular GUI toolkit.

The initial objective is an ergonomic Nim alternative to the common
request/response workflow associated with browser-side libraries such as Axios.
Operations return `Future[JResult[T]]` values so callers can use both Nim's
standard `await` and Promise-style composition without making operational
failure a failed Future:

```nim
let usersResult = await client.getJson(
  "https://api.example.com/users",
  seq[User]
)
if usersResult.isErr:
  showRequestError(usersResult.error)
  return
renderUsers(usersResult.value)

client.getJson("https://api.example.com/users", seq[User])
  .then(renderUsers)
  .catch(showRequestError)
  .finally(stopLoading)
```

`then`, `catch`, and `finally` are control-flow APIs for completion callbacks,
error recovery, and cleanup; they are not merely aliases for `await`. The exact
surface syntax is not fixed. The important contract is that the request API
remains non-blocking, typed where possible, and suitable for event handlers in
a native UI.

Expected transport, timeout, cancellation, status, size, and codec failures are
`JResult.Err` values. Joubako consumes any failed internal Future at its
settling boundary. Applications do not call that internal boundary and do not
need a custom await operator.

Joubako is independent from Clay Board Style System (CBSS). A CBSS application
may call Joubako from an event handler, but Joubako must also work in command
line tools, services, tests, and other native applications.

## Scope

Joubako has three deliberately separate layers.

```text
Application
  -> request API and callbacks
  -> transport selection
  -> serialization codec
  -> remote process, local process, or service
```

### Request API

The public API owns request construction, response handling, cancellation,
deadlines, callback composition, and diagnostics. It must not force a GUI
dependency or a global event loop onto the application.

Request and response interceptors may perform synchronous or asynchronous
work. They run in registration order and can be removed by their registration
ID. Typical uses include authentication headers, tracing, metrics, and common
response normalization.

### Transports

Transports carry bytes. Initial work should focus on HTTP(S), using a mature
Nim or native HTTP implementation rather than creating a new HTTP parser or
TLS stack. Planned transport adapters are:

- HTTP(S)
- local IPC, including Unix domain sockets where supported
- WebSocket where a long-lived bidirectional connection is appropriate
- in-process transport for tests and local composition

Each transport must implement the same cancellation, deadline, size-limit, and
error-reporting contracts.

### Codecs

JSON is the default interoperability format. NIF/BIF through NIFKit is an
optional codec for typed, efficient communication between cooperating native
programs. NIF is data, not executable code.

Codec selection must be explicit per request or client. JSON remains the
portable default for external APIs.

## Relationship With FlowBrigade

Joubako should use FlowBrigade for generic resilience mechanisms rather than
copying retry, backoff, deadline, circuit-breaker, rate-limit, or bulkhead
logic.

The responsibility boundary is:

| Concern | Owner |
| --- | --- |
| Backoff calculation, asynchronous waiting, deadlines, circuit breaker, bulkhead | FlowBrigade |
| Result-valued HTTP attempt loop | Joubako, using FlowBrigade primitives |
| HTTP status classification, idempotency, request-body replayability, `Retry-After` | Joubako |
| Business decision after success or failure | Application |

Joubako depends on FlowBrigade 0.5 or newer. The following capabilities are a
compatibility requirement for that dependency:

1. A retry predicate so that cancellation and permanent errors are not retried.
2. An asynchronous retry observer for status UI, metrics, logs, and tests.
3. Deadline-aware retry waiting and termination.
4. A bounded half-open probe mechanism in the circuit breaker.
5. Deterministic, injectable jitter for tests, with a clear definition of
   decorrelated jitter.

Joubako must never run FlowBrigade's blocking retry API on a UI thread. It uses
FlowBrigade's asynchronous wait, deadline, observer, and backoff policy
primitives while keeping HTTP classification and Result-valued attempt control
inside Joubako.

## HTTP Retry Policy

HTTP retry policy is intentionally outside FlowBrigade because it depends on
HTTP semantics. Joubako will decide whether an attempt is retryable from:

- the HTTP method and an explicit idempotency declaration;
- whether the request body can be replayed safely;
- network and timeout errors;
- response status and service-specific error codes;
- a `Retry-After` response header;
- the request's remaining total deadline;
- caller cancellation.

No request is retried merely because it failed. In particular, cancellation,
invalid input, authentication failures, and non-replayable writes must stop
immediately unless the application explicitly opts in.

Retry is disabled by default. Safe HTTP methods are treated as idempotent;
unsafe methods require an explicit idempotency declaration. A request's total
deadline covers attempts and retry waits. `Retry-After` may extend the
FlowBrigade backoff delay but is clamped to the remaining total deadline.

## UI Integration

Joubako does not own application state or business logic. A UI event handler
starts a request and updates state only from its completion callback.

```nim
saveButton.onClick = proc() =
  api.post("/documents", documentPayload)
    .then(proc(response: Response) = documentStore.replace(response.document))
    .catch(proc(error: JoubakoError) = notification.showError(error.message))
```

The API must make it straightforward to cancel work associated with a removed
view, a changed selection, or a superseded request. Completion callbacks must
not mutate stale UI state accidentally.

## Security Baseline

Joubako must preserve secure transport defaults and make unsafe behavior
explicit. The baseline includes:

- TLS certificate validation enabled by default;
- bounded request and response body sizes;
- connect, read, and total deadlines;
- cancellation that interrupts pending work where the transport supports it;
- redirect handling that does not forward credentials across origins by
  default;
- structured URL and header handling rather than string concatenation;
- optional host allowlists for applications that need them;
- NIF decoding limits for payload size, nesting depth, and schema/version
  validation.

Buffered transports must enforce response limits while consuming the stream,
before appending a chunk that would exceed the limit. `Content-Length` may be
used for early rejection but must never be treated as the sole size check.

Joubako is not a browser sandbox. Origin policy, authorization, and trust in a
remote service remain application decisions.

## Non-Goals

Joubako will not:

- implement a GUI toolkit or state-management framework;
- implement business workflows, authentication UI, or server-side logic;
- replace a mature HTTP parser, TLS implementation, or operating-system IPC
  primitive;
- silently retry all failures;
- require JSON when both parties deliberately use NIF;
- make browser-only constraints such as CORS part of native request behavior.

## Initial Delivery Order

1. Define transport, response, error, deadline, cancellation, and codec
   interfaces.
2. Complete the required FlowBrigade improvements and their tests.
3. Implement HTTP(S) with JSON request/response helpers.
4. Add typed query, headers, body, and response APIs.
5. Add `then`, `catch`, `finally`, and cancellation ergonomics over Nim's
   asynchronous primitives.
6. Add NIFKit codec support behind an explicit dependency/feature boundary.
7. Add local IPC and in-process test transports.
8. Add WebSocket only after the common lifecycle and cancellation model is
   stable.

## Verification

The project should have unit, integration, and transport-level tests from the
first implementation. Essential cases include:

- cancellation during connect, read, retry wait, and callback dispatch;
- total deadlines across multiple attempts;
- repeated requests and concurrent requests without UI-thread blocking;
- retry classification, idempotency, and `Retry-After` behavior;
- response/body limit enforcement;
- JSON and NIF round trips plus malformed-payload rejection;
- local IPC cleanup and failed-peer handling.

Benchmarks should measure request construction, codec work, callback dispatch,
and retry overhead separately from remote network latency.
