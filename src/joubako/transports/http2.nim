## HTTP/2 transport backed by libcurl's multi interface.
##
## Joubako owns request policy, bounded streaming, cancellation, and callback
## ordering. libcurl owns TLS, HTTP/2 framing, HPACK, connection reuse, and
## multiplexing (normally through nghttp2).

import std/[asyncdispatch, monotimes, sequtils, strutils, tables, times, uri]
import libcurl
import ../[chunkconsumer, compression, cookiejar, result, transport, types]

when defined(windows):
  const CurlLibrary = "libcurl.dll"
elif defined(macosx):
  const CurlLibrary = "libcurl(|.4).dylib"
else:
  const CurlLibrary = "libcurl.so(|.4)"

const
  CurlHttpVersion2Tls = 4.clong
  CurlHttpVersion2PriorKnowledge = 5.clong
  CurlInfoHttpVersion = 0x00200000 + 46
  CurlHttpVersion2 = 3.clong
  CurlOptTimeoutMs = 155
  CurlOptConnectTimeoutMs = 156
  CurlOptPipeWait = 237
  CurlOptXferInfoFunction = 20_219
  CurlOptXferInfoData = 10_057
  CurlMultiOptPipelining = 3
  CurlMultiOptMaxHostConnections = 7
  CurlPipeMultiplex = 2.clong
  CurlPauseReceive = 1
  CurlPauseContinue = 0
  CurlErrorTimeout = 28

proc rawEasySetopt(handle: PCurl; option: cint): Code {.
  cdecl, varargs, dynlib: CurlLibrary, importc: "curl_easy_setopt".}
proc rawEasyGetinfo(handle: PCurl; info: cint): Code {.
  cdecl, varargs, dynlib: CurlLibrary, importc: "curl_easy_getinfo".}
proc rawEasyPause(handle: PCurl; bitmask: cint): Code {.
  cdecl, dynlib: CurlLibrary, importc: "curl_easy_pause".}
proc rawMultiSetopt(handle: PM; option: cint): Mcode {.
  cdecl, varargs, dynlib: CurlLibrary, importc: "curl_multi_setopt".}
proc rawEasyStrerror(code: cint): cstring {.
  cdecl, dynlib: CurlLibrary, importc: "curl_easy_strerror".}

type
  CurlOutcome = object
    response: Response
    error: ref JoubakoError

  CurlTransfer = ref object
    transport: Http2Transport
    easy: PCurl
    request: Request
    done: Future[CurlOutcome]
    headerList: Pslist
    errorBuffer: string
    responseHeaders: Headers
    status: int
    statusText: string
    protocol: string
    headersDelivered: bool
    decoder: ContentDecoder
    body: string
    received: int
    total: int64
    pendingWireChunks: seq[string]
    queuedWireBytes: int
    currentWireChunk: string
    pauseRequested: bool
    receivePaused: bool
    processing: Future[JResult[void]]
    curlCompleted: bool
    curlCode: cint
    error: ref JoubakoError
    startedAt: MonoTime
    lastActivityAt: MonoTime
    lastUploaded: int64
    cleaned: bool

  Http2Transport* = ref object of Transport
    userAgent*: string
    maxRedirects*: Natural
    allowH2c*: bool
    cookieJar*: CookieJar
    maxConnectionsPerOrigin*: Natural
    multi: PM
    transfers: Table[uint, CurlTransfer]
    pumpFuture: Future[void]
    closed: bool

var curlTransportUsers = 0

proc acquireCurl() =
  if curlTransportUsers == 0:
    let code = global_init(GLOBAL_DEFAULT)
    if code != E_OK:
      raise newException(IOError, "failed to initialize libcurl: " &
        $easy_strerror(code))
  inc curlTransportUsers

proc releaseCurl() =
  if curlTransportUsers <= 0:
    return
  dec curlTransportUsers
  if curlTransportUsers == 0:
    global_cleanup()

