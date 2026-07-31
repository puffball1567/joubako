import std/[asyncdispatch, httpclient, httpcore, strutils, times, uri]
import flowbrigade/timeout
import ../[chunkconsumer, http_retry, transport, types]

type
  PooledConnection = object
    client: AsyncHttpClient
    origin: string

  HttpTransport* = ref object of Transport
    userAgent*: string
    maxRedirects*: Natural
    proxy*: Proxy
    ## Maximum number of completed HTTP connections retained for reuse.
    ## Active requests are not limited; use the client bulkhead for that.
    maxIdleConnections*: Natural
    idleConnections: seq[PooledConnection]

proc validateAllowedHost(request: Request; url: Uri) =
  if url.hostname.len == 0:
    raise newJoubakoError(
      jeInvalidRequest,
      "HTTP request URL has no host",
      $url
    )
  if not isHostAllowed(url.hostname, request.options.allowedHosts):
    raise newJoubakoError(
      jeInvalidRequest,
      "request host is not in the configured allowlist",
      $url
    )

func sameOrigin(left, right: Uri): bool =
  proc effectivePort(url: Uri): string =
    if url.port.len > 0:
      url.port
    elif url.scheme.toLowerAscii == "https":
      "443"
    else:
      "80"
  left.scheme.toLowerAscii == right.scheme.toLowerAscii and
    left.hostname.toLowerAscii == right.hostname.toLowerAscii and
    left.effectivePort == right.effectivePort

func redirectedUrl(current: Uri; location: string): Uri =
  let target = parseUri(location)
  if target.isAbsolute:
    target
  else:
    combine(current, target)

func isRedirect(status: int): bool =
  status in [301, 302, 303, 307, 308]

func newHttpTransport*(
    userAgent = "Joubako/0.1";
    maxRedirects: Natural = 5;
    proxy: Proxy = nil;
    maxIdleConnections: Natural = 8
): HttpTransport =
  HttpTransport(
    userAgent: userAgent,
    maxRedirects: maxRedirects,
    proxy: proxy,
    maxIdleConnections: maxIdleConnections
  )

func originKey(url: Uri): string =
  let scheme = url.scheme.toLowerAscii
  let port =
    if url.port.len > 0:
      url.port
    elif scheme == "https":
      "443"
    else:
      "80"
  scheme & "://" & url.hostname.toLowerAscii & ":" & port

proc checkoutConnection(
    transport: HttpTransport;
    origin: string
): PooledConnection =
  ## Async transports are event-loop local. No yield occurs while the idle
  ## list is inspected, so checkout is atomic within that event loop.
  for index in 0 ..< transport.idleConnections.len:
    if transport.idleConnections[index].origin == origin:
      result = transport.idleConnections[index]
      transport.idleConnections.delete(index)
      return
  result = PooledConnection(
    client: newAsyncHttpClient(
      userAgent = transport.userAgent,
      maxRedirects = 0,
      proxy = transport.proxy
    ),
    origin: origin
  )

proc checkinConnection(
    transport: HttpTransport;
    connection: sink PooledConnection
) =
  if transport.maxIdleConnections == 0 or
      transport.idleConnections.len >= int(transport.maxIdleConnections):
    connection.client.close()
  else:
    transport.idleConnections.add(move(connection))

proc closeIdleConnections*(transport: HttpTransport) =
  ## Closes retained keep-alive sockets. Requests currently in progress are
  ## unaffected and may return their connection to the pool afterwards.
  for connection in transport.idleConnections.mitems:
    connection.client.close()
  transport.idleConnections.setLen(0)

func idleConnectionCount*(transport: HttpTransport): int =
  transport.idleConnections.len

func toStdMethod(httpMethod: RequestMethod): HttpMethod =
  case httpMethod
  of rmGet: HttpGet
  of rmHead: HttpHead
  of rmPost: HttpPost
  of rmPut: HttpPut
  of rmPatch: HttpPatch
  of rmDelete: HttpDelete
  of rmOptions: HttpOptions

