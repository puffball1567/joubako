import std/asyncdispatch
import joubako/[result, types]
import joubako/transports/http2

proc main() {.async.} =
  let transport = newHttp2Transport(allowH2c = true)
  var options = defaultRequestOptions()
  options.timeoutMs = -1
  options.connectTimeoutMs = -1
  options.readTimeoutMs = -1
  for _ in 0 ..< 100:
    let response = await transport.send(Request(
      httpMethod: rmGet,
      url: "http://127.0.0.1:18943/",
      headers: initHeaders(),
      options: options
    ))
    doAssert response.status == 200
    doAssert response.httpVersion == "HTTP/2"
    doAssert response.body == "ok"

  for _ in 0 ..< 25:
    var bounded = options
    bounded.maxResponseBytes = 1024
    let boundedOutcome = await settle(fallible(transport.send(Request(
      httpMethod: rmGet,
      url: "http://127.0.0.1:18943/large",
      headers: initHeaders(),
      options: bounded
    ))))
    doAssert boundedOutcome.isErr
    doAssert boundedOutcome.error.kind == jeBodyTooLarge

    var timed = options
    timed.timeoutMs = 5
    let timedOutcome = await settle(fallible(transport.send(Request(
      httpMethod: rmGet,
      url: "http://127.0.0.1:18943/slow",
      headers: initHeaders(),
      options: timed
    ))))
    doAssert timedOutcome.isErr
    doAssert timedOutcome.error.kind == jeTimeout

    var cancelled = options
    cancelled.cancellation = newCancellationToken()
    cancelled.cancellation.cancel("probe")
    let cancelledOutcome = await settle(fallible(transport.send(Request(
      httpMethod: rmGet,
      url: "http://127.0.0.1:18943/",
      headers: initHeaders(),
      options: cancelled
    ))))
    doAssert cancelledOutcome.isErr
    doAssert cancelledOutcome.error.kind == jeCancelled
  await transport.close()

let probe = main()
waitFor probe
probe.clearCallbacks()
doAssert not hasPendingOperations()
setGlobalDispatcher(nil)
