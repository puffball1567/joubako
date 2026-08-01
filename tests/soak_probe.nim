import std/[asyncdispatch, os, strutils, times]
import joubako

proc noWait(_: Duration): Future[void] {.async.} =
  discard

proc main(): Future[void] {.async.} =
  let iterations = getEnv("JOUBAKO_SOAK_ITERATIONS", "20000").parseInt
  var calls = 0
  let handler = proc(request: Request): Future[Response] {.async.} =
    inc calls
    if calls mod 17 == 0:
      raise newException(IOError, "intermittent disconnect")
    if calls mod 11 == 0:
      return Response(status: 503, body: "retry", request: request)
    return Response(status: 200, body: request.body, request: request)
  let client = newClient(newInProcessTransport(handler))
  let codec = Codec[int, int](
    encode: proc(value: int): string = $value,
    decode: proc(payload: string): int = payload.parseInt
  )
  var options = defaultRequestOptions()
  options.retry = defaultHttpRetryOptions()
  options.retry.maxAttempts = 3
  options.retry.sleep = noWait
  let jar = newCookieJar(maxCookies = 64, maxCookiesPerDomain = 32)
  var completed = 0
  for index in 0 ..< iterations:
    let outcome = await client.sendWithCodec(
      rmPut, "/soak", index, codec, options = options
    )
    doAssert outcome.isOk
    doAssert outcome.value == index
    inc completed
    discard jar.store(
      "https://api.example.test/session",
      "slot" & $(index mod 40) & "=" & $index & "; Path=/; Max-Age=60",
      fromUnix(int64(index))
    )
    discard jar.cookieHeader(
      "https://api.example.test/resource", fromUnix(int64(index))
    )
  doAssert completed == iterations
  doAssert jar.len(fromUnix(int64(iterations))) <= 32

waitFor main()