proc newHttp2Transport*(
    userAgent = "Joubako/0.1";
    maxRedirects: Natural = 5;
    allowH2c = false;
    cookieJar: CookieJar = nil;
    maxConnectionsPerOrigin: Natural = 1
): Http2Transport =
  ## Creates an HTTP/2-only transport. HTTPS is required unless `allowH2c` is
  ## explicitly enabled for controlled clear-text HTTP/2 endpoints.
  acquireCurl()
  let multi = multi_init()
  if multi == nil:
    releaseCurl()
    raise newException(IOError, "failed to initialize libcurl multi handle")
  if rawMultiSetopt(
      multi, CurlMultiOptPipelining, CurlPipeMultiplex) != M_OK:
    discard multi_cleanup(multi)
    releaseCurl()
    raise newException(IOError, "libcurl does not support HTTP multiplexing")
  if maxConnectionsPerOrigin > 0:
    discard rawMultiSetopt(
      multi,
      CurlMultiOptMaxHostConnections,
      maxConnectionsPerOrigin.clong
    )
  Http2Transport(
    userAgent: userAgent,
    maxRedirects: maxRedirects,
    allowH2c: allowH2c,
    cookieJar: cookieJar,
    maxConnectionsPerOrigin: maxConnectionsPerOrigin,
    multi: multi,
    transfers: initTable[uint, CurlTransfer]()
  )

method usesImplicitCredentials*(transport: Http2Transport): bool =
  transport != nil and transport.cookieJar != nil

func effectivePort(url: Uri): int =
  if url.port.len > 0:
    try:
      url.port.parseInt
    except ValueError:
      0
  elif url.scheme.toLowerAscii == "https":
    443
  else:
    80

func sameOrigin(left, right: Uri): bool =
  left.scheme.toLowerAscii == right.scheme.toLowerAscii and
    left.hostname.toLowerAscii == right.hostname.toLowerAscii and
    left.effectivePort == right.effectivePort

func redirectedUrl(current: Uri; location: string): Uri =
  let target = parseUri(location)
  if target.isAbsolute: target else: combine(current, target)

func isRedirect(status: int): bool =
  status in [301, 302, 303, 307, 308]

proc validateUrl(transport: Http2Transport; request: Request; url: Uri) =
  let scheme = url.scheme.toLowerAscii
  if url.hostname.len == 0 or scheme notin ["https", "http"] or
      url.effectivePort notin 1 .. 65_535:
    raise newJoubakoError(jeInvalidRequest, "invalid HTTP/2 URL", $url)
  if scheme == "http" and not transport.allowH2c:
    raise newJoubakoError(
      jeInvalidRequest,
      "clear-text HTTP/2 requires allowH2c = true",
      $url
    )
  if not isHostAllowed(url.hostname, request.options.allowedHosts):
    raise newJoubakoError(
      jeInvalidRequest,
      "request host is not in the configured allowlist",
      $url
    )

func forbiddenHttp2Header(name: string): bool =
  name in ["connection", "keep-alive", "proxy-connection",
    "transfer-encoding", "upgrade", "host"]

proc rememberError(state: CurlTransfer; error: ref JoubakoError) =
  if state.error == nil:
    state.error = error

proc finalizeHeaders(state: CurlTransfer) =
  if state.headersDelivered:
    return
  if state.protocol != "HTTP/2":
    state.rememberError(newJoubakoError(
      jeTransport,
      "peer did not negotiate HTTP/2",
      state.request.url,
      state.status
    ))
    return
  if state.request.options.maxResponseBytes >= 0 and
      state.responseHeaders.contains("content-length"):
    try:
      let declared = state.responseHeaders.get("content-length").parseBiggestInt
      if declared > state.request.options.maxResponseBytes.int64:
        state.rememberError(newJoubakoError(
          jeBodyTooLarge,
          "HTTP/2 response exceeds the configured limit",
          state.request.url,
          state.status
        ))
        return
      state.total = declared
    except ValueError:
      discard
  state.decoder = newContentDecoder(
    state.responseHeaders.get("content-encoding"),
    state.request.options.maxResponseBytes,
    state.request.url,
    state.status
  )
  if state.decoder != nil:
    state.responseHeaders.del("content-encoding")
    state.responseHeaders.del("content-length")
    state.total = -1
  if state.request.options.onResponseHeaders != nil:
    try:
      state.request.options.onResponseHeaders(
        state.status, state.responseHeaders
      )
    except CatchableError as error:
      state.rememberError(error.asJoubakoError(
        jeStream, state.request.url
      ))
      return
  state.headersDelivered = true

