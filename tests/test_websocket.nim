import std/[asyncdispatch, asyncnet, base64, net, strutils, unittest]
{.push warning[Deprecated]: off.}
import std/sha1
{.pop.}
import joubako
import ./result_test_helpers

const Magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

type WebSocketProgressCapture = ref object
  chunk: string
  asyncChunk: string
  uploaded: tuple[done, total: int64]
  downloaded: tuple[done, total: int64]

proc webSocketProgressOptions(
    capture: WebSocketProgressCapture
): RequestOptions =
  result = defaultRequestOptions()
  result.streamResponse = true
  result.onDownloadChunk =
    proc(value: string) = capture.chunk.add value
  result.onDownloadChunkAsync =
    proc(value: string): Future[void] =
      capture.asyncChunk.add value
      result = newFuture[void]("test.websocketAsyncChunk")
      result.complete()
  result.onUploadProgress =
    proc(done, total: int64) = capture.uploaded = (done, total)
  result.onDownloadProgress =
    proc(done, total: int64) = capture.downloaded = (done, total)

func acceptFor(key: string): string =
  let digest = Sha1Digest(secureHash(key & Magic))
  var raw = newString(digest.len)
  for index, value in digest:
    raw[index] = char(value)
  encode(raw)

proc receiveHeaders(socket: AsyncSocket): Future[string] {.async.} =
  while "\r\n\r\n" notin result:
    let chunk = await socket.recv(1)
    if chunk.len == 0:
      return
    result.add chunk

func header(headers, name: string): string =
  for line in headers.splitLines:
    let separator = line.find(':')
    if separator > 0 and
        line[0 ..< separator].strip.toLowerAscii == name.toLowerAscii:
      return line[separator + 1 .. ^1].strip

proc receiveMaskedText(socket: AsyncSocket): Future[string] {.async.} =
  let head = await socket.recv(2)
  doAssert head.len == 2
  doAssert (uint8(head[1]) and 0x80) != 0
  var size = int(uint8(head[1]) and 0x7f)
  if size == 126:
    let extended = await socket.recv(2)
    size = (int(uint8(extended[0])) shl 8) or int(uint8(extended[1]))
  elif size == 127:
    let extended = await socket.recv(8)
    var longSize = 0'u64
    for value in extended:
      longSize = (longSize shl 8) or uint64(uint8(value))
    doAssert longSize <= uint64(high(int))
    size = int(longSize)
  let mask = await socket.recv(4)
  let payload = await socket.recv(size)
  for index, value in payload:
    result.add char(uint8(value) xor uint8(mask[index mod 4]))

