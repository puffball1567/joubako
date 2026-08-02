import std/[asyncdispatch, strutils, times, uri]
import flowbrigade/[backoff, bulkhead, circuit_breaker, retry, timeout]
import flowbrigade/ratelimit/token_bucket
import ./[http_retry, query, result, transport, types]

type
  StatusValidator* = proc(status: int): bool {.closure.}
  RequestInterceptor* =
    proc(request: Request): Future[Request] {.closure.}
  ResponseInterceptor* =
    proc(response: Response): Future[Response] {.closure.}

  RequestInterceptorEntry = object
    id: int
    handler: RequestInterceptor

  ResponseInterceptorEntry = object
    id: int
    handler: ResponseInterceptor

  Client* = ref object
    transport*: Transport
    baseUrl*: string
    defaultHeaders*: Headers
    defaultOptions*: RequestOptions
    validateStatus*: StatusValidator
    requestInterceptors: seq[RequestInterceptorEntry]
    responseInterceptors: seq[ResponseInterceptorEntry]
    nextInterceptorId: int
    circuitBreaker: ref CircuitBreaker
    bulkhead: ref Bulkhead
    rateLimiter: ref TokenBucket

proc useCircuitBreaker*(
    client: Client;
    failureThreshold: int;
    resetAfter: Duration;
    observer: CircuitBreakerObserverProc = nil;
    halfOpenMaxProbes = 1
) =
  new client.circuitBreaker
  client.circuitBreaker[] = initCircuitBreaker(
    failureThreshold,
    resetAfter,
    observer,
    halfOpenMaxProbes
  )

proc clearCircuitBreaker*(client: Client) =
  client.circuitBreaker = nil

proc circuitState*(client: Client): CircuitState =
  if client.circuitBreaker == nil:
    circuitClosed
  else:
    client.circuitBreaker[].state

proc useBulkhead*(client: Client; capacity: int) =
  new client.bulkhead
  client.bulkhead[] = initBulkhead(capacity)

proc clearBulkhead*(client: Client) =
  client.bulkhead = nil

proc useRateLimit*(
    client: Client;
    rate: int;
    per: Duration;
    burst: int
) =
  new client.rateLimiter
  client.rateLimiter[] = initTokenBucket(rate, per, burst)

proc clearRateLimit*(client: Client) =
  client.rateLimiter = nil

func acceptsSuccess(status: int): bool =
  status >= 200 and status < 300

func newClient*(
    transport: Transport;
    baseUrl = "";
    defaultHeaders = initHeaders();
    defaultOptions = defaultRequestOptions();
    validateStatus: StatusValidator = acceptsSuccess
): Client =
  Client(
    transport: transport,
    baseUrl: baseUrl,
    defaultHeaders: defaultHeaders,
    defaultOptions: defaultOptions,
    validateStatus: validateStatus,
    nextInterceptorId: 1
  )

proc useRequestInterceptor*(
    client: Client;
    interceptor: RequestInterceptor
): int =
  result = client.nextInterceptorId
  inc client.nextInterceptorId
  client.requestInterceptors.add RequestInterceptorEntry(
    id: result,
    handler: interceptor
  )

proc useRequestInterceptor*(
    client: Client;
    interceptor: proc(request: Request): Future[Request] {.nimcall.}
): int =
  let wrapped = proc(request: Request): Future[Request] =
    interceptor(request)
  client.useRequestInterceptor(wrapped)

proc useRequestInterceptor*(
    client: Client;
    interceptor: proc(request: Request): Request {.closure.}
): int =
  let wrapped = proc(request: Request): Future[Request] {.async.} =
    return interceptor(request)
  client.useRequestInterceptor(wrapped)

proc useRequestInterceptor*(
    client: Client;
    interceptor: proc(request: Request): Request {.nimcall.}
): int =
  let wrapped = proc(request: Request): Future[Request] {.async.} =
    return interceptor(request)
  client.useRequestInterceptor(wrapped)

proc useResponseInterceptor*(
    client: Client;
    interceptor: ResponseInterceptor
): int =
  result = client.nextInterceptorId
  inc client.nextInterceptorId
  client.responseInterceptors.add ResponseInterceptorEntry(
    id: result,
    handler: interceptor
  )

