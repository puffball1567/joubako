import std/[asyncdispatch, asyncnet, base64, json, nativesockets]
import ../[transport, types]

type
  UnixIpcTransport* = ref object of Transport
    socketPath*: string

func newUnixIpcTransport*(socketPath: string): UnixIpcTransport =
  UnixIpcTransport(socketPath: socketPath)

func encodeLength(size: int): string =
  if size < 0 or uint64(size) > uint64(high(uint32)):
    raise newException(ValueError, "IPC frame is too large")
  let value = uint32(size)
  result = newString(4)
  result[0] = char((value shr 24) and 0xff)
  result[1] = char((value shr 16) and 0xff)
  result[2] = char((value shr 8) and 0xff)
  result[3] = char(value and 0xff)

func decodeLength(value: string): int =
  if value.len != 4:
    raise newException(ValueError, "invalid IPC frame prefix")
  int(
    (uint32(uint8(value[0])) shl 24) or
    (uint32(uint8(value[1])) shl 16) or
    (uint32(uint8(value[2])) shl 8) or
    uint32(uint8(value[3]))
  )

func frameLimitForBody(bodyLimit: int): int =
  if bodyLimit < 0:
    return -1
  let expanded = uint64(bodyLimit) + (uint64(bodyLimit) + 2) div 3 + 65_536
  if expanded > uint64(high(int)):
    high(int)
  else:
    int(expanded)

proc receiveExact(socket: AsyncSocket; size: int): Future[string] {.async.} =
  if size < 0:
    raise newException(ValueError, "negative IPC read size")
  result = await socket.recv(size)
  if result.len != size:
    raise newException(IOError, "IPC peer disconnected during a frame")

proc sendFrame(socket: AsyncSocket; payload: string): Future[void] {.async.} =
  await socket.send(encodeLength(payload.len) & payload)

proc receiveFrame(
    socket: AsyncSocket;
    maxBytes: int
): Future[string] {.async.} =
  let prefix = await socket.receiveExact(4)
  let size = decodeLength(prefix)
  if maxBytes >= 0 and size > maxBytes:
    raise newJoubakoError(
      jeBodyTooLarge,
      "IPC frame exceeded the configured limit"
    )
  result = await socket.receiveExact(size)

proc headersToJson(headers: Headers): JsonNode =
  result = newJArray()
  for name, value in headers.pairs:
    result.add(%[name, value])

proc headersFromJson(node: JsonNode): Headers =
  result = initHeaders()
  if node.kind != JArray:
    raise newException(ValueError, "IPC headers must be an array")
  for pair in node:
    if pair.kind != JArray or pair.len != 2:
      raise newException(ValueError, "invalid IPC header pair")
    result.add(pair[0].getStr, pair[1].getStr)

proc encodeRequest(request: Request): string =
  $(%*{
    "method": $request.httpMethod,
    "url": request.url,
    "headers": headersToJson(request.headers),
    "body": encode(request.body)
  })

func parseMethod(value: string): RequestMethod =
  case value
  of "GET": rmGet
  of "HEAD": rmHead
  of "POST": rmPost
  of "PUT": rmPut
  of "PATCH": rmPatch
  of "DELETE": rmDelete
  of "OPTIONS": rmOptions
  else:
    raise newException(ValueError, "unsupported IPC request method")

proc decodeRequest(payload: string): Request =
  let node = payload.parseJson
  Request(
    httpMethod: parseMethod(node["method"].getStr),
    url: node["url"].getStr,
    headers: headersFromJson(node["headers"]),
    body: decode(node["body"].getStr),
    options: defaultRequestOptions()
  )

proc encodeResponse(response: Response): string =
  $(%*{
    "ok": true,
    "status": response.status,
    "statusText": response.statusText,
    "headers": headersToJson(response.headers),
    "body": encode(response.body)
  })

proc encodeFailure(message: string): string =
  $(%*{"ok": false, "error": message})

