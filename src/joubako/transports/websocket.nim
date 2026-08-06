import std/[asyncdispatch, asyncnet, base64, monotimes, net, strutils, sysrand,
  times, uri]
{.push warning[Deprecated]: off.}
import std/sha1
{.pop.}
import ../[chunkconsumer, transport, types]

const WebSocketMagic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

type
  WebSocket* = ref object
    socket: AsyncSocket
    url*: string
    subprotocol*: string
    closed*: bool

  WebSocketTransport* = ref object of Transport
    maxMessageBytes*: int

func newWebSocketTransport*(
    maxMessageBytes = 16 * 1024 * 1024
): WebSocketTransport =
  WebSocketTransport(maxMessageBytes: maxMessageBytes)

func websocketAccept(key: string): string =
  let digest = Sha1Digest(secureHash(key & WebSocketMagic))
  var raw = newString(digest.len)
  for index, value in digest:
    raw[index] = char(value)
  encode(raw)

proc receiveHeaders(socket: AsyncSocket): Future[string] {.async.} =
  while "\r\n\r\n" notin result:
    if result.len >= 64 * 1024:
      raise newException(IOError, "WebSocket handshake headers are too large")
    let chunk = await socket.recv(1)
    if chunk.len == 0:
      raise newException(IOError, "WebSocket peer disconnected during handshake")
    result.add chunk

func headerValue(headers, name: string): string =
  let wanted = name.toLowerAscii
  for line in headers.splitLines:
    let separator = line.find(':')
    if separator > 0 and line[0 ..< separator].strip.toLowerAscii == wanted:
      return line[separator + 1 .. ^1].strip

func isWebSocketToken(value: string): bool =
  if value.len == 0:
    return false
  for character in value:
    if character < '!' or character > '~' or
        character in {'(', ')', '<', '>', '@', ',', ';', ':', '\\', '"',
          '/', '[', ']', '?', '=', '{', '}'}:
      return false
  true

