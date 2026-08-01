import std/[asyncdispatch, asyncnet, net, os, strutils, unittest]
import joubako

when not defined(ssl):
  {.error: "test_secure_transport.nim requires -d:ssl".}

const
  fixtureDir = currentSourcePath.parentDir / "testdata" / "tls"
  caFile = fixtureDir / "ca.pem"
  serverCertFile = fixtureDir / "server.pem"
  serverKeyFile = fixtureDir / "server-key.pem"
  clientCertFile = fixtureDir / "client.pem"
  clientKeyFile = fixtureDir / "client-key.pem"

type SocksCapture = object
  username: string
  password: string
  hostname: string
  port: int
  requestHeaders: string

proc recvExact(socket: AsyncSocket; size: int): Future[string] {.async.} =
  while result.len < size:
    let chunk = await socket.recv(size - result.len)
    if chunk.len == 0:
      raise newException(IOError, "connection closed before enough bytes arrived")
    result.add chunk

proc recvHeaders(socket: AsyncSocket): Future[string] {.async.} =
  while "\r\n\r\n" notin result:
    let chunk = await socket.recv(4096)
    if chunk.len == 0:
      raise newException(IOError, "connection closed before HTTP headers arrived")
    result.add chunk

proc serveTlsOnce(
    server: AsyncSocket;
    context: SslContext;
    clientCertificateSeen: Future[bool]
): Future[void] {.async.} =
  let socket = await server.accept()
  defer:
    socket.close()
    context.destroyContext()
  try:
    context.wrapConnectedSocket(socket, handshakeAsServer)
    discard await socket.recvHeaders()
    if not clientCertificateSeen.finished:
      clientCertificateSeen.complete(socket.getPeerCertificates().len > 0)
    let body = "secure-response"
    await socket.send(
      "HTTP/1.1 200 OK\r\n" &
      "Content-Length: " & $body.len & "\r\n" &
      "Connection: close\r\n\r\n" & body
    )
  except CatchableError:
    if not clientCertificateSeen.finished:
      clientCertificateSeen.complete(false)

proc startTlsServer(
    verifyMode = CVerifyNone;
    caFile = ""
): tuple[server: AsyncSocket, port: Port, serving: Future[void], peer: Future[bool]] =
  result.server = newAsyncSocket(buffered = false)
  result.server.setSockOpt(OptReuseAddr, true)
  result.server.bindAddr(Port(0), "127.0.0.1")
  result.server.listen()
  let (_, port) = result.server.getLocalAddr()
  result.port = port
  result.peer = newFuture[bool]("test_secure_transport.clientCertificateSeen")
  let context = newContext(
    verifyMode = verifyMode,
    certFile = serverCertFile,
    keyFile = serverKeyFile,
    caFile = caFile
  )
  result.serving = serveTlsOnce(result.server, context, result.peer)

proc serveSocks5hOnce(
    server: AsyncSocket;
    captured: Future[SocksCapture];
    rejectAuthentication = false
): Future[void] {.async.} =
  let socket = await server.accept()
  defer:
    socket.close()

  var capture: SocksCapture
  try:
    let greeting = await socket.recvExact(2)
    if greeting[0] != '\x05':
      raise newException(IOError, "unexpected SOCKS version")
    let methods = await socket.recvExact(ord(greeting[1]))
    if '\x02' notin methods:
      raise newException(IOError, "username/password authentication not offered")
    await socket.send("\x05\x02")

    let authHeader = await socket.recvExact(2)
    if authHeader[0] != '\x01':
      raise newException(IOError, "unexpected SOCKS auth version")
    capture.username = await socket.recvExact(ord(authHeader[1]))
    let passwordLength = await socket.recvExact(1)
    capture.password = await socket.recvExact(ord(passwordLength[0]))
    if rejectAuthentication:
      await socket.send("\x01\x01")
      captured.complete(capture)
      return
    await socket.send("\x01\x00")

    let request = await socket.recvExact(4)
    if request != "\x05\x01\x00\x03":
      raise newException(IOError, "expected a SOCKS5 domain-name request")
    let hostnameLength = await socket.recvExact(1)
    capture.hostname = await socket.recvExact(ord(hostnameLength[0]))
    let portBytes = await socket.recvExact(2)
    capture.port = ord(portBytes[0]) shl 8 or ord(portBytes[1])
    await socket.send("\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x00")

    capture.requestHeaders = await socket.recvHeaders()
    captured.complete(capture)
    let body = "proxied-response"
    await socket.send(
      "HTTP/1.1 200 OK\r\n" &
      "Content-Length: " & $body.len & "\r\n" &
      "Connection: close\r\n\r\n" & body
    )
  except CatchableError:
    if not captured.finished:
      captured.fail(getCurrentException())

