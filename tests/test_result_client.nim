import std/[asyncdispatch, strutils, unittest]
import joubako

proc handler(request: Request): Future[Response] {.async.} =
  if request.url.endsWith("missing"):
    return Response(status: 404, request: request)
  return Response(status: 200, body: "ok", request: request)

type SynchronousFailureTransport = ref object of Transport

method send(
    transport: SynchronousFailureTransport;
    request: Request
): Future[Response] =
  discard transport
  raise newException(IOError, "synchronous dispatch failure: " & request.url)

suite "Result-valued client API":
  test "await returns Ok for a successful request":
    let client = newClient(newInProcessTransport(handler))
    let outcome = waitFor client.get("success")
    check outcome.isOk
    check outcome.value.body == "ok"

  test "await returns Err instead of raising for HTTP failures":
    let client = newClient(newInProcessTransport(handler))
    let pending = client.get("missing")
    let outcome = waitFor pending
    check not pending.failed
    check outcome.isErr
    check outcome.error.kind == jeHttpStatus
    check outcome.error.status == 404

  test "then and catch operate on Result without await":
    let client = newClient(newInProcessTransport(handler))
    let pending = client.get("missing")
      .then(proc(response: Response): int = response.status)
      .catch(proc(error: ref JoubakoError): int = error.status)
    let outcome = waitFor pending
    check outcome.isOk
    check outcome.value == 404

  test "synchronous transport failures remain Result values":
    let client = newClient(SynchronousFailureTransport())
    let pending = client.get("/sync-failure")
    let outcome = waitFor pending
    check not pending.failed
    check outcome.isErr
    check outcome.error.kind == jeTransport
    check outcome.error.msg.startsWith("synchronous dispatch failure")

  test "telemetry observers cannot turn a request into a failed Future":
    let client = newClient(newInProcessTransport(handler))
    client.useOpenTelemetry(
      proc(_: OpenTelemetrySpan) =
        raise newException(IOError, "observer failure")
    )
    let pending = client.get("success")
    let outcome = waitFor pending
    check not pending.failed
    check outcome.isOk
    check outcome.value.body == "ok"