proc useResponseInterceptor*(
    client: Client;
    interceptor: proc(response: Response): Future[Response] {.nimcall.}
): int =
  let wrapped = proc(response: Response): Future[Response] =
    interceptor(response)
  client.useResponseInterceptor(wrapped)

proc useResponseInterceptor*(
    client: Client;
    interceptor: proc(response: Response): Response {.closure.}
): int =
  let wrapped = proc(response: Response): Future[Response] {.async.} =
    return interceptor(response)
  client.useResponseInterceptor(wrapped)

proc useResponseInterceptor*(
    client: Client;
    interceptor: proc(response: Response): Response {.nimcall.}
): int =
  let wrapped = proc(response: Response): Future[Response] {.async.} =
    return interceptor(response)
  client.useResponseInterceptor(wrapped)

proc ejectRequestInterceptor*(client: Client; id: int): bool =
  for index, entry in client.requestInterceptors:
    if entry.id == id:
      client.requestInterceptors.delete(index)
      return true

proc ejectResponseInterceptor*(client: Client; id: int): bool =
  for index, entry in client.responseInterceptors:
    if entry.id == id:
      client.responseInterceptors.delete(index)
      return true

func resolveUrl(client: Client; path: string): string =
  if path.len == 0:
    return client.baseUrl
  let parsed = parseUri(path)
  if parsed.isAbsolute or client.baseUrl.len == 0:
    return path
  $combine(parseUri(client.baseUrl), parsed)

