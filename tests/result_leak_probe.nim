import std/asyncdispatch
import joubako

const Iterations = 800

proc rawFailure(index: int): Future[int] =
  result = newFuture[int]("resultLeak.rawFailure")
  result.fail(newException(IOError, "failure " & $index))

proc safeValue(value: int): Future[JResult[int]] =
  completedResult(ok(value))

proc safeError(index: int): Future[JResult[int]] =
  completedResult(err[int](
    newJoubakoError(jeTransport, "safe failure " & $index)
  ))

proc missingHandler(request: Request): Future[Response] {.async.} =
  if request.url == "offline":
    raise newException(IOError, "offline")
  return Response(status: 404, request: request)

proc main(): Future[void] {.async.} =
  var callbackTotal = 0
  let client = newClient(newInProcessTransport(missingHandler))
  for index in 0 ..< Iterations:
    let raw = rawFailure(index)
    let normalized = settle(fallible(raw))
    let settled = await normalized
    doAssert settled.isErr

    let recovery = safeError(index)
      .then(proc(value: int): int = value + 1)
      .catch(proc(error: ref JoubakoError): int =
        doAssert error.kind == jeTransport
        index
      )
    let recovered = await recovery
    doAssert recovered.isOk
    doAssert recovered.value == index

    let response = await client.get("missing")
    doAssert response.isErr
    doAssert response.error.kind == jeHttpStatus

    let offline = await client.get("offline")
    doAssert offline.isErr
    doAssert offline.error.kind == jeTransport

    let parallel = await all(safeValue(index), safeError(index))
    doAssert parallel.isErr

    discard safeValue(index).then(
      proc(value: int) = callbackTotal += value
    )

  doAssert callbackTotal == (Iterations - 1) * Iterations div 2

let probe = main()
waitFor probe
probe.clearCallbacks()