proc headerCallback(
    buffer: cstring;
    size, count: int;
    userdata: pointer
): int {.cdecl.} =
  let state = cast[CurlTransfer](userdata)
  let byteCount = size * count
  if state == nil or byteCount <= 0:
    return byteCount
  try:
    var line = newString(byteCount)
    copyMem(line[0].addr, buffer, byteCount)
    line = line.strip(chars = {'\r', '\n'})
    if line.startsWith("HTTP/"):
      state.responseHeaders = initHeaders()
      state.headersDelivered = false
      state.status = 0
      state.statusText = ""
      let parts = line.splitWhitespace(maxsplit = 2)
      if parts.len >= 2:
        state.protocol =
          if parts[0].startsWith("HTTP/2"): "HTTP/2" else: parts[0]
        state.status = parts[1].parseInt
        if parts.len == 3:
          state.statusText = parts[2]
    elif line.len == 0:
      if state.status >= 200:
        state.finalizeHeaders()
    else:
      let separator = line.find(':')
      if separator > 0:
        state.responseHeaders.add(
          line[0 ..< separator], line[separator + 1 .. ^1].strip
        )
    if state.error != nil: 0 else: byteCount
  except CatchableError as error:
    state.rememberError(error.asJoubakoError(jeTransport, state.request.url))
    0

proc bodyCallback(
    buffer: cstring;
    size, count: int;
    userdata: pointer
): int {.cdecl.} =
  let state = cast[CurlTransfer](userdata)
  let byteCount = size * count
  if state == nil or byteCount <= 0:
    return byteCount
  if state.error != nil:
    return 0
  try:
    state.finalizeHeaders()
    if state.error != nil:
      return 0
    if state.decoder == nil and state.request.options.maxResponseBytes >= 0 and
        (state.received > state.request.options.maxResponseBytes or
         state.queuedWireBytes >
           state.request.options.maxResponseBytes - state.received or
         byteCount > state.request.options.maxResponseBytes -
           state.received - state.queuedWireBytes):
      state.rememberError(newJoubakoError(
        jeBodyTooLarge,
        "HTTP/2 response exceeded the configured limit",
        state.request.url,
        state.status
      ))
      return 0
    var chunk = newString(byteCount)
    copyMem(chunk[0].addr, buffer, byteCount)
    state.pendingWireChunks.add(move(chunk))
    state.queuedWireBytes += byteCount
    state.pauseRequested = true
    state.lastActivityAt = getMonoTime()
    byteCount
  except CatchableError as error:
    state.rememberError(error.asJoubakoError(jeTransport, state.request.url))
    0

proc progressCallback(
    userdata: pointer;
    downloadTotal, downloaded, uploadTotal, uploaded: clonglong
): int32 {.cdecl.} =
  let state = cast[CurlTransfer](userdata)
  if state == nil:
    return 0
  let token = state.request.options.cancellation
  if token != nil and token.cancelled:
    return 1
  if uploaded.int64 != state.lastUploaded:
    state.lastUploaded = uploaded.int64
    if state.request.options.onUploadProgress != nil:
      try:
        state.request.options.onUploadProgress(
          uploaded.int64, uploadTotal.int64
        )
      except CatchableError as error:
        state.rememberError(error.asJoubakoError(
          jeStream, state.request.url
        ))
        return 1
  0

proc deliverChunk(state: CurlTransfer; chunk: string): Future[void] {.async.} =
  if state.request.options.maxResponseBytes >= 0 and
      (state.received > state.request.options.maxResponseBytes or
       chunk.len > state.request.options.maxResponseBytes - state.received):
    raise newJoubakoError(
      jeBodyTooLarge,
      "HTTP/2 response exceeded the configured limit",
      state.request.url,
      state.status
    )
  state.received += chunk.len
  await state.request.consumeDownloadChunk(chunk)
  if not state.request.options.streamResponse:
    state.body.add chunk
  if state.request.options.onDownloadProgress != nil:
    state.request.options.onDownloadProgress(
      state.received.int64, state.total
    )

proc processWireChunk(state: CurlTransfer): Future[void] {.async.} =
  let chunk = move(state.currentWireChunk)
  if state.decoder == nil:
    await state.deliverChunk(chunk)
  else:
    proc emit(decoded: string): Future[void] =
      state.deliverChunk(decoded)
    await state.decoder.decode(chunk, emit)

