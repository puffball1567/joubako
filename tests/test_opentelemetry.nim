import std/[asyncdispatch, sequtils, strutils, times, unittest]
import flowbrigade/backoff
import joubako

const
  ParentTraceId = "0af7651916cd43dd8448eb211c80319c"
  ParentSpanId = "b7ad6b7169203331"
  ParentHeader = "00-" & ParentTraceId & "-" & ParentSpanId & "-01"

proc success(request: Request): Future[Response] {.async.} =
  return Response(status: 200, body: "ok", request: request)

proc noWait(delay: Duration): Future[void] {.async.} =
  discard delay

proc attributesByKey(
    span: OpenTelemetrySpan
): seq[string] =
  span.semanticAttributes.mapIt(it.key)

suite "W3C trace context":
  test "accepts a valid version 00 traceparent":
    check ParentHeader.validTraceParent

  test "accepts uppercase hexadecimal input":
    check ParentHeader.toUpperAscii.validTraceParent

  test "rejects malformed lengths separators and hex":
    check not "".validTraceParent
    check not "00-short-b7ad6b7169203331-01".validTraceParent
    check not "00-0af7651916cd43dd8448eb211c80319c-bad-01".validTraceParent
    check not "00_0af7651916cd43dd8448eb211c80319c_b7ad6b7169203331_01".validTraceParent
    check not "00-0af7651916cd43dd8448eb211c80319g-b7ad6b7169203331-01".validTraceParent

  test "rejects forbidden version and all-zero identifiers":
    check not ("ff-" & ParentTraceId & "-" & ParentSpanId & "-01").validTraceParent
    check not ("00-" & repeat('0', 32) & "-" & ParentSpanId & "-01").validTraceParent
    check not ("00-" & ParentTraceId & "-" & repeat('0', 16) & "-01").validTraceParent