proc requestResult(
    client: Client;
    httpMethod: RequestMethod;
    path: string;
    body = "";
    headers = initHeaders();
    options: RequestOptions = RequestOptions();
    multipartParts: seq[MultipartPart] = @[]
): Future[JResult[Response]] {.async.} =
  if client == nil or client.transport == nil:
    return err[Response](newJoubakoError(
      jeInvalidRequest, "client has no transport"
    ))

  var mergedHeaders = initHeaders()
  mergedHeaders.merge(client.defaultHeaders)
  mergedHeaders.overlay(headers)

  var effectiveOptions = client.defaultOptions
  if options.timeoutMs != 0:
    effectiveOptions.timeoutMs = options.timeoutMs
  if options.connectTimeoutMs != 0:
    effectiveOptions.connectTimeoutMs = options.connectTimeoutMs
  if options.readTimeoutMs != 0:
    effectiveOptions.readTimeoutMs = options.readTimeoutMs
  if options.maxResponseBytes != 0:
    effectiveOptions.maxResponseBytes = options.maxResponseBytes
  if options.maxRequestBytes != 0:
    effectiveOptions.maxRequestBytes = options.maxRequestBytes
  if options.cancellation != nil:
    effectiveOptions.cancellation = options.cancellation
  if options.retry.maxAttempts != 0:
    effectiveOptions.retry = options.retry
  if options.allowedHosts.len > 0:
    effectiveOptions.allowedHosts = options.allowedHosts
  if not options.onUploadProgress.isNil:
    effectiveOptions.onUploadProgress = options.onUploadProgress
  if not options.onDownloadProgress.isNil:
    effectiveOptions.onDownloadProgress = options.onDownloadProgress
  if not options.onDownloadChunk.isNil:
    effectiveOptions.onDownloadChunk = options.onDownloadChunk
  if not options.onDownloadChunkAsync.isNil:
    effectiveOptions.onDownloadChunkAsync = options.onDownloadChunkAsync
  if options.streamResponse:
    effectiveOptions.streamResponse = true

  let url = client.resolveUrl(path)
  if url.len == 0:
    return err[Response](newJoubakoError(
      jeInvalidRequest, "request URL is empty"
    ))

  var request = Request(
    httpMethod: httpMethod,
    url: url,
    headers: mergedHeaders,
    body: body,
    multipartParts: multipartParts,
    options: effectiveOptions
  )

  for entry in client.requestInterceptors:
    if request.options.cancellation != nil and
        request.options.cancellation.cancelled:
      return err[Response](newJoubakoError(
        jeCancelled, request.options.cancellation.reason, request.url
      ))
    var intercepted: Future[Request]
    try:
      intercepted = entry.handler(request)
    except CatchableError as error:
      return err[Response](error.asJoubakoError(jeTransport, request.url))
    let interceptorResult = await settle(
      fallible(intercepted), jeTransport, request.url
    )
    if interceptorResult.isErr:
      return err[Response](interceptorResult.error)
    request = interceptorResult.value

  if request.url.len == 0:
    return err[Response](newJoubakoError(
      jeInvalidRequest, "interceptor produced an empty URL"
    ))
  if request.url.contains({'\r', '\n'}):
    return err[Response](newJoubakoError(
      jeInvalidRequest,
      "request URL contains a line break",
      request.url
    ))
  for name, value in request.headers.pairs:
    if name.len == 0 or name.contains({'\r', '\n'}) or
        value.contains({'\r', '\n'}):
      return err[Response](newJoubakoError(
        jeInvalidRequest,
        "request contains an invalid header",
        request.url
      ))

  if request.multipartParts.len > 0:
    if request.body.len > 0:
      return err[Response](newJoubakoError(
        jeInvalidRequest,
        "multipart requests cannot also contain a buffered body",
        request.url
      ))
    if request.headers.contains("content-type"):
      return err[Response](newJoubakoError(
        jeInvalidRequest,
        "file-backed multipart content type and boundary are generated automatically",
        request.url
      ))
    for part in request.multipartParts:
      if part.name.len == 0 or
          part.name.contains({'\r', '\n', '"'}):
        return err[Response](newJoubakoError(
          jeInvalidRequest, "invalid multipart field name", request.url
        ))
      if part.filename.contains({'\r', '\n', '"'}):
        return err[Response](newJoubakoError(
          jeInvalidRequest, "invalid multipart filename", request.url
        ))
      if part.contentType.contains({'\r', '\n'}):
        return err[Response](newJoubakoError(
          jeInvalidRequest, "invalid multipart content type", request.url
        ))
      if part.filePath.len > 0 and part.filename.len == 0:
        return err[Response](newJoubakoError(
          jeInvalidRequest,
          "file-backed multipart part has no transmitted filename",
          request.url
        ))
      if part.filePath.len > 0 and part.body.len > 0:
        return err[Response](newJoubakoError(
          jeInvalidRequest,
          "file-backed multipart part cannot also contain buffered data",
          request.url
        ))

  if request.options.maxRequestBytes >= 0 and
      request.body.len > request.options.maxRequestBytes:
    return err[Response](newJoubakoError(
      jeBodyTooLarge,
      "request body exceeded the configured limit",
      request.url
    ))

  if request.options.cancellation != nil and
      request.options.cancellation.cancelled:
    return err[Response](newJoubakoError(
      jeCancelled,
      request.options.cancellation.reason,
      request.url
    ))

  if client.rateLimiter != nil:
    let decision = client.rateLimiter[].consume()
    if not decision.allowed:
      return err[Response](newJoubakoError(
        jeRateLimited,
        "client rate limit exceeded",
        request.url,
        retryAfterMs = decision.retryAfter.inMilliseconds
      ))

  var circuitAdmitted = false
  var bulkheadAcquired = false
  let admittedBulkhead = client.bulkhead
  let admittedCircuit = client.circuitBreaker
  defer:
    if bulkheadAcquired:
      admittedBulkhead[].release()

  if admittedBulkhead != nil:
    if not admittedBulkhead[].tryAcquire:
      return err[Response](newJoubakoError(
        jeBulkheadRejected,
        "client bulkhead capacity exceeded",
        request.url
      ))
    bulkheadAcquired = true

  if admittedCircuit != nil:
    if not admittedCircuit[].allow:
      return err[Response](newJoubakoError(
        jeCircuitOpen,
        "client circuit breaker is open",
        request.url
      ))
    circuitAdmitted = true

  let retryEnabled = request.options.retry.maxAttempts >= 2
  let retryDeadline =
    if retryEnabled and request.options.timeoutMs >= 0:
      initDeadline(initDuration(milliseconds = request.options.timeoutMs))
    else:
      Deadline()

  var completedAttempts = 0
  proc executeAttempt(): Future[JResult[Response]] {.async.} =
    var attemptRequest = request
    if retryDeadline.isInitialized:
      let remainingMs = retryDeadline.remaining.durationMillisecondsCeil
      if remainingMs <= 0:
        return err[Response](newJoubakoError(
          jeTimeout,
          "request deadline expired before the next attempt",
          request.url
        ))
      attemptRequest.options.timeoutMs = remainingMs

    inc completedAttempts
    var transportFuture: Future[Response]
    try:
      transportFuture = client.transport.send(attemptRequest)
    except CatchableError as error:
      return err[Response](error.asJoubakoError(jeTransport, request.url))

    let transportResult = await settle(
      fallible(transportFuture), jeTransport, request.url
    )
    if transportResult.isErr:
      return err[Response](transportResult.error)
    var response = transportResult.value

    response.request = request

    if request.options.cancellation != nil and
        request.options.cancellation.cancelled:
      return err[Response](newJoubakoError(
        jeCancelled,
        request.options.cancellation.reason,
        request.url
      ))

    if request.options.maxResponseBytes >= 0 and
        response.body.len > request.options.maxResponseBytes:
      return err[Response](newJoubakoError(
        jeBodyTooLarge,
        "response body exceeded the configured limit",
        request.url,
        response.status
      ))

    if client.validateStatus != nil:
      var accepted = false
      try:
        accepted = client.validateStatus(response.status)
      except CatchableError as error:
        return err[Response](error.asJoubakoError(
          jeInvalidRequest, request.url
        ))
      if not accepted:
        let statusError = newJoubakoError(
          jeHttpStatus,
          "HTTP request failed with status " & $response.status,
          request.url,
          response.status,
          parseRetryAfterMs(response.headers.get("retry-after"))
        )
        statusError.attachResponse(response)
        return err[Response](statusError)
    return ok(response)

  var attemptResult: JResult[Response]
  if retryEnabled:
    var attempt = 1
    while true:
      if retryDeadline.isInitialized and retryDeadline.expired:
        attemptResult = err[Response](newJoubakoError(
          jeTimeout, "request deadline expired during retry", request.url
        ))
        break
      attemptResult = await executeAttempt()
      if attemptResult.isOk:
        if not request.options.retry.observer.isNil:
          request.options.retry.observer(RetryEvent(
            kind: retrySucceeded, attempt: attempt
          ))
        break
      let failure = attemptResult.error
      failure.attempts = completedAttempts
      if not request.options.retry.observer.isNil:
        request.options.retry.observer(RetryEvent(
          kind: retryAttemptFailed, attempt: attempt, error: failure
        ))
      if attempt >= request.options.retry.maxAttempts or
          not request.shouldRetryHttpError(failure, attempt):
        if not request.options.retry.observer.isNil:
          request.options.retry.observer(RetryEvent(
            kind: retryExhausted, attempt: attempt, error: failure
          ))
        break
      let delay = request.options.retry.backoff.delayFor(attempt)
      if not request.options.retry.observer.isNil:
        request.options.retry.observer(RetryEvent(
          kind: retrySleeping,
          attempt: attempt,
          delay: delay,
          error: failure
        ))
      let waiting = retrySleep(
        delay,
        failure.retryAfterMs,
        request.options.cancellation,
        if request.options.retry.sleep.isNil:
          sleepDurationAsync
        else:
          request.options.retry.sleep,
        retryDeadline
      )
      let waited = await settle(fallible(waiting), jeTimeout, request.url)
      if waited.isErr:
        waited.error.attempts = completedAttempts
        attemptResult = err[Response](waited.error)
        break
      inc attempt
  else:
    attemptResult = await executeAttempt()
    if attemptResult.isErr:
      attemptResult.error.attempts = completedAttempts

  if circuitAdmitted:
    if attemptResult.isOk:
      admittedCircuit[].recordSuccess()
    else:
      let failure = attemptResult.error
      if failure.kind in {jeTransport, jeTimeout} or
          (failure.kind == jeHttpStatus and failure.status >= 500):
        admittedCircuit[].recordFailure()
      else:
        admittedCircuit[].recordSuccess()

  if attemptResult.isErr:
    attemptResult.error.attempts = completedAttempts
    return err[Response](attemptResult.error)
  var response = attemptResult.value

  for entry in client.responseInterceptors:
    if request.options.cancellation != nil and
        request.options.cancellation.cancelled:
      let cancellationError = newJoubakoError(
        jeCancelled, request.options.cancellation.reason, request.url
      )
      cancellationError.attempts = completedAttempts
      return err[Response](cancellationError)
    var intercepted: Future[Response]
    try:
      intercepted = entry.handler(response)
    except CatchableError as error:
      let interceptorError = error.asJoubakoError(jeTransport, request.url)
      interceptorError.attempts = completedAttempts
      return err[Response](interceptorError)
    let interceptorResult = await settle(
      fallible(intercepted), jeTransport, request.url
    )
    if interceptorResult.isErr:
      interceptorResult.error.attempts = completedAttempts
      return err[Response](interceptorResult.error)
    response = interceptorResult.value
    response.request = request

  if request.options.maxResponseBytes >= 0 and
      response.body.len > request.options.maxResponseBytes:
    let limitError = newJoubakoError(
      jeBodyTooLarge,
      "response interceptor produced a body over the configured limit",
      request.url,
      response.status
    )
    limitError.attempts = completedAttempts
    return err[Response](limitError)
  return ok(response)

