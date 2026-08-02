import std/[asyncdispatch, monotimes, strformat, times]
import joubako

const Iterations = 10_000

proc report(name: string; started: MonoTime; iterations: int) =
  let elapsed = getMonoTime() - started
  let nanos = elapsed.inNanoseconds div int64(iterations)
  echo &"{name}: {nanos} ns/op ({iterations} iterations)"

proc benchRequests(): Future[void] {.async.} =
  let transport = newInProcessTransport(
    proc(request: Request): Future[Response] {.async.} =
      return Response(status: 200, body: "ok", request: request)
  )
  let client = newClient(transport, "inprocess://benchmark/")
  let started = getMonoTime()
  for index in 0 ..< Iterations:
    let outcome = await client.get("items/" & $index)
    doAssert outcome.isOk
  report("request construction and dispatch", started, Iterations)

proc benchCallbacks(): Future[void] {.async.} =
  let started = getMonoTime()
  for index in 0 ..< Iterations:
    let outcome = await completedResult(ok(index))
      .then(proc(value: int): int = value + 1)
      .then(proc(value: int): int = value * 2)
      .finally(proc() = discard)
    doAssert outcome.isOk
    doAssert outcome.value == (index + 1) * 2
  report("then/finally callback dispatch", started, Iterations)

proc benchCodec() =
  type Payload = object
    id: int
    name: string
  let response = Response(
    status: 200,
    body: """{"id":7,"name":"benchmark"}""",
    request: Request(url: "benchmark://json")
  )
  let started = getMonoTime()
  for index in 0 ..< Iterations:
    discard index
    discard response.decodeJson(Payload)
  report("typed JSON decode", started, Iterations)

proc benchRetry(): Future[void] {.async.} =
  var attempt = 0
  let transport = newInProcessTransport(
    proc(request: Request): Future[Response] {.async.} =
      inc attempt
      if attempt mod 2 == 1:
        return Response(status: 503, request: request)
      return Response(status: 200, request: request)
  )
  let client = newClient(transport)
  var options = defaultRequestOptions()
  options.timeoutMs = -1
  options.retry = defaultHttpRetryOptions()
  options.retry.maxAttempts = 2
  options.retry.sleep =
    proc(delay: Duration): Future[void] {.async.} =
      discard delay
  let iterations = Iterations div 5
  let started = getMonoTime()
  for index in 0 ..< iterations:
    discard index
    let outcome = await client.get("/", options = options)
    doAssert outcome.isOk
  report("one-failure retry path", started, iterations)

when isMainModule:
  waitFor benchRequests()
  waitFor benchCallbacks()
  benchCodec()
  waitFor benchRetry()