proc decodeResponse(payload: string; request: Request): Response =
  let node = payload.parseJson
  if not node{"ok"}.getBool(false):
    raise newJoubakoError(
      jeTransport,
      "IPC peer failed the request: " & node{"error"}.getStr("unknown error"),
      request.url
    )
  Response(
    status: node["status"].getInt,
    statusText: node["statusText"].getStr,
    headers: headersFromJson(node["headers"]),
    body: decode(node["body"].getStr),
    request: request
  )

proc exchange(
    transport: UnixIpcTransport;
    request: Request;
    socket: AsyncSocket
): Future[Response] {.async.} =
  when defined(posix):
    await socket.connectUnix(transport.socketPath)
  else:
    raise newJoubakoError(
      jeInvalidRequest,
      "Unix domain sockets are not supported on this platform",
      request.url
    )
  await socket.sendFrame(encodeRequest(request))
  if not request.options.onUploadProgress.isNil:
    request.options.onUploadProgress(
      int64(request.body.len), int64(request.body.len)
    )
  let frameLimit = frameLimitForBody(request.options.maxResponseBytes)
  let payload = await socket.receiveFrame(frameLimit)
  result = decodeResponse(payload, request)
  if request.options.maxResponseBytes >= 0 and
      result.body.len > request.options.maxResponseBytes:
    raise newJoubakoError(
      jeBodyTooLarge,
      "IPC response body exceeded the configured limit",
      request.url,
      result.status
    )
  if not request.options.onDownloadProgress.isNil:
    request.options.onDownloadProgress(
      int64(result.body.len), int64(result.body.len)
    )
  if not request.options.onDownloadChunk.isNil:
    request.options.onDownloadChunk(result.body)
  if request.options.streamResponse:
    result.body = ""

method send*(
    transport: UnixIpcTransport;
    request: Request
): Future[Response] {.async.} =
  when not defined(posix):
    raise newJoubakoError(
      jeInvalidRequest,
      "Unix domain sockets are not supported on this platform",
      request.url
    )
  if transport.socketPath.len == 0:
    raise newJoubakoError(
      jeInvalidRequest, "Unix socket path is empty", request.url
    )
  let socket = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
  defer:
    socket.close()
  try:
    let pending = transport.exchange(request, socket)
    let token = request.options.cancellation
    if token != nil:
      let cancelled = token.cancellationFuture()
      if request.options.timeoutMs >= 0:
        let timer = sleepAsync(request.options.timeoutMs)
        await ((pending or cancelled) or timer)
        if not pending.finished:
          socket.close()
          if token.cancelled:
            raise newJoubakoError(
              jeCancelled, token.reason, request.url
            )
          raise newJoubakoError(
            jeTimeout, "IPC request exceeded its deadline", request.url
          )
      else:
        await (pending or cancelled)
        if not pending.finished:
          socket.close()
          raise newJoubakoError(jeCancelled, token.reason, request.url)
    elif request.options.timeoutMs >= 0 and
        not await pending.withTimeout(request.options.timeoutMs):
      socket.close()
      raise newJoubakoError(
        jeTimeout, "IPC request exceeded its deadline", request.url
      )
    result = await pending
  except JoubakoError:
    raise
  except CatchableError as error:
    raise newJoubakoError(jeTransport, error.msg, request.url)

proc handleIpcConnection*(
    socket: AsyncSocket;
    handler: proc(request: Request): Future[Response] {.closure.};
    maxRequestBytes = 16 * 1024 * 1024
): Future[void] {.async.} =
  ## Handles one framed request and closes the connection. Servers retain
  ## ownership of accepting connections; this procedure owns `socket`.
  defer:
    socket.close()
  try:
    let frameLimit = frameLimitForBody(maxRequestBytes)
    let payload = await socket.receiveFrame(frameLimit)
    let request = decodeRequest(payload)
    if maxRequestBytes >= 0 and request.body.len > maxRequestBytes:
      raise newJoubakoError(
        jeBodyTooLarge, "IPC request body exceeded the configured limit"
      )
    let response = await handler(request)
    await socket.sendFrame(encodeResponse(response))
  except CatchableError as error:
    try:
      await socket.sendFrame(encodeFailure(error.msg))
    except CatchableError:
      discard