proc request*(
    client: Client;
    httpMethod: RequestMethod;
    path: string;
    body = "";
    headers = initHeaders();
    options: RequestOptions = RequestOptions()
): Future[JResult[Response]] =
  settleResult(
    fallible(client.requestResult(
      httpMethod, path, body, headers, options
    )),
    jeTransport, path
  )

proc requestMultipart*(
    client: Client;
    httpMethod: RequestMethod;
    path: string;
    parts: seq[MultipartPart];
    headers = initHeaders();
    options: RequestOptions = RequestOptions()
): Future[JResult[Response]] =
  ## Dispatches multipart metadata without materializing file-backed parts.
  ## The HTTP transport supplies the boundary and streams each file path.
  settleResult(
    fallible(client.requestResult(
      httpMethod,
      path,
      headers = headers,
      options = options,
      multipartParts = parts
    )),
    jeTransport,
    path
  )

proc get*(
    client: Client;
    path: string;
    headers = initHeaders();
    options = RequestOptions()
): Future[JResult[Response]] =
  client.request(rmGet, path, headers = headers, options = options)

proc get*(
    client: Client;
    path: string;
    query: openArray[QueryParam];
    headers = initHeaders();
    options = RequestOptions()
): Future[JResult[Response]] =
  client.get(path.withQuery(query), headers, options)