proc serverFrame(payload: string; opcode = 1'u8): string =
  result.add char(0x80'u8 or opcode)
  if payload.len <= 125:
    result.add char(payload.len)
  elif payload.len <= 0xffff:
    result.add char(126)
    result.add char((payload.len shr 8) and 0xff)
    result.add char(payload.len and 0xff)
  else:
    result.add char(127)
    let size = uint64(payload.len)
    for shift in countdown(56, 0, 8):
      result.add char((size shr shift) and 0xff)
  result.add payload

proc rawFrame(
    payload: string;
    firstByte: uint8;
    masked = false
): string =
  result.add char(firstByte)
  result.add char((if masked: 0x80 else: 0) or payload.len)
  if masked:
    result.add "\1\2\3\4"
    for index, value in payload:
      result.add char(uint8(value) xor uint8((index mod 4) + 1))
  else:
    result.add payload

proc serveFrameSequence(
    server: AsyncSocket;
    frames: seq[string];
    received: Future[string] = nil;
    waitAfter = false
): Future[void] {.async.} =
  let socket = await server.accept()
  defer:
    socket.close()
  let headers = await socket.receiveHeaders()
  let key = headers.header("sec-websocket-key")
  await socket.send(
    "HTTP/1.1 101 Switching Protocols\r\n" &
    "Upgrade: websocket\r\n" &
    "Connection: Upgrade\r\n" &
    "Sec-WebSocket-Accept: " & acceptFor(key) & "\r\n\r\n"
  )
  let message = await socket.receiveMaskedText()
  if received != nil:
    received.complete(message)
  for frame in frames:
    await socket.send(frame)
  if waitAfter:
    while (await socket.recv(64)).len > 0:
      discard

proc withFrameServer(
    frames: seq[string];
    action: proc(url: string): Future[void] {.closure.};
    waitAfter = false
): Future[string] {.async.} =
  let server = newAsyncSocket(buffered = false)
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(Port(0), "127.0.0.1")
  server.listen()
  defer:
    server.close()
  let (_, port) = server.getLocalAddr()
  let received = newFuture[string]("test_websocket.frameReceived")
  let serving = serveFrameSequence(server, frames, received, waitAfter)
  await action("ws://127.0.0.1:" & $int(port) & "/frames")
  await serving
  return received.read

proc serveDelayedExchange(
    server: AsyncSocket;
    handshakeDelayMs, responseDelayMs: int
): Future[void] {.async.} =
  let socket = await server.accept()
  defer:
    socket.close()
  let headers = await socket.receiveHeaders()
  let key = headers.header("sec-websocket-key")
  await sleepAsync(handshakeDelayMs)
  await socket.send(
    "HTTP/1.1 101 Switching Protocols\r\n" &
    "Upgrade: websocket\r\n" &
    "Connection: Upgrade\r\n" &
    "Sec-WebSocket-Accept: " & acceptFor(key) & "\r\n\r\n"
  )
  discard await socket.receiveMaskedText()
  await sleepAsync(responseDelayMs)
  try:
    await socket.send(serverFrame("late"))
  except CatchableError:
    discard

proc serveExchange(
    server: AsyncSocket;
    responseBody: string;
    validAccept = true;
    waitForClose = false
): Future[string] {.async.} =
  let socket = await server.accept()
  defer:
    socket.close()
  let headers = await socket.receiveHeaders()
  let key = headers.header("sec-websocket-key")
  await socket.send(
    "HTTP/1.1 101 Switching Protocols\r\n" &
    "Upgrade: websocket\r\n" &
    "Connection: Upgrade\r\n" &
    "Sec-WebSocket-Accept: " &
      (if validAccept: acceptFor(key) else: "wrong") & "\r\n\r\n"
  )
  if not validAccept:
    return
  result = await socket.receiveMaskedText()
  if waitForClose:
    while (await socket.recv(64)).len > 0:
      discard
  else:
    await socket.send(serverFrame(responseBody))

proc exercise(
    responseBody: string;
    action: proc(url: string): Future[void] {.closure.};
    validAccept = true;
    waitForClose = false
): Future[string] {.async.} =
  let server = newAsyncSocket(buffered = false)
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(Port(0), "127.0.0.1")
  server.listen()
  defer:
    server.close()
  let (_, port) = server.getLocalAddr()
  let serving = serveExchange(server, responseBody, validAccept, waitForClose)
  await action("ws://127.0.0.1:" & $int(port) & "/messages?room=one")
  return await serving

suite "WebSocket transport":
  test "performs an upgrade and a request-response message exchange":
    let action = proc(url: string): Future[void] {.async.} =
      let client = newClient(newWebSocketTransport())
      let response = await client.post(url, "hello")
      check response.status == 200
      check response.body == "world"
    check waitFor(exercise("world", action)) == "hello"

  test "invalid upgrade accept values are rejected":
    let action = proc(url: string): Future[void] {.async.} =
      let client = newClient(newWebSocketTransport())
      try:
        discard await client.post(url, "hello")
        fail()
      except JoubakoError as error:
        check error.kind == jeTransport
    discard waitFor exercise("", action, validAccept = false)

  test "message size limits are enforced before returning":
    let action = proc(url: string): Future[void] {.async.} =
      let client = newClient(newWebSocketTransport())
      var options = defaultRequestOptions()
      options.maxResponseBytes = 3
      try:
        discard await client.post(url, "hello", options = options)
        fail()
      except JoubakoError as error:
        check error.kind == jeBodyTooLarge
    discard waitFor exercise("four", action)

  test "active cancellation closes a waiting exchange":
    let action = proc(url: string): Future[void] {.async.} =
      let client = newClient(newWebSocketTransport())
      let token = newCancellationToken()
      var options = defaultRequestOptions()
      options.cancellation = token
      let pending = client.post(url, "hello", options = options)
      await sleepAsync(10)
      token.cancel("superseded")
      try:
        discard await pending
        fail()
      except JoubakoError as error:
        check error.kind == jeCancelled
    discard waitFor exercise("", action, waitForClose = true)

  test "non-WebSocket URL schemes are invalid":
    let client = newClient(newWebSocketTransport())
    try:
      discard waitFor client.post("http://example.test/", "hello")
      fail()
    except JoubakoError as error:
      check error.kind == jeInvalidRequest

  test "126-byte client and server payloads use extended lengths":
    let payload = "x".repeat(126)
    let action = proc(url: string): Future[void] {.async.} =
      let client = newClient(newWebSocketTransport())
      check (await client.post(url, payload)).body == payload
    check waitFor(withFrameServer(@[serverFrame(payload)], action)) == payload

  test "large server payloads use 64-bit lengths":
    let payload = "z".repeat(65_536)
    let action = proc(url: string): Future[void] {.async.} =
      let client = newClient(newWebSocketTransport())
      check (await client.post(url, "request")).body == payload
    discard waitFor withFrameServer(@[serverFrame(payload)], action)

  test "fragmented messages are reconstructed":
    let frames = @[
      rawFrame("hel", 0x01),
      rawFrame("lo", 0x80)
    ]
    let action = proc(url: string): Future[void] {.async.} =
      let client = newClient(newWebSocketTransport())
      check (await client.post(url, "request")).body == "hello"
    discard waitFor withFrameServer(frames, action)

  test "ping frames are skipped before a data response":
    let action = proc(url: string): Future[void] {.async.} =
      let client = newClient(newWebSocketTransport())
      check (await client.post(url, "request")).body == "reply"
    discard waitFor withFrameServer(
      @[serverFrame("ping", 9), serverFrame("reply")],
      action
    )

  test "masked server frames are rejected":
    let action = proc(url: string): Future[void] {.async.} =
      let client = newClient(newWebSocketTransport())
      try:
        discard await client.post(url, "request")
        fail()
      except JoubakoError as error:
        check error.kind == jeTransport
        check "must not be masked" in error.msg
    discard waitFor withFrameServer(@[rawFrame("bad", 0x81, true)], action)

  test "unexpected continuation frames are rejected":
    let action = proc(url: string): Future[void] {.async.} =
      let client = newClient(newWebSocketTransport())
      expect JoubakoError:
        discard await client.post(url, "request")
    discard waitFor withFrameServer(@[rawFrame("bad", 0x80)], action)

  test "reserved bits are rejected":
    let action = proc(url: string): Future[void] {.async.} =
      let client = newClient(newWebSocketTransport())
      try:
        discard await client.post(url, "request")
        fail()
      except JoubakoError as error:
        check "reserved bits" in error.msg
    discard waitFor withFrameServer(@[rawFrame("bad", 0xC1)], action)

  test "fragmented control frames are rejected":
    let action = proc(url: string): Future[void] {.async.} =
      let client = newClient(newWebSocketTransport())
      try:
        discard await client.post(url, "request")
        fail()
      except JoubakoError as error:
        check "control frame" in error.msg
    discard waitFor withFrameServer(@[rawFrame("bad", 0x09)], action)

  test "unsupported opcodes are rejected":
    let action = proc(url: string): Future[void] {.async.} =
      let client = newClient(newWebSocketTransport())
      expect JoubakoError:
        discard await client.post(url, "request")
    discard waitFor withFrameServer(@[rawFrame("bad", 0x83)], action)

  test "silent upgraded peers hit the exchange timeout":
    let action = proc(url: string): Future[void] {.async.} =
      let client = newClient(newWebSocketTransport())
      var options = defaultRequestOptions()
      options.timeoutMs = 20
      try:
        discard await client.post(url, "request", options = options)
        fail()
      except JoubakoError as error:
        check error.kind == jeTimeout
    discard waitFor withFrameServer(@[], action, waitAfter = true)

  test "streaming and progress callbacks receive WebSocket messages":
    let action = proc(url: string): Future[void] {.async.} =
      let client = newClient(newWebSocketTransport())
      let capture = WebSocketProgressCapture(
        uploaded: (-1'i64, -1'i64),
        downloaded: (-1'i64, -1'i64)
      )
      let options = webSocketProgressOptions(capture)
      let response = await client.post(url, "sent", options = options)
      check response.body == ""
      check capture.chunk == "reply"
      check capture.asyncChunk == "reply"
      check capture.uploaded == (4'i64, 4'i64)
      check capture.downloaded == (5'i64, 5'i64)
    discard waitFor withFrameServer(@[serverFrame("reply")], action)

  test "host allowlists reject before WebSocket connection":
    let client = newClient(newWebSocketTransport())
    var options = defaultRequestOptions()
    options.allowedHosts = @["allowed.test"]
    try:
      discard waitFor client.post(
        "ws://127.0.0.1:1/", "x", options = options
      )
      fail()
    except JoubakoError as error:
      check error.kind == jeInvalidRequest
      check "allowlist" in error.msg

  when not defined(ssl):
    test "wss fails clearly when SSL support is not compiled":
      let client = newClient(newWebSocketTransport())
      try:
        discard waitFor client.post("wss://127.0.0.1:1/", "x")
        fail()
      except JoubakoError as error:
        check error.kind == jeInvalidRequest
        check "-d:ssl" in error.msg

  test "direct connection rejects URL line break injection":
    try:
      discard waitFor connectWebSocket("ws://example.test/\r\nX-Bad: yes")
      fail()
    except JoubakoError as error:
      check error.kind == jeInvalidRequest

  test "direct connection rejects handshake header injection":
    var headers = initHeaders()
    headers.set("x-test", "safe\r\nX-Bad: yes")
    try:
      discard waitFor connectWebSocket("ws://example.test/", headers)
      fail()
    except JoubakoError as error:
      check error.kind == jeInvalidRequest

  test "invalid WebSocket ports are structured input errors":
    for url in ["ws://example.test:0/", "ws://example.test:70000/"]:
      try:
        discard waitFor connectWebSocket(url)
        fail()
      except JoubakoError as error:
        check error.kind == jeInvalidRequest

  test "one total deadline covers handshake and message exchange":
    let server = newAsyncSocket(buffered = false)
    server.setSockOpt(OptReuseAddr, true)
    server.bindAddr(Port(0), "127.0.0.1")
    server.listen()
    let (_, port) = server.getLocalAddr()
    let serving = serveDelayedExchange(server, 20, 20)
    let client = newClient(newWebSocketTransport())
    var options = defaultRequestOptions()
    options.timeoutMs = 30
    try:
      discard waitFor client.post(
        "ws://127.0.0.1:" & $int(port) & "/",
        "request",
        options = options
      )
      fail()
    except JoubakoError as error:
      check error.kind == jeTimeout
    waitFor serving
    server.close()
