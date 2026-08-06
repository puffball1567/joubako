import std/[asyncdispatch, asyncnet, base64, json, net, options, strutils,
  unittest]
{.push warning[Deprecated]: off.}
import std/sha1
{.pop.}
import joubako

const Magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

type
  Tick = object
    value: int

  TickData = object
    tick: Tick

  ClientFrame = tuple[opcode: uint8, payload: string]

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
      raise newException(IOError, "peer disconnected during handshake")
    result.add chunk

func header(headers, name: string): string =
  for line in headers.splitLines:
    let separator = line.find(':')
    if separator > 0 and
        line[0 ..< separator].strip.toLowerAscii == name.toLowerAscii:
      return line[separator + 1 .. ^1].strip

proc receiveExact(socket: AsyncSocket; size: int): Future[string] {.async.} =
  while result.len < size:
    let chunk = await socket.recv(size - result.len)
    if chunk.len == 0:
      raise newException(IOError, "peer disconnected during frame")
    result.add chunk

proc receiveClientFrame(socket: AsyncSocket): Future[ClientFrame] {.async.} =
  let head = await socket.receiveExact(2)
  result.opcode = uint8(head[0]) and 0x0f
  doAssert (uint8(head[1]) and 0x80) != 0
  var size = uint64(uint8(head[1]) and 0x7f)
  if size == 126:
    let extended = await socket.receiveExact(2)
    size = (uint64(uint8(extended[0])) shl 8) or uint64(uint8(extended[1]))
  elif size == 127:
    let extended = await socket.receiveExact(8)
    size = 0
    for value in extended:
      size = (size shl 8) or uint64(uint8(value))
  doAssert size <= uint64(high(int))
  let mask = await socket.receiveExact(4)
  let encoded = await socket.receiveExact(int(size))
  for index, value in encoded:
    result.payload.add char(uint8(value) xor uint8(mask[index mod 4]))

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

proc upgrade(
    socket: AsyncSocket;
    headers: string;
    acceptProtocol = true
): Future[void] {.async.} =
  var response =
    "HTTP/1.1 101 Switching Protocols\r\n" &
    "Upgrade: websocket\r\n" &
    "Connection: Upgrade\r\n" &
    "Sec-WebSocket-Accept: " &
      acceptFor(headers.header("sec-websocket-key")) & "\r\n"
  if acceptProtocol:
    response.add "Sec-WebSocket-Protocol: graphql-transport-ws\r\n"
  response.add "\r\n"
  await socket.send(response)

proc serveOne(
    server: AsyncSocket;
    handler: proc(socket: AsyncSocket; headers: string): Future[void] {.closure.}
): Future[void] {.async.} =
  let socket = await server.accept()
  defer:
    socket.close()
  let headers = await socket.receiveHeaders()
  await handler(socket, headers)

proc withServer(
    handler: proc(socket: AsyncSocket; headers: string): Future[void] {.closure.};
    action: proc(url: string): Future[void] {.closure.}
): Future[void] {.async.} =
  let server = newAsyncSocket(buffered = false)
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(Port(0), "127.0.0.1")
  server.listen()
  defer:
    server.close()
  let (_, port) = server.getLocalAddr()
  let serving = serveOne(server, handler)
  await action("ws://127.0.0.1:" & $int(port) & "/graphql")
  await serving

proc tickDocument(): GraphqlDocument =
  gqlSubscription(
    "Ticks",
    variables = [gqlVariableDefinition("from", "Int!")],
    selection = [gqlField("tick", selection = [gqlField("value")])]
  )

