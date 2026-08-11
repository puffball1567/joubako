import std/[asyncdispatch, asyncnet, json, net, sequtils, strutils, unittest]
import joubako

type
  Event = object
    id: int
    name: string

proc values(outcome: JResult[seq[JsonNode]]): seq[int] =
  doAssert outcome.isOk, outcome.error.msg
  outcome.value.mapIt(it["id"].getInt)

proc streamResponse(request: Request; body, contentType: string;
    status = 200): Response =
  var headers = initHeaders()
  if contentType.len > 0:
    headers.set("content-type", contentType)
  Response(status: status, headers: headers, body: body, request: request)

proc serveChunkedNdjson(server: AsyncSocket): Future[void] {.async.} =
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
    "Content-Type: application/x-ndjson\r\n" &
    "Transfer-Encoding: chunked\r\n" &
    "Connection: close\r\n\r\n"
  )
  for chunk in [
    "{\"id\":1,", "\"name\":\"one\"}\n{\"id\"", ":2,", "\"name\":\"two\"}\n"
  ]:
    await socket.send(toHex(chunk.len) & "\r\n" & chunk & "\r\n")
    await sleepAsync(1)
  await socket.send("0\r\n\r\n")

proc exerciseRealNdjson(): Future[seq[int]] {.async.} =
  let server = newAsyncSocket(buffered = false)
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(Port(0), "127.0.0.1")
  server.listen()
  defer:
    server.close()
  let (_, port) = server.getLocalAddr()
  let serving = server.serveChunkedNdjson()
  let client = newClient(
    newHttpTransport(), "http://127.0.0.1:" & $int(port) & "/"
  )
  var received: ref seq[int]
  new(received)
  let outcome = await client.getNdjson(
    "events", Event, proc(event: Event) = received[].add(event.id)
  )
  doAssert outcome.isOk, outcome.error.msg
  await serving
  return received[]

suite "NDJSON parser and encoder":
  test "parses records split across arbitrary chunks":
    let parser = newJsonStreamParser(jsfNdjson)
    check parser.feed("{\"id\":1").value.len == 0
    check parser.feed("}\n{\"id\":").values == @[1]
    check parser.feed("2}\n").values == @[2]
    check parser.finish().value.len == 0

  test "accepts CRLF and ignores empty lines by default":
    let parser = newJsonStreamParser(jsfNdjson)
    check parser.feed("\r\n{\"id\":1}\r\n\n").values == @[1]
    check parser.finish().isOk

  test "can reject empty lines":
    var options = defaultJsonStreamParserOptions()
    options.ignoreEmptyNdjsonLines = false
    let outcome = newJsonStreamParser(jsfNdjson, options).feed("\n")
    check outcome.isErr
    check outcome.error.kind == jeCodec

  test "requires the final LF by default":
    let parser = newJsonStreamParser(jsfNdjson)
    check parser.feed("{\"id\":1}").isOk
    let outcome = parser.finish()
    check outcome.isErr
    check outcome.error.kind == jeCodec

  test "can accept an explicitly allowed unterminated final record":
    var options = defaultJsonStreamParserOptions()
    options.allowUnterminatedNdjsonRecord = true
    let parser = newJsonStreamParser(jsfNdjson, options)
    discard parser.feed("{\"id\":1}")
    check parser.finish().values == @[1]

  test "rejects malformed records and invalid UTF-8":
    let malformed = newJsonStreamParser(jsfNdjson).feed("{bad}\n")
    let invalidUtf8 = newJsonStreamParser(jsfNdjson).feed("\xff\n")
    check malformed.isErr
    check malformed.error.kind == jeCodec
    check invalidUtf8.isErr
    check invalidUtf8.error.kind == jeCodec

  test "can explicitly skip malformed records and resume":
    var options = defaultJsonStreamParserOptions()
    options.skipInvalidRecords = true
    let parser = newJsonStreamParser(jsfNdjson, options)
    check parser.feed("{bad}\n{\"id\":2}\n").values == @[2]
    check parser.finish().isOk

  test "enforces the record limit while data is still incomplete":
    var options = defaultJsonStreamParserOptions()
    options.maxRecordBytes = 4
    let parser = newJsonStreamParser(jsfNdjson, options)
    let outcome = parser.feed("12345")
    check outcome.isErr
    check outcome.error.kind == jeBodyTooLarge

  test "accepts a record exactly at the configured limit":
    var options = defaultJsonStreamParserOptions()
    options.maxRecordBytes = 7
    let parser = newJsonStreamParser(jsfNdjson, options)
    check parser.feed("{\"x\":1}\n").value.len == 1

  test "rejects use after finish and nil parsers":
    let parser = newJsonStreamParser(jsfNdjson)
    check parser.finish().isOk
    check parser.feed("{}\n").error.kind == jeInvalidRequest
    check parser.finish().error.kind == jeInvalidRequest
    let missing: JsonStreamParser = nil
    check missing.feed("{}").error.kind == jeInvalidRequest

  test "encodes every JSON value with one LF":
    let encoded = encodeNdjson([%*{"id": 1}, %*{"id": 2}])
    check encoded.isOk
    check encoded.value == "{\"id\":1}\n{\"id\":2}\n"

