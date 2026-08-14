import std/[asyncdispatch, asyncnet, net, os, strutils, unittest]
from std/httpclient import newProxy
import joubako
import ./compression_test_helpers
import ./result_test_helpers

proc serveOne(server: AsyncSocket): Future[void] {.async.} =
  let socket = await server.accept()
  defer:
    socket.close()

  var request = ""
  while "\r\n\r\n" notin request:
    let chunk = await socket.recv(4096)
    if chunk.len == 0:
      return
    request.add chunk

  let body = """{"id":7,"name":"HTTP transport"}"""
  await socket.send(
    "HTTP/1.1 200 OK\r\n" &
    "Content-Type: application/json\r\n" &
    "Content-Length: " & $body.len & "\r\n" &
    "Connection: close\r\n\r\n" &
    body
  )

proc acceptUntilClosed(
    server: AsyncSocket;
    accepted: Future[void]
): Future[void] {.async.} =
  let socket = await server.accept()
  defer:
    socket.close()
  accepted.complete()
  while (await socket.recv(4096)).len > 0:
    discard

proc serveHeadersThenWait(
    server: AsyncSocket;
    contentLength: int
): Future[void] {.async.} =
  let socket = await server.accept()
  defer:
    socket.close()

  var request = ""
  while "\r\n\r\n" notin request:
    let chunk = await socket.recv(4096)
    if chunk.len == 0:
      return
    request.add chunk

  await socket.send(
    "HTTP/1.1 200 OK\r\n" &
    "Content-Type: text/plain\r\n" &
    "Content-Length: " & $contentLength & "\r\n" &
    "Connection: close\r\n\r\n"
  )
  while (await socket.recv(4096)).len > 0:
    discard

proc receiveRequestHeaders(socket: AsyncSocket): Future[bool] {.async.} =
  var request = ""
  while "\r\n\r\n" notin request:
    let chunk = await socket.recv(4096)
    if chunk.len == 0:
      return false
    request.add chunk
  return true

proc serveKeepAlivePair(
    server: AsyncSocket;
    accepted: Future[int]
): Future[void] {.async.} =
  let socket = await server.accept()
  defer:
    socket.close()
  accepted.complete(1)
  for index in 0 .. 1:
    if not await socket.receiveRequestHeaders():
      return
    let body = if index == 0: "first" else: "second"
    let connection = if index == 0: "keep-alive" else: "close"
    await socket.send(
      "HTTP/1.1 200 OK\r\n" &
      "Content-Length: " & $body.len & "\r\n" &
      "Connection: " & connection & "\r\n\r\n" &
      body
    )

proc exerciseConnectionReuse(): Future[void] {.async.} =
  let server = newAsyncSocket(buffered = false)
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(Port(0), "127.0.0.1")
  server.listen()
  defer:
    server.close()
  let (_, port) = server.getLocalAddr()
  let accepted = newFuture[int]("test_http.connectionReuseAccepted")
  let serving = server.serveKeepAlivePair(accepted)
  let transport = newHttpTransport()
  let client = newClient(
    transport,
    "http://127.0.0.1:" & $int(port) & "/"
  )

  let first = await client.get("first")
  let second = await client.get("second")
  await serving

  check first.body == "first"
  check second.body == "second"
  check accepted.read == 1
  check transport.idleConnectionCount == 1
  transport.closeIdleConnections()
  check transport.idleConnectionCount == 0

proc serveCloseDelimitedBody(
    server: AsyncSocket;
    body: string
): Future[void] {.async.} =
  let socket = await server.accept()
  defer:
    socket.close()
  if not await socket.receiveRequestHeaders():
    return
  await socket.send(
    "HTTP/1.1 200 OK\r\n" &
    "Content-Type: text/plain\r\n" &
    "Connection: close\r\n\r\n" &
    body
  )

proc serveChunkedBody(
    server: AsyncSocket;
    chunks: seq[string]
): Future[void] {.async.} =
  let socket = await server.accept()
  defer:
    socket.close()
  if not await socket.receiveRequestHeaders():
    return
  await socket.send(
    "HTTP/1.1 200 OK\r\n" &
    "Content-Type: text/plain\r\n" &
    "Transfer-Encoding: chunked\r\n" &
    "Connection: close\r\n\r\n"
  )
  for chunk in chunks:
    await socket.send(toHex(chunk.len) & "\r\n" & chunk & "\r\n")
  await socket.send("0\r\n\r\n")

proc serveRawResponse(
    server: AsyncSocket;
    rawResponse: string
): Future[void] {.async.} =
  let socket = await server.accept()
  defer:
    socket.close()
  if not await socket.receiveRequestHeaders():
    return
  await socket.send(rawResponse)

proc serveRangeResponse(
    server: AsyncSocket;
    captured: Future[string]
): Future[void] {.async.} =
  let socket = await server.accept()
  defer: socket.close()
  var request = ""
  while "\r\n\r\n" notin request:
    let chunk = await socket.recv(4096)
    if chunk.len == 0:
      return
    request.add chunk
  captured.complete(request)
  await socket.send(
    "HTTP/1.1 206 Partial Content\r\n" &
    "Content-Range: bytes 7-11/12\r\n" &
    "Content-Length: 5\r\n" &
    "Content-Type: application/octet-stream\r\n" &
    "Connection: close\r\n\r\n" &
    "-tail"
  )

proc serveRedirect(
    server: AsyncSocket;
    location: string
): Future[void] {.async.} =
  let socket = await server.accept()
  defer:
    socket.close()
  if not await socket.receiveRequestHeaders():
    return
  await socket.send(
    "HTTP/1.1 302 Found\r\n" &
    "Location: " & location & "\r\n" &
    "Content-Length: 0\r\n" &
    "Connection: close\r\n\r\n"
  )

proc captureAuthorization(
    server: AsyncSocket;
    captured: Future[string]
): Future[void] {.async.} =
  let socket = await server.accept()
  defer:
    socket.close()
  var request = ""
  while "\r\n\r\n" notin request:
    let chunk = await socket.recv(4096)
    if chunk.len == 0:
      return
    request.add chunk
  var authorization = ""
  for line in request.splitLines:
    if line.toLowerAscii.startsWith("authorization:"):
      authorization = line.split(":", 1)[1].strip
  captured.complete(authorization)
  await socket.send(
    "HTTP/1.1 200 OK\r\n" &
    "Content-Length: 2\r\n" &
    "Connection: close\r\n\r\nok"
  )