suite "GraphQL subscriptions over graphql-transport-ws":
  test "negotiates, authenticates, answers ping, streams, and completes":
    let handler = proc(socket: AsyncSocket; headers: string): Future[void] {.async.} =
      check headers.header("sec-websocket-protocol") == GraphqlTransportWs
      check headers.header("authorization") == "Bearer header-token"
      await socket.upgrade(headers)
      let init = (await socket.receiveClientFrame()).payload.parseJson
      check init["type"].getStr == "connection_init"
      check init["payload"]["token"].getStr == "init-token"
      await socket.send(serverFrame($(%*{
        "type": "ping", "payload": {"sequence": 7}
      })))
      let pong = (await socket.receiveClientFrame()).payload.parseJson
      check pong["type"].getStr == "pong"
      check pong["payload"]["sequence"].getInt == 7
      await socket.send(serverFrame("""{"type":"connection_ack"}"""))
      let subscribe = (await socket.receiveClientFrame()).payload.parseJson
      check subscribe["type"].getStr == "subscribe"
      check subscribe["id"].getStr == "ticks-1"
      check subscribe["payload"]["operationName"].getStr == "Ticks"
      check subscribe["payload"]["variables"]["from"].getInt == 3
      check subscribe["payload"]["extensions"]["trace"].getBool
      await socket.send(serverFrame(
        """{"id":"ticks-1","type":"next","payload":{"data":{"tick":{"value":3}}}}"""
      ))
      await socket.send(serverFrame(
        """{"id":"ticks-1","type":"next","payload":{"data":{"tick":{"value":4}},"extensions":{"cursor":"four"}}}"""
      ))
      await socket.send(serverFrame(
        """{"id":"ticks-1","type":"complete"}"""
      ))
    let action = proc(url: string): Future[void] {.async.} =
      var headers = initHeaders()
      headers.set("authorization", "Bearer header-token")
      let opened = await openGraphqlSubscription(
        url, tickDocument(), TickData,
        variables = %*{"from": 3},
        operationName = "Ticks",
        headers = headers,
        connectionParams = %*{"token": "init-token"},
        extensions = %*{"trace": true},
        operationId = "ticks-1"
      )
      check opened.isOk
      let first = await opened.value.next()
      check first.isOk and first.value.isSome
      check first.value.get.data.get.tick.value == 3
      let second = await opened.value.next()
      check second.isOk and second.value.isSome
      check second.value.get.data.get.tick.value == 4
      check second.value.get.extensions["cursor"].getStr == "four"
      let completed = await opened.value.next()
      check completed.isOk and completed.value.isNone
      check opened.value.completed
      check (await opened.value.close()).isOk
    waitFor withServer(handler, action)

  test "returns terminal GraphQL protocol errors as a typed response":
    let handler = proc(socket: AsyncSocket; headers: string): Future[void] {.async.} =
      await socket.upgrade(headers)
      discard await socket.receiveClientFrame()
      await socket.send(serverFrame("""{"type":"connection_ack"}"""))
      discard await socket.receiveClientFrame()
      await socket.send(serverFrame(
        """{"id":"1","type":"error","payload":[{"message":"forbidden","extensions":{"code":"DENIED"}}]}"""
      ))
    let action = proc(url: string): Future[void] {.async.} =
      let opened = await openGraphqlSubscription(url, tickDocument(), TickData)
      check opened.isOk
      let event = await opened.value.next()
      check event.isOk and event.value.isSome
      check event.value.get.hasErrors
      check event.value.get.errors[0].message == "forbidden"
      check event.value.get.errors[0].extensions["code"].getStr == "DENIED"
      check (await opened.value.next()).value.isNone
      check (await opened.value.close()).isOk
    waitFor withServer(handler, action)

  test "close sends a complete operation message":
    let handler = proc(socket: AsyncSocket; headers: string): Future[void] {.async.} =
      await socket.upgrade(headers)
      discard await socket.receiveClientFrame()
      await socket.send(serverFrame("""{"type":"connection_ack"}"""))
      discard await socket.receiveClientFrame()
      let completed = await socket.receiveClientFrame()
      check completed.opcode == 1
      check completed.payload.parseJson["type"].getStr == "complete"
      check completed.payload.parseJson["id"].getStr == "1"
    let action = proc(url: string): Future[void] {.async.} =
      let opened = await openGraphqlSubscription(url, tickDocument(), TickData)
      check opened.isOk
      check (await opened.value.close()).isOk
    waitFor withServer(handler, action)

  test "cancellation aborts a waiting event receive":
    let token = newCancellationToken()
    let handler = proc(socket: AsyncSocket; headers: string): Future[void] {.async.} =
      await socket.upgrade(headers)
      discard await socket.receiveClientFrame()
      await socket.send(serverFrame("""{"type":"connection_ack"}"""))
      discard await socket.receiveClientFrame()
      while (await socket.recv(64)).len > 0:
        discard
    let action = proc(url: string): Future[void] {.async.} =
      var options = defaultGraphqlSubscriptionOptions()
      options.cancellation = token
      let opened = await openGraphqlSubscription(
        url, tickDocument(), TickData, options = options
      )
      check opened.isOk
      let pending = opened.value.next()
      await sleepAsync(10)
      token.cancel("screen closed")
      let event = await pending
      check event.isErr
      check event.error.kind == jeCancelled
      check event.error.msg.startsWith("screen closed")
    waitFor withServer(handler, action)

  test "connection acknowledgement timeout is a Result error":
    let handler = proc(socket: AsyncSocket; headers: string): Future[void] {.async.} =
      await socket.upgrade(headers)
      discard await socket.receiveClientFrame()
      while (await socket.recv(64)).len > 0:
        discard
    let action = proc(url: string): Future[void] {.async.} =
      var options = defaultGraphqlSubscriptionOptions()
      options.connectionAckTimeoutMs = 10
      let opened = await openGraphqlSubscription(
        url, tickDocument(), TickData, options = options
      )
      check opened.isErr
      check opened.error.kind == jeTimeout
    waitFor withServer(handler, action)

  test "rejects a server that does not accept the subprotocol":
    let handler = proc(socket: AsyncSocket; headers: string): Future[void] {.async.} =
      await socket.upgrade(headers, acceptProtocol = false)
    let action = proc(url: string): Future[void] {.async.} =
      let opened = await openGraphqlSubscription(url, tickDocument(), TickData)
      check opened.isErr
      check opened.error.kind == jeTransport
    waitFor withServer(handler, action)

  test "rejects malformed control-message payloads":
    let handler = proc(socket: AsyncSocket; headers: string): Future[void] {.async.} =
      await socket.upgrade(headers)
      discard await socket.receiveClientFrame()
      await socket.send(serverFrame("""{"type":"ping","payload":[]}"""))
      while (await socket.recv(64)).len > 0:
        discard
    let action = proc(url: string): Future[void] {.async.} =
      let opened = await openGraphqlSubscription(url, tickDocument(), TickData)
      check opened.isErr
      check opened.error.kind == jeCodec
    waitFor withServer(handler, action)

  test "enforces protocol message size before decoding":
    let handler = proc(socket: AsyncSocket; headers: string): Future[void] {.async.} =
      await socket.upgrade(headers)
      discard await socket.receiveClientFrame()
      await socket.send(serverFrame("""{"type":"connection_ack"}"""))
      discard await socket.receiveClientFrame()
      await socket.send(serverFrame(
        """{"id":"1","type":"next","payload":{"data":{"tick":{"value":123456}},"extensions":{"padding":""" &
          "x".repeat(300) & "\"}}}"
      ))
    let action = proc(url: string): Future[void] {.async.} =
      var options = defaultGraphqlSubscriptionOptions()
      options.maxMessageBytes = 200
      let opened = await openGraphqlSubscription(
        url, tickDocument(), TickData, options = options
      )
      check opened.isOk
      let event = await opened.value.next()
      check event.isErr
      check event.error.kind == jeBodyTooLarge
    waitFor withServer(handler, action)

  test "ignores pong and messages for unrelated operation IDs":
    let handler = proc(socket: AsyncSocket; headers: string): Future[void] {.async.} =
      await socket.upgrade(headers)
      discard await socket.receiveClientFrame()
      await socket.send(serverFrame("""{"type":"connection_ack"}"""))
      discard await socket.receiveClientFrame()
      await socket.send(serverFrame("""{"type":"pong"}"""))
      await socket.send(serverFrame(
        """{"id":"other","type":"next","payload":{"data":{"tick":{"value":99}}}}"""
      ))
      await socket.send(serverFrame(
        """{"id":"1","type":"next","payload":{"data":{"tick":{"value":5}}}}"""
      ))
    let action = proc(url: string): Future[void] {.async.} =
      let opened = await openGraphqlSubscription(url, tickDocument(), TickData)
      check opened.isOk
      let event = await opened.value.next()
      check event.isOk and event.value.get.data.get.tick.value == 5
      check (await opened.value.close()).isOk
    waitFor withServer(handler, action)

  test "malformed operation payload terminates and releases the socket":
    let handler = proc(socket: AsyncSocket; headers: string): Future[void] {.async.} =
      await socket.upgrade(headers)
      discard await socket.receiveClientFrame()
      await socket.send(serverFrame("""{"type":"connection_ack"}"""))
      discard await socket.receiveClientFrame()
      await socket.send(serverFrame(
        """{"id":"1","type":"next","payload":[]}"""
      ))
      while (await socket.recv(64)).len > 0:
        discard
    let action = proc(url: string): Future[void] {.async.} =
      let opened = await openGraphqlSubscription(url, tickDocument(), TickData)
      check opened.isOk
      let event = await opened.value.next()
      check event.isErr
      check event.error.kind == jeCodec
      check opened.value.completed
      check (await opened.value.next()).value.isNone
    waitFor withServer(handler, action)

  test "validates envelopes before opening a socket":
    let badVariables = waitFor openGraphqlSubscription(
      "ws://127.0.0.1:1/graphql", tickDocument(), TickData,
      variables = %*[1, 2]
    )
    check badVariables.isErr
    check badVariables.error.kind == jeInvalidRequest
    let badParams = waitFor openGraphqlSubscription(
      "ws://127.0.0.1:1/graphql", tickDocument(), TickData,
      connectionParams = %*["token"]
    )
    check badParams.isErr
    check badParams.error.kind == jeInvalidRequest
    let badId = waitFor openGraphqlSubscription(
      "ws://127.0.0.1:1/graphql", tickDocument(), TickData,
      operationId = ""
    )
    check badId.isErr
    check badId.error.kind == jeInvalidRequest
    let token = newCancellationToken()
    token.cancel("already cancelled")
    var options = defaultGraphqlSubscriptionOptions()
    options.cancellation = token
    let cancelled = waitFor openGraphqlSubscription(
      "ws://127.0.0.1:1/graphql", tickDocument(), TickData,
      options = options
    )
    check cancelled.isErr
    check cancelled.error.kind == jeCancelled