proc head*(
    client: Client;
    path: string;
    headers = initHeaders();
    options = RequestOptions()
): Future[JResult[Response]] =
  client.request(rmHead, path, headers = headers, options = options)

proc options*(
    client: Client;
    path: string;
    headers = initHeaders();
    options = RequestOptions()
): Future[JResult[Response]] =
  client.request(rmOptions, path, headers = headers, options = options)

proc delete*(
    client: Client;
    path: string;
    headers = initHeaders();
    options = RequestOptions()
): Future[JResult[Response]] =
  client.request(rmDelete, path, headers = headers, options = options)

proc delete*(
    client: Client;
    path: string;
    query: openArray[QueryParam];
    headers = initHeaders();
    options = RequestOptions()
): Future[JResult[Response]] =
  client.delete(path.withQuery(query), headers, options)

proc post*(
    client: Client;
    path: string;
    body = "";
    headers = initHeaders();
    options = RequestOptions()
): Future[JResult[Response]] =
  client.request(rmPost, path, body, headers, options)

proc put*(
    client: Client;
    path: string;
    body = "";
    headers = initHeaders();
    options = RequestOptions()
): Future[JResult[Response]] =
  client.request(rmPut, path, body, headers, options)

proc patch*(
    client: Client;
    path: string;
    body = "";
    headers = initHeaders();
    options = RequestOptions()
): Future[JResult[Response]] =
  client.request(rmPatch, path, body, headers, options)
