import std/[asyncdispatch, asyncnet, net, strutils]
import joubako/cabi

const
  OwnershipCycles = 80
  NetworkRequests = 8

proc receiveHeaders(socket: AsyncSocket): Future[bool] {.async.} =
  var request = ""
  while "\r\n\r\n" notin request:
    let chunk = await socket.recv(4096)
    if chunk.len == 0:
      return false
    request.add chunk
  true

proc serve(server: AsyncSocket): Future[void] {.async.} =
  let socket = await server.accept()
  try:
    for _ in 0 ..< NetworkRequests:
      doAssert await socket.receiveHeaders()
      let body = "{\"ok\":true}"
      await socket.send(
        "HTTP/1.1 200 OK\r\n" &
        "Content-Type: application/json\r\n" &
        "Content-Length: " & $body.len & "\r\n" &
        "Connection: keep-alive\r\n\r\n" & body
      )
  finally:
    socket.close()

let server = newAsyncSocket(buffered = false)
server.setSockOpt(OptReuseAddr, true)
server.bindAddr(Port(0), "127.0.0.1")
server.listen()
let (_, port) = server.getLocalAddr()
let serving = server.serve()

# Exercise client and validation-response ownership without starting network
# timers for every client. Transport timers are covered below by repeated real
# requests through one long-lived client.
for _ in 0 ..< OwnershipCycles:
  var clientHandle: pointer
  doAssert joubako_client_create(
    ("http://127.0.0.1:" & $int(port) & "/").cstring,
    addr clientHandle
  ) == 0
  doAssert clientHandle != nil
  var responseHandle: pointer
  doAssert joubako_request_json(
    clientHandle, "POST", "health", "{broken", addr responseHandle
  ) == 16
  doAssert responseHandle != nil
  joubako_response_free(responseHandle)
  joubako_client_free(clientHandle)

var clientHandle: pointer
doAssert joubako_client_create(
  ("http://127.0.0.1:" & $int(port) & "/").cstring,
  addr clientHandle
) == 0
doAssert joubako_client_set_max_response_bytes(clientHandle, 1_024) == 0
for _ in 0 ..< NetworkRequests:
  var responseHandle: pointer
  doAssert joubako_request_json(
    clientHandle, "GET", "health", nil, addr responseHandle
  ) == 0
  doAssert responseHandle != nil
  doAssert joubako_response_status(responseHandle) == 200
  doAssert $joubako_response_body(responseHandle) == "{\"ok\":true}"
  joubako_response_free(responseHandle)
joubako_client_free(clientHandle)

waitFor serving
server.close()