proc connectWebSocket*(
    url: string;
    headers = initHeaders();
    timeoutMs = 30_000;
    cancellation: CancellationToken = nil;
    subprotocol = ""
): Future[WebSocket] {.async.} =
  let started = getMonoTime()
  proc remainingMs(): int =
    if timeoutMs < 0:
      return -1
    max(0, timeoutMs - int((getMonoTime() - started).inMilliseconds))
  if url.contains({'\r', '\n'}):
    raise newJoubakoError(
      jeInvalidRequest, "WebSocket URL contains a line break", url
    )
  if subprotocol.len > 0 and not subprotocol.isWebSocketToken:
    raise newJoubakoError(
      jeInvalidRequest, "invalid WebSocket subprotocol", url
    )
  if headers.contains("sec-websocket-protocol"):
    raise newJoubakoError(
      jeInvalidRequest,
      "Sec-WebSocket-Protocol must be supplied through the subprotocol argument",
      url
    )
  for name, value in headers.pairs:
    if name.len == 0 or name.contains({'\r', '\n'}) or
        value.contains({'\r', '\n'}):
      raise newJoubakoError(
        jeInvalidRequest, "invalid WebSocket handshake header", url
      )
  let parsed = parseUri(url)
  let scheme = parsed.scheme.toLowerAscii
  if scheme notin ["ws", "wss"] or parsed.hostname.len == 0:
    raise newJoubakoError(
      jeInvalidRequest, "WebSocket URL must use ws or wss", url
    )
  when not defined(ssl):
    if scheme == "wss":
      raise newJoubakoError(
        jeInvalidRequest,
        "wss requires compiling with -d:ssl",
        url
      )
  var port =
    if scheme == "wss": Port(443)
    else: Port(80)
  if parsed.port.len > 0:
    try:
      let parsedPort = parsed.port.parseInt
      if parsedPort <= 0 or parsedPort > 65_535:
        raise newException(ValueError, "port out of range")
      port = Port(parsedPort)
    except ValueError:
      raise newJoubakoError(
        jeInvalidRequest, "invalid WebSocket port", url
      )
  let socket = newAsyncSocket()
  var keepSocket = false
  defer:
    if not keepSocket:
      socket.close()
  try:
    let connecting = socket.connect(parsed.hostname, port)
    let connectWaitMs = remainingMs()
    if cancellation != nil:
      let cancelled = cancellation.cancellationFuture()
      if connectWaitMs >= 0:
        let timer = sleepAsync(connectWaitMs)
        await ((connecting or cancelled) or timer)
      else:
        await (connecting or cancelled)
      if not connecting.finished:
        socket.close()
        if cancellation.cancelled:
          raise newJoubakoError(jeCancelled, cancellation.reason, url)
        raise newJoubakoError(
          jeTimeout, "WebSocket connection exceeded its deadline", url
        )
    elif connectWaitMs >= 0 and not await connecting.withTimeout(connectWaitMs):
      socket.close()
      raise newJoubakoError(
        jeTimeout, "WebSocket connection exceeded its deadline", url
      )
    await connecting

    if scheme == "wss":
      when defined(ssl):
        let context = newContext(verifyMode = CVerifyPeer)
        context.wrapConnectedSocket(
          socket, handshakeAsClient, hostname = parsed.hostname
        )

    let randomBytes = urandom(16)
    var nonce = newString(randomBytes.len)
    for index, value in randomBytes:
      nonce[index] = char(value)
    let key = encode(nonce)
    var target = parsed.path
    if target.len == 0:
      target = "/"
    if parsed.query.len > 0:
      target.add "?" & parsed.query
    let hostHeader =
      if parsed.port.len > 0: parsed.hostname & ":" & parsed.port
      else: parsed.hostname
    var requestHeaders =
      "GET " & target & " HTTP/1.1\r\n" &
      "Host: " & hostHeader & "\r\n" &
      "Upgrade: websocket\r\n" &
      "Connection: Upgrade\r\n" &
      "Sec-WebSocket-Version: 13\r\n" &
      "Sec-WebSocket-Key: " & key & "\r\n"
    if subprotocol.len > 0:
      requestHeaders.add "Sec-WebSocket-Protocol: " & subprotocol & "\r\n"
    for name, value in headers.pairs:
      if name notin [
          "host", "upgrade", "connection", "sec-websocket-version",
          "sec-websocket-key", "sec-websocket-protocol"]:
        requestHeaders.add name & ": " & value & "\r\n"
    requestHeaders.add "\r\n"
    await socket.send(requestHeaders)

    let pendingHeaders = socket.receiveHeaders()
    let headerWaitMs = remainingMs()
    if cancellation != nil:
      let cancelled = cancellation.cancellationFuture()
      if headerWaitMs >= 0:
        let timer = sleepAsync(headerWaitMs)
        await ((pendingHeaders or cancelled) or timer)
      else:
        await (pendingHeaders or cancelled)
      if not pendingHeaders.finished:
        socket.close()
        if cancellation.cancelled:
          raise newJoubakoError(jeCancelled, cancellation.reason, url)
        raise newJoubakoError(
          jeTimeout, "WebSocket handshake exceeded its deadline", url
        )
    elif headerWaitMs >= 0 and
        not await pendingHeaders.withTimeout(headerWaitMs):
      socket.close()
      raise newJoubakoError(
        jeTimeout, "WebSocket handshake exceeded its deadline", url
      )
    let responseHeaders = await pendingHeaders
    let statusLine = responseHeaders.splitLines[0]
    if not statusLine.startsWith("HTTP/1.1 101 "):
      raise newJoubakoError(
        jeTransport, "WebSocket upgrade was rejected: " & statusLine, url
      )
    if responseHeaders.headerValue("upgrade").toLowerAscii != "websocket" or
        "upgrade" notin responseHeaders.headerValue("connection").toLowerAscii or
        responseHeaders.headerValue("sec-websocket-accept") != websocketAccept(key):
      raise newJoubakoError(
        jeTransport, "invalid WebSocket upgrade response", url
      )
    if subprotocol.len > 0 and
        responseHeaders.headerValue("sec-websocket-protocol") != subprotocol:
      raise newJoubakoError(
        jeTransport, "WebSocket server did not accept the requested subprotocol",
        url
      )
    keepSocket = true
    return WebSocket(socket: socket, url: url, subprotocol: subprotocol)
  except JoubakoError:
    raise
  except CatchableError as error:
    raise newJoubakoError(jeTransport, error.msg, url)