proc cleanupTransfer(state: CurlTransfer) =
  if state == nil or state.cleaned:
    return
  state.cleaned = true
  if state.easy != nil:
    discard multi_remove_handle(state.transport.multi, state.easy)
    state.transport.transfers.del(cast[uint](state.easy))
    easy_cleanup(state.easy)
    state.easy = nil
  if state.headerList != nil:
    slist_free_all(state.headerList)
    state.headerList = nil
  state.decoder.close()
  state.decoder = nil

proc finishTransfer(
    state: CurlTransfer;
    error: ref JoubakoError = nil
) =
  let done = state.done
  var outcome: CurlOutcome
  if error != nil:
    outcome.error = error
  else:
    outcome.response = Response(
      status: state.status,
      statusText: state.statusText,
      httpVersion: "HTTP/2",
      headers: state.responseHeaders,
      body: move(state.body),
      request: state.request,
      attempts: 1
    )
  state.cleanupTransfer()
  state.error = nil
  if not done.finished:
    done.complete(move(outcome))

proc elapsedMs(startedAt: MonoTime): int64 =
  (getMonoTime() - startedAt).inMilliseconds

proc cancellationError(state: CurlTransfer): ref JoubakoError =
  let token = state.request.options.cancellation
  if token != nil and token.cancelled:
    return newJoubakoError(jeCancelled, token.reason, state.request.url)
  elif state.request.options.timeoutMs >= 0 and
      state.startedAt.elapsedMs >= state.request.options.timeoutMs:
    return newJoubakoError(
      jeTimeout, "HTTP/2 request exceeded its deadline", state.request.url
    )
  elif state.headersDelivered and state.request.options.readTimeoutMs >= 0 and
      state.lastActivityAt.elapsedMs >= state.request.options.readTimeoutMs:
    return newJoubakoError(
      jeTimeout,
      "HTTP/2 response read exceeded its deadline",
      state.request.url,
      state.status
    )

proc completeFromCurl(state: CurlTransfer; curlCode: cint) =
  if state.error != nil:
    state.finishTransfer(state.error)
    return
  if curlCode != 0:
    let message =
      if state.errorBuffer.len > 0 and state.errorBuffer[0] != '\0':
        $cast[cstring](state.errorBuffer[0].addr)
      else:
        $rawEasyStrerror(curlCode)
    let kind = if curlCode == CurlErrorTimeout: jeTimeout else: jeTransport
    state.finishTransfer(newJoubakoError(
      kind, message, state.request.url, state.status
    ))
    return
  try:
    state.finalizeHeaders()
    if state.error != nil:
      state.finishTransfer(state.error)
      return
    var negotiated: clong
    if rawEasyGetinfo(
        state.easy, CurlInfoHttpVersion, negotiated.addr) != E_OK or
        negotiated != CurlHttpVersion2:
      state.finishTransfer(newJoubakoError(
        jeTransport,
        "peer did not negotiate HTTP/2",
        state.request.url,
        state.status
      ))
      return
    state.decoder.finish()
    state.finishTransfer()
  except JoubakoError as error:
    state.finishTransfer(error)
  except CatchableError as error:
    state.finishTransfer(error.asJoubakoError(
      jeTransport, state.request.url
    ))

