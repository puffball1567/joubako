import std/[asyncdispatch, strutils, times, unittest]
import flowbrigade/[backoff, retry]
import joubako
import ./result_test_helpers

proc noWait(delay: Duration): Future[void] {.async.} =
  discard delay

func retryRequest(
    httpMethod: RequestMethod;
    mode = imDefault
): Request =
  var retry = defaultHttpRetryOptions()
  retry.idempotency = mode
  Request(
    httpMethod: httpMethod,
    options: RequestOptions(retry: retry)
  )

suite "HTTP retry classification":
  test "GET is idempotent by default":
    check rmGet.isMethodIdempotent

  test "HEAD is idempotent by default":
    check rmHead.isMethodIdempotent

  test "PUT is idempotent by default":
    check rmPut.isMethodIdempotent

  test "DELETE is idempotent by default":
    check rmDelete.isMethodIdempotent

  test "OPTIONS is idempotent by default":
    check rmOptions.isMethodIdempotent

  test "POST is not idempotent by default":
    check not rmPost.isMethodIdempotent

  test "PATCH is not idempotent by default":
    check not rmPatch.isMethodIdempotent

  test "explicit idempotency enables POST":
    check rmPost.isMethodIdempotent(imIdempotent)

  test "explicit non-idempotency disables GET":
    check not rmGet.isMethodIdempotent(imNonIdempotent)

  test "408 is retryable":
    check isRetryStatus(408)

  test "425 is retryable":
    check isRetryStatus(425)

  test "429 is retryable":
    check isRetryStatus(429)

  test "500 is retryable":
    check isRetryStatus(500)

  test "502 is retryable":
    check isRetryStatus(502)

  test "503 is retryable":
    check isRetryStatus(503)

  test "504 is retryable":
    check isRetryStatus(504)

  test "400 is not retryable":
    check not isRetryStatus(400)

  test "401 is not retryable":
    check not isRetryStatus(401)

  test "403 is not retryable":
    check not isRetryStatus(403)

  test "404 is not retryable":
    check not isRetryStatus(404)

  test "409 is not retryable by default":
    check not isRetryStatus(409)

  test "422 is not retryable":
    check not isRetryStatus(422)

  test "501 is not retryable":
    check not isRetryStatus(501)

  test "transport errors are retryable for idempotent requests":
    let request = retryRequest(rmGet)
    check request.shouldRetryHttpError(
      newJoubakoError(jeTransport, "offline"),
      1
    )

  test "timeouts are retryable for idempotent requests":
    let request = retryRequest(rmGet)
    check request.shouldRetryHttpError(
      newJoubakoError(jeTimeout, "slow"),
      1
    )

  test "cancellation is never retryable":
    let request = retryRequest(rmGet)
    check not request.shouldRetryHttpError(
      newJoubakoError(jeCancelled, "cancelled"),
      1
    )

  test "invalid requests are never retryable":
    let request = retryRequest(rmGet)
    check not request.shouldRetryHttpError(
      newJoubakoError(jeInvalidRequest, "bad"),
      1
    )

  test "body limit failures are never retryable":
    let request = retryRequest(rmGet)
    check not request.shouldRetryHttpError(
      newJoubakoError(jeBodyTooLarge, "large"),
      1
    )

  test "codec failures are never retryable":
    let request = retryRequest(rmGet)
    check not request.shouldRetryHttpError(
      newJoubakoError(jeCodec, "bad JSON"),
      1
    )

  test "unknown exception types are not retried":
    let request = retryRequest(rmGet)
    check not request.shouldRetryHttpError(
      newException(IOError, "unknown"),
      1
    )

  test "retryable status still respects method idempotency":
    let request = retryRequest(rmPost)
    check not request.shouldRetryHttpError(
      newJoubakoError(jeHttpStatus, "unavailable", status = 503),
      1
    )

