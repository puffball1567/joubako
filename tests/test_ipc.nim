import std/[asyncdispatch, asyncnet, base64, json, nativesockets, os, strutils,
  unittest]
import joubako
import ./result_test_helpers

when defined(posix):
  type IpcProgressCapture = ref object
    chunk: string
    asyncChunk: string
    download: tuple[done, total: int64]
    upload: tuple[done, total: int64]

  proc ipcProgressOptions(capture: IpcProgressCapture): RequestOptions =
    result = defaultRequestOptions()
    result.streamResponse = true
    result.onDownloadChunk =
      proc(value: string) = capture.chunk.add value
    result.onDownloadChunkAsync =
      proc(value: string): Future[void] =
        capture.asyncChunk.add value
        result = newFuture[void]("test.ipcAsyncChunk")
        result.complete()
    result.onDownloadProgress =
      proc(done, total: int64) = capture.download = (done, total)
    result.onUploadProgress =
      proc(done, total: int64) = capture.upload = (done, total)

  proc socketPath(suffix: string): string =
    "/tmp/joubako-" & $getCurrentProcessId() & "-" & suffix & ".sock"

  proc serveOne(
      server: AsyncSocket;
      handler: proc(request: Request): Future[Response] {.closure.};
      maxRequestBytes = 16 * 1024 * 1024
  ): Future[void] {.async.} =
    let peer = await server.accept()
    await handleIpcConnection(peer, handler, maxRequestBytes)

  func frame(payload: string): string =
    let size = uint32(payload.len)
    result = newString(4)
    result[0] = char((size shr 24) and 0xff)
    result[1] = char((size shr 16) and 0xff)
    result[2] = char((size shr 8) and 0xff)
    result[3] = char(size and 0xff)
    result.add payload

  proc serveRaw(
      server: AsyncSocket;
      response: string
  ): Future[void] {.async.} =
    let peer = await server.accept()
    defer:
      peer.close()
    let prefix = await peer.recv(4)
    if prefix.len != 4:
      return
    let requestSize = int(
      (uint32(uint8(prefix[0])) shl 24) or
      (uint32(uint8(prefix[1])) shl 16) or
      (uint32(uint8(prefix[2])) shl 8) or
      uint32(uint8(prefix[3]))
    )
    let requestData = await peer.recv(requestSize)
    discard requestData
    await peer.send(response)

  proc serveUntilClientCloses(
      server: AsyncSocket;
      accepted: Future[void]
  ): Future[void] {.async.} =
    let peer = await server.accept()
    defer:
      peer.close()
    accepted.complete()
    while (await peer.recv(4096)).len > 0:
      discard

  proc rawResponse(body: string; status = 200): string =
    frame($( %*{
      "ok": true,
      "status": status,
      "statusText": "OK",
      "headers": newJArray(),
      "body": encode(body)
    }))

  proc withServer(
      path: string;
      handler: proc(request: Request): Future[Response] {.closure.};
      action: proc(client: Client): Future[void] {.closure.};
      maxRequestBytes = 16 * 1024 * 1024
  ): Future[void] {.async.} =
    if fileExists(path):
      removeFile(path)
    let server = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
    server.bindUnix(path)
    server.listen()
    defer:
      server.close()
      if fileExists(path):
        removeFile(path)
    let serving = serveOne(server, handler, maxRequestBytes)
    let client = newClient(newUnixIpcTransport(path))
    await action(client)
    await serving

  suite "Unix IPC transport":
    test "round trips method URL headers and binary bodies":
      let path = socketPath("roundtrip")
      let handler = proc(request: Request): Future[Response] {.async.} =
        check request.httpMethod == rmPost
        check request.url == "/ipc"
        check request.headers.get("x-test") == "yes"
        check request.body == "a\0b"
        var headers = initHeaders()
        headers.add("set-cookie", "a=1")
        headers.add("set-cookie", "b=2")
        return Response(
          status: 201,
          statusText: "Created",
          headers: headers,
          body: request.body & "!",
          request: request
        )
      let action = proc(client: Client): Future[void] {.async.} =
        var headers = initHeaders()
        headers.set("x-test", "yes")
        let response = await client.post("/ipc", "a\0b", headers)
        check response.status == 201
        check response.body == "a\0b!"
        check response.headers.getAll("set-cookie") == @["a=1", "b=2"]
      waitFor withServer(path, handler, action)

    test "peer handler failures become transport errors":
      let path = socketPath("failure")
      let handler = proc(request: Request): Future[Response] {.async.} =
        discard request
        raise newException(IOError, "peer exploded")
      let action = proc(client: Client): Future[void] {.async.} =
        try:
          discard await client.get("/ipc")
          fail()
        except JoubakoError as error:
          check error.kind == jeTransport
          check "peer exploded" in error.msg
      waitFor withServer(path, handler, action)

    test "request limits are enforced before connection":
      let client = newClient(newUnixIpcTransport(socketPath("unused")))
      var options = defaultRequestOptions()
      options.maxRequestBytes = 2
      try:
        discard waitFor client.post("/ipc", "abc", options = options)
        fail()
      except JoubakoError as error:
        check error.kind == jeBodyTooLarge

    test "empty socket paths are invalid":
      let client = newClient(newUnixIpcTransport(""))
      try:
        discard waitFor client.get("/ipc")
        fail()
      except JoubakoError as error:
        check error.kind == jeInvalidRequest

    test "missing peers become transport errors":
      let path = socketPath("missing")
      if fileExists(path):
        removeFile(path)
      let client = newClient(newUnixIpcTransport(path))
      try:
        discard waitFor client.get("/ipc")
        fail()
      except JoubakoError as error:
        check error.kind == jeTransport

    test "malformed response JSON becomes a transport error":
      let path = socketPath("bad-json")
      if fileExists(path):
        removeFile(path)
      let server = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
      server.bindUnix(path)
      server.listen()
      let serving = serveRaw(server, frame("{bad"))
      let client = newClient(newUnixIpcTransport(path))
      try:
        discard waitFor client.get("/ipc")
        fail()
      except JoubakoError as error:
        check error.kind == jeTransport
      waitFor serving
      server.close()
      if fileExists(path):
        removeFile(path)

    test "premature response frames become transport errors":
      let path = socketPath("short")
      if fileExists(path):
        removeFile(path)
      let server = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
      server.bindUnix(path)
      server.listen()
      let serving = serveRaw(server, "\0\0\0\x10short")
      let client = newClient(newUnixIpcTransport(path))
      try:
        discard waitFor client.get("/ipc")
        fail()
      except JoubakoError as error:
        check error.kind == jeTransport
      waitFor serving
      server.close()
      if fileExists(path):
        removeFile(path)

    test "oversized declared frames are rejected before their body":
      let path = socketPath("declared-large")
      if fileExists(path):
        removeFile(path)
      let server = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
      server.bindUnix(path)
      server.listen()
      let serving = serveRaw(server, "\0\x10\0\0")
      let client = newClient(newUnixIpcTransport(path))
      var options = defaultRequestOptions()
      options.maxResponseBytes = 4
      try:
        discard waitFor client.get("/ipc", options = options)
        fail()
      except JoubakoError as error:
        check error.kind == jeBodyTooLarge
      waitFor serving
      server.close()
      if fileExists(path):
        removeFile(path)

    test "response bodies exactly at the limit are accepted":
      let path = socketPath("exact-limit")
      if fileExists(path):
        removeFile(path)
      let server = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
      server.bindUnix(path)
      server.listen()
      let serving = serveRaw(server, rawResponse("1234"))
      let client = newClient(newUnixIpcTransport(path))
      var options = defaultRequestOptions()
      options.maxResponseBytes = 4
      check waitFor(client.get("/ipc", options = options)).body == "1234"
      waitFor serving
      server.close()
      if fileExists(path):
        removeFile(path)

    test "decoded bodies over the limit are rejected":
      let path = socketPath("body-large")
      if fileExists(path):
        removeFile(path)
      let server = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
      server.bindUnix(path)
      server.listen()
      let serving = serveRaw(server, rawResponse("12345"))
      let client = newClient(newUnixIpcTransport(path))
      var options = defaultRequestOptions()
      options.maxResponseBytes = 4
      try:
        discard waitFor client.get("/ipc", options = options)
        fail()
      except JoubakoError as error:
        check error.kind == jeBodyTooLarge
      waitFor serving
      server.close()
      if fileExists(path):
        removeFile(path)

    test "active cancellation closes the IPC socket":
      let path = socketPath("cancel")
      if fileExists(path):
        removeFile(path)
      let server = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
      server.bindUnix(path)
      server.listen()
      let accepted = newFuture[void]("test_ipc.cancelAccepted")
      let serving = serveUntilClientCloses(server, accepted)
      let client = newClient(newUnixIpcTransport(path))
      let token = newCancellationToken()
      var options = defaultRequestOptions()
      options.cancellation = token
      let pending = client.get("/ipc", options = options)
      waitFor accepted
      token.cancel("superseded")
      try:
        discard waitFor pending
        fail()
      except JoubakoError as error:
        check error.kind == jeCancelled
      waitFor serving
      server.close()
      if fileExists(path):
        removeFile(path)

    test "IPC deadlines close silent peers":
      let path = socketPath("timeout")
      if fileExists(path):
        removeFile(path)
      let server = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
      server.bindUnix(path)
      server.listen()
      let accepted = newFuture[void]("test_ipc.timeoutAccepted")
      let serving = serveUntilClientCloses(server, accepted)
      let client = newClient(newUnixIpcTransport(path))
      var options = defaultRequestOptions()
      options.timeoutMs = 20
      let pending = client.get("/ipc", options = options)
      waitFor accepted
      try:
        discard waitFor pending
        fail()
      except JoubakoError as error:
        check error.kind == jeTimeout
      waitFor serving
      server.close()
      if fileExists(path):
        removeFile(path)

    test "IPC streaming and progress callbacks receive decoded bytes":
      let path = socketPath("stream")
      let handler = proc(request: Request): Future[Response] {.async.} =
        return Response(status: 200, body: "streamed", request: request)
      let action = proc(client: Client): Future[void] {.async.} =
        let capture = IpcProgressCapture(
          download: (-1'i64, -1'i64),
          upload: (-1'i64, -1'i64)
        )
        let options = ipcProgressOptions(capture)
        let response = await client.post("/ipc", "sent", options = options)
        check response.body == ""
        check capture.chunk == "streamed"
        check capture.asyncChunk == "streamed"
        check capture.download == (8'i64, 8'i64)
        check capture.upload == (4'i64, 4'i64)
      waitFor withServer(path, handler, action)

    test "server-side request limits reject decoded bodies":
      let path = socketPath("server-limit")
      let handler = proc(request: Request): Future[Response] {.async.} =
        return Response(status: 200, request: request)
      let action = proc(client: Client): Future[void] {.async.} =
        try:
          discard await client.post("/ipc", "too large")
          fail()
        except JoubakoError as error:
          check error.kind == jeTransport
          check "exceeded" in error.msg
      waitFor withServer(path, handler, action, maxRequestBytes = 2)

    test "concurrent IPC requests retain independent frames":
      let path = socketPath("concurrent")
      if fileExists(path):
        removeFile(path)
      let server = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
      server.bindUnix(path)
      server.listen()
      proc handler(request: Request): Future[Response] {.async.} =
        await sleepAsync(if request.body == "first": 10 else: 0)
        return Response(status: 200, body: request.body & "!", request: request)
      proc serveTwo(): Future[void] {.async.} =
        let firstPeer = await server.accept()
        let firstHandling = handleIpcConnection(firstPeer, handler)
        let secondPeer = await server.accept()
        let secondHandling = handleIpcConnection(secondPeer, handler)
        await firstHandling
        await secondHandling
      let serving = serveTwo()
      let client = newClient(newUnixIpcTransport(path))
      let first = client.post("/one", "first")
      let second = client.post("/two", "second")
      check (waitFor second).body == "second!"
      check (waitFor first).body == "first!"
      waitFor serving
      server.close()
      if fileExists(path):
        removeFile(path)

else:
  suite "Unix IPC transport":
    test "reports unsupported platforms":
      let client = newClient(newUnixIpcTransport("/tmp/not-supported"))
      expect JoubakoError:
        discard waitFor client.get("/ipc")