type CapturedRequest = object
  requestLine: string
  headers: string
  body: string

proc captureRequest(
    server: AsyncSocket;
    captured: Future[CapturedRequest];
    responseBody = "ok"
): Future[void] {.async.} =
  let socket = await server.accept()
  defer:
    socket.close()
  var raw = ""
  while "\r\n\r\n" notin raw:
    let chunk = await socket.recv(4096)
    if chunk.len == 0:
      return
    raw.add chunk
  let splitAt = raw.find("\r\n\r\n")
  let headerBlock = raw[0 ..< splitAt]
  var body = raw[splitAt + 4 .. ^1]
  var contentLength = 0
  for line in headerBlock.splitLines:
    if line.toLowerAscii.startsWith("content-length:"):
      contentLength = line.split(":", 1)[1].strip.parseInt
  while body.len < contentLength:
    let chunk = await socket.recv(contentLength - body.len)
    if chunk.len == 0:
      break
    body.add chunk
  captured.complete(CapturedRequest(
    requestLine: headerBlock.splitLines[0],
    headers: headerBlock,
    body: body
  ))
  await socket.send(
    "HTTP/1.1 200 OK\r\n" &
    "Content-Length: " & $responseBody.len & "\r\n" &
    "Connection: close\r\n\r\n" & responseBody
  )

proc captureRequestPair(
    server: AsyncSocket;
    first, second: Future[CapturedRequest]
): Future[void] {.async.} =
  await captureRequest(server, first)
  await captureRequest(server, second)

proc exerciseRedirectMethod(
    status: int;
    body: string
): Future[CapturedRequest] {.async.} =
  let server = newAsyncSocket(buffered = false)
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(Port(0), "127.0.0.1")
  server.listen()
  defer:
    server.close()
  let (_, port) = server.getLocalAddr()
  proc redirectOnce(): Future[void] {.async.} =
    let socket = await server.accept()
    defer:
      socket.close()
    if not await socket.receiveRequestHeaders():
      return
    await socket.send(
      "HTTP/1.1 " & $status & " Redirect\r\n" &
      "Location: /target\r\n" &
      "Content-Length: 0\r\n" &
      "Connection: close\r\n\r\n"
    )
  let captured = newFuture[CapturedRequest]("test_http.redirectMethod")
  proc serveBoth(): Future[void] {.async.} =
    await redirectOnce()
    await captureRequest(server, captured)
  let serving = serveBoth()
  let client = newClient(newHttpTransport())
  var headers = initHeaders()
  headers.set("content-type", "text/plain")
  discard await client.post(
    "http://127.0.0.1:" & $int(port) & "/start",
    body,
    headers
  )
  await serving
  return captured.read

proc exerciseRedirectCookie(): Future[CapturedRequest] {.async.} =
  let server = newAsyncSocket(buffered = false)
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(Port(0), "127.0.0.1")
  server.listen()
  defer:
    server.close()
  let (_, port) = server.getLocalAddr()
  proc redirectOnce(): Future[void] {.async.} =
    let socket = await server.accept()
    defer:
      socket.close()
    if not await socket.receiveRequestHeaders():
      return
    await socket.send(
      "HTTP/1.1 302 Found\r\n" &
      "Location: /target\r\n" &
      "Set-Cookie: session=redirected; Path=/target; HttpOnly\r\n" &
      "Content-Length: 0\r\n" &
      "Connection: close\r\n\r\n"
    )
  let captured = newFuture[CapturedRequest]("test_http.redirectCookie")
  proc serveBoth(): Future[void] {.async.} =
    await redirectOnce()
    await captureRequest(server, captured)
  let serving = serveBoth()
  let jar = newCookieJar()
  let client = newClient(newHttpTransport(cookieJar = jar))
  discard await client.get(
    "http://127.0.0.1:" & $int(port) & "/start"
  )
  await serving
  return captured.read

proc exerciseExplicitCookie(): Future[CapturedRequest] {.async.} =
  let server = newAsyncSocket(buffered = false)
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(Port(0), "127.0.0.1")
  server.listen()
  defer:
    server.close()
  let (_, port) = server.getLocalAddr()
  let captured = newFuture[CapturedRequest]("test_http.explicitCookie")
  let serving = captureRequest(server, captured)
  let jar = newCookieJar()
  discard jar.store(
    "http://127.0.0.1:" & $int(port) & "/", "session=jar; Path=/"
  )
  let client = newClient(newHttpTransport(cookieJar = jar))
  var headers = initHeaders()
  headers.set("cookie", "session=explicit")
  discard await client.get(
    "http://127.0.0.1:" & $int(port) & "/", headers
  )
  await serving
  return captured.read

proc exerciseCrossOriginRedirect(): Future[string] {.async.} =
  let first = newAsyncSocket(buffered = false)
  let second = newAsyncSocket(buffered = false)
  for server in [first, second]:
    server.setSockOpt(OptReuseAddr, true)
    server.bindAddr(Port(0), "127.0.0.1")
    server.listen()
  defer:
    first.close()
    second.close()
  let (_, firstPort) = first.getLocalAddr()
  let (_, secondPort) = second.getLocalAddr()
  let destination = "http://127.0.0.1:" & $int(secondPort) & "/target"
  let captured = newFuture[string]("test_http.redirectAuthorization")
  let redirecting = serveRedirect(first, destination)
  let capturing = captureAuthorization(second, captured)
  let client = newClient(newHttpTransport())
  var headers = initHeaders()
  headers.set("authorization", "Bearer secret")
  let response = await client.get(
    "http://127.0.0.1:" & $int(firstPort) & "/start",
    headers
  )
  await redirecting
  await capturing
  check response.body == "ok"
  return captured.read

proc exerciseCrossOriginSensitiveHeaders(): Future[CapturedRequest] {.async.} =
  let first = newAsyncSocket(buffered = false)
  let second = newAsyncSocket(buffered = false)
  for server in [first, second]:
    server.setSockOpt(OptReuseAddr, true)
    server.bindAddr(Port(0), "127.0.0.1")
    server.listen()
  defer:
    first.close()
    second.close()
  let (_, firstPort) = first.getLocalAddr()
  let (_, secondPort) = second.getLocalAddr()
  let destination = "http://127.0.0.1:" & $int(secondPort) & "/target"
  let captured = newFuture[CapturedRequest]("test_http.sensitiveHeaders")
  let redirecting = serveRedirect(first, destination)
  let capturing = captureRequest(second, captured)
  let client = newClient(newHttpTransport())
  var headers = initHeaders()
  headers.set("authorization", "Bearer secret")
  headers.set("cookie", "session=secret")
  headers.set("proxy-authorization", "Basic secret")
  headers.set("host", "forged.invalid")
  discard await client.get(
    "http://127.0.0.1:" & $int(firstPort) & "/start",
    headers
  )
  await redirecting
  await capturing
  return captured.read