proc readBodyBounded(
    client: AsyncHttpClient;
    response: AsyncResponse;
    request: Request;
    deadline: Deadline
): Future[string] {.async.} =
  ## Read one transport chunk at a time and check before appending it. This
  ## keeps an untrusted response from being fully materialized before the
  ## configured limit is enforced.
  let limit = request.options.maxResponseBytes
  var received = 0
  var total = -1'i64
  let declaredLength = response.headers.getOrDefault("content-length")
  if declaredLength.len > 0:
    try:
      total = declaredLength.parseBiggestInt
    except ValueError:
      discard
  while true:
    let reading = response.bodyStream.read()
    var waitMs = request.options.readTimeoutMs
    if deadline.isInitialized:
      let remainingMs = deadline.remaining.durationMillisecondsCeil
      if remainingMs <= 0:
        client.close()
        raise newJoubakoError(
          jeTimeout,
          "request exceeded its total deadline while reading the response",
          request.url,
          int(response.code)
        )
      if waitMs < 0 or remainingMs < waitMs:
        waitMs = remainingMs

    let token = request.options.cancellation
    if token != nil:
      let cancelled = token.cancellationFuture()
      if waitMs >= 0:
        let timer = sleepAsync(waitMs)
        await ((reading or cancelled) or timer)
        if not reading.finished:
          client.close()
          if token.cancelled:
            raise newJoubakoError(
              jeCancelled, token.reason, request.url, int(response.code)
            )
          raise newJoubakoError(
            jeTimeout,
            "response body read exceeded its deadline",
            request.url,
            int(response.code)
          )
      else:
        await (reading or cancelled)
        if not reading.finished:
          client.close()
          raise newJoubakoError(
            jeCancelled, token.reason, request.url, int(response.code)
          )
    elif waitMs >= 0 and not await reading.withTimeout(waitMs):
      client.close()
      raise newJoubakoError(
        jeTimeout,
        "response body read exceeded its deadline",
        request.url,
        int(response.code)
      )
    let (hasValue, chunk) = await reading
    if not hasValue:
      break

    if limit >= 0 and (received > limit or chunk.len > limit - received):
      client.close()
      raise newJoubakoError(
        jeBodyTooLarge,
        "response body exceeded the configured limit while streaming",
        request.url,
        int(response.code)
      )

    received += chunk.len
    await request.consumeDownloadChunk(chunk)
    if not request.options.streamResponse:
      result.add chunk
    if not request.options.onDownloadProgress.isNil:
      request.options.onDownloadProgress(int64(received), total)

proc buildResponse(
    client: AsyncHttpClient;
    raw: AsyncResponse;
    request: Request;
    deadline: Deadline
): Future[types.Response] {.async.} =
  if request.options.maxResponseBytes >= 0:
    let declaredLength = raw.headers.getOrDefault("content-length")
    if declaredLength.len > 0:
      try:
        if declaredLength.parseInt > request.options.maxResponseBytes:
          raise newJoubakoError(
            jeBodyTooLarge,
            "declared response body exceeds the configured limit",
            request.url,
            int(raw.code)
          )
      except ValueError:
        discard

  let body = await readBodyBounded(client, raw, request, deadline)

  var responseHeaders = initHeaders()
  for name, value in raw.headers.pairs:
    responseHeaders.add(name, value)

  return types.Response(
    status: int(raw.code),
    statusText: raw.status,
    headers: responseHeaders,
    body: body,
    request: request
  )