proc pump(transport: Http2Transport): Future[void] {.async.} =
  try:
    while transport.transfers.len > 0:
      var running: int32
      var multiCode = multi_perform(transport.multi, running)
      while multiCode == M_CALL_MULTI_PERFORM:
        multiCode = multi_perform(transport.multi, running)
      if multiCode != M_OK:
        let message = "libcurl multi failure: " & $multi_strerror(multiCode)
        let active = toSeq(transport.transfers.values)
        for state in active:
          state.finishTransfer(newJoubakoError(
            jeTransport, message, state.request.url
          ))
        break

      let active = toSeq(transport.transfers.values)
      for state in active:
        if state.cleaned:
          continue
        let stopped = state.cancellationError()
        if stopped != nil:
          state.rememberError(stopped)
        if state.pauseRequested and not state.receivePaused and
            not state.curlCompleted and running > 0:
          state.pauseRequested = false
          let paused = rawEasyPause(state.easy, CurlPauseReceive)
          if paused == E_OK:
            state.receivePaused = true
          else:
            # Some libcurl/nghttp2 combinations reject pausing an individual
            # stream while multiplexing. Delivery remains ordered and bounded
            # by maxResponseBytes; only transport-level flow control is skipped.
            discard
        if state.processing == nil and state.pendingWireChunks.len > 0:
          state.currentWireChunk = move(state.pendingWireChunks[0])
          state.pendingWireChunks.delete(0)
          state.queuedWireBytes -= state.currentWireChunk.len
          state.processing = settle(
            fallible(state.processWireChunk()),
            jeStream,
            state.request.url
          )
        elif state.processing != nil and state.processing.finished:
          let processed = state.processing.read()
          state.processing = nil
          if processed.isErr:
            state.rememberError(processed.error)
          state.currentWireChunk.setLen(0)
        if state.error == nil and state.processing == nil and
            state.pendingWireChunks.len == 0 and state.receivePaused:
          state.receivePaused = false
          let resumed = rawEasyPause(state.easy, CurlPauseContinue)
          if resumed != E_OK:
            state.rememberError(newJoubakoError(
              jeTransport,
              "failed to resume HTTP/2 response: " &
                $easy_strerror(resumed),
              state.request.url,
              state.status
            ))
        if state.error != nil and state.processing == nil:
          state.finishTransfer(state.error)
        elif state.curlCompleted and state.processing == nil and
            state.pendingWireChunks.len == 0:
          state.completeFromCurl(state.curlCode)

      var queued: int32
      var message = multi_info_read(transport.multi, queued)
      while message != nil:
        if message.msg == MSG_DONE:
          let key = cast[uint](message.easy_handle)
          let state = transport.transfers.getOrDefault(key)
          if state != nil and not state.cleaned:
            state.curlCompleted = true
            state.curlCode = cast[cint](cast[int](message.whatever))
            if state.processing == nil and state.pendingWireChunks.len == 0:
              state.completeFromCurl(state.curlCode)
        message = multi_info_read(transport.multi, queued)

      if transport.transfers.len > 0:
        await sleepAsync(2)
  except CatchableError as error:
    let active = toSeq(transport.transfers.values)
    for state in active:
      state.finishTransfer(error.asJoubakoError(
        jeTransport, state.request.url
      ))
  finally:
    transport.pumpFuture = nil

proc ensurePump(transport: Http2Transport) =
  ## An immediately cancelled or expired transfer can make `pump` finish before
  ## this call returns. Do not retain that already-finished Future: doing so
  ## would prevent the next transfer from starting a new multi loop.
  if transport.pumpFuture == nil or transport.pumpFuture.finished:
    let pending = transport.pump()
    if pending.finished:
      transport.pumpFuture = nil
    else:
      transport.pumpFuture = pending

proc checkedSetopt(
    state: CurlTransfer;
    option: cint;
    value: auto
) =
  let code = rawEasySetopt(state.easy, option, value)
  if code != E_OK:
    raise newJoubakoError(
      jeTransport,
      "failed to configure libcurl: " & $easy_strerror(code),
      state.request.url
    )