suite "RFC 7464 JSON Text Sequence parser and encoder":
  test "parses records split before and after separators":
    let parser = newJsonStreamParser(jsfJsonSequence)
    check parser.feed("\x1e{\"id\":1").value.len == 0
    check parser.feed("}\n\x1e{\"id\":2}\n").values == @[1, 2]
    check parser.finish().isOk

  test "accepts repeated record separators":
    let parser = newJsonStreamParser(jsfJsonSequence)
    check parser.feed("\x1e\x1e{\"id\":1}\n").values == @[1]
    check parser.finish().isOk

  test "supports pretty JSON containing line feeds":
    let parser = newJsonStreamParser(jsfJsonSequence)
    check parser.feed("\x1e{\n  \"id\": 1\n}\n").values == @[1]
    check parser.finish().isOk

  test "rejects data before the first record separator":
    let outcome = newJsonStreamParser(jsfJsonSequence).feed("{}\n")
    check outcome.isErr
    check outcome.error.kind == jeCodec

  test "detects a possibly truncated top-level number without LF":
    let parser = newJsonStreamParser(jsfJsonSequence)
    check parser.feed("\x1e123").isOk
    let outcome = parser.finish()
    check outcome.isErr
    check outcome.error.kind == jeCodec

  test "accepts top-level numbers when terminated by LF":
    let parser = newJsonStreamParser(jsfJsonSequence)
    let records = parser.feed("\x1e123\n")
    check records.isOk
    check records.value[0].getInt == 123
    check parser.finish().isOk

  test "accepts a final object delimited by EOF":
    let parser = newJsonStreamParser(jsfJsonSequence)
    discard parser.feed("\x1e{\"id\":1}")
    check parser.finish().values == @[1]

  test "rejects non-whitespace after an LF-completed record":
    let parser = newJsonStreamParser(jsfJsonSequence)
    let outcome = parser.feed("\x1e{}\ninvalid")
    check outcome.isErr
    check outcome.error.kind == jeCodec

  test "recovers at the next separator only when explicitly enabled":
    var options = defaultJsonStreamParserOptions()
    options.skipInvalidRecords = true
    let parser = newJsonStreamParser(jsfJsonSequence, options)
    let records = parser.feed("\x1e{bad}\x1e{\"id\":2}\n")
    check records.values == @[2]
    check parser.finish().isOk

  test "encodes the RS JSON LF wire format":
    let encoded = encodeJsonSequence([%*{"id": 1}, %*true])
    check encoded.isOk
    check encoded.value == "\x1e{\"id\":1}\n\x1etrue\n"

