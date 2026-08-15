import std/[asyncdispatch, asyncnet, base64, httpclient, httpcore, monotimes,
  nativesockets, os, strutils, times, uri]
when defined(ssl):
  import std/[net, openssl, ssl_config]
import flowbrigade/timeout
import ../[chunkconsumer, compression, cookiejar, http_retry, result,
  proxyconfig, transport, types]

type
  TlsVerifyMode* = enum
    tvmPeer,
    tvmPeerUseEnvVars,
    tvmNone

  TlsOptions* = object
    ## Peer verification is enabled by default. `tvmNone` must be selected
    ## explicitly and should be limited to controlled development systems.
    verifyMode*: TlsVerifyMode
    caFile*: string
    caDir*: string
    certFile*: string
    keyFile*: string
    cipherList*: string
    cipherSuites*: string

  PooledConnection = object
    client: AsyncHttpClient
    origin: string
    proxyAuthorization: string
    noDelaySocket: pointer
    when defined(ssl):
      sslContext: SslContext

  TimeoutWaiter = ref object
    expiresAt: MonoTime
    destination: Future[bool]
    pending: FutureBase

  TimeoutScheduler = ref object
    waiters: seq[TimeoutWaiter]
    wake: Future[void]
    sleepingUntil: MonoTime
    sleeping: bool
    running: bool

  HttpTransport* = ref object of Transport
    userAgent*: string
    maxRedirects*: Natural
    proxy*: Proxy
    proxyOptions*: ProxyOptions
    ## Maximum number of completed HTTP connections retained for reuse.
    ## Active requests are not limited; use the client bulkhead for that.
    maxIdleConnections*: Natural
    cookieJar*: CookieJar
    tlsOptions*: TlsOptions
    idleConnections: seq[PooledConnection]
    timeoutScheduler: TimeoutScheduler

proc wakeScheduler(scheduler: TimeoutScheduler) =
  if scheduler.sleeping and scheduler.wake != nil and
      not scheduler.wake.finished:
    scheduler.wake.complete()

proc runTimeoutScheduler(scheduler: TimeoutScheduler): Future[void] {.async.} =
  try:
    while scheduler.waiters.len > 0:
      var earliest = scheduler.waiters[0].expiresAt
      for index in 1 ..< scheduler.waiters.len:
        if scheduler.waiters[index].expiresAt < earliest:
          earliest = scheduler.waiters[index].expiresAt

      scheduler.sleepingUntil = earliest
      scheduler.sleeping = true
      let remaining = earliest - getMonoTime()
      let waitMs = max(
        0'i64,
        (remaining.inNanoseconds + 999_999) div 1_000_000
      )
      let timer = sleepAsync(waitMs.int)
      let wake = newFuture[void]("Joubako.HttpTimeoutScheduler.wake")
      let gate = newFuture[void]("Joubako.HttpTimeoutScheduler.gate")
      scheduler.wake = wake

      proc openGate() =
        if not gate.finished:
          gate.complete()

      timer.addCallback(openGate)
      wake.addCallback(openGate)
      await gate
      # Whichever side lost must not retain the completed gate or this async
      # scheduler until a stale dispatcher timer eventually expires.
      timer.clearCallbacks()
      wake.clearCallbacks()
      scheduler.sleeping = false

      let now = getMonoTime()
      var index = scheduler.waiters.high
      while index >= 0:
        let waiter = scheduler.waiters[index]
        if waiter.expiresAt <= now:
          scheduler.waiters.del(index)
          waiter.pending.clearCallbacks()
          if not waiter.destination.finished:
            waiter.destination.complete(false)
        dec index
  finally:
    scheduler.wake = nil
    scheduler.sleeping = false
    scheduler.running = false

proc registerTimeout(
    scheduler: TimeoutScheduler;
    timeoutMs: int;
    destination: Future[bool];
    pending: FutureBase
): TimeoutWaiter =
  result = TimeoutWaiter(
    expiresAt: getMonoTime() + initDuration(milliseconds = timeoutMs),
    destination: destination,
    pending: pending
  )
  scheduler.waiters.add result
  if not scheduler.running:
    scheduler.running = true
    asyncCheck scheduler.runTimeoutScheduler()
  elif scheduler.sleeping and result.expiresAt < scheduler.sleepingUntil:
    scheduler.wakeScheduler()

