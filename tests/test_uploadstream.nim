import std/[asyncdispatch, strutils, unittest]
import joubako

proc consumingHandler(
    body: ref string;
    capacity = 3;
    initialDelayMs = 0
): InProcessHandler =
  result = proc(request: Request): Future[Response] {.async.} =
    if initialDelayMs > 0:
      await sleepAsync(initialDelayMs)
    var buffer = newString(capacity)
    while true:
      let count = request.uploadSource.read(buffer[0].addr, capacity)
      if count > 0:
        body[].add(buffer[0 ..< count])
      elif count == UploadReadEof:
        break
      elif count == UploadReadAbort:
        raise newJoubakoError(jeStream, "producer aborted", request.url)
      else:
        await sleepAsync(1)
    request.uploadSource.setWake(nil)
    return Response(status: 200, body: body[], request: request)

suite "bounded upload producer":
  test "splits large writes and preserves every byte":
    var received = new string
    let client = newClient(newInProcessTransport(consumingHandler(received)))
    let upload = client.openUpload(rmPost, "/upload", maxBufferedBytes = 5)
    check (waitFor upload.send("abcdefghijk")).isOk
    check (waitFor upload.send("")).isOk
    check (waitFor upload.send("-tail")).isOk
    let response = waitFor upload.finish()
    check response.isOk
    check received[] == "abcdefghijk-tail"
    check upload.acceptedBytes == 16
    check upload.queuedBytes == 0

  test "rejects a non-positive queue limit before dispatch":
    var dispatched = false
    let handler = proc(request: Request): Future[Response] {.async.} =
      dispatched = true
      return Response(status: 200, request: request)
    let upload = newClient(newInProcessTransport(handler)).openUpload(
      rmPost, "/upload", maxBufferedBytes = 0
    )
    let outcome = waitFor upload.finish()
    check outcome.isErr
    check outcome.error.kind == jeInvalidRequest
    check not dispatched

  test "rejects concurrent sends without corrupting the first write":
    var received = new string
    let client = newClient(newInProcessTransport(
      consumingHandler(received, capacity = 1, initialDelayMs = 20)
    ))
    let upload = client.openUpload(rmPost, "/upload", maxBufferedBytes = 2)
    let first = upload.send(repeat('x', 32))
    check not first.finished
    let second = waitFor upload.send("other")
    check second.isErr
    check second.error.kind == jeInvalidRequest
    check (waitFor first).isOk
    check (waitFor upload.finish()).isOk
    check received[] == repeat('x', 32)

  test "a peer response wakes a producer waiting for queue space":
    let handler = proc(request: Request): Future[Response] {.async.} =
      await sleepAsync(5)
      return Response(status: 204, request: request)
    let upload = newClient(newInProcessTransport(handler)).openUpload(
      rmPost, "/early", maxBufferedBytes = 2
    )
    let sending = upload.send(repeat('z', 64))
    let sent = waitFor sending
    check sent.isErr
    check sent.error.kind == jeStream
    let response = waitFor upload.finish()
    check response.isOk
    if response.isOk:
      check response.value.status == 204

  test "cancellation wakes a producer waiting for queue space":
    var received = new string
    let client = newClient(newInProcessTransport(
      consumingHandler(received, capacity = 1, initialDelayMs = 50)
    ))
    let upload = client.openUpload(rmPost, "/upload", maxBufferedBytes = 2)
    let sending = upload.send(repeat('q', 64))
    upload.cancel("test cancellation")
    let sent = waitFor sending
    check sent.isErr
    check sent.error.kind == jeCancelled

  test "request validation rejects mixed bodies and incomplete sources":
    let handler = proc(request: Request): Future[Response] {.async.} =
      return Response(status: 200, request: request)
    let client = newClient(newInProcessTransport(handler))
    let incomplete = UploadSource()
    let incompleteResult = waitFor client.requestUploadSource(
      rmPost, "/upload", incomplete
    )
    check incompleteResult.isErr
    check incompleteResult.error.kind == jeInvalidRequest

    let source = UploadSource(
      read: proc(buffer: pointer; capacity: int): int {.gcsafe.} = UploadReadEof,
      setWake: proc(wake: UploadWakeProc) {.gcsafe.} = discard
    )
    discard client.useRequestInterceptor(
      proc(request: Request): Request {.closure.} =
        result = request
        result.body = "interceptor body"
    )
    let mixed = waitFor client.requestUploadSource(rmPost, "/upload", source)
    check mixed.isErr
    check mixed.error.kind == jeInvalidRequest

    let headerClient = newClient(newInProcessTransport(handler))
    var lengthHeader = initHeaders()
    lengthHeader.set("content-length", "0")
    let declared = waitFor headerClient.requestUploadSource(
      rmPost, "/upload", source, lengthHeader
    )
    check declared.isErr
    check declared.error.kind == jeInvalidRequest

  test "the HTTP/1 transport rejects upload sources instead of dropping data":
    let source = UploadSource(
      read: proc(buffer: pointer; capacity: int): int {.gcsafe.} = UploadReadEof,
      setWake: proc(wake: UploadWakeProc) {.gcsafe.} = discard
    )
    let outcome = waitFor newClient(newHttpTransport()).requestUploadSource(
      rmPost, "http://127.0.0.1/never-connected", source
    )
    check outcome.isErr
    check outcome.error.kind == jeInvalidRequest
