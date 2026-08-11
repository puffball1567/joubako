import std/[asyncdispatch, asyncnet, net, sequtils, strutils, times, unittest]
import joubako

proc eventStreamHeaders(): Headers =
  result = initHeaders()
  result.set("content-type", "text/event-stream; charset=utf-8")

proc immediateSleep(delay: Duration): Future[void] {.async.} =
  discard delay

proc ignoreEvent(event: ServerSentEvent) =
  discard event

proc serveSseChunks(server: AsyncSocket): Future[void] {.async.} =
  let socket = await server.accept()
  defer:
    socket.close()
  var request = ""
  while "\r\n\r\n" notin request:
    let chunk = await socket.recv(4096)
    if chunk.len == 0:
      return
    request.add chunk

  let chunks = @["\xEF", "\xBB\xBFid: real\r", "\ndata: net", "work\r\n\r\n"]
  var bodyBytes = 0
  for chunk in chunks:
    bodyBytes += chunk.len
  await socket.send(
    "HTTP/1.1 200 OK\r\n" &
    "Content-Type: text/event-stream; charset=utf-8\r\n" &
    "Content-Length: " & $bodyBytes & "\r\n" &
    "Connection: close\r\n\r\n"
  )
  for chunk in chunks:
    await socket.send(chunk)
    await sleepAsync(2)

suite "SSE parser":
  test "dispatches data with the default event type":
    let parser = newSseParser()
    let parsed = parser.feed("data: hello\n\n")

    check parsed.isOk
    check parsed.value.len == 1
    check parsed.value[0].event == "message"
    check parsed.value[0].data == "hello"
    check parsed.value[0].id == ""

  test "joins repeated data fields with newlines":
    let parsed = newSseParser().feed(
      "data:first\ndata: second\ndata:\n\n"
    )

    check parsed.isOk
    check parsed.value[0].data == "first\nsecond\n"

  test "supports custom event names and resets them after dispatch":
    let parser = newSseParser()
    let parsed = parser.feed(
      "event: update\ndata: one\n\ndata: two\n\n"
    )

    check parsed.isOk
    check parsed.value.mapIt(it.event) == @["update", "message"]

  test "handles CRLF CR and LF across arbitrary chunks":
    let parser = newSseParser()
    var events: seq[ServerSentEvent]
    for chunk in @["data: a\r", "\n", "data: b\r", "\r", "data: c\n\n"]:
      let parsed = parser.feed(chunk)
      check parsed.isOk
      events.add parsed.value

    check events.mapIt(it.data) == @["a\nb", "c"]

  test "strips a UTF-8 BOM even when it is split across chunks":
    let parser = newSseParser()
    check parser.feed("\xEF").isOk
    check parser.feed("\xBB").isOk
    let parsed = parser.feed("\xBFdata: bom\n\n")

    check parsed.isOk
    check parsed.value[0].data == "bom"

  test "ignores comments unknown fields and data-less events":
    let parser = newSseParser()
    let parsed = parser.feed(
      ": keep alive\nunknown: value\nevent: unused\nid: 7\n\n"
    )

    check parsed.isOk
    check parsed.value.len == 0
    check parser.lastEventId == ""

  test "retains the last dispatched event ID":
    let parser = newSseParser()
    let first = parser.feed("id: 42\ndata: first\n\n")
    let second = parser.feed("data: second\n\n")

    check first.value[0].id == "42"
    check second.value[0].id == "42"
    check parser.lastEventId == "42"

  test "ignores event IDs containing a null byte":
    let parser = newSseParser()
    discard parser.feed("id: safe\ndata: one\n\n")
    let parsed = parser.feed("id: bad\0id\ndata: two\n\n")

    check parsed.value[0].id == "safe"

  test "accepts decimal retry fields and ignores invalid values":
    let parser = newSseParser(initialRetryMs = 3_000)
    discard parser.feed("retry: 125\ndata: one\n\n")
    check parser.reconnectDelayMs == 125
    discard parser.feed("retry: 1.5\nretry: -1\ndata: two\n\n")
    check parser.reconnectDelayMs == 125

  test "dispatches an explicitly empty data field":
    let parsed = newSseParser().feed("data:\n\n")

    check parsed.isOk
    check parsed.value.len == 1
    check parsed.value[0].data == ""

  test "does not dispatch an incomplete event":
    let parser = newSseParser()
    let parsed = parser.feed("data: incomplete")

    check parsed.isOk
    check parsed.value.len == 0

  test "enforces a cumulative event byte limit":
    let parser = newSseParser(maxEventBytes = 12)
    let parsed = parser.feed("data: 123456\n\n")

    check parsed.isErr
    check parsed.error.kind == jeStream

  test "resets the byte limit after each event":
    let parser = newSseParser(maxEventBytes = 9)
    let parsed = parser.feed("data: a\n\ndata: b\n\n")

    check parsed.isOk
    check parsed.value.mapIt(it.data) == @["a", "b"]

  test "resetConnection drops partial data but retains reconnect state":
    let parser = newSseParser()
    discard parser.feed("id: 9\nretry: 17\ndata: complete\n\n")
    discard parser.feed("data: partial")
    parser.resetConnection()
    let parsed = parser.feed("data: next\n\n")

    check parsed.value[0].id == "9"
    check parsed.value[0].data == "next"
    check parser.reconnectDelayMs == 17

