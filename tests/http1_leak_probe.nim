import std/[asyncdispatch, asyncnet, net, strutils]
import joubako

const Iterations = 200

proc receiveHeaders(socket: AsyncSocket): Future[bool] {.async.} =
  var request = ""
  while "\r\n\r\n" notin request:
    let chunk = await socket.recv(4096)
    if chunk.len == 0:
      return false
    request.add chunk
  return true

proc serve(server: AsyncSocket): Future[void] {.async.} =
  let socket = await server.accept()
  defer:
    socket.close()
  for index in 0 ..< Iterations:
    doAssert await socket.receiveHeaders()
    let connection = if index + 1 == Iterations: "close" else: "keep-alive"
    await socket.send(
      "HTTP/1.1 200 OK\r\n" &
      "Content-Length: 2\r\n" &
      "Connection: " & connection & "\r\n\r\nok"
    )

proc exercise() {.async.} =
  let server = newAsyncSocket(buffered = false)
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(Port(0), "127.0.0.1")
  server.listen()
  defer:
    server.close()
  let (_, port) = server.getLocalAddr()
  let serving = server.serve()
  let transport = newHttpTransport(maxIdleConnections = 1)
  var options = defaultRequestOptions()
  options.timeoutMs = 1_000
  options.connectTimeoutMs = 1_000
  options.readTimeoutMs = 1_000
  let client = newClient(
    transport,
    "http://127.0.0.1:" & $int(port) & "/",
    defaultOptions = options
  )
  for _ in 0 ..< Iterations:
    let token = newCancellationToken()
    var requestOptions = options
    requestOptions.cancellation = token
    let outcome = await client.get("", options = requestOptions)
    doAssert outcome.isOk
    doAssert outcome.value.body == "ok"
    # A token cancelled after its exchange must not close the pooled
    # connection, and its registration must remain cycle-free under ARC/ORC.
    token.cancel("request already completed")
  await serving
  transport.closeIdleConnections()
  # Successful races detach their callbacks immediately. Let the dispatcher
  # pop the now-unreferenced timer Futures as well before leak accounting.
  await sleepAsync(1_001)

waitFor exercise()