suite "streaming JSON client":
  test "streams records split across real HTTP chunk boundaries":
    check waitFor(exerciseRealNdjson()) == @[1, 2]

  test "streams typed NDJSON records and sets Accept":
    var received: seq[Event]
    let transport = newInProcessTransport(proc(request: Request): Future[Response] {.async.} =
      check request.httpMethod == rmGet
      check request.headers.get("accept") == NdjsonMediaType
      return request.streamResponse(
        "{\"id\":1,\"name\":\"one\"}\n{\"id\":2,\"name\":\"two\"}\n",
        NdjsonMediaType & "; charset=utf-8"
      )
    )
    let outcome = waitFor newClient(transport).getNdjson(
      "/events", Event,
      proc(event: Event) = received.add(event)
    )
    check outcome.isOk
    check received.mapIt(it.id) == @[1, 2]

  test "streams JSON Sequence records with asynchronous backpressure":
    var order: seq[string]
    let transport = newInProcessTransport(proc(request: Request): Future[Response] {.async.} =
      return request.streamResponse(
        "\x1e{\"id\":1,\"name\":\"one\"}\n\x1e{\"id\":2,\"name\":\"two\"}\n",
        JsonSequenceMediaType
      )
    )
    let handler = proc(event: Event): Future[void] {.async.} =
      order.add("start-" & $event.id)
      await sleepAsync(1)
      order.add("end-" & $event.id)
    let outcome = waitFor newClient(transport).getJsonSequenceAsync(
      "/events", Event, handler
    )
    check outcome.isOk
    check order == @["start-1", "end-1", "start-2", "end-2"]

  test "posts encoded NDJSON and streams the response":
    var received: seq[int]
    let transport = newInProcessTransport(proc(request: Request): Future[Response] {.async.} =
      check request.httpMethod == rmPost
      check request.headers.get("content-type") == NdjsonMediaType
      check request.body == "{\"id\":1,\"name\":\"one\"}\n"
      return request.streamResponse(
        "{\"id\":2,\"name\":\"two\"}\n", NdjsonMediaType
      )
    )
    let handler = proc(event: Event): Future[void] {.async.} =
      received.add(event.id)
    let outcome = waitFor newClient(transport).postNdjsonAsync(
      "/events", [Event(id: 1, name: "one")], Event, handler
    )
    check outcome.isOk
    check received == @[2]

  test "posts encoded JSON Sequence with its media type":
    let transport = newInProcessTransport(proc(request: Request): Future[Response] {.async.} =
      check request.headers.get("content-type") == JsonSequenceMediaType
      check request.body.startsWith("\x1e")
      return request.streamResponse("\x1etrue\n", JsonSequenceMediaType)
    )
    var received = false
    let handler = proc(value: bool) = received = value
    let outcome = waitFor newClient(transport).postJsonSequence(
      "/events", [%*false], bool, handler
    )
    check outcome.isOk
    check received

  test "rejects the wrong or missing response content type":
    for contentType in ["application/json", ""]:
      let current = contentType
      let transport = newInProcessTransport(proc(request: Request): Future[Response] {.async.} =
        return request.streamResponse("{}\n", current)
      )
      let outcome = waitFor newClient(transport).getNdjson(
        "/events", JsonNode, proc(_: JsonNode) = discard
      )
      check outcome.isErr
      check outcome.error.kind == jeCodec

  test "can explicitly disable content type validation":
    let transport = newInProcessTransport(proc(request: Request): Future[Response] {.async.} =
      return request.streamResponse("true\n", "")
    )
    var options = defaultJsonStreamOptions()
    options.requireContentType = false
    var received = false
    let outcome = waitFor newClient(transport).getNdjson(
      "/events", bool, proc(value: bool) = received = value,
      streamOptions = options
    )
    check outcome.isOk
    check received

  test "settles malformed records and typed decode failures":
    for body in ["{bad}\n", "\"not an event\"\n"]:
      let current = body
      let transport = newInProcessTransport(proc(request: Request): Future[Response] {.async.} =
        return request.streamResponse(current, NdjsonMediaType)
      )
      let outcome = waitFor newClient(transport).getNdjson(
        "/events", Event, proc(_: Event) = discard
      )
      check outcome.isErr
      check outcome.error.kind == jeCodec

  test "settles synchronous asynchronous and nil handler failures":
    let transport = newInProcessTransport(proc(request: Request): Future[Response] {.async.} =
      return request.streamResponse("true\n", NdjsonMediaType)
    )
    let client = newClient(transport)
    let synchronous = waitFor client.getNdjson(
      "/events", bool,
      proc(_: bool) = raise newException(ValueError, "sync failed")
    )
    let asynchronous = waitFor client.getNdjsonAsync(
      "/events", bool,
      proc(_: bool): Future[void] {.async.} =
        raise newException(ValueError, "async failed")
    )
    let nilHandler: AsyncJsonRecordProc[bool] = nil
    let missing = waitFor client.getNdjsonAsync(
      "/events", bool, nilHandler
    )
    check synchronous.isErr
    check synchronous.error.kind == jeStream
    check asynchronous.isErr
    check asynchronous.error.kind == jeStream
    check missing.isErr
    check missing.error.kind == jeInvalidRequest

  test "enforces per-record and total response limits":
    let transport = newInProcessTransport(proc(request: Request): Future[Response] {.async.} =
      return request.streamResponse("{\"id\":123}\n", NdjsonMediaType)
    )
    var streamOptions = defaultJsonStreamOptions()
    streamOptions.parser.maxRecordBytes = 4
    let recordLimit = waitFor newClient(transport).getNdjson(
      "/events", JsonNode, proc(_: JsonNode) = discard,
      streamOptions = streamOptions
    )
    let totalLimit = waitFor newClient(transport).getNdjson(
      "/events", JsonNode, proc(_: JsonNode) = discard,
      requestOptions = RequestOptions(maxResponseBytes: 4)
    )
    check recordLimit.isErr
    check recordLimit.error.kind == jeBodyTooLarge
    check totalLimit.isErr
    check totalLimit.error.kind == jeBodyTooLarge
