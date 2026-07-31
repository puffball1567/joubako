import std/[asyncdispatch, strutils, times, unittest]
import flowbrigade/circuit_breaker
import joubako
import ./result_test_helpers

proc ok(request: Request): Future[Response] {.async.} =
  return Response(status: 200, body: "ok", request: request)

suite "Client resilience":
  test "a circuit opens after the configured final failure":
    var calls = 0
    let handler = proc(request: Request): Future[Response] {.async.} =
      inc calls
      return Response(status: 503, request: request)
    let client = newClient(newInProcessTransport(handler))
    client.useCircuitBreaker(1, initDuration(seconds = 10))

    expect JoubakoError:
      discard waitFor client.get("/first")
    try:
      discard waitFor client.get("/blocked")
      fail()
    except JoubakoError as error:
      check error.kind == jeCircuitOpen
    check calls == 1
    check client.circuitState == circuitOpen

  test "successful requests keep the circuit closed":
    let client = newClient(newInProcessTransport(ok))
    client.useCircuitBreaker(1, initDuration(seconds = 10))
    check waitFor(client.get("/")).body == "ok"
    check client.circuitState == circuitClosed

  test "4xx responses do not trip the circuit":
    let handler = proc(request: Request): Future[Response] {.async.} =
      return Response(status: 404, request: request)
    let client = newClient(newInProcessTransport(handler))
    client.useCircuitBreaker(1, initDuration(seconds = 10))
    for index in 0 .. 1:
      discard index
      expect JoubakoError:
        discard waitFor client.get("/")
    check client.circuitState == circuitClosed

  test "a permanent HTTP response resets earlier service failures":
    var statuses = @[503, 404, 503]
    let handler = proc(request: Request): Future[Response] {.async.} =
      let status = statuses[0]
      statuses.delete(0)
      return Response(status: status, request: request)
    let client = newClient(newInProcessTransport(handler))
    client.useCircuitBreaker(2, initDuration(seconds = 10))
    for index in 0 .. 2:
      discard index
      expect JoubakoError:
        discard waitFor client.get("/")
    check client.circuitState == circuitClosed

  test "the rate limiter rejects excess requests locally":
    var calls = 0
    let handler = proc(request: Request): Future[Response] {.async.} =
      inc calls
      return Response(status: 200, request: request)
    let client = newClient(newInProcessTransport(handler))
    client.useRateLimit(1, initDuration(hours = 1), 1)
    discard waitFor client.get("/first")
    try:
      discard waitFor client.get("/second")
      fail()
    except JoubakoError as error:
      check error.kind == jeRateLimited
      check error.retryAfterMs > 0
    check calls == 1

  test "bulkhead permits are released after success":
    let client = newClient(newInProcessTransport(ok))
    client.useBulkhead(1)
    discard waitFor client.get("/one")
    discard waitFor client.get("/two")

  test "bulkhead rejects overlapping work":
    let gate = newFuture[void]("test_resilience_security.gate")
    let started = newFuture[void]("test_resilience_security.started")
    let handler = proc(request: Request): Future[Response] {.async.} =
      if not started.finished:
        started.complete()
      await gate
      return Response(status: 200, request: request)
    let client = newClient(newInProcessTransport(handler))
    client.useBulkhead(1)
    let first = client.get("/first")
    waitFor started
    try:
      discard waitFor client.get("/second")
      fail()
    except JoubakoError as error:
      check error.kind == jeBulkheadRejected
    gate.complete()
    discard waitFor first

  test "bulkhead permits are released after failures":
    var failNext = true
    let handler = proc(request: Request): Future[Response] {.async.} =
      if failNext:
        failNext = false
        raise newException(IOError, "failed")
      return Response(status: 200, request: request)
    let client = newClient(newInProcessTransport(handler))
    client.useBulkhead(1)
    expect JoubakoError:
      discard waitFor client.get("/failure")
    check waitFor(client.get("/success")).status == 200

  test "a blocked circuit does not leak a bulkhead permit":
    var failNext = true
    let handler = proc(request: Request): Future[Response] {.async.} =
      if failNext:
        failNext = false
        return Response(status: 503, request: request)
      return Response(status: 200, request: request)
    let client = newClient(newInProcessTransport(handler))
    client.useBulkhead(1)
    client.useCircuitBreaker(1, initDuration(hours = 1))
    expect JoubakoError:
      discard waitFor client.get("/opens")
    expect JoubakoError:
      discard waitFor client.get("/blocked")
    client.clearCircuitBreaker()
    check waitFor(client.get("/after-clear")).status == 200

  test "clearing bulkhead disables admission checks":
    let gate = newFuture[void]("test_resilience_security.clearGate")
    let started = newFuture[void]("test_resilience_security.clearStarted")
    let handler = proc(request: Request): Future[Response] {.async.} =
      if not started.finished:
        started.complete()
      await gate
      return Response(status: 200, request: request)
    let client = newClient(newInProcessTransport(handler))
    client.useBulkhead(1)
    let first = client.get("/one")
    waitFor started
    client.clearBulkhead()
    let second = client.get("/two")
    gate.complete()
    discard waitFor first
    discard waitFor second

  test "clearing rate limits permits later requests":
    let client = newClient(newInProcessTransport(ok))
    client.useRateLimit(1, initDuration(hours = 1), 1)
    discard waitFor client.get("/one")
    expect JoubakoError:
      discard waitFor client.get("/two")
    client.clearRateLimit()
    discard waitFor client.get("/three")

  test "invalid resilience configuration is rejected":
    let client = newClient(newInProcessTransport(ok))
    expect ValueError:
      client.useBulkhead(0)
    expect ValueError:
      client.useRateLimit(0, initDuration(seconds = 1), 1)
    expect ValueError:
      client.useCircuitBreaker(0, initDuration(seconds = 1))

  test "retry success is one successful circuit operation":
    var calls = 0
    let handler = proc(request: Request): Future[Response] {.async.} =
      inc calls
      return Response(
        status: (if calls == 1: 503 else: 200),
        request: request
      )
    let client = newClient(newInProcessTransport(handler))
    client.useCircuitBreaker(1, initDuration(hours = 1))
    var options = defaultRequestOptions()
    options.retry = defaultHttpRetryOptions()
    options.retry.sleep =
      proc(delay: Duration): Future[void] {.async.} =
        discard delay
    check waitFor(client.get("/", options = options)).status == 200
    check calls == 2
    check client.circuitState == circuitClosed