proc performRedirectingRequest(
    transport: HttpTransport;
    request: Request;
    initialHeaders: HttpHeaders
): Future[types.Response] {.async.} =
  var currentUrl = parseUri(request.url)
  request.validateAllowedHost(currentUrl)
  var connection = transport.checkoutConnection(currentUrl.originKey)
  var reusable = false
  defer:
    if reusable:
      transport.checkinConnection(move(connection))
    else:
      connection.client.close()
  var currentMethod = request.httpMethod
  var currentBody = request.body
  var currentHeaders = initialHeaders
  let deadline =
    if request.options.timeoutMs >= 0:
      initDeadline(initDuration(milliseconds = request.options.timeoutMs))
    else:
      Deadline()

  for redirectCount in 0 .. transport.maxRedirects:
    let client = connection.client
    block:
      var hopRequest = request
      hopRequest.url = $currentUrl
      hopRequest.httpMethod = currentMethod
      hopRequest.body = currentBody

      let pendingHeaders = client.request(
        hopRequest.url,
        hopRequest.httpMethod.toStdMethod,
        hopRequest.body,
        currentHeaders
      )
      var waitMs = request.options.connectTimeoutMs
      if deadline.isInitialized:
        let remainingMs = deadline.remaining.durationMillisecondsCeil
        if remainingMs <= 0:
          raise newJoubakoError(
            jeTimeout, "request exceeded its total deadline", hopRequest.url
          )
        if waitMs < 0 or remainingMs < waitMs:
          waitMs = remainingMs

      let token = request.options.cancellation
      if token != nil:
        let cancelled = token.cancellationFuture()
        if waitMs >= 0:
          let timer = sleepAsync(waitMs)
          await ((pendingHeaders or cancelled) or timer)
          if not pendingHeaders.finished:
            client.close()
            if token.cancelled:
              raise newJoubakoError(
                jeCancelled, token.reason, hopRequest.url
              )
            raise newJoubakoError(
              jeTimeout,
              "connection or response headers exceeded their deadline",
              hopRequest.url
            )
        else:
          await (pendingHeaders or cancelled)
          if not pendingHeaders.finished:
            client.close()
            raise newJoubakoError(
              jeCancelled, token.reason, hopRequest.url
            )
      elif waitMs >= 0 and not await pendingHeaders.withTimeout(waitMs):
        client.close()
        raise newJoubakoError(
          jeTimeout,
          "connection or response headers exceeded their deadline",
          hopRequest.url
        )

      let raw = await pendingHeaders
      if not request.options.onUploadProgress.isNil:
        request.options.onUploadProgress(
          int64(hopRequest.body.len),
          int64(hopRequest.body.len)
        )
      result = await buildResponse(client, raw, hopRequest, deadline)

      if not result.status.isRedirect or
          not result.headers.contains("location"):
        result.request = request
        connection.origin = currentUrl.originKey
        reusable = true
        return
      if transport.maxRedirects == 0:
        result.request = request
        connection.origin = currentUrl.originKey
        reusable = true
        return
      if redirectCount >= transport.maxRedirects:
        raise newJoubakoError(
          jeTransport,
          "maximum HTTP redirects exceeded",
          hopRequest.url,
          result.status
        )

      let nextUrl = redirectedUrl(currentUrl, result.headers.get("location"))
      request.validateAllowedHost(nextUrl)
      if not sameOrigin(currentUrl, nextUrl):
        currentHeaders.del("authorization")
        currentHeaders.del("cookie")
        currentHeaders.del("proxy-authorization")
        currentHeaders.del("host")

      if result.status in [301, 302, 303] and
          currentMethod notin {rmGet, rmHead}:
        currentMethod = rmGet
        currentBody = ""
        currentHeaders.del("content-length")
        currentHeaders.del("content-type")
        currentHeaders.del("transfer-encoding")
      currentUrl = nextUrl

method send*(
    transport: HttpTransport;
    request: Request
): Future[types.Response] {.async.} =
  if request.options.cancellation != nil and
      request.options.cancellation.cancelled:
    raise newJoubakoError(
      jeCancelled,
      request.options.cancellation.reason,
      request.url
    )

  var stdHeaders = newHttpHeaders()
  for name, value in request.headers.pairs:
    stdHeaders.add(name, value)

  try:
    let pending = transport.performRedirectingRequest(request, stdHeaders)

    let token = request.options.cancellation
    if token != nil:
      let cancelled = token.cancellationFuture()
      if request.options.timeoutMs >= 0:
        let deadline = sleepAsync(request.options.timeoutMs)
        await ((pending or cancelled) or deadline)
        if pending.finished:
          discard
        elif token.cancelled:
          raise newJoubakoError(
            jeCancelled,
            token.reason,
            request.url
          )
        else:
          raise newJoubakoError(
            jeTimeout,
            "request exceeded its deadline",
            request.url
          )
      else:
        await (pending or cancelled)
        if not pending.finished:
          raise newJoubakoError(
            jeCancelled,
            token.reason,
            request.url
          )
    elif request.options.timeoutMs >= 0:
      if not await pending.withTimeout(request.options.timeoutMs):
        raise newJoubakoError(
          jeTimeout,
          "request exceeded its deadline",
          request.url
        )

    result = await pending
  except JoubakoError:
    raise
  except CatchableError as error:
    raise newJoubakoError(jeTransport, error.msg, request.url)