proc configureTransfer(state: CurlTransfer; url: Uri) =
  state.checkedSetopt(cint(OPT_URL), state.request.url.cstring)
  state.checkedSetopt(cint(OPT_CUSTOMREQUEST), ($state.request.httpMethod).cstring)
  state.checkedSetopt(cint(OPT_NOSIGNAL), 1.clong)
  state.checkedSetopt(cint(OPT_FOLLOWLOCATION), 0.clong)
  state.checkedSetopt(cint(OPT_HTTP_VERSION),
    if url.scheme.toLowerAscii == "https": CurlHttpVersion2Tls
    else: CurlHttpVersion2PriorKnowledge)
  state.checkedSetopt(CurlOptPipeWait, 1.clong)
  state.checkedSetopt(cint(OPT_WRITEFUNCTION), bodyCallback)
  state.checkedSetopt(cint(OPT_WRITEDATA), cast[pointer](state))
  state.checkedSetopt(cint(OPT_HEADERFUNCTION), headerCallback)
  state.checkedSetopt(cint(OPT_HEADERDATA), cast[pointer](state))
  state.checkedSetopt(cint(OPT_NOPROGRESS), 0.clong)
  state.checkedSetopt(CurlOptXferInfoFunction, progressCallback)
  state.checkedSetopt(CurlOptXferInfoData, cast[pointer](state))
  state.checkedSetopt(cint(OPT_ERRORBUFFER), state.errorBuffer[0].addr)
  if state.request.options.timeoutMs >= 0:
    state.checkedSetopt(
      CurlOptTimeoutMs, state.request.options.timeoutMs.clong
    )
  if state.request.options.connectTimeoutMs >= 0:
    state.checkedSetopt(
      CurlOptConnectTimeoutMs, state.request.options.connectTimeoutMs.clong
    )
  if state.request.httpMethod == rmHead:
    state.checkedSetopt(cint(OPT_NOBODY), 1.clong)
  if state.request.body.len > 0:
    state.checkedSetopt(
      cint(OPT_POSTFIELDS), state.request.body[0].unsafeAddr
    )
    state.checkedSetopt(
      cint(OPT_POSTFIELDSIZE_LARGE), state.request.body.len.clonglong
    )

  var hasUserAgent = false
  for name, value in state.request.headers.pairs:
    let normalized = name.toLowerAscii
    if normalized.forbiddenHttp2Header:
      continue
    if normalized == "te" and value.strip.toLowerAscii != "trailers":
      continue
    hasUserAgent = hasUserAgent or normalized == "user-agent"
    let line = normalized & ": " & value
    let appended = slist_append(state.headerList, line.cstring)
    if appended == nil:
      raise newJoubakoError(
        jeTransport, "failed to allocate HTTP/2 headers", state.request.url
      )
    state.headerList = appended
  if not hasUserAgent:
    let appended = slist_append(
      state.headerList, ("user-agent: " & state.transport.userAgent).cstring
    )
    if appended == nil:
      raise newJoubakoError(
        jeTransport, "failed to allocate HTTP/2 headers", state.request.url
      )
    state.headerList = appended
  if state.headerList != nil:
    state.checkedSetopt(cint(OPT_HTTPHEADER), state.headerList)

proc exchange(
    transport: Http2Transport;
    request: Request;
    url: Uri
): Future[CurlOutcome] {.async.} =
  if request.multipartParts.len > 0:
    raise newJoubakoError(
      jeInvalidRequest,
      "file-backed multipart is not supported by the HTTP/2 transport yet",
      request.url
    )
  if transport.closed or transport.multi == nil:
    raise newJoubakoError(
      jeTransport, "HTTP/2 transport is closed", request.url
    )
  let easy = easy_init()
  if easy == nil:
    raise newJoubakoError(
      jeTransport, "failed to allocate HTTP/2 request", request.url
    )
  let now = getMonoTime()
  let state = CurlTransfer(
    transport: transport,
    easy: easy,
    request: request,
    done: newFuture[CurlOutcome]("Joubako.Http2Transport.exchange"),
    errorBuffer: newString(ERROR_SIZE),
    responseHeaders: initHeaders(),
    total: -1,
    startedAt: now,
    lastActivityAt: now
  )
  try:
    state.configureTransfer(url)
    let added = multi_add_handle(transport.multi, easy)
    if added != M_OK:
      raise newJoubakoError(
        jeTransport,
        "failed to queue HTTP/2 request: " & $multi_strerror(added),
        request.url
      )
    transport.transfers[cast[uint](easy)] = state
    transport.ensurePump()
    let pending = state.done
    let outcome = await pending
    pending.clearCallbacks()
    state.done = nil
    return outcome
  except JoubakoError as error:
    state.cleanupTransfer()
    return CurlOutcome(error: error)
  except CatchableError as error:
    state.cleanupTransfer()
    return CurlOutcome(error: error.asJoubakoError(
      jeTransport, request.url
    ))

