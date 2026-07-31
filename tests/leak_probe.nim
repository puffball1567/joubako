import std/[asyncdispatch, strutils, times]
import joubako

const Iterations = 2_000

type DispatchStats = ref object
  count: int

proc newProbeHandler(stats: DispatchStats): InProcessHandler =
  result =
    proc(request: Request): Future[Response] {.async.} =
      inc stats.count
      if request.url.endsWith("/failure"):
        return Response(status: 503, body: "failure", request: request)
      return Response(
        status: 200,
        body: """{"id":7,"name":"leak-probe"}""",
        request: request
      )

proc main(): Future[void] {.async.} =
  let stats = DispatchStats()
  let transport = newInProcessTransport(newProbeHandler(stats))
  let client = newClient(transport, "inprocess://leak/")
  client.useBulkhead(8)
  client.useCircuitBreaker(
    failureThreshold = Iterations + 1,
    resetAfter = initDuration(seconds = 1)
  )
  client.useRateLimit(
    rate = Iterations * 2,
    per = initDuration(seconds = 1),
    burst = Iterations * 2
  )
  discard client.useRequestInterceptor(
    proc(request: Request): Request = request
  )
  discard client.useResponseInterceptor(
    proc(response: Response): Response = response
  )

  type Payload = object
    id: int
    name: string

  for index in 0 ..< Iterations:
    if index mod 2 == 0:
      let payload = await client.getJson("success", Payload)
      doAssert payload.isOk
      doAssert payload.value.id == 7
    else:
      let status = await client.get("success")
        .then(proc(response: Response): int = response.status)
        .finally(proc() = discard)
      doAssert status.isOk
      doAssert status.value == 200

  doAssert stats.count > 0

let probe = main()
waitFor probe
probe.clearCallbacks()
