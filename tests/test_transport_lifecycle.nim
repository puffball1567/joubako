import std/[asyncdispatch, asyncnet, strutils, unittest]
import joubako

type
  TrackingTransport = ref object of Transport
    closeCalls: int
    closed: bool
    failClose: bool
    raiseClose: bool
    nilClose: bool
    implicitCredentials: bool
    runtimeMultipartLimits: bool

  BareTransport = ref object of Transport

method usesImplicitCredentials(transport: TrackingTransport): bool =
  transport != nil and transport.implicitCredentials

method supportsRuntimeMultipartLimits(transport: TrackingTransport): bool =
  transport != nil and transport.runtimeMultipartLimits

method send(
    transport: TrackingTransport;
    request: Request
): Future[Response] {.async.} =
  if transport.closed:
    raise newJoubakoError(jeTransport, "tracking transport is closed")
  return Response(status: 200, body: "ok", request: request)

method close(transport: TrackingTransport): Future[void] =
  inc transport.closeCalls
  transport.closed = true
  if transport.raiseClose:
    raise newException(IOError, "synchronous close failed")
  if transport.nilClose:
    return nil
  result = newFuture[void]("test_transport_lifecycle.close")
  if transport.failClose:
    result.fail(newException(IOError, "close failed"))
  else:
    result.complete()

method send(
    transport: BareTransport;
    request: Request
): Future[Response] {.async.} =
  return Response(status: 200, body: "bare", request: request)

proc receiveHeaders(socket: AsyncSocket): Future[bool] {.async.} =
  var request = ""
  while "\r\n\r\n" notin request:
    let chunk = await socket.recv(4096)
    if chunk.len == 0:
      return false
    request.add(chunk)
  true

proc servePersistentOnce(server: AsyncSocket): Future[void] {.async.} =
  let socket = await server.accept()
  defer:
    socket.close()
  if not await socket.receiveHeaders():
    return
  await socket.send(
    "HTTP/1.1 200 OK\r\n" &
    "Content-Length: 2\r\n" &
    "Connection: keep-alive\r\n\r\nok"
  )
  while (await socket.recv(4096)).len > 0:
    discard

proc serveDelayedOnce(
    server: AsyncSocket;
    headersReceived: Future[void]
): Future[void] {.async.} =
  let socket = await server.accept()
  defer:
    socket.close()
  if not await socket.receiveHeaders():
    return
  if not headersReceived.finished:
    headersReceived.complete()
  await sleepAsync(20)
  await socket.send(
    "HTTP/1.1 200 OK\r\n" &
    "Content-Length: 2\r\n" &
    "Connection: keep-alive\r\n\r\nok"
  )

proc exerciseHttpClose(): Future[void] {.async.} =
  let server = newAsyncSocket(buffered = false)
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(Port(0), "127.0.0.1")
  server.listen()
  defer:
    server.close()
  let (_, port) = server.getLocalAddr()
  let serving = server.servePersistentOnce()
  let transport = newHttpTransport()
  let client = newClient(transport)

  let response = await client.get(
    "http://127.0.0.1:" & $int(port) & "/"
  )
  check response.isOk
  check response.value.body == "ok"
  check transport.idleConnectionCount == 1

  let closed = await client.close()
  check closed.isOk
  check client.isClosed
  check transport.idleConnectionCount == 0
  await serving

  let afterClose = await client.get(
    "http://127.0.0.1:" & $int(port) & "/"
  )
  check afterClose.isErr
  check afterClose.error.kind == jeInvalidRequest

proc exerciseHttpCloseDuringRequest(): Future[void] {.async.} =
  let server = newAsyncSocket(buffered = false)
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(Port(0), "127.0.0.1")
  server.listen()
  defer:
    server.close()
  let (_, port) = server.getLocalAddr()
  let headersReceived = newFuture[void](
    "test_transport_lifecycle.headersReceived"
  )
  let serving = server.serveDelayedOnce(headersReceived)
  let transport = newHttpTransport()
  let client = newClient(transport)
  let pending = client.get(
    "http://127.0.0.1:" & $int(port) & "/"
  )

  await headersReceived
  let closed = await client.close()
  check closed.isOk
  check client.isClosed

  let response = await pending
  check response.isOk
  check response.value.body == "ok"
  check transport.idleConnectionCount == 0
  await serving

suite "Transport lifecycle":
  test "client close is idempotent and rejects later requests":
    let transport = TrackingTransport()
    let client = newClient(transport)
    check waitFor(client.get("/before-close")).isOk

    let first = client.close()
    let second = client.close()
    check first == second
    check waitFor(first).isOk
    check transport.closeCalls == 1
    check client.isClosed

    let afterClose = waitFor client.get("/after-close")
    check afterClose.isErr
    check afterClose.error.kind == jeInvalidRequest
    check afterClose.error.msg == "client is closed"

  test "close failures settle as transport errors":
    let transport = TrackingTransport(failClose: true)
    let client = newClient(transport)

    let closed = waitFor client.close()

    check closed.isErr
    check closed.error.kind == jeTransport
    check closed.error.msg == "close failed"
    check client.isClosed
    check transport.closeCalls == 1

  test "synchronous and nil close failures also settle as values":
    for transport in [
      TrackingTransport(raiseClose: true),
      TrackingTransport(nilClose: true)
    ]:
      let client = newClient(transport)
      let closed = waitFor client.close()
      check closed.isErr
      check closed.error.kind == jeTransport
      check client.isClosed
      check transport.closeCalls == 1

  test "nil clients and clients without transports fail safely":
    let nilClient: Client = nil
    let nilClosed = waitFor nilClient.close()
    check nilClosed.isErr
    check nilClosed.error.kind == jeInvalidRequest

    let missing = newClient(nil)
    let missingClosed = waitFor missing.close()
    check missingClosed.isErr
    check missingClosed.error.kind == jeInvalidRequest
    check missing.isClosed

  test "the base close method keeps third-party transports compatible":
    let client = newClient(BareTransport())
    check waitFor(client.get("/bare")).isOk
    check waitFor(client.close()).isOk
    check client.isClosed

  test "nested wrappers preserve security and streaming capabilities":
    let delegate = TrackingTransport(
      implicitCredentials: true,
      runtimeMultipartLimits: true
    )
    let cached = newCachingTransport(delegate)
    let faults = newFaultInjectingTransport(
      cached, newSeq[FaultStep]()
    )

    check cached.usesImplicitCredentials
    check cached.supportsRuntimeMultipartLimits
    check faults.usesImplicitCredentials
    check faults.supportsRuntimeMultipartLimits

    let client = newClient(faults)
    check waitFor(client.close()).isOk
    check delegate.closeCalls == 1

  test "HTTP client close releases an idle keep-alive connection":
    waitFor exerciseHttpClose()

  test "HTTP close lets an active request finish without re-pooling it":
    waitFor exerciseHttpCloseDuringRequest()
