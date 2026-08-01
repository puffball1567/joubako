import std/[asyncdispatch, times]
import joubako

const Iterations = 2_000

proc okHandler(request: Request): Future[Response] {.async.} =
  return Response(status: 200, body: "ok", request: request)

proc failingHandler(request: Request): Future[Response] {.async.} =
  raise newJoubakoError(jeTransport, "delegate failed", request.url)

proc noWait(_: Duration): Future[void] {.async.} =
  discard

proc main(): Future[void] {.async.} =
  for index in 0 ..< Iterations:
    let fault =
      if index mod 2 == 0: transportFault("offline")
      else: statusFault(503, "unavailable")
    let transport = newFaultInjectingTransport(
      newInProcessTransport(okHandler), [fault, passThrough()]
    )
    let client = newClient(transport)
    var options = defaultRequestOptions()
    options.retry = defaultHttpRetryOptions()
    options.retry.maxAttempts = 2
    options.retry.sleep = noWait
    let outcome = await client.get("/probe", options = options)
    doAssert outcome.isOk
    doAssert transport.callCount == 2

    if index mod 4 == 0:
      let delegated = newClient(newFaultInjectingTransport(
        newInProcessTransport(failingHandler), [passThrough()]
      ))
      let failed = await delegated.get("/delegate-failure")
      doAssert failed.isErr
      doAssert failed.error.kind == jeTransport

waitFor main()