proc startSocksServer(
    rejectAuthentication = false
): tuple[server: AsyncSocket, port: Port, serving: Future[void], captured: Future[SocksCapture]] =
  result.server = newAsyncSocket(buffered = false)
  result.server.setSockOpt(OptReuseAddr, true)
  result.server.bindAddr(Port(0), "127.0.0.1")
  result.server.listen()
  let (_, port) = result.server.getLocalAddr()
  result.port = port
  result.captured = newFuture[SocksCapture]("test_secure_transport.socksCapture")
  result.serving = serveSocks5hOnce(
    result.server,
    result.captured,
    rejectAuthentication
  )

suite "secure transport integration":
  test "default TLS verification rejects an untrusted CA":
    let endpoint = startTlsServer()
    defer:
      endpoint.server.close()
    let client = newClient(newHttpTransport())
    let outcome = waitFor client.get(
      "https://localhost:" & $int(endpoint.port) & "/"
    )
    waitFor endpoint.serving
    check outcome.isErr
    if outcome.isErr:
      check outcome.error.kind == jeTransport
    check not endpoint.peer.read

  test "a configured CA verifies a real TLS connection":
    let endpoint = startTlsServer()
    defer:
      endpoint.server.close()
    let transport = newHttpTransport(tlsOptions = TlsOptions(
      verifyMode: tvmPeer,
      caFile: caFile
    ))
    let outcome = waitFor newClient(transport).get(
      "https://localhost:" & $int(endpoint.port) & "/"
    )
    waitFor endpoint.serving
    check outcome.isOk
    check outcome.value.body == "secure-response"
    check not endpoint.peer.read

  test "TLS verification rejects a certificate for another hostname":
    let endpoint = startTlsServer()
    defer:
      endpoint.server.close()
    let transport = newHttpTransport(tlsOptions = TlsOptions(
      verifyMode: tvmPeer,
      caFile: caFile
    ))
    let outcome = waitFor newClient(transport).get(
      "https://127.0.0.1:" & $int(endpoint.port) & "/"
    )
    waitFor endpoint.serving
    check outcome.isErr
    if outcome.isErr:
      check outcome.error.kind == jeTransport

  test "mTLS presents and verifies the configured client certificate":
    let endpoint = startTlsServer(CVerifyPeer, caFile)
    defer:
      endpoint.server.close()
    let transport = newHttpTransport(tlsOptions = TlsOptions(
      verifyMode: tvmPeer,
      caFile: caFile,
      certFile: clientCertFile,
      keyFile: clientKeyFile
    ))
    let outcome = waitFor newClient(transport).get(
      "https://localhost:" & $int(endpoint.port) & "/"
    )
    waitFor endpoint.serving
    check outcome.isOk
    check outcome.value.body == "secure-response"
    check endpoint.peer.read

  test "SOCKS5h authenticates and sends the upstream hostname to the proxy":
    let endpoint = startSocksServer()
    defer:
      endpoint.server.close()
    let proxyUrl = "socks5h://proxy-user:proxy-pass@127.0.0.1:" &
      $int(endpoint.port)
    let transport = newHttpTransport(proxyOptions = ProxyOptions(
      httpProxy: proxyUrl
    ))
    let outcome = waitFor newClient(transport).get(
      "http://upstream.invalid:8088/resource?q=1"
    )
    waitFor endpoint.serving
    check outcome.isOk
    check outcome.value.body == "proxied-response"
    let capture = endpoint.captured.read
    check capture.username == "proxy-user"
    check capture.password == "proxy-pass"
    check capture.hostname == "upstream.invalid"
    check capture.port == 8088
    check capture.requestHeaders.startsWith(
      "GET http://upstream.invalid:8088/resource?q=1 HTTP/"
    )
    check "host: upstream.invalid:8088" in capture.requestHeaders.toLowerAscii

  test "SOCKS5h authentication rejection is a structured transport error":
    let endpoint = startSocksServer(rejectAuthentication = true)
    defer:
      endpoint.server.close()
    let proxyUrl = "socks5h://bad-user:bad-pass@127.0.0.1:" &
      $int(endpoint.port)
    let transport = newHttpTransport(proxyOptions = ProxyOptions(
      httpProxy: proxyUrl
    ))
    let outcome = waitFor newClient(transport).get(
      "http://upstream.invalid/private"
    )
    waitFor endpoint.serving
    check outcome.isErr
    if outcome.isErr:
      check outcome.error.kind == jeTransport
    check endpoint.captured.read.username == "bad-user"