proc redirectingExchange(
    transport: Http2Transport;
    request: Request
): Future[CurlOutcome] {.async.} =
  try:
    var currentUrl = parseUri(request.url)
    var currentMethod = request.httpMethod
    var currentBody = request.body
    var currentHeaders = request.headers
    let startedAt = getMonoTime()

    for redirectCount in 0 .. transport.maxRedirects:
      transport.validateUrl(request, currentUrl)
      var hop = request
      hop.url = $currentUrl
      hop.httpMethod = currentMethod
      hop.body = currentBody
      hop.headers = currentHeaders
      if request.options.timeoutMs >= 0:
        hop.options.timeoutMs = max(
          0,
          request.options.timeoutMs - startedAt.elapsedMs.int
        )
      if transport.cookieJar != nil and not hop.headers.contains("cookie"):
        let cookies = transport.cookieJar.cookieHeader(hop.url)
        if cookies.len > 0:
          hop.headers.set("cookie", cookies)

      let pending = transport.exchange(hop, currentUrl)
      var exchanged = await pending
      pending.clearCallbacks()
      if exchanged.error != nil:
        return exchanged
      var response = move(exchanged.response)
      if transport.cookieJar != nil:
        for setCookie in response.headers.getAll("set-cookie"):
          discard transport.cookieJar.store(hop.url, setCookie)

      if not response.status.isRedirect or
          not response.headers.contains("location"):
        response.request = request
        return CurlOutcome(response: move(response))
      if transport.maxRedirects == 0:
        response.request = request
        return CurlOutcome(response: move(response))
      if redirectCount >= transport.maxRedirects:
        return CurlOutcome(error: newJoubakoError(
          jeTransport,
          "maximum HTTP/2 redirects exceeded",
          hop.url,
          response.status
        ))

      let nextUrl = redirectedUrl(
        currentUrl, response.headers.get("location")
      )
      transport.validateUrl(request, nextUrl)
      if not sameOrigin(currentUrl, nextUrl):
        currentHeaders.del("authorization")
        currentHeaders.del("cookie")
        currentHeaders.del("proxy-authorization")
        currentHeaders.del("host")
      if response.status in [301, 302, 303] and
          currentMethod notin {rmGet, rmHead}:
        currentMethod = rmGet
        currentBody = ""
        currentHeaders.del("content-length")
        currentHeaders.del("content-type")
      currentUrl = nextUrl
  except JoubakoError as error:
    return CurlOutcome(error: error)
  except CatchableError as error:
    return CurlOutcome(error: error.asJoubakoError(
      jeTransport, request.url
    ))

proc close*(transport: Http2Transport): Future[void] {.async.} =
  ## Cancels active transfers and releases the connection pool.
  if transport == nil or transport.closed:
    return
  transport.closed = true
  let active = toSeq(transport.transfers.values)
  for state in active:
    state.rememberError(newJoubakoError(
      jeCancelled, "HTTP/2 transport closed", state.request.url
    ))
  if transport.pumpFuture != nil:
    await transport.pumpFuture
  if transport.multi != nil:
    discard multi_cleanup(transport.multi)
    transport.multi = nil
  releaseCurl()

method send*(
    transport: Http2Transport;
    request: Request
): Future[Response] =
  ## Keep the public failed-Future boundary single and consumable. In
  ## particular, do not re-raise through multiple async frames under ARC.
  result = newFuture[Response]("Joubako.Http2Transport.send")
  let destination = result
  try:
    if request.options.cancellation != nil and
        request.options.cancellation.cancelled:
      destination.fail(newJoubakoError(
        jeCancelled, request.options.cancellation.reason, request.url
      ))
      return
    let url = parseUri(request.url)
    transport.validateUrl(request, url)
    if request.options.maxRequestBytes >= 0 and
        request.body.len > request.options.maxRequestBytes:
      destination.fail(newJoubakoError(
        jeBodyTooLarge,
        "HTTP/2 request exceeded the configured limit",
        request.url
      ))
      return

    var pending = transport.redirectingExchange(request)
    pending.addCallback(proc() =
      let source = pending
      source.clearCallbacks()
      if source.failed:
        var failure = move(source.error)
        source.errorStackTrace.setLen(0)
        destination.fail(failure.asJoubakoError(jeTransport, request.url))
      else:
        var outcome = source.read()
        if outcome.error != nil:
          var failure = move(outcome.error)
          destination.fail(failure)
        else:
          destination.complete(move(outcome.response))
      pending = nil
    )
  except CatchableError as error:
    destination.fail(error.asJoubakoError(jeTransport, request.url))