proc unregisterTimeout(
    scheduler: TimeoutScheduler;
    waiter: TimeoutWaiter
) =
  for index in 0 ..< scheduler.waiters.len:
    if scheduler.waiters[index] == waiter:
      scheduler.waiters.del(index)
      # Removing the earliest waiter does not require rescheduling: the old
      # timer may wake before the next deadline, which is safe, and avoids a
      # scheduler restart for every successful I/O completion. Wake only to
      # let an otherwise idle scheduler terminate promptly.
      if scheduler.waiters.len == 0:
        scheduler.wakeScheduler()
      return

proc waitWithTimeout[T](
    scheduler: TimeoutScheduler;
    pending: Future[T];
    timeoutMs: int
): Future[bool] =
  ## The caller owns `pending` exclusively while this race is active. Both
  ## completion paths detach the losing callback before releasing the waiter.
  result = newFuture[bool]("Joubako.HttpTimeoutScheduler.waitWithTimeout")
  let destination = result
  let waiter = scheduler.registerTimeout(timeoutMs, destination, pending)

  pending.addCallback(proc() =
    scheduler.unregisterTimeout(waiter)
    if destination.finished:
      return
    if pending.failed:
      destination.fail(pending.error)
    else:
      destination.complete(true)
  )

proc closeImmediately(client: AsyncHttpClient) {.raises: [].} =
  ## `AsyncHttpClient.close` only closes its socket after std/httpclient has
  ## marked the client connected. On older Nim releases, cancellation can win
  ## after the peer accepts the socket but just before that flag is set. Close
  ## the actual socket first so this narrow connect/cancel race cannot leave a
  ## live connection behind; the public close then resets client state.
  try:
    let socket = client.getSocket()
    if socket != nil and not socket.isClosed:
      socket.close()
    client.close()
  except Exception:
    discard

proc registerConnectionCancellation(
    token: CancellationToken;
    client: AsyncHttpClient
): tuple[active: ref bool, signal: Future[void]] =
  ## Register exactly once per HTTP exchange. The token callback closes the
  ## owned socket before completing the private relay, so cancellation does
  ## not depend on a nested Future `or` waking a platform selector. Consumers
  ## race the relay rather than the shared token Future and therefore cannot
  ## overwrite this connection-closing callback.
  new(result.active)
  result.active[] = true
  result.signal = newFuture[void](
    "Joubako.HttpTransport.cancellationRelay"
  )
  let active = result.active
  let signal = result.signal
  token.cancellationFuture().addCallback(proc() =
    if active[]:
      client.closeImmediately()
    if not signal.finished:
      signal.complete()
  )

func defaultTlsOptions*(): TlsOptions =
  TlsOptions(verifyMode: tvmPeer)

method usesImplicitCredentials*(transport: HttpTransport): bool =
  transport != nil and transport.cookieJar != nil

proc `=copy`(destination: var PooledConnection; source: PooledConnection) {.
  error: "PooledConnection owns a TLS context and cannot be copied".}

proc close(connection: var PooledConnection) {.raises: [].} =
  if connection.client != nil:
    connection.client.closeImmediately()
    connection.client = nil
  when defined(ssl):
    if connection.sslContext != nil:
      try:
        connection.sslContext.destroyContext()
      except Exception:
        discard
      connection.sslContext = nil

proc `=destroy`(connection: var PooledConnection) =
  connection.close()
  `=destroy`(connection.origin)
  `=destroy`(connection.proxyAuthorization)

func baseHttpHeaders(): HttpHeaders =
  newHttpHeaders({"accept-encoding": "gzip, deflate"})

proc enableTcpNoDelay(connection: var PooledConnection) =
  ## AsyncHttpClient sends the header block and request body separately. On a
  ## reused connection, Nagle's algorithm can otherwise turn a small-body
  ## request into a delayed-ACK stall. AsyncHttpClient does not expose its
  ## async socket, so fieldPairs is used to configure the typed socket field.
  for name, field in fieldPairs(connection.client[]):
    when name == "socket":
      if field == nil or field.isClosed:
        connection.noDelaySocket = nil
      elif cast[pointer](field) != connection.noDelaySocket:
        field.setSockOpt(OptNoDelay, true, level = IPPROTO_TCP.cint)
        connection.noDelaySocket = cast[pointer](field)

