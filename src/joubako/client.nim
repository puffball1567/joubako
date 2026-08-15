import std/[asyncdispatch, strutils, times, uri]
import flowbrigade/[backoff, bulkhead, circuit_breaker, retry, timeout]
import flowbrigade/ratelimit/token_bucket
import ./[http_retry, opentelemetry, query, result, transport, types]
import ./internal/futurevalue

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
    telemetry: OpenTelemetryConfig

proc addClientCallback(
    source: FutureBase;
    callback: proc() {.closure.}
) =
  ## asyncdispatch requires a gcsafe callback even though its dispatcher runs
  ## this closure on the current event-loop thread. User status validators are
  ## intentionally not required to claim thread safety.
  type SafeCallback = proc() {.closure, gcsafe.}
  {.cast(gcsafe).}:
    source.addCallback(cast[SafeCallback](callback))

proc useOpenTelemetry*(
    client: Client;
    observer: OpenTelemetryObserverProc;
    options = defaultOpenTelemetryOptions()
) =
  if client != nil:
    client.telemetry = newOpenTelemetryConfig(observer, options)

proc clearOpenTelemetry*(client: Client) =
  if client != nil:
    client.telemetry = nil

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

proc prepareRequest(
    client: Client;
    httpMethod: RequestMethod;
    path: string;
    body: string;
    headers: Headers;
    options: RequestOptions;
    multipartParts: seq[MultipartPart];
    uploadSource: UploadSource
): JResult[Request] =
  ## Request construction is shared by the lightweight single-attempt path
  ## and the full interceptor/resilience path. This keeps every method and
  ## body format under the same defaults and validation contract.
  if client == nil or client.transport == nil:
    return err[Request](newJoubakoError(
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
  if not options.onResponseHeaders.isNil:
    effectiveOptions.onResponseHeaders = options.onResponseHeaders
  if options.streamResponse:
    effectiveOptions.streamResponse = true

  let url = client.resolveUrl(path)
  if url.len == 0:
    return err[Request](newJoubakoError(
      jeInvalidRequest, "request URL is empty"
    ))

  ok(Request(
    httpMethod: httpMethod,
    url: url,
    headers: mergedHeaders,
    body: body,
    multipartParts: multipartParts,
    uploadSource: uploadSource,
    options: effectiveOptions
  ))

proc requestValidationError(
    request: Request;
    emptyUrlMessage = "request URL is empty"
): ref JoubakoError =
  if request.url.len == 0:
    return newJoubakoError(jeInvalidRequest, emptyUrlMessage)
  if request.url.contains({'\r', '\n'}):
    return newJoubakoError(
      jeInvalidRequest,
      "request URL contains a line break",
      request.url
    )
  for name, value in request.headers.pairs:
    if name.len == 0 or name.contains({'\r', '\n'}) or
        value.contains({'\r', '\n'}):
      return newJoubakoError(
        jeInvalidRequest,
        "request contains an invalid header",
        request.url
      )

  if request.uploadSource != nil:
    if request.body.len > 0 or request.multipartParts.len > 0:
      return newJoubakoError(
        jeInvalidRequest,
        "streaming uploads cannot also contain a buffered or multipart body",
        request.url
      )
    if request.uploadSource.read.isNil or request.uploadSource.setWake.isNil:
      return newJoubakoError(
        jeInvalidRequest, "streaming upload source is incomplete", request.url
      )
    if request.headers.contains("content-length"):
      return newJoubakoError(
        jeInvalidRequest,
        "streaming uploads determine their length from end-of-stream",
        request.url
      )
    if request.options.retry.maxAttempts >= 2:
      return newJoubakoError(
        jeInvalidRequest,
        "streaming uploads cannot be retried because the body is not replayable",
        request.url
      )

  if request.multipartParts.len > 0:
    if request.body.len > 0:
      return newJoubakoError(
        jeInvalidRequest,
        "multipart requests cannot also contain a buffered body",
        request.url
      )
    if request.headers.contains("content-type"):
      return newJoubakoError(
        jeInvalidRequest,
        "file-backed multipart content type and boundary are generated automatically",
        request.url
      )
    for part in request.multipartParts:
      if part.name.len == 0 or
          part.name.contains({'\0', '\r', '\n', '"'}):
        return newJoubakoError(
          jeInvalidRequest, "invalid multipart field name", request.url
        )
      if part.filename.contains({'\0', '\r', '\n', '"'}):
        return newJoubakoError(
          jeInvalidRequest, "invalid multipart filename", request.url
        )
      if part.contentType.contains({'\0', '\r', '\n'}):
        return newJoubakoError(
          jeInvalidRequest, "invalid multipart content type", request.url
        )
      if part.filePath.len > 0 and part.filename.len == 0:
        return newJoubakoError(
          jeInvalidRequest,
          "file-backed multipart part has no transmitted filename",
          request.url
        )
      if part.filePath.len > 0 and part.body.len > 0:
        return newJoubakoError(
          jeInvalidRequest,
          "file-backed multipart part cannot also contain buffered data",
          request.url
        )

  if request.options.maxRequestBytes >= 0 and
      request.body.len > request.options.maxRequestBytes:
    return newJoubakoError(
      jeBodyTooLarge,
      "request body exceeded the configured limit",
      request.url
    )

  if request.options.cancellation != nil and
      request.options.cancellation.cancelled:
    return newJoubakoError(
      jeCancelled,
      request.options.cancellation.reason,
      request.url
    )

proc evaluateResponseValue(
    client: Client;
    response: sink Response
): JResult[Response] =
  ## Central post-transport safety contract shared by compatible custom
  ## transports and the ownership-aware built-in path.
  # A completed response must not retain the producer closures or queued
  # upload chunks. The ordinary request metadata remains inspectable.
  response.request.uploadSource = nil

  if response.request.options.cancellation != nil and
      response.request.options.cancellation.cancelled:
    return err[Response](newJoubakoError(
      jeCancelled,
      response.request.options.cancellation.reason,
      response.request.url
    ))

  if response.request.options.maxResponseBytes >= 0 and
      response.body.len > response.request.options.maxResponseBytes:
    return err[Response](newJoubakoError(
      jeBodyTooLarge,
      "response body exceeded the configured limit",
      response.request.url,
      response.status
    ))

  if client.validateStatus != nil:
    var accepted = false
    try:
      accepted = client.validateStatus(response.status)
    except CatchableError as error:
      return err[Response](error.asJoubakoError(
        jeInvalidRequest, response.request.url
      ))
    if not accepted:
      let statusError = newJoubakoError(
        jeHttpStatus,
        "HTTP request failed with status " & $response.status,
        response.request.url,
        response.status,
        parseRetryAfterMs(response.headers.get("retry-after"))
      )
      statusError.attachResponse(response)
      return err[Response](statusError)
  ok(move(response))

proc evaluateResponse(
    client: Client;
    request: Request;
    transportResult: var JResult[Response]
): JResult[Response] =
  ## Apply the same post-transport safety contract on both orchestration
  ## paths. Keeping this independent of the request method prevents the
  ## lightweight path from becoming a benchmark-specific GET shortcut.
  if transportResult.isErr:
    return err[Response](transportResult.error)
  var response = transportResult.takeValue()

  # Transports normally attach the request they actually dispatched. Avoid
  # replacing that value with another deep copy of the same strings, headers,
  # multipart parts and options on every successful response. Custom
  # transports may omit it, in which case the client supplies the contract.
  if response.request.url.len == 0:
    response.request = request
  client.evaluateResponseValue(move(response))

proc evaluateOwnedResponse(
    client: Client;
    transportResult: var JResult[Response]
): JResult[Response] =
  ## Evaluate a response from a transport that guarantees the dispatched
  ## Request is moved into Response.request. This avoids keeping a second full
  ## Request alive solely for post-dispatch checks on the common success path.
  if transportResult.isErr:
    return err[Response](transportResult.error)
  var response = transportResult.takeValue()
  if response.request.url.len == 0:
    return err[Response](newJoubakoError(
      jeTransport,
      "owned request transport returned no request metadata"
    ))
  client.evaluateResponseValue(move(response))

proc requestResult(
    client: Client;
    httpMethod: RequestMethod;
    path: string;
    body = "";
    headers = initHeaders();
    options: RequestOptions = RequestOptions();
    multipartParts: seq[MultipartPart] = @[];
    uploadSource: UploadSource = nil
): Future[JResult[Response]] {.async.} =
  var prepared = client.prepareRequest(
    httpMethod,
    path,
    body,
    headers,
    options,
    multipartParts,
    uploadSource
  )
  if prepared.isErr:
    return err[Response](prepared.error)
  var request = prepared.takeValue()

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
    var interceptorResult = await settle(
      fallible(intercepted), jeTransport, request.url
    )
    if interceptorResult.isErr:
      return err[Response](interceptorResult.error)
    request = interceptorResult.takeValue()

  let validationError = request.requestValidationError(
    "interceptor produced an empty URL"
  )
  if validationError != nil:
    return err[Response](validationError)

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
  proc dispatchAttempt(
      attemptRequest: Request
  ): Future[JResult[Response]] =
    inc completedAttempts
    try:
      settle(
        fallible(client.transport.send(attemptRequest)),
        jeTransport,
        request.url
      )
    except CatchableError as error:
      completedResult(err[Response](
        error.asJoubakoError(jeTransport, request.url)
      ))

  proc evaluateAttempt(
      transportResult: var JResult[Response]
  ): JResult[Response] =
    client.evaluateResponse(request, transportResult)

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

    var transportResult = await dispatchAttempt(attemptRequest)
    return evaluateAttempt(transportResult)

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
    var transportResult = await dispatchAttempt(request)
    attemptResult = evaluateAttempt(transportResult)
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
  var response = attemptResult.takeValue()
  response.attempts = completedAttempts

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
    var interceptorResult = await settle(
      fallible(intercepted), jeTransport, request.url
    )
    if interceptorResult.isErr:
      interceptorResult.error.attempts = completedAttempts
      return err[Response](interceptorResult.error)
    response = interceptorResult.takeValue()
    if response.request.url.len == 0:
      response.request = request
    response.request.uploadSource = nil
    response.attempts = completedAttempts

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

proc observedRequestResultWithTelemetry(
    client: Client;
    httpMethod: RequestMethod;
    path: string;
    body = "";
    headers = initHeaders();
    options: RequestOptions = RequestOptions();
    multipartParts: seq[MultipartPart] = @[];
    uploadSource: UploadSource = nil
): Future[JResult[Response]] {.async.} =
  var tracedHeaders = initHeaders()
  tracedHeaders.merge(headers)
  var propagationHeaders = initHeaders()
  if client != nil:
    propagationHeaders.merge(client.defaultHeaders)
  propagationHeaders.overlay(headers)
  let resolvedUrl =
    if client == nil: path
    else: client.resolveUrl(path)
  let telemetry = if client == nil: nil else: client.telemetry
  let span = startHttpClientSpan(
    telemetry,
    httpMethod,
    resolvedUrl,
    propagationHeaders,
    tracedHeaders
  )
  let outcome = await settleResult(
    fallible(client.requestResult(
      httpMethod,
      path,
      body,
      tracedHeaders,
      options,
      multipartParts,
      uploadSource
    )),
    jeTransport,
    path
  )
  if span != nil:
    if outcome.isOk:
      finishHttpClientSpan(
        telemetry,
        span,
        outcome.value.request.url,
        outcome.value.status,
        outcome.value.attempts
      )
    else:
      finishHttpClientSpan(
        telemetry,
        span,
        outcome.error.url,
        outcome.error.status,
        outcome.error.attempts,
        outcome.error
      )
  return outcome

func canUseSingleAttemptPath(
    client: Client;
    options: RequestOptions
): bool =
  ## This path is method- and payload-independent. It is selected solely by
  ## whether request-level orchestration is required.
  if client == nil or client.transport == nil:
    return false
  let maxAttempts =
    if options.retry.maxAttempts != 0:
      options.retry.maxAttempts
    else:
      client.defaultOptions.retry.maxAttempts
  maxAttempts < 2 and
    client.requestInterceptors.len == 0 and
    client.responseInterceptors.len == 0 and
    client.circuitBreaker == nil and
    client.bulkhead == nil and
    client.rateLimiter == nil

proc singleAttemptResult(
    client: Client;
    httpMethod: RequestMethod;
    path: string;
    body: string;
    headers: Headers;
    options: RequestOptions;
    multipartParts: seq[MultipartPart];
    uploadSource: UploadSource
): Future[JResult[Response]] =
  ## Avoid the full async retry/interceptor state machine when none of those
  ## features are active. All methods, headers, limits and body formats share
  ## the same preparation, validation and response evaluation as the full
  ## path, and this Future still cannot fail with a CatchableError.
  result = newFuture[JResult[Response]]("Joubako.Client.singleAttemptResult")
  let destination = result
  var request: Request
  var pending: Future[Response]
  var ownedDispatch = false
  var requestUrl: string

  try:
    var prepared = client.prepareRequest(
      httpMethod,
      path,
      body,
      headers,
      options,
      multipartParts,
      uploadSource
    )
    if prepared.isErr:
      destination.complete(err[Response](prepared.error))
      return
    request = prepared.takeValue()

    let validationError = request.requestValidationError()
    if validationError != nil:
      destination.complete(err[Response](validationError))
      return

    requestUrl = request.url
    ownedDispatch = client.transport.supportsOwnedRequestDispatch()
    if ownedDispatch:
      pending = client.transport.sendOwned(move(request))
    else:
      pending = client.transport.send(request)
    if pending == nil:
      let failure = newJoubakoError(
        jeTransport, "transport returned a nil Future", requestUrl
      )
      failure.attempts = 1
      destination.complete(err[Response](failure))
      return
  except CatchableError as error:
    let failure = error.asJoubakoError(jeTransport, requestUrl)
    failure.attempts = if requestUrl.len == 0: 0 else: 1
    destination.complete(err[Response](failure))
    return

  pending.addClientCallback(proc() =
    pending.clearCallbacks()
    if pending.failed:
      var failure = move(pending.error)
      pending.errorStackTrace.setLen(0)
      let structured = failure.asJoubakoError(jeTransport, requestUrl)
      structured.attempts = 1
      destination.complete(err[Response](structured))
      pending = nil
      return

    try:
      var response = pending.takeFutureValue()
      response.attempts = 1
      var transportOutcome = ok(move(response))
      var outcome =
        if ownedDispatch:
          client.evaluateOwnedResponse(transportOutcome)
        else:
          client.evaluateResponse(request, transportOutcome)
      if outcome.isErr:
        outcome.error.attempts = 1
      destination.complete(move(outcome))
    except CatchableError as error:
      let failure = error.asJoubakoError(jeTransport, requestUrl)
      failure.attempts = 1
      destination.complete(err[Response](failure))
    pending = nil
  )

proc observedRequestResult(
    client: Client;
    httpMethod: RequestMethod;
    path: string;
    body = "";
    headers = initHeaders();
    options: RequestOptions = RequestOptions();
    multipartParts: seq[MultipartPart] = @[];
    uploadSource: UploadSource = nil
): Future[JResult[Response]] =
  ## Avoid constructing tracing headers and another async state machine when
  ## telemetry is disabled, which is the ordinary request path.
  if client == nil or client.telemetry == nil:
    when not defined(joubakoDisableSingleAttemptFastPath):
      if client.canUseSingleAttemptPath(options):
        return client.singleAttemptResult(
          httpMethod,
          path,
          body,
          headers,
          options,
          multipartParts,
          uploadSource
        )
    return settleResult(
      fallible(client.requestResult(
        httpMethod,
        path,
        body,
        headers,
        options,
        multipartParts,
        uploadSource
      )),
      jeTransport,
      path
    )
  client.observedRequestResultWithTelemetry(
    httpMethod,
    path,
    body,
    headers,
    options,
    multipartParts,
    uploadSource
  )

proc request*(
    client: Client;
    httpMethod: RequestMethod;
    path: string;
    body = "";
    headers = initHeaders();
    options: RequestOptions = RequestOptions()
): Future[JResult[Response]] =
  client.observedRequestResult(httpMethod, path, body, headers, options)

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
  client.observedRequestResult(
    httpMethod,
    path,
    headers = headers,
    options = options,
    multipartParts = parts
  )

proc requestUploadSource*(
    client: Client;
    httpMethod: RequestMethod;
    path: string;
    source: UploadSource;
    headers = initHeaders();
    options: RequestOptions = RequestOptions()
): Future[JResult[Response]] =
  ## Low-level entry point used by bounded upload producers. Most callers
  ## should use `openUpload` from `joubako/uploadstream`.
  client.observedRequestResult(
    httpMethod,
    path,
    headers = headers,
    options = options,
    uploadSource = source
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