suite "SSE subscription":
  test "streams from a real HTTP socket":
    let server = newAsyncSocket(buffered = false)
    server.setSockOpt(OptReuseAddr, true)
    server.bindAddr(Port(0), "127.0.0.1")
    server.listen()
    defer:
      server.close()
    let (_, port) = server.getLocalAddr()
    let serving = serveSseChunks(server)
    let client = newClient(newHttpTransport())
    var received: seq[ServerSentEvent]
    let onEvent = proc(event: ServerSentEvent) = received.add event
    var options = defaultSseOptions()
    options.maxReconnects = 0

    let subscribed = waitFor client.subscribeSse(
      "http://127.0.0.1:" & $int(port) & "/events",
      onEvent,
      sseOptions = options
    )
    waitFor serving

    check subscribed.isOk
    check received.len == 1
    check received[0].id == "real"
    check received[0].data == "network"

  test "streams events without retaining the response body":
    var received: seq[ServerSentEvent]
    let handler = proc(request: Request): Future[Response] {.async.} =
      check request.headers.get("accept") == "text/event-stream"
      return Response(
        status: 200,
        headers: eventStreamHeaders(),
        body: "data: one\n\ndata: two\n\n",
        request: request
      )
    let client = newClient(newInProcessTransport(handler))
    let onEvent = proc(event: ServerSentEvent) = received.add event
    var options = defaultSseOptions()
    options.maxReconnects = 0

    let subscribed = waitFor client.subscribeSse(
      "/events",
      onEvent,
      sseOptions = options
    )

    check subscribed.isOk
    check received.mapIt(it.data) == @["one", "two"]

  test "reconnects with Last-Event-ID and the server retry delay":
    var calls = 0
    var delays: seq[int64]
    let handler = proc(request: Request): Future[Response] {.async.} =
      inc calls
      if calls == 1:
        check request.headers.get("last-event-id") == ""
        return Response(
          status: 200,
          headers: eventStreamHeaders(),
          body: "id: event-1\nretry: 25\ndata: first\n\n",
          request: request
        )
      check request.headers.get("last-event-id") == "event-1"
      return Response(status: 204, headers: initHeaders(), request: request)
    let sleeper = proc(delay: Duration): Future[void] {.async.} =
      delays.add delay.inMilliseconds
    let client = newClient(newInProcessTransport(handler))
    var options = defaultSseOptions()
    options.maxReconnects = 1
    options.sleep = sleeper

    let subscribed = waitFor client.subscribeSse(
      "/events", ignoreEvent,
      sseOptions = options
    )

    check subscribed.isOk
    check calls == 2
    check delays == @[25'i64]

  test "rejects a successful response with the wrong content type":
    var delivered = false
    let handler = proc(request: Request): Future[Response] {.async.} =
      var headers = initHeaders()
      headers.set("content-type", "application/json")
      return Response(
        status: 200,
        headers: headers,
        body: "data: must-not-run\n\n",
        request: request
      )
    let client = newClient(newInProcessTransport(handler))
    let onEvent = proc(event: ServerSentEvent) =
      discard event
      delivered = true
    var options = defaultSseOptions()
    options.maxReconnects = 0

    let subscribed = waitFor client.subscribeSse(
      "/events", onEvent,
      sseOptions = options
    )

    check subscribed.isErr
    check subscribed.error.kind == jeStream
    check delivered == false

  test "does not deliver an HTTP error body as SSE":
    var delivered = false
    let handler = proc(request: Request): Future[Response] {.async.} =
      return Response(
        status: 503,
        headers: eventStreamHeaders(),
        body: "data: unavailable\n\n",
        request: request
      )
    let client = newClient(newInProcessTransport(handler))
    let onEvent = proc(event: ServerSentEvent) =
      discard event
      delivered = true
    var options = defaultSseOptions()
    options.maxReconnects = 0

    let subscribed = waitFor client.subscribeSse(
      "/events", onEvent,
      sseOptions = options
    )

    check subscribed.isErr
    check subscribed.error.kind == jeHttpStatus
    check delivered == false

  test "settles synchronous event handler failures":
    let handler = proc(request: Request): Future[Response] {.async.} =
      return Response(
        status: 200,
        headers: eventStreamHeaders(),
        body: "data: event\n\n",
        request: request
      )
    let client = newClient(newInProcessTransport(handler))
    let onEvent = proc(event: ServerSentEvent) =
      discard event
      raise newException(ValueError, "handler failed")
    var options = defaultSseOptions()
    options.maxReconnects = 0

    let subscribed = waitFor client.subscribeSse(
      "/events", onEvent,
      sseOptions = options
    )

    check subscribed.isErr
    check subscribed.error.kind == jeStream
    check subscribed.error.msg.startsWith("handler failed")

  test "settles nil asynchronous event handlers":
    let handler = proc(request: Request): Future[Response] {.async.} =
      return Response(
        status: 200,
        headers: eventStreamHeaders(),
        body: "data: event\n\n",
        request: request
      )
    let client = newClient(newInProcessTransport(handler))
    var options = defaultSseOptions()
    options.maxReconnects = 0
    let nilHandler = proc(event: ServerSentEvent): Future[void] =
      discard event
      nil

    let subscribed = waitFor client.subscribeSse(
      "/events", nilHandler, sseOptions = options
    )

    check subscribed.isErr
    check subscribed.error.kind == jeStream

  test "reconnects after a transport failure":
    var calls = 0
    let handler = proc(request: Request): Future[Response] {.async.} =
      inc calls
      if calls == 1:
        raise newJoubakoError(jeTransport, "disconnected", request.url)
      return Response(status: 204, headers: initHeaders(), request: request)
    let client = newClient(newInProcessTransport(handler))
    var options = defaultSseOptions()
    options.maxReconnects = 1
    options.sleep = immediateSleep

    let subscribed = waitFor client.subscribeSse(
      "/events", ignoreEvent,
      sseOptions = options
    )

    check subscribed.isOk
    check calls == 2

  test "returns cancellation during reconnect waiting":
    let token = newCancellationToken()
    let handler = proc(request: Request): Future[Response] {.async.} =
      token.cancel("subscription stopped")
      return Response(
        status: 200,
        headers: eventStreamHeaders(),
        request: request
      )
    let client = newClient(newInProcessTransport(handler))
    var requestOptions = defaultRequestOptions()
    requestOptions.cancellation = token
    var options = defaultSseOptions()
    options.maxReconnects = 1

    let subscribed = waitFor client.subscribeSse(
      "/events", ignoreEvent,
      requestOptions = requestOptions,
      sseOptions = options
    )

    check subscribed.isErr
    check subscribed.error.kind == jeCancelled