suite "Cancellation and host policy":
  test "cancellation during a request interceptor stops dispatch":
    let token = newCancellationToken()
    var transportCalled = false
    let handler = proc(request: Request): Future[Response] {.async.} =
      transportCalled = true
      return Response(status: 200, request: request)
    let client = newClient(newInProcessTransport(handler))
    discard client.useRequestInterceptor(
      proc(request: Request): Future[Request] {.async.} =
        token.cancel("view removed")
        return request
    )
    var options = defaultRequestOptions()
    options.cancellation = token
    try:
      discard waitFor client.get("/", options = options)
      fail()
    except JoubakoError as error:
      check error.kind == jeCancelled
      check error.msg.startsWith("view removed")
    check not transportCalled

  test "cancellation during a response interceptor stops later callbacks":
    let token = newCancellationToken()
    var secondCalled = false
    let client = newClient(newInProcessTransport(ok))
    discard client.useResponseInterceptor(
      proc(response: Response): Response =
        token.cancel("stale response")
        response
    )
    discard client.useResponseInterceptor(
      proc(response: Response): Response =
        secondCalled = true
        response
    )
    var options = defaultRequestOptions()
    options.cancellation = token
    try:
      discard waitFor client.get("/", options = options)
      fail()
    except JoubakoError as error:
      check error.kind == jeCancelled
    check not secondCalled

  test "HTTP host allowlists reject before connecting":
    let client = newClient(newHttpTransport())
    var options = defaultRequestOptions()
    options.allowedHosts = @["api.example.test"]
    try:
      discard waitFor client.get(
        "http://127.0.0.1:1/private",
        options = options
      )
      fail()
    except JoubakoError as error:
      check error.kind == jeInvalidRequest
      check "allowlist" in error.msg

  test "wildcard host policies match subdomains only":
    let client = newClient(newHttpTransport())
    var options = defaultRequestOptions()
    options.allowedHosts = @["*.example.test"]
    try:
      discard waitFor client.get(
        "http://example.test/",
        options = options
      )
      fail()
    except JoubakoError as error:
      check error.kind == jeInvalidRequest

  test "host matching is case insensitive":
    check isHostAllowed("API.Example.Test", @["api.example.test"])
    check isHostAllowed("A.Example.Test", @["*.EXAMPLE.TEST"])

  test "wildcards do not match sibling suffix attacks":
    check not isHostAllowed("badexample.test", @["*.example.test"])
    check not isHostAllowed("example.test", @["*.example.test"])

suite "New request option inheritance":
  test "new timeout and host options reach the transport":
    var seen = RequestOptions()
    let handler = proc(request: Request): Future[Response] {.async.} =
      seen = request.options
      return Response(status: 200, request: request)
    var defaults = defaultRequestOptions()
    defaults.connectTimeoutMs = 111
    defaults.readTimeoutMs = 222
    defaults.allowedHosts = @["default.test"]
    let client = newClient(
      newInProcessTransport(handler),
      defaultOptions = defaults
    )
    discard waitFor client.get("/")
    check seen.connectTimeoutMs == 111
    check seen.readTimeoutMs == 222
    check seen.allowedHosts == @["default.test"]

  test "per-request new options override defaults":
    var seen = RequestOptions()
    let handler = proc(request: Request): Future[Response] {.async.} =
      seen = request.options
      return Response(status: 200, request: request)
    var defaults = defaultRequestOptions()
    defaults.connectTimeoutMs = 111
    defaults.readTimeoutMs = 222
    defaults.allowedHosts = @["default.test"]
    let client = newClient(
      newInProcessTransport(handler),
      defaultOptions = defaults
    )
    var options = RequestOptions(
      connectTimeoutMs: 7,
      readTimeoutMs: 8,
      allowedHosts: @["request.test"]
    )
    discard waitFor client.get("/", options = options)
    check seen.connectTimeoutMs == 7
    check seen.readTimeoutMs == 8
    check seen.allowedHosts == @["request.test"]

  test "stream and callback options are inherited":
    var seen = RequestOptions()
    let handler = proc(request: Request): Future[Response] {.async.} =
      seen = request.options
      return Response(status: 200, request: request)
    var defaults = defaultRequestOptions()
    defaults.streamResponse = true
    defaults.onDownloadChunk = proc(chunk: string) = discard chunk
    defaults.onUploadProgress =
      proc(transferred, total: int64) =
        discard transferred
        discard total
    let client = newClient(
      newInProcessTransport(handler),
      defaultOptions = defaults
    )
    discard waitFor client.get("/")
    check seen.streamResponse
    check not seen.onDownloadChunk.isNil
    check not seen.onUploadProgress.isNil
