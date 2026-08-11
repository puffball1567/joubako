import std/asyncdispatch
import joubako

proc success(request: Request): Future[Response] {.async.} =
  return Response(status: 200, body: "ok", request: request)

proc unavailable(request: Request): Future[Response] {.async.} =
  return Response(status: 503, body: "unavailable", request: request)

proc observe(span: OpenTelemetrySpan) =
  doAssert span.traceId.len == 32
  doAssert span.spanId.len == 16
  doAssert span.durationNano >= 0

proc rejectingObserver(span: OpenTelemetrySpan) =
  discard span
  raise newException(ValueError, "export rejected")

proc exercise(): Future[void] {.async.} =
  for iteration in 0 ..< 100:
    discard iteration
    block:
      let client = newClient(newInProcessTransport(success))
      client.useOpenTelemetry(observe)
      let outcome = await client.get("https://api.example.com/ok?secret=1")
      doAssert outcome.isOk

    block:
      let client = newClient(newInProcessTransport(unavailable))
      client.useOpenTelemetry(observe)
      let outcome = await client.get("https://api.example.com/down")
      doAssert outcome.isErr
      doAssert outcome.error.kind == jeHttpStatus

    block:
      let client = newClient(newInProcessTransport(success))
      client.useOpenTelemetry(rejectingObserver)
      let outcome = await client.get("https://api.example.com/observed")
      doAssert outcome.isOk

waitFor exercise()