proc exerciseSameOriginRedirect(): Future[string] {.async.} =
  let server = newAsyncSocket(buffered = false)
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(Port(0), "127.0.0.1")
  server.listen()
  defer:
    server.close()
  let (_, port) = server.getLocalAddr()
  let captured = newFuture[string]("test_http.sameOriginAuthorization")
  proc serveBoth(): Future[void] {.async.} =
    await serveRedirect(server, "/target")
    await captureAuthorization(server, captured)
  let serving = serveBoth()
  let client = newClient(newHttpTransport())
  var headers = initHeaders()
  headers.set("authorization", "Bearer same-origin")
  discard await client.get(
    "http://127.0.0.1:" & $int(port) & "/start",
    headers
  )
  await serving
  return captured.read

proc requestRaw(
    rawResponse: string;
    options = RequestOptions();
    httpMethod = rmGet
): Future[Response] {.async.} =
  let server = newAsyncSocket(buffered = false)
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(Port(0), "127.0.0.1")
  server.listen()
  defer:
    server.close()

  let (_, port) = server.getLocalAddr()
  let serving = serveRawResponse(server, rawResponse)
  let client = newClient(
    newHttpTransport(),
    "http://127.0.0.1:" & $int(port) & "/"
  )
  try:
    return await client.request(httpMethod, "raw", options = options)
  finally:
    await serving

proc exerciseHeaderDeadline(): Future[ErrorKind] {.async.} =
  let server = newAsyncSocket(buffered = false)
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(Port(0), "127.0.0.1")
  server.listen()
  defer:
    server.close()

  let (_, port) = server.getLocalAddr()
  let accepted = newFuture[void]("test_http.headerDeadlineAccepted")
  let serving = acceptUntilClosed(server, accepted)
  let client = newClient(
    newHttpTransport(),
    "http://127.0.0.1:" & $int(port) & "/"
  )
  var options = defaultRequestOptions()
  options.timeoutMs = 20
  let pending = client.get("headers", options = options)
  await accepted

  try:
    discard await pending
  except JoubakoError as error:
    await serving
    return error.kind
  raise newException(AssertionDefect, "request should have timed out")

type
  User = object
    id: int
    name: string

proc exerciseHttpTransport(): Future[void] {.async.} =
  let server = newAsyncSocket(buffered = false)
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(Port(0), "127.0.0.1")
  server.listen()
  defer:
    server.close()

  let (_, port) = server.getLocalAddr()
  let serving = serveOne(server)
  let client = newClient(
    newHttpTransport(),
    "http://127.0.0.1:" & $int(port) & "/"
  )

  let user = await client.getJson("users/7", User)
  await serving

  check user.id == 7
  check user.name == "HTTP transport"

proc exerciseActiveCancellation(): Future[ErrorKind] {.async.} =
  let server = newAsyncSocket(buffered = false)
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(Port(0), "127.0.0.1")
  server.listen()
  defer:
    server.close()

  let (_, port) = server.getLocalAddr()
  let accepted = newFuture[void]("test_http.accepted")
  let serving = acceptUntilClosed(server, accepted)
  let client = newClient(
    newHttpTransport(),
    "http://127.0.0.1:" & $int(port) & "/"
  )
  let token = newCancellationToken()
  var options = defaultRequestOptions()
  options.cancellation = token
  let pending = client.get("slow", options = options)

  await accepted
  token.cancel("superseded")

  try:
    discard await pending
  except JoubakoError as error:
    await serving
    return error.kind
  raise newException(AssertionDefect, "request should have been cancelled")

proc exerciseBodyDeadline(): Future[ErrorKind] {.async.} =
  let server = newAsyncSocket(buffered = false)
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(Port(0), "127.0.0.1")
  server.listen()
  defer:
    server.close()

  let (_, port) = server.getLocalAddr()
  let serving = serveHeadersThenWait(server, 10)
  let client = newClient(
    newHttpTransport(),
    "http://127.0.0.1:" & $int(port) & "/"
  )
  var options = defaultRequestOptions()
  options.timeoutMs = 50

  try:
    discard await client.get("slow-body", options = options)
  except JoubakoError as error:
    await serving
    return error.kind
  raise newException(AssertionDefect, "request should have timed out")

proc exerciseDeclaredBodyLimit(): Future[ErrorKind] {.async.} =
  let server = newAsyncSocket(buffered = false)
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(Port(0), "127.0.0.1")
  server.listen()
  defer:
    server.close()

  let (_, port) = server.getLocalAddr()
  let serving = serveHeadersThenWait(server, 1_000)
  let client = newClient(
    newHttpTransport(),
    "http://127.0.0.1:" & $int(port) & "/"
  )
  var options = defaultRequestOptions()
  options.maxResponseBytes = 10

  try:
    discard await client.get("large", options = options)
  except JoubakoError as error:
    await serving
    return error.kind
  raise newException(AssertionDefect, "request should have exceeded its limit")

proc exerciseCloseDelimitedBodyLimit(): Future[ErrorKind] {.async.} =
  let server = newAsyncSocket(buffered = false)
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(Port(0), "127.0.0.1")
  server.listen()
  defer:
    server.close()

  let (_, port) = server.getLocalAddr()
  let serving = serveCloseDelimitedBody(server, "0123456789abcdef")
  let client = newClient(
    newHttpTransport(),
    "http://127.0.0.1:" & $int(port) & "/"
  )
  var options = defaultRequestOptions()
  options.maxResponseBytes = 10

  try:
    discard await client.get("no-content-length", options = options)
  except JoubakoError as error:
    await serving
    return error.kind
  raise newException(AssertionDefect, "request should have exceeded its limit")