suite "Retry-After parsing":
  test "zero seconds is valid":
    check parseRetryAfterMs("0") == 0

  test "positive delta seconds become milliseconds":
    check parseRetryAfterMs("12") == 12_000

  test "negative delta seconds are rejected":
    check parseRetryAfterMs("-1") == -1

  test "nonnumeric values are rejected":
    check parseRetryAfterMs("later") == -1

  test "empty values are rejected":
    check parseRetryAfterMs("") == -1

  test "past HTTP dates clamp to zero":
    check parseRetryAfterMs(
      "Thu, 01 Jan 1970 00:00:00 GMT",
      fromUnix(10)
    ) == 0

suite "Joubako HTTP retry policy":
  test "idempotent GET retries retryable statuses through FlowBrigade":
    var attempts = 0
    var events: seq[RetryEventKind]
    let handler = proc(request: Request): Future[Response] {.async.} =
      inc attempts
      return Response(
        status: (if attempts < 3: 503 else: 200),
        body: "ok",
        request: request
      )
    let client = newClient(newInProcessTransport(handler))
    var options = defaultRequestOptions()
    options.retry = defaultHttpRetryOptions()
    options.retry.sleep = noWait
    options.retry.observer = proc(event: RetryEvent) =
      events.add event.kind

    let response = waitFor client.get("/eventual", options = options)

    check response.status == 200
    check attempts == 3
    check events == @[
      retryAttemptFailed,
      retrySleeping,
      retryAttemptFailed,
      retrySleeping,
      retrySucceeded
    ]

  test "POST is not retried without explicit idempotency":
    var attempts = 0
    let handler = proc(request: Request): Future[Response] {.async.} =
      inc attempts
      return Response(status: 503, request: request)
    let client = newClient(newInProcessTransport(handler))
    var options = defaultRequestOptions()
    options.retry = defaultHttpRetryOptions()
    options.retry.sleep = noWait

    expect JoubakoError:
      discard waitFor client.post("/documents", "body", options = options)
    check attempts == 1

  test "explicitly idempotent POST may be retried":
    var attempts = 0
    let handler = proc(request: Request): Future[Response] {.async.} =
      inc attempts
      return Response(
        status: (if attempts == 1: 503 else: 200),
        request: request
      )
    let client = newClient(newInProcessTransport(handler))
    var options = defaultRequestOptions()
    options.retry = defaultHttpRetryOptions()
    options.retry.idempotency = imIdempotent
    options.retry.sleep = noWait

    discard waitFor client.post("/documents", "replayable", options = options)
    check attempts == 2

  test "Retry-After takes precedence over the backoff delay":
    var attempts = 0
    var waits: seq[Duration]
    let handler = proc(request: Request): Future[Response] {.async.} =
      inc attempts
      var headers = initHeaders()
      if attempts == 1:
        headers.set("retry-after", "3")
      return Response(
        status: (if attempts == 1: 429 else: 200),
        headers: headers,
        request: request
      )
    let client = newClient(newInProcessTransport(handler))
    var options = defaultRequestOptions()
    options.retry = defaultHttpRetryOptions()
    options.retry.backoff = fixedBackoff(initDuration(milliseconds = 100))
    options.retry.sleep = proc(delay: Duration): Future[void] {.async.} =
      waits.add delay

    discard waitFor client.get("/limited", options = options)

    check attempts == 2
    check waits == @[initDuration(seconds = 3)]

  test "cancellation interrupts a retry wait":
    var attempts = 0
    let handler = proc(request: Request): Future[Response] {.async.} =
      inc attempts
      return Response(status: 503, request: request)
    let client = newClient(newInProcessTransport(handler))
    let token = newCancellationToken()
    var options = defaultRequestOptions()
    options.cancellation = token
    options.retry = defaultHttpRetryOptions()
    options.retry.backoff = fixedBackoff(initDuration(seconds = 1))

    let pending = client.get("/slow-retry", options = options)
    let cancelSoon = proc(): Future[void] {.async.} =
      await sleepAsync(1)
      token.cancel("superseded")
    asyncCheck cancelSoon()

    try:
      discard waitFor pending
      fail()
    except JoubakoError as error:
      check error.kind == jeCancelled
      check error.msg.startsWith("superseded")
    check attempts == 1

  test "one total deadline covers attempts and retry waits":
    var attempts = 0
    let handler = proc(request: Request): Future[Response] {.async.} =
      inc attempts
      return Response(status: 503, request: request)
    let client = newClient(newInProcessTransport(handler))
    var options = defaultRequestOptions()
    options.timeoutMs = 20
    options.retry = defaultHttpRetryOptions()
    options.retry.backoff = fixedBackoff(initDuration(seconds = 1))

    try:
      discard waitFor client.get("/deadline", options = options)
      fail()
    except JoubakoError as error:
      check error.kind == jeTimeout
    check attempts == 1

  test "Retry-After supports HTTP dates":
    check parseRetryAfterMs(
      "Thu, 01 Jan 1970 00:00:05 GMT",
      fromUnix(0)
    ) == 5_000

  test "maxAttempts bounds the number of dispatches":
    var attempts = 0
    let handler = proc(request: Request): Future[Response] {.async.} =
      inc attempts
      return Response(status: 503, request: request)
    let client = newClient(newInProcessTransport(handler))
    var options = defaultRequestOptions()
    options.retry = defaultHttpRetryOptions()
    options.retry.maxAttempts = 2
    options.retry.sleep = noWait

    try:
      discard waitFor client.get("/always-down", options = options)
      fail()
    except JoubakoError as error:
      check error.kind == jeHttpStatus
      check error.hasResponse
      check error.response.status == 503
      check error.attempts == 2
    check attempts == 2

  test "explicit non-idempotency prevents GET retry":
    var attempts = 0
    let handler = proc(request: Request): Future[Response] {.async.} =
      inc attempts
      return Response(status: 503, request: request)
    let client = newClient(newInProcessTransport(handler))
    var options = defaultRequestOptions()
    options.retry = defaultHttpRetryOptions()
    options.retry.idempotency = imNonIdempotent
    options.retry.sleep = noWait

    expect JoubakoError:
      discard waitFor client.get("/side-effecting-get", options = options)
    check attempts == 1

  test "401 authentication failures stop immediately":
    var attempts = 0
    let handler = proc(request: Request): Future[Response] {.async.} =
      inc attempts
      return Response(status: 401, request: request)
    let client = newClient(newInProcessTransport(handler))
    var options = defaultRequestOptions()
    options.retry = defaultHttpRetryOptions()
    options.retry.sleep = noWait

    expect JoubakoError:
      discard waitFor client.get("/private", options = options)
    check attempts == 1

  test "request interceptors run once for a logical retried request":
    var interceptorCalls = 0
    var attempts = 0
    let handler = proc(request: Request): Future[Response] {.async.} =
      inc attempts
      return Response(
        status: (if attempts == 1: 503 else: 200),
        request: request
      )
    let client = newClient(newInProcessTransport(handler))
    discard client.useRequestInterceptor(
      proc(request: Request): Request =
        inc interceptorCalls
        request
    )
    var options = defaultRequestOptions()
    options.retry = defaultHttpRetryOptions()
    options.retry.sleep = noWait

    discard waitFor client.get("/eventual", options = options)
    check attempts == 2
    check interceptorCalls == 1

  test "response interceptors run only for the final success":
    var interceptorCalls = 0
    var attempts = 0
    let handler = proc(request: Request): Future[Response] {.async.} =
      inc attempts
      return Response(
        status: (if attempts == 1: 503 else: 200),
        request: request
      )
    let client = newClient(newInProcessTransport(handler))
    discard client.useResponseInterceptor(
      proc(response: Response): Response =
        inc interceptorCalls
        response
    )
    var options = defaultRequestOptions()
    options.retry = defaultHttpRetryOptions()
    options.retry.sleep = noWait

    discard waitFor client.get("/eventual", options = options)
    check attempts == 2
    check interceptorCalls == 1