proc encodeFrame(opcode: uint8; payload: string): string =
  let randomMask = urandom(4)
  result.add char(0x80'u8 or opcode)
  if payload.len <= 125:
    result.add char(0x80 or payload.len)
  elif payload.len <= 0xffff:
    result.add char(0x80 or 126)
    result.add char((payload.len shr 8) and 0xff)
    result.add char(payload.len and 0xff)
  else:
    result.add char(0x80 or 127)
    let size = uint64(payload.len)
    for shift in countdown(56, 0, 8):
      result.add char((size shr shift) and 0xff)
  for value in randomMask:
    result.add char(value)
  for index, value in payload:
    result.add char(uint8(value) xor randomMask[index mod 4])

proc sendText*(websocket: WebSocket; message: string): Future[void] {.async.} =
  if websocket == nil or websocket.closed:
    raise newJoubakoError(jeTransport, "WebSocket is closed")
  await websocket.socket.send(encodeFrame(1, message))

proc receiveExact(socket: AsyncSocket; size: int): Future[string] {.async.} =
  while result.len < size:
    let chunk = await socket.recv(size - result.len)
    if chunk.len == 0:
      raise newException(IOError, "WebSocket peer disconnected during a frame")
    result.add chunk

proc receiveMessage*(
    websocket: WebSocket;
    maxBytes = 16 * 1024 * 1024
): Future[string] {.async.} =
  if websocket == nil or websocket.closed:
    raise newJoubakoError(jeTransport, "WebSocket is closed")
  var fragmented = false
  while true:
    let header = await websocket.socket.receiveExact(2)
    let first = uint8(header[0])
    let second = uint8(header[1])
    let finalFrame = (first and 0x80) != 0
    let opcode = first and 0x0f
    if (first and 0x70) != 0:
      raise newJoubakoError(
        jeTransport, "WebSocket reserved bits are not supported", websocket.url
      )
    if (second and 0x80) != 0:
      raise newJoubakoError(
        jeTransport, "server WebSocket frames must not be masked", websocket.url
      )
    var size = uint64(second and 0x7f)
    if size == 126:
      let extended = await websocket.socket.receiveExact(2)
      size = (uint64(uint8(extended[0])) shl 8) or uint64(uint8(extended[1]))
    elif size == 127:
      let extended = await websocket.socket.receiveExact(8)
      size = 0
      for value in extended:
        size = (size shl 8) or uint64(uint8(value))
    if opcode >= 8 and (not finalFrame or size > 125):
      raise newJoubakoError(
        jeTransport, "invalid WebSocket control frame", websocket.url
      )
    if size > uint64(high(int)) or
        (maxBytes >= 0 and
          (result.len > maxBytes or int(size) > maxBytes - result.len)):
      raise newJoubakoError(
        jeBodyTooLarge,
        "WebSocket message exceeded the configured limit",
        websocket.url
      )
    let payload = await websocket.socket.receiveExact(int(size))
    case opcode
    of 0:
      if not fragmented:
        raise newJoubakoError(
          jeTransport, "unexpected WebSocket continuation frame", websocket.url
        )
      result.add payload
    of 1, 2:
      if fragmented or result.len > 0:
        raise newJoubakoError(
          jeTransport, "unexpected WebSocket data frame", websocket.url
        )
      result.add payload
      fragmented = not finalFrame
    of 8:
      websocket.closed = true
      websocket.socket.close()
      raise newJoubakoError(jeTransport, "WebSocket peer closed", websocket.url)
    of 9:
      await websocket.socket.send(encodeFrame(10, payload))
      continue
    of 10:
      continue
    else:
      raise newJoubakoError(
        jeTransport, "unsupported WebSocket opcode", websocket.url
      )
    if finalFrame:
      return

proc close*(websocket: WebSocket): Future[void] {.async.} =
  if websocket == nil or websocket.closed:
    return
  websocket.closed = true
  try:
    await websocket.socket.send(encodeFrame(8, ""))
  finally:
    websocket.socket.close()

proc abort*(websocket: WebSocket) =
  ## Immediately releases the socket and wakes any pending receive operation.
  if websocket == nil or websocket.closed:
    return
  websocket.closed = true
  websocket.socket.close()

method send*(
    transport: WebSocketTransport;
    request: Request
): Future[Response] {.async.} =
  if request.multipartParts.len > 0:
    raise newJoubakoError(
      jeInvalidRequest,
      "file-backed multipart requests require the HTTP transport",
      request.url
    )
  let started = getMonoTime()
  let parsed = parseUri(request.url)
  if not isHostAllowed(parsed.hostname, request.options.allowedHosts):
    raise newJoubakoError(
      jeInvalidRequest,
      "WebSocket host is not in the configured allowlist",
      request.url
    )
  let websocket = await connectWebSocket(
    request.url,
    request.headers,
    request.options.timeoutMs,
    request.options.cancellation
  )
  defer:
    if not websocket.closed:
      websocket.socket.close()
      websocket.closed = true
  let limit =
    if request.options.maxResponseBytes == 0:
      transport.maxMessageBytes
    else:
      request.options.maxResponseBytes
  proc exchangeMessage(): Future[string] {.async.} =
    await websocket.sendText(request.body)
    if not request.options.onUploadProgress.isNil:
      request.options.onUploadProgress(
        int64(request.body.len), int64(request.body.len)
      )
    result = await websocket.receiveMessage(limit)
    await request.consumeDownloadChunk(result)
    if not request.options.onDownloadProgress.isNil:
      request.options.onDownloadProgress(int64(result.len), int64(result.len))
    if request.options.streamResponse:
      result = ""
  let pending = exchangeMessage()
  let exchangeTimeoutMs =
    if request.options.timeoutMs < 0:
      -1
    else:
      max(
        0,
        request.options.timeoutMs -
          int((getMonoTime() - started).inMilliseconds)
      )
  let token = request.options.cancellation
  if token != nil:
    let cancelled = token.cancellationFuture()
    if exchangeTimeoutMs >= 0:
      let timer = sleepAsync(exchangeTimeoutMs)
      await ((pending or cancelled) or timer)
    else:
      await (pending or cancelled)
    if not pending.finished:
      websocket.socket.close()
      websocket.closed = true
      if token.cancelled:
        raise newJoubakoError(jeCancelled, token.reason, request.url)
      raise newJoubakoError(
        jeTimeout, "WebSocket exchange exceeded its deadline", request.url
      )
  elif exchangeTimeoutMs >= 0 and
      not await pending.withTimeout(exchangeTimeoutMs):
    websocket.socket.close()
    websocket.closed = true
    raise newJoubakoError(
      jeTimeout, "WebSocket exchange exceeded its deadline", request.url
    )
  let body = await pending
  return Response(
    status: 200,
    statusText: "WebSocket message",
    body: body,
    request: request
  )