func hasHeader(headers: HttpHeaders; name: string): bool =
  headers != nil and headers.hasKey(name)

proc deleteHeader(headers: HttpHeaders; name: string) =
  if headers != nil:
    headers.del(name)

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

func hasResponseBody(request: Request; status: int): bool =
  request.httpMethod != rmHead and
    status notin 100 .. 199 and
    status notin [204, 304]

proc newHttpTransport*(
    userAgent = "Joubako/0.1";
    maxRedirects: Natural = 5;
    proxy: Proxy = nil;
    maxIdleConnections: Natural = 32;
    cookieJar: CookieJar = nil;
    tlsOptions = defaultTlsOptions();
    proxyOptions = ProxyOptions()
): HttpTransport =
  if (tlsOptions.certFile.len == 0) != (tlsOptions.keyFile.len == 0):
    raise newException(
      ValueError,
      "TLS client certificate and private key must be configured together"
    )
  proxyOptions.validate()
  HttpTransport(
    userAgent: userAgent,
    maxRedirects: maxRedirects,
    proxy: proxy,
    proxyOptions: proxyOptions,
    maxIdleConnections: maxIdleConnections,
    cookieJar: cookieJar,
    tlsOptions: tlsOptions,
    timeoutScheduler: TimeoutScheduler()
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

when defined(ssl):
  type X509VerifyParam = pointer

  proc SSL_CTX_get0_param(context: SslCtx): X509VerifyParam {.
    cdecl, dynlib: DLLSSLName, importc.}
  proc X509_VERIFY_PARAM_set1_host(
      param: X509VerifyParam;
      hostname: cstring;
      hostnameLength: csize_t
  ): cint {.cdecl, dynlib: DLLSSLName, importc.}
  proc X509_VERIFY_PARAM_set1_ip_asc(
      param: X509VerifyParam;
      address: cstring
  ): cint {.cdecl, dynlib: DLLSSLName, importc.}

  proc newTlsContext(transport: HttpTransport; hostname: string): SslContext =
    let verifyMode =
      case transport.tlsOptions.verifyMode
      of tvmPeer: CVerifyPeer
      of tvmPeerUseEnvVars: CVerifyPeerUseEnvVars
      of tvmNone: CVerifyNone
    result = newContext(
      verifyMode = verifyMode,
      certFile = transport.tlsOptions.certFile,
      keyFile = transport.tlsOptions.keyFile,
      cipherList = if transport.tlsOptions.cipherList.len == 0:
        CiphersIntermediate
      else:
        transport.tlsOptions.cipherList,
      caDir = transport.tlsOptions.caDir,
      caFile = transport.tlsOptions.caFile,
      ciphersuites = if transport.tlsOptions.cipherSuites.len == 0:
        CiphersModern
      else:
        transport.tlsOptions.cipherSuites
    )

    when not defined(nimDisableCertificateValidation):
      if transport.tlsOptions.verifyMode != tvmNone:
        let param = SSL_CTX_get0_param(result.context)
        if param == nil:
          raise newException(IOError, "failed to configure TLS hostname verification")
        let configured =
          if hostname.isIpAddress:
            X509_VERIFY_PARAM_set1_ip_asc(param, hostname.cstring)
          else:
            X509_VERIFY_PARAM_set1_host(
              param,
              hostname.cstring,
              csize_t(hostname.len)
            )
        if configured != 1:
          raise newException(IOError, "failed to configure TLS hostname verification")

proc checkoutConnection(
    transport: HttpTransport;
    url: Uri
): PooledConnection =
  ## Async transports are event-loop local. No yield occurs while the idle
  ## list is inspected, so checkout is atomic within that event loop.
  let selectedProxy =
    if transport.proxy != nil:
      transport.proxy
    elif not transport.proxyOptions.useEnvironment and
        transport.proxyOptions.httpProxy.len == 0 and
        transport.proxyOptions.httpsProxy.len == 0 and
        transport.proxyOptions.allProxy.len == 0:
      nil
    else:
      let configured = transport.proxyOptions.proxyUrlFor($url)
      if configured.len == 0: nil else: newProxy(configured)
  let origin = url.originKey & "|proxy=" &
    (if selectedProxy == nil: "direct" else: $selectedProxy.url)
  for index in 0 ..< transport.idleConnections.len:
    if transport.idleConnections[index].origin == origin:
      result = move(transport.idleConnections[index])
      # Idle connection order has no public meaning. Swap-delete avoids
      # shifting the remaining pool on every same-origin checkout.
      transport.idleConnections.del(index)
      return
  var clientProxy = selectedProxy
  var proxyAuthorization = ""
  if selectedProxy != nil and
      selectedProxy.url.scheme.toLowerAscii == "http" and
      selectedProxy.url.username.len > 0:
    proxyAuthorization = "Basic " & encode(
      selectedProxy.url.username & ":" & selectedProxy.url.password
    )
    var proxyUrl = selectedProxy.url
    proxyUrl.username = ""
    proxyUrl.password = ""
    clientProxy = newProxy(proxyUrl)
  when defined(ssl):
    if url.scheme.toLowerAscii == "https":
      let sslContext = transport.newTlsContext(url.hostname)
      result = PooledConnection(
        client: newAsyncHttpClient(
          userAgent = transport.userAgent,
          maxRedirects = 0,
          # The verification parameter is hostname-specific. A context per
          # new pooled connection keeps concurrent origins isolated.
          sslContext = sslContext,
          proxy = clientProxy
        ),
        origin: origin,
        proxyAuthorization: proxyAuthorization,
        sslContext: sslContext
      )
    else:
      result = PooledConnection(
        client: newAsyncHttpClient(
          userAgent = transport.userAgent,
          maxRedirects = 0,
          proxy = clientProxy
        ),
        origin: origin,
        proxyAuthorization: proxyAuthorization
      )
  else:
    result = PooledConnection(
      client: newAsyncHttpClient(
        userAgent = transport.userAgent,
        maxRedirects = 0,
        proxy = clientProxy
      ),
      origin: origin,
      proxyAuthorization: proxyAuthorization
    )
  # Compression support is connection-invariant. Keeping it in the client's
  # base headers avoids allocating a one-entry override table on every method
  # when callers did not provide request headers.
  result.client.headers = baseHttpHeaders()

proc checkinConnection(
    transport: HttpTransport;
    connection: sink PooledConnection
) =
  if transport.maxIdleConnections == 0 or
      transport.idleConnections.len >= int(transport.maxIdleConnections):
    connection.close()
  else:
    transport.idleConnections.add(move(connection))

proc closeIdleConnections*(transport: HttpTransport) =
  ## Closes retained keep-alive sockets. Requests currently in progress are
  ## unaffected and may return their connection to the pool afterwards.
  for connection in transport.idleConnections.mitems:
    connection.close()
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

proc addMultipartSize(total: var int64; amount: int64; request: Request) =
  if amount < 0 or total > high(int64) - amount:
    raise newJoubakoError(
      jeBodyTooLarge, "multipart request size overflow", request.url
    )
  total += amount
  if request.options.maxRequestBytes >= 0 and
      total > int64(request.options.maxRequestBytes):
    raise newJoubakoError(
      jeBodyTooLarge,
      "multipart request body exceeded the configured limit",
      request.url
    )

proc multipartWireSizeUpperBound(request: Request): int64 =
  ## std/httpclient chooses a decimal random-int boundary. Using the maximum
  ## possible decimal width gives a safe pre-dispatch upper bound without
  ## opening or buffering file contents.
  let boundaryLength = ($high(int)).len
  for part in request.multipartParts:
    result.addMultipartSize(int64(2 + boundaryLength + 2), request)
    result.addMultipartSize(int64(
      "Content-Disposition: form-data; name=\"\"".len + part.name.len
    ), request)
    if part.filename.len > 0:
      result.addMultipartSize(int64(
        "; filename=\"\"\r\n".len + part.filename.len +
        "Content-Type: \r\n\r\n".len + part.contentType.len
      ), request)
      let contentSize =
        if part.filePath.len > 0:
          if not fileExists(part.filePath):
            raise newJoubakoError(
              jeStream,
              "multipart file does not exist or is not a regular file",
              request.url
            )
          try:
            getFileSize(part.filePath)
          except CatchableError as error:
            raise error.asJoubakoError(jeStream, request.url)
        else:
          int64(part.body.len)
      if part.maxBytes > 0 and contentSize > part.maxBytes:
        raise newJoubakoError(
          jeBodyTooLarge,
          "multipart part exceeded its configured limit",
          request.url
        )
      result.addMultipartSize(contentSize, request)
      result.addMultipartSize(2, request)
    else:
      if part.maxBytes > 0 and part.body.len.int64 > part.maxBytes:
        raise newJoubakoError(
          jeBodyTooLarge,
          "multipart part exceeded its configured limit",
          request.url
        )
      result.addMultipartSize(int64(4 + part.body.len + 2), request)
  result.addMultipartSize(int64(2 + boundaryLength + 4), request)

proc buildMultipart(request: Request): MultipartData =
  if request.multipartParts.len == 0:
    return nil
  discard request.multipartWireSizeUpperBound()
  result = newMultipartData()
  for part in request.multipartParts:
    if part.filename.len == 0:
      result.add(part.name, part.body)
    elif part.filePath.len > 0:
      result.add(
        part.name,
        part.filePath,
        part.filename,
        part.contentType,
        useStream = true
      )
    else:
      result.add(
        part.name,
        part.body,
        part.filename,
        part.contentType,
        useStream = false
      )

proc performRedirectingRequest(
    transport: HttpTransport;
    request: sink Request;
    initialHeaders: HttpHeaders
): Future[types.Response] {.async.} =
  var currentUrl = parseUri(request.url)
  request.validateAllowedHost(currentUrl)
  var connection = transport.checkoutConnection(currentUrl)
  var reusable = false
  defer:
    if reusable:
      transport.checkinConnection(move(connection))
    elif connection.client != nil:
      connection.close()
  # Reuse one mutable hop request across redirects. Copying Request separately
  # into current method/body/parts and again on every hop adds ARC/ORC traffic
  # to every successful request, including POST and multipart requests.
  var hopRequest = move(request)
  var originalRequest: Request
  var followedRedirect = false
  var currentHeaders = initialHeaders
  let deadline =
    if hopRequest.options.timeoutMs >= 0:
      initDeadline(initDuration(milliseconds = hopRequest.options.timeoutMs))
    else:
      Deadline()

  for redirectCount in 0 .. transport.maxRedirects:
    let client = connection.client
    block:
      let needsCookie = transport.cookieJar != nil and
        not currentHeaders.hasHeader("cookie")
      let needsProxyAuthorization = connection.proxyAuthorization.len > 0 and
        not currentHeaders.hasHeader("proxy-authorization")
      var hopHeaders = currentHeaders
      if needsCookie or needsProxyAuthorization:
        hopHeaders = newHttpHeaders()
        if currentHeaders != nil:
          for name, value in currentHeaders.pairs:
            hopHeaders.add(name, value)
      if needsCookie:
        let cookies = transport.cookieJar.cookieHeader(hopRequest.url)
        if cookies.len > 0:
          hopHeaders.add("cookie", cookies)
      if needsProxyAuthorization:
        hopHeaders.add("proxy-authorization", connection.proxyAuthorization)

      let multipart = hopRequest.buildMultipart()
      if multipart != nil:
        # Nim's multipart formatter stores generated framing headers on the
        # client. Ordinary requests never mutate this map and can reuse the
        # empty instance without allocating a replacement per request.
        client.headers = baseHttpHeaders()
      connection.enableTcpNoDelay()
      let pendingHeaders = client.request(
        hopRequest.url,
        hopRequest.httpMethod.toStdMethod,
        hopRequest.body,
        hopHeaders,
        multipart
      )
      let token = hopRequest.options.cancellation
      let cancellation =
        if token == nil:
          default(tuple[active: ref bool, signal: Future[void]])
        else:
          registerConnectionCancellation(token, client)
      defer:
        if cancellation.active != nil:
          cancellation.active[] = false
        if cancellation.signal != nil:
          cancellation.signal.clearCallbacks()

      var waitMs = hopRequest.options.connectTimeoutMs
      if deadline.isInitialized:
        let remainingMs = deadline.remaining.durationMillisecondsCeil
        if remainingMs <= 0:
          raise newJoubakoError(
            jeTimeout, "request exceeded its total deadline", hopRequest.url
          )
        if waitMs < 0 or remainingMs < waitMs:
          waitMs = remainingMs

      if token != nil:
        let cancelled = cancellation.signal
        if waitMs >= 0:
          let timer = sleepAsync(waitMs)
          await ((pendingHeaders or cancelled) or timer)
          if token.cancelled:
            client.close()
            raise newJoubakoError(
              jeCancelled, token.reason, hopRequest.url
            )
          if not pendingHeaders.finished:
            client.close()
            raise newJoubakoError(
              jeTimeout,
              "connection or response headers exceeded their deadline",
              hopRequest.url
            )
        else:
          await (pendingHeaders or cancelled)
          if token.cancelled:
            client.close()
            raise newJoubakoError(
              jeCancelled, token.reason, hopRequest.url
            )
      elif waitMs >= 0 and not pendingHeaders.finished and
          not await transport.timeoutScheduler.waitWithTimeout(
            pendingHeaders, waitMs
          ):
        client.close()
        raise newJoubakoError(
          jeTimeout,
          "connection or response headers exceeded their deadline",
          hopRequest.url
        )

      let raw = await pendingHeaders
      if not hopRequest.options.onUploadProgress.isNil:
        var uploadedBytes = int64(hopRequest.body.len)
        if multipart != nil:
          try:
            uploadedBytes = client.headers
              .getOrDefault("content-length")
              .parseBiggestInt
          except ValueError:
            uploadedBytes = hopRequest.multipartWireSizeUpperBound()
        hopRequest.options.onUploadProgress(
          uploadedBytes,
          uploadedBytes
        )
      if multipart != nil:
        client.headers = baseHttpHeaders()
      let contentEncoding: string =
        raw.headers.getOrDefault("content-encoding")
      let decoded = hopRequest.hasResponseBody(int(raw.code)) and
        contentEncoding.isCompressedEncoding
      var responseHeaders = initHeaders()
      for name, value in raw.headers.pairs:
        # std/httpclient stores response names in lowercase. Preserve that
        # parser guarantee instead of allocating another lowercase copy for
        # both filtering and insertion on every response header.
        if not decoded or name notin ["content-encoding", "content-length"]:
          responseHeaders.addParsedHeader(name, value)

      if not hopRequest.options.onResponseHeaders.isNil:
        try:
          hopRequest.options.onResponseHeaders(int(raw.code), responseHeaders)
        except CatchableError as error:
          client.close()
          raise error.asJoubakoError(jeStream, hopRequest.url)

      let declaredLengthText = raw.headers.getOrDefault("content-length")
      var declaredLength = -1'i64
      if declaredLengthText.len > 0:
        try:
          declaredLength = declaredLengthText.parseBiggestInt
        except ValueError:
          discard
      if hopRequest.options.maxResponseBytes >= 0 and not decoded and
          declaredLength > hopRequest.options.maxResponseBytes.int64:
        raise newJoubakoError(
          jeBodyTooLarge,
          "declared response body exceeds the configured limit",
          hopRequest.url,
          int(raw.code)
        )

      let responseLimit = hopRequest.options.maxResponseBytes
      let decoder = newContentDecoder(
        if hopRequest.hasResponseBody(int(raw.code)):
          contentEncoding
        else:
          "",
        responseLimit,
        hopRequest.url,
        int(raw.code)
      )
      defer:
        decoder.close()
      var received = 0
      var total = -1'i64
      var responseBody: string
      if decoder == nil and declaredLength >= 0:
        total = declaredLength

      proc acceptChunk(chunk: string) =
        if responseLimit >= 0 and
            (received > responseLimit or
              chunk.len > responseLimit - received):
          client.close()
          raise newJoubakoError(
            jeBodyTooLarge,
            "response body exceeded the configured limit while streaming",
            hopRequest.url,
            int(raw.code)
          )
        received += chunk.len

      proc finishChunk(chunk: string) =
        if not hopRequest.options.streamResponse:
          responseBody.add chunk
        if not hopRequest.options.onDownloadProgress.isNil:
          hopRequest.options.onDownloadProgress(int64(received), total)

      proc deliver(chunk: string): Future[void] {.async.} =
        acceptChunk(chunk)
        let consuming = hopRequest.consumeDownloadChunk(chunk)
        var consumeWaitMs = -1
        if deadline.isInitialized:
          let remainingMs = deadline.remaining.durationMillisecondsCeil
          if remainingMs <= 0:
            client.close()
            raise newJoubakoError(
              jeTimeout,
              "request exceeded its total deadline while delivering the response",
              hopRequest.url,
              int(raw.code)
            )
          consumeWaitMs = remainingMs

        let consumeToken = hopRequest.options.cancellation
        if consumeToken != nil:
          let cancelled = cancellation.signal
          if consumeWaitMs >= 0:
            let timer = sleepAsync(consumeWaitMs)
            await ((consuming or cancelled) or timer)
            if consumeToken.cancelled:
              client.close()
              raise newJoubakoError(
                jeCancelled,
                consumeToken.reason,
                hopRequest.url,
                int(raw.code)
              )
            if not consuming.finished:
              client.close()
              raise newJoubakoError(
                jeTimeout,
                "request exceeded its total deadline while delivering the response",
                hopRequest.url,
                int(raw.code)
              )
          else:
            await (consuming or cancelled)
            if consumeToken.cancelled:
              client.close()
              raise newJoubakoError(
                jeCancelled,
                consumeToken.reason,
                hopRequest.url,
                int(raw.code)
              )
        elif consumeWaitMs >= 0 and not consuming.finished and
            not await consuming.withTimeout(consumeWaitMs):
          client.close()
          raise newJoubakoError(
            jeTimeout,
            "request exceeded its total deadline while delivering the response",
            hopRequest.url,
            int(raw.code)
          )

        let consumed = await settle(
          fallible(consuming), jeStream, hopRequest.url
        )
        if consumed.isErr:
          raise consumed.error
        finishChunk(chunk)

      while true:
        let reading = raw.bodyStream.read()
        var bodyWaitMs = hopRequest.options.readTimeoutMs
        if deadline.isInitialized:
          let remainingMs = deadline.remaining.durationMillisecondsCeil
          if remainingMs <= 0:
            client.close()
            raise newJoubakoError(
              jeTimeout,
              "request exceeded its total deadline while reading the response",
              hopRequest.url,
              int(raw.code)
            )
          if bodyWaitMs < 0 or remainingMs < bodyWaitMs:
            bodyWaitMs = remainingMs

        let bodyToken = hopRequest.options.cancellation
        if bodyToken != nil:
          let cancelled = cancellation.signal
          if bodyWaitMs >= 0:
            let timer = sleepAsync(bodyWaitMs)
            await ((reading or cancelled) or timer)
            if bodyToken.cancelled:
              client.close()
              raise newJoubakoError(
                jeCancelled,
                bodyToken.reason,
                hopRequest.url,
                int(raw.code)
              )
            if not reading.finished:
              client.close()
              raise newJoubakoError(
                jeTimeout,
                "response body read exceeded its deadline",
                hopRequest.url,
                int(raw.code)
              )
          else:
            await (reading or cancelled)
            if bodyToken.cancelled:
              client.close()
              raise newJoubakoError(
                jeCancelled,
                bodyToken.reason,
                hopRequest.url,
                int(raw.code)
              )
        elif bodyWaitMs >= 0 and not reading.finished and
            not await transport.timeoutScheduler.waitWithTimeout(
              reading, bodyWaitMs
            ):
          client.close()
          raise newJoubakoError(
            jeTimeout,
            "response body read exceeded its deadline",
            hopRequest.url,
            int(raw.code)
          )

        let (hasValue, chunk) = await reading
        if not hasValue:
          break
        if decoder == nil:
          if hopRequest.options.onDownloadChunk.isNil and
              hopRequest.options.onDownloadChunkAsync.isNil and
              hopRequest.options.cancellation == nil:
            acceptChunk(chunk)
            finishChunk(chunk)
          else:
            await deliver(chunk)
        else:
          let decodedChunk = await settle(
            fallible(decoder.decode(chunk, deliver)),
            jeCompression,
            hopRequest.url
          )
          if decodedChunk.isErr:
            raise decodedChunk.error
      decoder.finish()

      let statusText =
        if raw.status.len > 3:
          raw.status[3 .. ^1].strip
        else:
          ""
      result = types.Response(
        status: int(raw.code),
        statusText: statusText,
        httpVersion: "HTTP/1.1",
        headers: responseHeaders,
        body: responseBody
      )
      if transport.cookieJar != nil:
        for setCookie in result.headers.getAll("set-cookie"):
          discard transport.cookieJar.store(hopRequest.url, setCookie)

      if not result.status.isRedirect or
          not result.headers.contains("location"):
        if followedRedirect:
          result.request = move(originalRequest)
        else:
          result.request = move(hopRequest)
        reusable = true
        return
      if transport.maxRedirects == 0:
        result.request = move(hopRequest)
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
      hopRequest.validateAllowedHost(nextUrl)
      if not followedRedirect:
        # Preserve the public response contract while keeping the common
        # non-redirect path move-only. Redirects pay this snapshot cost once,
        # regardless of the number of hops.
        originalRequest = move(hopRequest)
        hopRequest = originalRequest
        followedRedirect = true
      let originChanged = not sameOrigin(currentUrl, nextUrl)
      if originChanged:
        currentHeaders.deleteHeader("authorization")
        currentHeaders.deleteHeader("cookie")
        currentHeaders.deleteHeader("proxy-authorization")
        currentHeaders.deleteHeader("host")

      if result.status in [301, 302, 303] and
          hopRequest.httpMethod notin {rmGet, rmHead}:
        hopRequest.httpMethod = rmGet
        hopRequest.body = ""
        hopRequest.multipartParts.setLen(0)
        currentHeaders.deleteHeader("content-length")
        currentHeaders.deleteHeader("content-type")
        currentHeaders.deleteHeader("transfer-encoding")
      if originChanged:
        transport.checkinConnection(move(connection))
        connection = transport.checkoutConnection(nextUrl)
      currentUrl = nextUrl
      hopRequest.url = $currentUrl

proc sendOwnedImpl(
    transport: HttpTransport;
    request: sink Request
): Future[types.Response] =
  let requestUrl = request.url
  let cancellation = request.options.cancellation
  try:
    if request.uploadSource != nil:
      raise newJoubakoError(
        jeInvalidRequest,
        "streaming uploads require the HTTP/2 transport",
        request.url
      )
    if request.options.cancellation != nil and
        request.options.cancellation.cancelled:
      raise newJoubakoError(
        jeCancelled,
        request.options.cancellation.reason,
        request.url
      )

    var stdHeaders: HttpHeaders
    for name, value in request.headers.pairs:
      if stdHeaders == nil:
        stdHeaders = newHttpHeaders()
      stdHeaders.add(name, value)

    # performRedirectingRequest carries one total deadline through connection,
    # redirect, bounded body reads, and the platform-independent connection
    # cancellation relay. No second public wrapper is required.
    result = transport.performRedirectingRequest(move(request), stdHeaders)

    proc mapFailure(completed: Future[types.Response]) =
      if completed.failed:
        if cancellation != nil and cancellation.cancelled:
          completed.error = newJoubakoError(
            jeCancelled, cancellation.reason, requestUrl
          )
        elif not (completed.error of JoubakoError):
          completed.error = newJoubakoError(
            jeTransport, completed.error.msg, requestUrl
          )

    if result.finished:
      result.mapFailure()
    else:
      result.addCallback(mapFailure)
  except CatchableError as error:
    result = newFuture[types.Response]("Joubako.HttpTransport.send")
    if error of JoubakoError:
      result.fail(error)
    else:
      result.fail(newJoubakoError(jeTransport, error.msg, requestUrl))

method supportsOwnedRequestDispatch*(transport: HttpTransport): bool =
  discard transport
  true

method sendOwned*(
    transport: HttpTransport;
    request: sink Request
): Future[types.Response] =
  transport.sendOwnedImpl(move(request))

method send*(
    transport: HttpTransport;
    request: Request
): Future[types.Response] =
  ## Preserve the established public value-parameter transport API while the
  ## Client's common single-attempt path can transfer ownership explicitly.
  transport.sendOwnedImpl(request)
