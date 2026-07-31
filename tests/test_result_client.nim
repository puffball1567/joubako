import std/[asyncdispatch, strutils, unittest]
import joubako

proc handler(request: Request): Future[Response] {.async.} =
  if request.url.endsWith("missing"):
    return Response(status: 404, request: request)
  return Response(status: 200, body: "ok", request: request)

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
