import std/[asyncdispatch, asyncnet, strutils, unittest]
import joubako/cabi

proc serveJson(
    server: AsyncSocket;
    status: int;
    body: string
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
  let reason = if status == 200: "OK" else: "Unprocessable Entity"
  await socket.send(
    "HTTP/1.1 " & $status & " " & reason & "\r\n" &
    "Content-Type: application/json\r\n" &
    "Content-Length: " & $body.len & "\r\n" &
    "Connection: close\r\n\r\n" & body
  )

proc newServer(): tuple[server: AsyncSocket, baseUrl: string] =
  result.server = newAsyncSocket(buffered = false)
  result.server.setSockOpt(OptReuseAddr, true)
  result.server.bindAddr(Port(0), "127.0.0.1")
  result.server.listen()
  let (_, port) = result.server.getLocalAddr()
  result.baseUrl = "http://127.0.0.1:" & $int(port) & "/"

suite "Joubako C ABI":
  test "reports the stable ABI version":
    check joubako_abi_version() == JoubakoAbiVersion

  test "rejects invalid pointers without crossing the ABI with an exception":
    var clientHandle = cast[pointer](1)
    check joubako_client_create(nil, addr clientHandle) == 1
    check clientHandle == nil
    check joubako_client_create(nil, nil) == 1
    check joubako_client_set_header(nil, "x-test", "value") == 1
    check joubako_client_set_timeout_ms(nil, 100) == 1
    check joubako_client_set_max_response_bytes(nil, 100) == 1
    check joubako_request_json(nil, "GET", "/", nil, nil) == 1
    check joubako_response_error_code(nil) == 1
    check joubako_response_status(nil) == 0
    check joubako_response_body(nil) == nil
    check joubako_response_body_size(nil) == 0
    check joubako_response_error_message(nil) == nil
    check joubako_response_error_message_size(nil) == 0
    joubako_client_free(nil)
    joubako_response_free(nil)

  test "owns clients and structured validation errors explicitly":
    var clientHandle: pointer
    check joubako_client_create("http://127.0.0.1/", addr clientHandle) == 0
    check clientHandle != nil
    check joubako_client_set_timeout_ms(clientHandle, -2) == 1
    check joubako_client_set_timeout_ms(clientHandle, 500) == 0
    check joubako_client_set_max_response_bytes(clientHandle, -2) == 1
    check joubako_client_set_max_response_bytes(clientHandle, 4096) == 0
    check joubako_client_set_header(
      clientHandle, "x-joubako-test", "c-abi"
    ) == 0
    check joubako_client_set_header(clientHandle, nil, "value") == 1
    check joubako_client_set_header(clientHandle, "x-test", nil) == 1
    check joubako_request_json(
      clientHandle, "GET", "/", nil, nil
    ) == 1

    var responseHandle: pointer
    check joubako_request_json(
      clientHandle, "POST", "/", "{broken", addr responseHandle
    ) == 16
    check responseHandle != nil
    check joubako_response_error_code(responseHandle) == 16
    check joubako_response_status(responseHandle) == 0
    check "invalid JSON request body" in
      $joubako_response_error_message(responseHandle)
    joubako_response_free(responseHandle)

    responseHandle = nil
    check joubako_request_json(
      clientHandle, "TRACE", "/", nil, addr responseHandle
    ) == 1
    check responseHandle != nil
    check joubako_response_error_code(responseHandle) == 1
    joubako_response_free(responseHandle)
    joubako_client_free(clientHandle)

  test "delivers a valid JSON response across the ABI":
    let fixture = newServer()
    defer:
      fixture.server.close()
    let serving = serveJson(fixture.server, 200, "{\"ok\":true}")
    var clientHandle, responseHandle: pointer
    check joubako_client_create(fixture.baseUrl.cstring, addr clientHandle) == 0
    check joubako_request_json(
      clientHandle, "get", "health", nil, addr responseHandle
    ) == 0
    check joubako_response_error_code(responseHandle) == 0
    check joubako_response_status(responseHandle) == 200
    check joubako_response_body_size(responseHandle) == 11
    check $joubako_response_body(responseHandle) == "{\"ok\":true}"
    check joubako_response_error_message_size(responseHandle) == 0
    joubako_response_free(responseHandle)
    joubako_client_free(clientHandle)
    waitFor serving

  test "enforces the configured response limit while reading":
    let fixture = newServer()
    defer:
      fixture.server.close()
    let serving = serveJson(fixture.server, 200, "{\"value\":\"large\"}")
    var clientHandle, responseHandle: pointer
    check joubako_client_create(fixture.baseUrl.cstring, addr clientHandle) == 0
    check joubako_client_set_max_response_bytes(clientHandle, 8) == 0
    check joubako_request_json(
      clientHandle, "GET", "bounded", nil, addr responseHandle
    ) == 15
    check responseHandle != nil
    check joubako_response_error_code(responseHandle) == 15
    check joubako_response_status(responseHandle) == 200
    check joubako_response_body_size(responseHandle) == 0
    joubako_response_free(responseHandle)
    joubako_client_free(clientHandle)
    waitFor serving

  test "retains bounded HTTP error JSON in the response handle":
    let fixture = newServer()
    defer:
      fixture.server.close()
    let serving = serveJson(
      fixture.server, 422, "{\"error\":\"invalid\"}"
    )
    var clientHandle, responseHandle: pointer
    check joubako_client_create(fixture.baseUrl.cstring, addr clientHandle) == 0
    check joubako_request_json(
      clientHandle,
      "POST",
      "messages",
      "{\"priority\":0}",
      addr responseHandle
    ) == 14
    check joubako_response_error_code(responseHandle) == 14
    check joubako_response_status(responseHandle) == 422
    check $joubako_response_body(responseHandle) ==
      "{\"error\":\"invalid\"}"
    check "status 422" in $joubako_response_error_message(responseHandle)
    joubako_response_free(responseHandle)
    joubako_client_free(clientHandle)
    waitFor serving

  test "rejects a non-JSON success response as a codec error":
    let fixture = newServer()
    defer:
      fixture.server.close()
    let serving = serveJson(fixture.server, 200, "not-json")
    var clientHandle, responseHandle: pointer
    check joubako_client_create(fixture.baseUrl.cstring, addr clientHandle) == 0
    check joubako_request_json(
      clientHandle, "GET", "invalid", nil, addr responseHandle
    ) == 16
    check joubako_response_error_code(responseHandle) == 16
    check joubako_response_status(responseHandle) == 200
    check $joubako_response_body(responseHandle) == "not-json"
    joubako_response_free(responseHandle)
    joubako_client_free(clientHandle)
    waitFor serving

  test "rejects a non-JSON HTTP error response as a codec error":
    let fixture = newServer()
    defer:
      fixture.server.close()
    let serving = serveJson(fixture.server, 422, "not-json")
    var clientHandle, responseHandle: pointer
    check joubako_client_create(fixture.baseUrl.cstring, addr clientHandle) == 0
    check joubako_request_json(
      clientHandle, "POST", "invalid", "{}", addr responseHandle
    ) == 16
    check joubako_response_error_code(responseHandle) == 16
    check joubako_response_status(responseHandle) == 422
    check $joubako_response_body(responseHandle) == "not-json"
    check "invalid JSON response body" in
      $joubako_response_error_message(responseHandle)
    joubako_response_free(responseHandle)
    joubako_client_free(clientHandle)
    waitFor serving
