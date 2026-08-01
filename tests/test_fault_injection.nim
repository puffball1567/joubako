import std/[asyncdispatch, strutils, times, unittest]
import joubako
import ./result_test_helpers

proc okHandler(request: Request): Future[Response] {.async.} =
  return Response(status: 200, body: "ok", request: request)

proc noWait(_: Duration): Future[void] {.async.} =
  discard

suite "Fault injection transport":
  test "scripted transport failures are structured":
    let faults = newFaultInjectingTransport(
      newInProcessTransport(okHandler),
      [transportFault("offline")]
    )
    let client = newClient(faults)
    try:
      discard waitFor client.get("/failure")
      fail()
    except JoubakoError as error:
      check error.kind == jeTransport
      check error.msg.startsWith("offline")
    check faults.callCount == 1

  test "scripted status failures participate in retry":
    let faults = newFaultInjectingTransport(
      newInProcessTransport(okHandler),
      [statusFault(503, "unavailable"), passThrough()]
    )
    let client = newClient(faults)
    var options = defaultRequestOptions()
    options.retry = defaultHttpRetryOptions()
    options.retry.sleep = noWait
    check waitFor(client.get("/retry", options = options)).body == "ok"
    check faults.callCount == 2

  test "timeout faults participate in retry":
    let faults = newFaultInjectingTransport(
      newInProcessTransport(okHandler),
      [timeoutFault(), passThrough()]
    )
    let client = newClient(faults)
    var options = defaultRequestOptions()
    options.retry = defaultHttpRetryOptions()
    options.retry.sleep = noWait
    check waitFor(client.get("/retry", options = options)).status == 200
    check faults.callCount == 2

  test "repeatLast sustains a failure after the script ends":
    let faults = newFaultInjectingTransport(
      newInProcessTransport(okHandler),
      [statusFault(503)],
      repeatLast = true
    )
    let client = newClient(faults)
    var options = defaultRequestOptions()
    options.retry = defaultHttpRetryOptions()
    options.retry.sleep = noWait
    try:
      discard waitFor client.get("/down", options = options)
      fail()
    except JoubakoError as error:
      check error.kind == jeHttpStatus
      check error.attempts == 3
    check faults.callCount == 3

  test "a delay can trigger the client deadline":
    let faults = newFaultInjectingTransport(
      newInProcessTransport(okHandler),
      [delayFault(initDuration(milliseconds = 100))]
    )
    let client = newClient(faults)
    var options = defaultRequestOptions()
    options.timeoutMs = 5
    try:
      discard waitFor client.get("/slow", options = options)
      fail()
    except JoubakoError as error:
      check error.kind == jeTimeout

  test "cancellation interrupts an injected delay":
    let faults = newFaultInjectingTransport(
      newInProcessTransport(okHandler),
      [delayFault(initDuration(seconds = 1))]
    )
    let client = newClient(faults)
    let token = newCancellationToken()
    var options = defaultRequestOptions()
    options.cancellation = token
    let pending = client.get("/cancel", options = options)
    let cancelSoon = proc(): Future[void] {.async.} =
      await sleepAsync(1)
      token.cancel("injected operation cancelled")
    asyncCheck cancelSoon()
    try:
      discard waitFor pending
      fail()
    except JoubakoError as error:
      check error.kind == jeCancelled
      check error.msg.startsWith("injected operation cancelled")

  test "an empty script delegates every request":
    let faults = newFaultInjectingTransport(
      newInProcessTransport(okHandler),
      newSeq[FaultStep]()
    )
    let client = newClient(faults)
    check waitFor(client.get("/one")).body == "ok"
    check waitFor(client.get("/two")).body == "ok"
    check faults.callCount == 2

  test "pass-through without a delegate is rejected":
    let faults = newFaultInjectingTransport(nil, [passThrough()])
    let client = newClient(faults)
    try:
      discard waitFor client.get("/missing")
      fail()
    except JoubakoError as error:
      check error.kind == jeInvalidRequest