suite "OpenTelemetry HTTP client instrumentation":
  test "creates a client span and injects traceparent":
    var sentTraceParent = ""
    var spans: seq[OpenTelemetrySpan]
    let handler = proc(request: Request): Future[Response] {.async.} =
      sentTraceParent = request.headers.get("traceparent")
      return Response(status: 200, body: "ok", request: request)
    let client = newClient(
      newInProcessTransport(handler),
      "https://api.example.com:8443/v1/"
    )
    client.useOpenTelemetry(proc(span: OpenTelemetrySpan) = spans.add span)

    let outcome = waitFor client.get("users?id=secret#fragment")

    check outcome.isOk
    check sentTraceParent.validTraceParent
    check spans.len == 1
    check spans[0].kind == "CLIENT"
    check spans[0].name == "GET"
    check spans[0].httpRequestMethod == "GET"
    check spans[0].urlFull == "https://api.example.com:8443/v1/users"
    check spans[0].serverAddress == "api.example.com"
    check spans[0].serverPort == 8443
    check spans[0].httpResponseStatusCode == 200
    check spans[0].status == otelOk
    check spans[0].attemptCount == 1
    check spans[0].retryCount == 0
    check spans[0].durationNano >= 0
    check spans[0].endTimeUnixNano >= spans[0].startTimeUnixNano

  test "continues an existing parent and preserves tracestate":
    var requestHeaders = initHeaders()
    requestHeaders.set("traceparent", ParentHeader)
    requestHeaders.set("tracestate", "vendor=value")
    var sent = initHeaders()
    var span: OpenTelemetrySpan
    let handler = proc(request: Request): Future[Response] {.async.} =
      sent = request.headers
      return Response(status: 200, request: request)
    let client = newClient(newInProcessTransport(handler))
    client.useOpenTelemetry(proc(finished: OpenTelemetrySpan) = span = finished)

    discard waitFor client.get("https://api.example.com/items", requestHeaders)

    check span.traceId == ParentTraceId
    check span.parentSpanId == ParentSpanId
    check span.traceFlags == "01"
    check span.traceState == "vendor=value"
    check sent.get("traceparent").startsWith("00-" & ParentTraceId & "-")
    check sent.get("traceparent") != ParentHeader
    check sent.get("tracestate") == "vendor=value"

  test "invalid parent context starts a new root span":
    var headers = initHeaders()
    headers.set("traceparent", "invalid")
    var span: OpenTelemetrySpan
    let client = newClient(newInProcessTransport(success))
    client.useOpenTelemetry(proc(finished: OpenTelemetrySpan) = span = finished)

    let outcome = waitFor client.get("https://api.example.com/", headers)

    check outcome.isOk
    check span.parentSpanId == ""
    check span.traceId.len == 32
    check span.spanId.len == 16

  test "unsampled roots propagate flag 00":
    var sentTraceParent = ""
    var options = defaultOpenTelemetryOptions()
    options.sampled = false
    let handler = proc(request: Request): Future[Response] {.async.} =
      sentTraceParent = request.headers.get("traceparent")
      return Response(status: 200, request: request)
    let client = newClient(newInProcessTransport(handler))
    let observer = proc(span: OpenTelemetrySpan) = discard
    client.useOpenTelemetry(observer, options)

    discard waitFor client.get("https://api.example.com/")

    check sentTraceParent.endsWith("-00")

  test "propagation can be disabled without disabling spans":
    var sentTraceParent = ""
    var spans = 0
    var options = defaultOpenTelemetryOptions()
    options.propagateTraceContext = false
    let handler = proc(request: Request): Future[Response] {.async.} =
      sentTraceParent = request.headers.get("traceparent")
      return Response(status: 200, request: request)
    let client = newClient(newInProcessTransport(handler))
    let observer = proc(span: OpenTelemetrySpan) = inc spans
    client.useOpenTelemetry(observer, options)

    discard waitFor client.get("https://api.example.com/")

    check sentTraceParent == ""
    check spans == 1

  test "query capture is explicit and userinfo is always removed":
    var options = defaultOpenTelemetryOptions()
    options.captureQuery = true
    var span: OpenTelemetrySpan
    let client = newClient(newInProcessTransport(success))
    let observer = proc(finished: OpenTelemetrySpan) = span = finished
    client.useOpenTelemetry(observer, options)

    discard waitFor client.get("https://user:pass@example.com/path?q=visible#hidden")

    check span.urlFull == "https://example.com/path?q=visible"
    check "user" notin span.urlFull
    check "pass" notin span.urlFull
    check "hidden" notin span.urlFull

  test "HTTP status failures finish an error span":
    var span: OpenTelemetrySpan
    let handler = proc(request: Request): Future[Response] {.async.} =
      return Response(status: 503, body: "unavailable", request: request)
    let client = newClient(newInProcessTransport(handler))
    client.useOpenTelemetry(proc(finished: OpenTelemetrySpan) = span = finished)

    let outcome = waitFor client.get("https://api.example.com/down")

    check outcome.isErr
    check span.status == otelError
    check span.httpResponseStatusCode == 503
    check span.errorType == "jeHttpStatus"
    check span.attemptCount == 1

  test "transport failures retain their structured error type":
    var span: OpenTelemetrySpan
    let handler = proc(request: Request): Future[Response] {.async.} =
      raise newJoubakoError(jeTransport, "offline", request.url)
    let client = newClient(newInProcessTransport(handler))
    client.useOpenTelemetry(proc(finished: OpenTelemetrySpan) = span = finished)

    let outcome = waitFor client.get("https://api.example.com/down")

    check outcome.isErr
    check span.status == otelError
    check span.errorType == "jeTransport"
    check span.httpResponseStatusCode == 0

  test "a logical retry produces one span with attempt counts":
    var calls = 0
    var span: OpenTelemetrySpan
    let handler = proc(request: Request): Future[Response] {.async.} =
      inc calls
      return Response(
        status: if calls == 1: 503 else: 200,
        request: request
      )
    let client = newClient(newInProcessTransport(handler))
    client.useOpenTelemetry(proc(finished: OpenTelemetrySpan) = span = finished)
    var requestOptions = defaultRequestOptions()
    requestOptions.retry = defaultHttpRetryOptions()
    requestOptions.retry.backoff = fixedBackoff(initDuration(milliseconds = 1))
    requestOptions.retry.sleep = noWait

    let outcome = waitFor client.get(
      "https://api.example.com/retry", options = requestOptions
    )

    check outcome.isOk
    check calls == 2
    check span.attemptCount == 2
    check span.retryCount == 1

  test "observer exceptions never change the request result":
    let client = newClient(newInProcessTransport(success))
    client.useOpenTelemetry(proc(span: OpenTelemetrySpan) =
      raise newException(ValueError, "export queue full")
    )

    let outcome = waitFor client.get("https://api.example.com/")

    check outcome.isOk

  test "clearOpenTelemetry stops spans and propagation":
    var observed = 0
    var sent = ""
    let handler = proc(request: Request): Future[Response] {.async.} =
      sent = request.headers.get("traceparent")
      return Response(status: 200, request: request)
    let client = newClient(newInProcessTransport(handler))
    client.useOpenTelemetry(proc(span: OpenTelemetrySpan) = inc observed)
    client.clearOpenTelemetry()

    discard waitFor client.get("https://api.example.com/")

    check observed == 0
    check sent == ""

  test "semantic attributes use stable OpenTelemetry names":
    var span: OpenTelemetrySpan
    let client = newClient(newInProcessTransport(success))
    client.useOpenTelemetry(proc(finished: OpenTelemetrySpan) = span = finished)

    discard waitFor client.get("https://api.example.com:9443/items")
    let keys = span.attributesByKey

    check "http.request.method" in keys
    check "url.full" in keys
    check "server.address" in keys
    check "server.port" in keys
    check "http.response.status_code" in keys
    check "joubako.request.attempt_count" in keys
    check "joubako.request.retry_count" in keys
    check "error.type" notin keys

  test "concurrent requests receive distinct child span IDs":
    var spans: seq[OpenTelemetrySpan]
    let client = newClient(newInProcessTransport(success))
    client.useOpenTelemetry(proc(span: OpenTelemetrySpan) = spans.add span)

    let first = client.get("https://api.example.com/a")
    let second = client.get("https://api.example.com/b")
    discard waitFor all(first, second)

    check spans.len == 2
    check spans[0].traceId != spans[1].traceId
    check spans[0].spanId != spans[1].spanId