proc exerciseChunkedBodyLimit(): Future[ErrorKind] {.async.} =
  let server = newAsyncSocket(buffered = false)
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(Port(0), "127.0.0.1")
  server.listen()
  defer:
    server.close()

  let (_, port) = server.getLocalAddr()
  let serving = serveChunkedBody(server, @["12345678", "abcdefgh"])
  let client = newClient(
    newHttpTransport(),
    "http://127.0.0.1:" & $int(port) & "/"
  )
  var options = defaultRequestOptions()
  options.maxResponseBytes = 10

  try:
    discard await client.get("chunked", options = options)
  except JoubakoError as error:
    await serving
    return error.kind
  raise newException(AssertionDefect, "request should have exceeded its limit")

suite "Joubako HTTP transport":
  when defined(ssl):
    test "custom TLS trust is initialized only for HTTPS origins":
      let server = newAsyncSocket(buffered = false)
      server.setSockOpt(OptReuseAddr, true)
      server.bindAddr(Port(0), "127.0.0.1")
      server.listen()
      let (_, port) = server.getLocalAddr()
      let serving = serveOne(server)
      var tls = defaultTlsOptions()
      tls.caFile = "/definitely/missing/joubako-ca.pem"
      let client = newClient(newHttpTransport(tlsOptions = tls))
      let response = waitFor client.get(
        "http://127.0.0.1:" & $int(port) & "/"
      )
      check response.status == 200
      waitFor serving
      server.close()

    test "invalid custom TLS trust becomes a structured transport error":
      var tls = defaultTlsOptions()
      tls.caFile = "/definitely/missing/joubako-ca.pem"
      let client = newClient(newHttpTransport(tlsOptions = tls))
      try:
        discard waitFor client.get("https://127.0.0.1:1/")
        fail()
      except JoubakoError as error:
        check error.kind == jeTransport

  test "performs and decodes a real HTTP request":
    waitFor exerciseHttpTransport()

  test "sequential requests reuse one keep-alive connection":
    waitFor exerciseConnectionReuse()

  test "active cancellation interrupts an HTTP request":
    check waitFor(exerciseActiveCancellation()) == jeCancelled

  test "the total deadline includes response body reading":
    check waitFor(exerciseBodyDeadline()) == jeTimeout

  test "declared oversized bodies are rejected before buffering":
    check waitFor(exerciseDeclaredBodyLimit()) == jeBodyTooLarge

  test "close-delimited bodies are limited while streaming":
    check waitFor(exerciseCloseDelimitedBodyLimit()) == jeBodyTooLarge

  test "chunked bodies are limited while streaming":
    check waitFor(exerciseChunkedBodyLimit()) == jeBodyTooLarge

  test "gzip responses are decoded before delivery":
    let body = "compressed HTTP response\0body"
    let encoded = body.gzipForTest
    let response = waitFor requestRaw(
      "HTTP/1.1 200 OK\r\n" &
      "Content-Encoding: gzip\r\n" &
      "Content-Length: " & $encoded.len & "\r\n" &
      "Connection: close\r\n\r\n" & encoded
    )
    check response.body == body
    check not response.headers.contains("content-encoding")
    check not response.headers.contains("content-length")

  test "the response limit applies to decompressed bytes":
    let body = repeat('A', 128 * 1024)
    let encoded = body.gzipForTest
    var options = defaultRequestOptions()
    options.maxResponseBytes = 1024
    try:
      discard waitFor requestRaw(
        "HTTP/1.1 200 OK\r\n" &
        "Content-Encoding: gzip\r\n" &
        "Content-Length: " & $encoded.len & "\r\n" &
        "Connection: close\r\n\r\n" & encoded,
        options
      )
      fail()
    except JoubakoError as error:
      check error.kind == jeBodyTooLarge

  test "stream consumers receive decoded chunks with decoded progress":
    let body = repeat("decoded-stream-", 3000)
    let encoded = body.gzipForTest
    var delivered: string
    var progress = (-1'i64, 0'i64)
    var options = defaultRequestOptions()
    options.streamResponse = true
    options.onDownloadChunk = proc(chunk: string) = delivered.add chunk
    options.onDownloadProgress =
      proc(transferred, total: int64) = progress = (transferred, total)
    let response = waitFor requestRaw(
      "HTTP/1.1 200 OK\r\n" &
      "Content-Encoding: gzip\r\n" &
      "Content-Length: " & $encoded.len & "\r\n" &
      "Connection: close\r\n\r\n" & encoded,
      options
    )
    check response.body == ""
    check delivered == body
    check progress == (int64(body.len), -1'i64)

  test "corrupt compressed HTTP bodies are structured errors":
    var encoded = gzipForTest("broken checksum")
    encoded[^5] = char(uint8(encoded[^5]) xor 0xff'u8)
    try:
      discard waitFor requestRaw(
        "HTTP/1.1 200 OK\r\n" &
        "Content-Encoding: gzip\r\n" &
        "Content-Length: " & $encoded.len & "\r\n" &
        "Connection: close\r\n\r\n" & encoded
      )
      fail()
    except JoubakoError as error:
      check error.kind == jeCompression

  test "HTTP requests advertise supported response encodings":
    let server = newAsyncSocket(buffered = false)
    server.setSockOpt(OptReuseAddr, true)
    server.bindAddr(Port(0), "127.0.0.1")
    server.listen()
    let (_, port) = server.getLocalAddr()
    let captured = newFuture[CapturedRequest]("test_http.acceptEncoding")
    let serving = captureRequest(server, captured)
    let client = newClient(newHttpTransport())
    discard waitFor client.get("http://127.0.0.1:" & $int(port) & "/")
    waitFor serving
    check "accept-encoding: gzip, deflate" in
      captured.read.headers.toLowerAscii
    server.close()

  test "caller-supplied Accept-Encoding is not overwritten":
    let server = newAsyncSocket(buffered = false)
    server.setSockOpt(OptReuseAddr, true)
    server.bindAddr(Port(0), "127.0.0.1")
    server.listen()
    let (_, port) = server.getLocalAddr()
    let captured = newFuture[CapturedRequest]("test_http.customEncoding")
    let serving = captureRequest(server, captured)
    let client = newClient(newHttpTransport())
    var headers = initHeaders()
    headers.set("accept-encoding", "identity")
    discard waitFor client.get(
      "http://127.0.0.1:" & $int(port) & "/",
      headers
    )
    waitFor serving
    check "accept-encoding: identity" in captured.read.headers.toLowerAscii
    check "accept-encoding: gzip, deflate" notin
      captured.read.headers.toLowerAscii
    server.close()

  test "HEAD metadata is not treated as a compressed response body":
    let response = waitFor requestRaw(
      "HTTP/1.1 200 OK\r\n" &
      "Content-Encoding: gzip\r\n" &
      "Content-Length: 123\r\n" &
      "Connection: close\r\n\r\n",
      httpMethod = rmHead
    )
    check response.body == ""
    check response.headers.get("content-encoding") == "gzip"
    check response.headers.get("content-length") == "123"

  test "a body exactly at the configured limit is accepted":
    var options = defaultRequestOptions()
    options.maxResponseBytes = 4
    let response = waitFor requestRaw(
      "HTTP/1.1 200 OK\r\n" &
      "Content-Length: 4\r\n" &
      "Connection: close\r\n\r\n" &
      "1234",
      options
    )
    check response.body == "1234"

  test "a valid chunked response is reconstructed":
    let response = waitFor requestRaw(
      "HTTP/1.1 200 OK\r\n" &
      "Transfer-Encoding: chunked\r\n" &
      "Connection: close\r\n\r\n" &
      "3\r\nabc\r\n" &
      "2\r\nde\r\n" &
      "0\r\n\r\n"
    )
    check response.body == "abcde"

  test "binary NUL bytes are preserved":
    let body = "a\0b"
    let response = waitFor requestRaw(
      "HTTP/1.1 200 OK\r\n" &
      "Content-Length: 3\r\n" &
      "Connection: close\r\n\r\n" &
      body
    )
    check response.body == body

  test "repeated response headers are preserved":
    let response = waitFor requestRaw(
      "HTTP/1.1 200 OK\r\n" &
      "Set-Cookie: a=1\r\n" &
      "Set-Cookie: b=2\r\n" &
      "Content-Length: 0\r\n" &
      "Connection: close\r\n\r\n"
    )
    check response.headers.getAll("set-cookie") == @["a=1", "b=2"]

  test "204 responses complete with an empty body":
    let response = waitFor requestRaw(
      "HTTP/1.1 204 No Content\r\n" &
      "Connection: close\r\n\r\n"
    )
    check response.status == 204
    check response.body == ""

  test "HEAD responses complete without reading a body":
    let response = waitFor requestRaw(
      "HTTP/1.1 200 OK\r\n" &
      "Content-Length: 12\r\n" &
      "Connection: close\r\n\r\n",
      httpMethod = rmHead
    )
    check response.status == 200
    check response.body == ""

  test "HTTP 1.0 close-delimited bodies are read":
    let response = waitFor requestRaw(
      "HTTP/1.0 200 OK\r\n" &
      "Content-Type: text/plain\r\n\r\n" &
      "legacy"
    )
    check response.body == "legacy"

  test "invalid Content-Length becomes a transport error":
    try:
      discard waitFor requestRaw(
        "HTTP/1.1 200 OK\r\n" &
        "Content-Length: invalid\r\n" &
        "Connection: close\r\n\r\n"
      )
      fail()
    except JoubakoError as error:
      check error.kind == jeTransport

  test "premature body disconnect becomes a transport error":
    try:
      discard waitFor requestRaw(
        "HTTP/1.1 200 OK\r\n" &
        "Content-Length: 10\r\n" &
        "Connection: close\r\n\r\n" &
        "short"
      )
      fail()
    except JoubakoError as error:
      check error.kind == jeTransport

  test "malformed status lines become transport errors":
    try:
      discard waitFor requestRaw(
        "NOT-HTTP 200 OK\r\n" &
        "Content-Length: 0\r\n\r\n"
      )
      fail()
    except JoubakoError as error:
      check error.kind == jeTransport

  test "headers without a colon become transport errors":
    try:
      discard waitFor requestRaw(
        "HTTP/1.1 200 OK\r\n" &
        "Broken Header\r\n\r\n"
      )
      fail()
    except JoubakoError as error:
      check error.kind == jeTransport

  test "invalid chunk sizes become transport errors":
    try:
      discard waitFor requestRaw(
        "HTTP/1.1 200 OK\r\n" &
        "Transfer-Encoding: chunked\r\n" &
        "Connection: close\r\n\r\n" &
        "xyz\r\nbad\r\n"
      )
      fail()
    except JoubakoError as error:
      check error.kind == jeTransport

  test "disconnect before a status line becomes a transport error":
    try:
      discard waitFor requestRaw("")
      fail()
    except JoubakoError as error:
      check error.kind == jeTransport

  test "the total deadline includes waiting for response headers":
    check waitFor(exerciseHeaderDeadline()) == jeTimeout

  test "cross-origin redirects strip authorization":
    check waitFor(exerciseCrossOriginRedirect()) == ""

  test "same-origin redirects preserve authorization":
    check waitFor(exerciseSameOriginRedirect()) == "Bearer same-origin"

  test "read timeout is independent from the total deadline":
    let server = newAsyncSocket(buffered = false)
    server.setSockOpt(OptReuseAddr, true)
    server.bindAddr(Port(0), "127.0.0.1")
    server.listen()
    let (_, port) = server.getLocalAddr()
    let serving = serveHeadersThenWait(server, 10)
    let client = newClient(
      newHttpTransport(),
      "http://127.0.0.1:" & $int(port) & "/"
    )
    var options = defaultRequestOptions()
    options.timeoutMs = 2_000
    options.readTimeoutMs = 20
    try:
      discard waitFor client.get("slow", options = options)
      fail()
    except JoubakoError as error:
      check error.kind == jeTimeout
      check "body read" in error.msg
    waitFor serving
    server.close()

  test "streaming callbacks can consume a body without buffering it":
    var chunks: seq[string]
    var progress: seq[int64]
    var options = defaultRequestOptions()
    options.streamResponse = true
    options.onDownloadChunk =
      proc(chunk: string) = chunks.add chunk
    options.onDownloadProgress =
      proc(received, total: int64) =
        discard total
        progress.add received
    let response = waitFor requestRaw(
      "HTTP/1.1 200 OK\r\n" &
      "Content-Length: 6\r\n" &
      "Connection: close\r\n\r\nabcdef",
      options
    )
    check response.body == ""
    check chunks.join == "abcdef"
    check progress.len > 0
    check progress[^1] == 6

  test "asynchronous chunk consumers apply backpressure in order":
    let server = newAsyncSocket(buffered = false)
    server.setSockOpt(OptReuseAddr, true)
    server.bindAddr(Port(0), "127.0.0.1")
    server.listen()
    let (_, port) = server.getLocalAddr()
    let serving = serveChunkedBody(server, @["one", "two", "three"])
    let client = newClient(newHttpTransport())
    var events: seq[string]
    var options = defaultRequestOptions()
    options.streamResponse = true
    options.onDownloadChunkAsync =
      proc(chunk: string): Future[void] {.async.} =
        events.add("start:" & chunk)
        await sleepAsync(1)
        events.add("end:" & chunk)
    let response = waitFor client.get(
      "http://127.0.0.1:" & $int(port) & "/",
      options = options
    )
    waitFor serving
    check response.body == ""
    check events == @[
      "start:one", "end:one",
      "start:two", "end:two",
      "start:three", "end:three"
    ]
    server.close()

  test "the total deadline includes asynchronous chunk consumers":
    let server = newAsyncSocket(buffered = false)
    server.setSockOpt(OptReuseAddr, true)
    server.bindAddr(Port(0), "127.0.0.1")
    server.listen()
    let (_, port) = server.getLocalAddr()
    let serving = serveChunkedBody(server, @["data"])
    let client = newClient(newHttpTransport())
    var options = defaultRequestOptions()
    options.timeoutMs = 20
    options.onDownloadChunkAsync =
      proc(_: string): Future[void] {.async.} =
        await sleepAsync(200)
    try:
      discard waitFor client.get(
        "http://127.0.0.1:" & $int(port) & "/",
        options = options
      )
      fail()
    except JoubakoError as error:
      check error.kind == jeTimeout
      check "delivering the response" in error.msg
    waitFor serving
    server.close()

  test "asynchronous consumer failures are structured stream errors":
    let server = newAsyncSocket(buffered = false)
    server.setSockOpt(OptReuseAddr, true)
    server.bindAddr(Port(0), "127.0.0.1")
    server.listen()
    let (_, port) = server.getLocalAddr()
    let serving = serveChunkedBody(server, @["data"])
    let client = newClient(newHttpTransport())
    var options = defaultRequestOptions()
    options.onDownloadChunkAsync =
      proc(_: string): Future[void] {.async.} =
        raise newException(IOError, "consumer failed")
    try:
      discard waitFor client.get(
        "http://127.0.0.1:" & $int(port) & "/",
        options = options
      )
      fail()
    except JoubakoError as error:
      check error.kind == jeStream
    waitFor serving
    server.close()

  test "downloadToFile streams without retaining the response body":
    let server = newAsyncSocket(buffered = false)
    server.setSockOpt(OptReuseAddr, true)
    server.bindAddr(Port(0), "127.0.0.1")
    server.listen()
    let (_, port) = server.getLocalAddr()
    let serving = serveChunkedBody(server, @["binary\0", "payload"])
    let client = newClient(newHttpTransport())
    let outputPath = getTempDir() /
      ("joubako-download-" & $getCurrentProcessId() & ".bin")
    defer:
      if fileExists(outputPath):
        removeFile(outputPath)
    let response = waitFor client.downloadToFile(
      "http://127.0.0.1:" & $int(port) & "/",
      outputPath
    )
    waitFor serving
    check response.body == ""
    check readFile(outputPath) == "binary\0payload"
    server.close()

  test "resumeDownloadToFile interoperates with a real Range response":
    let server = newAsyncSocket(buffered = false)
    server.setSockOpt(OptReuseAddr, true)
    server.bindAddr(Port(0), "127.0.0.1")
    server.listen()
    let (_, port) = server.getLocalAddr()
    let captured = newFuture[string]("test_http.rangeRequest")
    let serving = serveRangeResponse(server, captured)
    let outputPath = getTempDir() /
      ("joubako-resume-" & $getCurrentProcessId() & ".bin")
    writeFile(outputPath, "partial")
    defer:
      if fileExists(outputPath): removeFile(outputPath)
    let client = newClient(newHttpTransport())
    discard waitFor client.resumeDownloadToFile(
      "http://127.0.0.1:" & $int(port) & "/asset",
      outputPath,
      "\"asset-v3\""
    )
    waitFor serving
    check readFile(outputPath) == "partial-tail"
    let request = captured.read.toLowerAscii
    check "range: bytes=7-" in request
    check "if-range: \"asset-v3\"" in request
    check "accept-encoding: identity" in request
    server.close()

  test "303 redirects rewrite POST to GET and remove body headers":
    let captured = waitFor exerciseRedirectMethod(303, "payload")
    check captured.requestLine.startsWith("GET /target ")
    check captured.body == ""
    check "content-type:" notin captured.headers.toLowerAscii
    check "content-length:" notin captured.headers.toLowerAscii

  test "307 redirects preserve POST method and body":
    let captured = waitFor exerciseRedirectMethod(307, "payload")
    check captured.requestLine.startsWith("POST /target ")
    check captured.body == "payload"
    check "content-type: text/plain" in captured.headers.toLowerAscii

  test "redirect Set-Cookie fields apply to the next hop":
    let captured = waitFor exerciseRedirectCookie()
    check "cookie: session=redirected" in captured.headers.toLowerAscii

  test "explicit Cookie headers override the configured jar":
    let captured = waitFor exerciseExplicitCookie()
    let lowered = captured.headers.toLowerAscii
    check "cookie: session=explicit" in lowered
    check "cookie: session=jar" notin lowered

  test "redirects disabled return a structured status error":
    let server = newAsyncSocket(buffered = false)
    server.setSockOpt(OptReuseAddr, true)
    server.bindAddr(Port(0), "127.0.0.1")
    server.listen()
    let (_, port) = server.getLocalAddr()
    let serving = serveRedirect(server, "/target")
    let client = newClient(newHttpTransport(maxRedirects = 0))
    try:
      discard waitFor client.get(
        "http://127.0.0.1:" & $int(port) & "/start"
      )
      fail()
    except JoubakoError as error:
      check error.kind == jeHttpStatus
      check error.status == 302
    waitFor serving
    server.close()

  test "redirect targets are checked against the host allowlist":
    let server = newAsyncSocket(buffered = false)
    server.setSockOpt(OptReuseAddr, true)
    server.bindAddr(Port(0), "127.0.0.1")
    server.listen()
    let (_, port) = server.getLocalAddr()
    let serving = serveRedirect(
      server, "http://localhost:" & $int(port) & "/target"
    )
    let client = newClient(newHttpTransport())
    var options = defaultRequestOptions()
    options.allowedHosts = @["127.0.0.1"]
    try:
      discard waitFor client.get(
        "http://127.0.0.1:" & $int(port) & "/start",
        options = options
      )
      fail()
    except JoubakoError as error:
      check error.kind == jeInvalidRequest
      check "allowlist" in error.msg
    waitFor serving
    server.close()

  test "connection/header timeout is independent from total timeout":
    let server = newAsyncSocket(buffered = false)
    server.setSockOpt(OptReuseAddr, true)
    server.bindAddr(Port(0), "127.0.0.1")
    server.listen()
    let (_, port) = server.getLocalAddr()
    let accepted = newFuture[void]("test_http.connectTimeout")
    let serving = acceptUntilClosed(server, accepted)
    let client = newClient(newHttpTransport())
    var options = defaultRequestOptions()
    options.timeoutMs = 2_000
    options.connectTimeoutMs = 20
    let pending = client.get(
      "http://127.0.0.1:" & $int(port) & "/", options = options
    )
    waitFor accepted
    try:
      discard waitFor pending
      fail()
    except JoubakoError as error:
      check error.kind == jeTimeout
      check "headers" in error.msg
    waitFor serving
    server.close()

  test "upload and download progress report final byte counts":
    var uploaded = (-1'i64, -1'i64)
    var downloaded = (-1'i64, -1'i64)
    let server = newAsyncSocket(buffered = false)
    server.setSockOpt(OptReuseAddr, true)
    server.bindAddr(Port(0), "127.0.0.1")
    server.listen()
    let (_, port) = server.getLocalAddr()
    let captured = newFuture[CapturedRequest]("test_http.progressCapture")
    let serving = captureRequest(server, captured, "reply")
    let client = newClient(newHttpTransport())
    var options = defaultRequestOptions()
    options.onUploadProgress =
      proc(transferred, total: int64) = uploaded = (transferred, total)
    options.onDownloadProgress =
      proc(transferred, total: int64) = downloaded = (transferred, total)
    discard waitFor client.post(
      "http://127.0.0.1:" & $int(port) & "/",
      "request",
      options = options
    )
    waitFor serving
    check captured.read.body == "request"
    check uploaded == (7'i64, 7'i64)
    check downloaded == (5'i64, 5'i64)
    server.close()

  test "file-backed multipart streams files with generated boundaries":
    let server = newAsyncSocket(buffered = false)
    server.setSockOpt(OptReuseAddr, true)
    server.bindAddr(Port(0), "127.0.0.1")
    server.listen()
    let (_, port) = server.getLocalAddr()
    let captured = newFuture[CapturedRequest]("test_http.multipartFile")
    let serving = captureRequest(server, captured, "uploaded")
    let sourcePath = getTempDir() /
      ("joubako-upload-" & $getCurrentProcessId() & ".bin")
    defer:
      if fileExists(sourcePath):
        removeFile(sourcePath)
    writeFile(sourcePath, "binary\0payload")
    var uploaded = (-1'i64, -1'i64)
    var options = defaultRequestOptions()
    options.onUploadProgress =
      proc(done, total: int64) = uploaded = (done, total)
    let client = newClient(newHttpTransport())
    let response = waitFor client.postMultipart(
      "http://127.0.0.1:" & $int(port) & "/upload",
      [
        formField("title", "report"),
        formFilePath(
          "document",
          sourcePath,
          filename = "report.bin",
          contentType = "application/octet-stream"
        )
      ],
      options = options
    )
    waitFor serving
    let request = captured.read
    check response.body == "uploaded"
    check request.requestLine.startsWith("POST /upload ")
    check "content-type: multipart/form-data; boundary=" in
      request.headers.toLowerAscii
    check "name=\"title\"" in request.body
    check "report" in request.body
    check "name=\"document\"; filename=\"report.bin\"" in request.body
    check "binary\0payload" in request.body
    check uploaded == (int64(request.body.len), int64(request.body.len))
    server.close()

  test "multipart framing headers do not leak into the next request":
    let server = newAsyncSocket(buffered = false)
    server.setSockOpt(OptReuseAddr, true)
    server.bindAddr(Port(0), "127.0.0.1")
    server.listen()
    let (_, port) = server.getLocalAddr()
    let first = newFuture[CapturedRequest]("test_http.multipartHeaderFirst")
    let second = newFuture[CapturedRequest]("test_http.multipartHeaderSecond")
    let serving = captureRequestPair(server, first, second)
    let sourcePath = getTempDir() /
      ("joubako-upload-header-state-" & $getCurrentProcessId() & ".bin")
    defer:
      if fileExists(sourcePath):
        removeFile(sourcePath)
    writeFile(sourcePath, "data")
    let transport = newHttpTransport(maxIdleConnections = 1)
    let client = newClient(
      transport,
      "http://127.0.0.1:" & $int(port) & "/"
    )
    discard waitFor client.postMultipart(
      "upload", [formFilePath("file", sourcePath)]
    )
    discard waitFor client.get("ordinary")
    waitFor serving
    check "content-type: multipart/form-data" in
      first.read.headers.toLowerAscii
    check "content-type:" notin second.read.headers.toLowerAscii
    check second.read.requestLine.startsWith("GET /ordinary ")
    transport.closeIdleConnections()
    server.close()

  test "streamed multipart enforces the complete wire-size limit":
    let sourcePath = getTempDir() /
      ("joubako-upload-limit-" & $getCurrentProcessId() & ".bin")
    defer:
      if fileExists(sourcePath):
        removeFile(sourcePath)
    writeFile(sourcePath, "12345678")
    var options = defaultRequestOptions()
    options.maxRequestBytes = 8
    let client = newClient(newHttpTransport())
    try:
      discard waitFor client.postMultipart(
        "http://127.0.0.1:1/upload",
        [formFilePath("file", sourcePath)],
        options = options
      )
      fail()
    except JoubakoError as error:
      check error.kind == jeBodyTooLarge

  test "streamed multipart enforces a file-part preflight limit":
    let sourcePath = getTempDir() /
      ("joubako-upload-part-limit-" & $getCurrentProcessId() & ".bin")
    defer:
      if fileExists(sourcePath):
        removeFile(sourcePath)
    writeFile(sourcePath, "12345678")
    var file = formFilePath("file", sourcePath)
    file.maxBytes = 7
    let client = newClient(newHttpTransport())
    try:
      discard waitFor client.postMultipart(
        "http://127.0.0.1:1/upload", [file]
      )
      fail()
    except JoubakoError as error:
      check error.kind == jeBodyTooLarge

  test "missing streamed multipart files are structured stream errors":
    let client = newClient(newHttpTransport())
    try:
      discard waitFor client.postMultipart(
        "http://127.0.0.1:1/upload",
        [formFilePath("file", "/tmp/joubako-file-does-not-exist")]
      )
      fail()
    except JoubakoError as error:
      check error.kind == jeStream

  test "streamed multipart rejects caller-supplied content types":
    let sourcePath = getTempDir() /
      ("joubako-upload-content-type-" & $getCurrentProcessId() & ".bin")
    defer:
      if fileExists(sourcePath):
        removeFile(sourcePath)
    writeFile(sourcePath, "data")
    var headers = initHeaders()
    headers.set("content-type", "multipart/form-data; boundary=forged")
    let client = newClient(newHttpTransport())
    try:
      discard waitFor client.postMultipart(
        "http://127.0.0.1:1/upload",
        [formFilePath("file", sourcePath)],
        headers
      )
      fail()
    except JoubakoError as error:
      check error.kind == jeInvalidRequest

  test "the configured HTTP proxy receives the absolute request URL":
    let proxyServer = newAsyncSocket(buffered = false)
    proxyServer.setSockOpt(OptReuseAddr, true)
    proxyServer.bindAddr(Port(0), "127.0.0.1")
    proxyServer.listen()
    let (_, proxyPort) = proxyServer.getLocalAddr()
    let captured = newFuture[CapturedRequest]("test_http.proxyCapture")
    let serving = captureRequest(proxyServer, captured)
    let proxy = newProxy("http://127.0.0.1:" & $int(proxyPort))
    let client = newClient(newHttpTransport(proxy = proxy))
    discard waitFor client.get("http://upstream.invalid/resource?q=1")
    waitFor serving
    check captured.read.requestLine.startsWith(
      "GET http://upstream.invalid/resource?q=1 "
    )
    proxyServer.close()

  test "ProxyOptions supplies proxy authentication from its URL":
    let proxyServer = newAsyncSocket(buffered = false)
    proxyServer.setSockOpt(OptReuseAddr, true)
    proxyServer.bindAddr(Port(0), "127.0.0.1")
    proxyServer.listen()
    let (_, proxyPort) = proxyServer.getLocalAddr()
    let captured = newFuture[CapturedRequest]("test_http.proxyOptionsCapture")
    let serving = captureRequest(proxyServer, captured)
    let options = ProxyOptions(
      httpProxy: "http://proxy-user:proxy-pass@127.0.0.1:" & $int(proxyPort)
    )
    let client = newClient(newHttpTransport(proxyOptions = options))
    discard waitFor client.get("http://upstream.invalid/private")
    waitFor serving
    let request = captured.read
    check request.requestLine.startsWith(
      "GET http://upstream.invalid/private "
    )
    check "proxy-authorization: basic chjvehktdxnlcjpwcm94es1wyxnz" in
      request.headers.toLowerAscii
    proxyServer.close()

  test "cross-origin redirects strip every sensitive header":
    let captured = waitFor exerciseCrossOriginSensitiveHeaders()
    let lowered = captured.headers.toLowerAscii
    check "authorization:" notin lowered
    check "cookie:" notin lowered
    check "proxy-authorization:" notin lowered
    check "host: forged.invalid" notin lowered
    check "host: 127.0.0.1:" in lowered

  test "redirect responses without Location are returned for validation":
    try:
      discard waitFor requestRaw(
        "HTTP/1.1 302 Found\r\n" &
        "Content-Length: 0\r\n" &
        "Connection: close\r\n\r\n"
      )
      fail()
    except JoubakoError as error:
      check error.kind == jeHttpStatus
      check error.status == 302

  test "HTTP status errors retain bounded wire response metadata":
    try:
      discard waitFor requestRaw(
        "HTTP/1.1 418 Deliberate Failure\r\n" &
        "Content-Type: application/problem+json\r\n" &
        "X-Trace: first\r\n" &
        "X-Trace: second\r\n" &
        "Content-Length: 15\r\n" &
        "Connection: close\r\n\r\n" &
        "failure\0payload"
      )
      fail()
    except JoubakoError as error:
      check error.kind == jeHttpStatus
      check error.status == 418
      check error.hasResponse
      check error.response.status == 418
      check error.response.statusText == "Deliberate Failure"
      check error.response.headers.get("content-type") ==
        "application/problem+json"
      check error.response.headers.getAll("x-trace") == @[
        "first", "second"
      ]
      check error.response.body == "failure\0payload"
      check error.attempts == 1

  test "streaming limits reject before delivering an overflowing chunk":
    let server = newAsyncSocket(buffered = false)
    server.setSockOpt(OptReuseAddr, true)
    server.bindAddr(Port(0), "127.0.0.1")
    server.listen()
    let (_, port) = server.getLocalAddr()
    let serving = serveChunkedBody(server, @["1234", "56"])
    let client = newClient(newHttpTransport())
    var delivered = ""
    var options = defaultRequestOptions()
    options.maxResponseBytes = 4
    options.streamResponse = true
    options.onDownloadChunk = proc(chunk: string) = delivered.add chunk
    try:
      discard waitFor client.get(
        "http://127.0.0.1:" & $int(port) & "/",
        options = options
      )
      fail()
    except JoubakoError as error:
      check error.kind == jeBodyTooLarge
    waitFor serving
    check delivered == "1234"
    server.close()

  test "close-delimited progress reports an unknown total":
    let server = newAsyncSocket(buffered = false)
    server.setSockOpt(OptReuseAddr, true)
    server.bindAddr(Port(0), "127.0.0.1")
    server.listen()
    let (_, port) = server.getLocalAddr()
    let serving = serveCloseDelimitedBody(server, "legacy")
    let client = newClient(newHttpTransport())
    var finalProgress = (-1'i64, 0'i64)
    var options = defaultRequestOptions()
    options.onDownloadProgress =
      proc(done, total: int64) = finalProgress = (done, total)
    discard waitFor client.get(
      "http://127.0.0.1:" & $int(port) & "/",
      options = options
    )
    waitFor serving
    check finalProgress == (6'i64, -1'i64)
    server.close()
