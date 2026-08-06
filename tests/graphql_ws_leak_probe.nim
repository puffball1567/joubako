import std/[asyncdispatch, asyncnet, base64, json, net, options, strutils]
{.push warning[Deprecated]: off.}
import std/sha1
{.pop.}
import joubako

const Magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

type
  ProbeTick = object
    value: int

  ProbeData = object
    tick: ProbeTick

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
    doAssert chunk.len > 0
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
    doAssert chunk.len > 0
    result.add chunk

proc receiveClientFrame(socket: AsyncSocket): Future[ClientFrame] {.async.} =
  let head = await socket.receiveExact(2)
  result.opcode = uint8(head[0]) and 0x0f
  var size = uint64(uint8(head[1]) and 0x7f)
  if size == 126:
    let extended = await socket.receiveExact(2)
    size = (uint64(uint8(extended[0])) shl 8) or uint64(uint8(extended[1]))
  elif size == 127:
    let extended = await socket.receiveExact(8)
    size = 0
    for value in extended:
      size = (size shl 8) or uint64(uint8(value))
  let mask = await socket.receiveExact(4)
  let encoded = await socket.receiveExact(int(size))
  for index, value in encoded:
    result.payload.add char(uint8(value) xor uint8(mask[index mod 4]))

proc serverFrame(payload: string): string =
  result.add char(0x81)
  if payload.len <= 125:
    result.add char(payload.len)
  else:
    result.add char(126)
    result.add char((payload.len shr 8) and 0xff)
    result.add char(payload.len and 0xff)
  result.add payload

proc upgrade(socket: AsyncSocket; headers: string): Future[void] {.async.} =
  await socket.send(
    "HTTP/1.1 101 Switching Protocols\r\n" &
    "Upgrade: websocket\r\n" &
    "Connection: Upgrade\r\n" &
    "Sec-WebSocket-Accept: " &
      acceptFor(headers.header("sec-websocket-key")) & "\r\n" &
    "Sec-WebSocket-Protocol: graphql-transport-ws\r\n\r\n"
  )

proc serve(server: AsyncSocket): Future[void] {.async.} =
  for scenario in 0 .. 2:
    let socket = await server.accept()
    let headers = await socket.receiveHeaders()
    await socket.upgrade(headers)
    discard await socket.receiveClientFrame()
    await socket.send(serverFrame("""{"type":"connection_ack"}"""))
    discard await socket.receiveClientFrame()
    case scenario
    of 0:
      await socket.send(serverFrame(
        """{"id":"1","type":"next","payload":{"data":{"tick":{"value":7}}}}"""
      ))
      await socket.send(serverFrame("""{"id":"1","type":"complete"}"""))
    of 1:
      await socket.send(serverFrame(
        """{"id":"1","type":"next","payload":[]}"""
      ))
    else:
      while (await socket.recv(64)).len > 0:
        discard
    socket.close()

proc document(): GraphqlDocument =
  gqlSubscription(
    "Ticks",
    selection = [gqlField("tick", selection = [gqlField("value")])]
  )

proc main(): Future[void] {.async.} =
  let server = newAsyncSocket(buffered = false)
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(Port(0), "127.0.0.1")
  server.listen()
  let (_, port) = server.getLocalAddr()
  let url = "ws://127.0.0.1:" & $int(port) & "/graphql"
  let serving = serve(server)
  var options = defaultGraphqlSubscriptionOptions()
  options.handshakeTimeoutMs = -1
  options.connectionAckTimeoutMs = -1

  let success = await openGraphqlSubscription(
    url, document(), ProbeData, options = options
  )
  doAssert success.isOk
  let event = await success.value.next()
  doAssert event.isOk and event.value.get.data.get.tick.value == 7
  doAssert (await success.value.next()).value.isNone
  doAssert (await success.value.close()).isOk

  let malformed = await openGraphqlSubscription(
    url, document(), ProbeData, options = options
  )
  doAssert malformed.isOk
  let malformedEvent = await malformed.value.next()
  doAssert malformedEvent.isErr and malformedEvent.error.kind == jeCodec

  let token = newCancellationToken()
  options.cancellation = token
  let cancelled = await openGraphqlSubscription(
    url, document(), ProbeData, options = options
  )
  doAssert cancelled.isOk
  let pending = cancelled.value.next()
  token.cancel("probe cancellation")
  let cancelledEvent = await pending
  doAssert cancelledEvent.isErr and cancelledEvent.error.kind == jeCancelled

  await serving
  server.close()

let probe = main()
waitFor probe
probe.clearCallbacks()
doAssert not hasPendingOperations()
setGlobalDispatcher(nil)
