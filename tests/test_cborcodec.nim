import std/[asyncdispatch, asyncnet, math, net, strutils, unittest]
import joubako
import ./result_test_helpers

type
  Priority = enum
    low, normal, high

  CborRequest = object
    id: uint64
    name: string
    payload: seq[byte]
    active: bool

  CborReply = object
    accepted: bool
    count: int64
    label: string

proc waitOutcome[T](future: Future[JResult[T]]): JResult[T] =
  asyncdispatch.waitFor(future)

proc cborBody[T](value: T): string =
  encodeCborPayload(value)

proc cborResponse(request: Request; body: string; status = 200;
    contentType = CborMediaType): Response =
  var headers = initHeaders()
  if contentType.len > 0:
    headers.set("content-type", contentType)
  Response(status: status, headers: headers, body: body, request: request)

proc serveCborOnce(server: AsyncSocket; body: string): Future[void] {.async.} =
  let socket = await server.accept()
  defer:
    socket.close()
  var request = ""
  while "\r\n\r\n" notin request:
    let chunk = await socket.recv(4096)
    if chunk.len == 0:
      return
    request.add chunk
  doAssert "accept: application/cbor" in request.toLowerAscii
  await socket.send(
    "HTTP/1.1 200 OK\r\n" &
    "Content-Type: application/cbor\r\n" &
    "Content-Length: " & $body.len & "\r\n" &
    "Connection: close\r\n\r\n" & body
  )

proc exerciseRealCbor(): Future[CborReply] {.async.} =
  let server = newAsyncSocket(buffered = false)
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(Port(0), "127.0.0.1")
  server.listen()
  defer:
    server.close()
  let (_, port) = server.getLocalAddr()
  let serving = server.serveCborOnce(cborBody(CborReply(
    accepted: true, count: 42, label: "real-http"
  )))
  let client = newClient(
    newHttpTransport(), "http://127.0.0.1:" & $int(port) & "/"
  )
  let outcome = asyncdispatch.await client.getCbor("value", CborReply)
  doAssert outcome.isOk, outcome.error.msg
  await serving
  return outcome.value

suite "CBOR codec":
  test "real HTTP transport preserves binary CBOR and headers":
    check waitFor(exerciseRealCbor()) == CborReply(
      accepted: true, count: 42, label: "real-http"
    )

  test "RFC 8949 representative deterministic encodings":
    check encodeCborPayload(0'u64) == "\x00"
    check encodeCborPayload(23'u64) == "\x17"
    check encodeCborPayload(24'u64) == "\x18\x18"
    check encodeCborPayload(-1'i64) == "\x20"
    check encodeCborPayload("a") == "\x61\x61"
    check encodeCborPayload(@[1'u64, 2, 3]) == "\x83\x01\x02\x03"

  test "typed objects round trip with Unicode and binary NUL":
    let value = CborRequest(
      id: uint64.high,
      name: "箱庭🌱",
      payload: @[0'u8, 1, 255, 0],
      active: true
    )
    check decodeCborPayload(encodeCborPayload(value), CborRequest) == value

  test "signed integer boundaries round trip":
    for value in @[int64.low, -24'i64, -1'i64, 0'i64, 23'i64,
        24'i64, int64.high]:
      check decodeCborPayload(encodeCborPayload(value), int64) == value

  test "floating point special values round trip":
    for value in @[0.0, -0.0, 1.5, Inf, NegInf]:
      let decoded = decodeCborPayload(encodeCborPayload(value), float64)
      if value == 0.0:
        check decoded == value
      else:
        check decoded == value
    let nanValue = decodeCborPayload(encodeCborPayload(NaN), float64)
    check nanValue.isNaN

  test "sequences arrays tuples enums and refs round trip":
    check decodeCborPayload(encodeCborPayload(@[true, false, true]), seq[bool]) ==
      @[true, false, true]
    check decodeCborPayload(encodeCborPayload([1'u16, 2, 3]), array[3, uint16]) ==
      [1'u16, 2, 3]
    check decodeCborPayload(encodeCborPayload((name: "x", count: 2)),
      tuple[name: string, count: int]) == (name: "x", count: 2)
    check decodeCborPayload(encodeCborPayload(high), Priority) == high

  test "malformed and truncated payloads are structured errors":
    for payload in ["", "\x18", "\x63ab", "\x9f\x01"]:
      let outcome = tryDecodeCborPayload(payload, uint64)
      check outcome.isErr
      check outcome.error.kind == jeCodec
      check outcome.error.codecCode == "cbor_decode"
      check outcome.error.codecOffset >= 0

  test "wire type mismatch is a codec error":
    let outcome = tryDecodeCborPayload(encodeCborPayload("text"), uint64)
    check outcome.isErr
    check outcome.error.codecCode == "cbor_decode"

  test "trailing bytes are rejected by default at their exact offset":
    let outcome = tryDecodeCborPayload("\x01\x02", uint64)
    check outcome.isErr
    check outcome.error.codecCode == "cbor_trailing_data"
    check outcome.error.codecOffset == 1

  test "trailing bytes can be permitted explicitly":
    var options = defaultCborCodecOptions()
    options.rejectTrailingData = false
    let outcome = tryDecodeCborPayload("\x01\x02", uint64, options)
    check outcome.isOk
    check outcome.value == 1'u64

  test "payload byte limit accepts boundary and rejects one more":
    let encoded = encodeCborPayload("boundary")
    var options = defaultCborCodecOptions()
    options.maxPayloadBytes = encoded.len
    check decodeCborPayload(encoded, string, options) == "boundary"
    options.maxPayloadBytes = encoded.len - 1
    let decodeFailure = tryDecodeCborPayload(encoded, string, options)
    check decodeFailure.isErr
    check decodeFailure.error.codecCode == "cbor_payload_too_large"
    let encodeFailure = tryEncodeCborPayload("boundary", options)
    check encodeFailure.isErr
    check encodeFailure.error.codecCode == "cbor_payload_too_large"

  test "negative payload limit disables the codec byte bound":
    var options = defaultCborCodecOptions()
    options.maxPayloadBytes = -1
    check decodeCborPayload(encodeCborPayload("ok", options), string, options) ==
      "ok"

  test "nesting depth limit is enforced during parsing":
    let payload = encodeCborPayload(@[@[@[1]]])
    var options = defaultCborCodecOptions()
    options.readerConf.nestedDepthLimit = 2
    let outcome = tryDecodeCborPayload(payload, seq[seq[seq[int]]], options)
    check outcome.isErr
    check outcome.error.codecCode == "cbor_decode"

  test "array element limit is enforced before materialization":
    let payload = encodeCborPayload(@[1, 2, 3])
    var options = defaultCborCodecOptions()
    options.readerConf.arrayElementsLimit = 2
    check tryDecodeCborPayload(payload, seq[int], options).isErr

  test "map field limit is enforced before materialization":
    let payload = encodeCborPayload(CborReply(
      accepted: true, count: 1, label: "ok"
    ))
    var options = defaultCborCodecOptions()
    options.readerConf.objectFieldsLimit = 2
    check tryDecodeCborPayload(payload, CborReply, options).isErr

  test "text and byte string limits are independent":
    var options = defaultCborCodecOptions()
    options.readerConf.stringLengthLimit = 2
    check tryDecodeCborPayload(encodeCborPayload("abc"), string, options).isErr
    options = defaultCborCodecOptions()
    options.readerConf.byteStringLengthLimit = 2
    check tryDecodeCborPayload(encodeCborPayload(@[1'u8, 2, 3]),
      seq[byte], options).isErr

  test "POST sets CBOR Content-Type and Accept and decodes typed response":
    var seenMethod = rmGet
    var seenContentType = ""
    var seenAccept = ""
    let handler = proc(request: Request): Future[Response] {.async.} =
      seenMethod = request.httpMethod
      seenContentType = request.headers.get("content-type")
      seenAccept = request.headers.get("accept")
      let decoded = decodeCborPayload(request.body, CborRequest)
      return cborResponse(request, cborBody(CborReply(
        accepted: decoded.active,
        count: decoded.payload.len,
        label: decoded.name
      )))
    let client = newClient(newInProcessTransport(handler))
    let reply = waitFor client.postCbor(
      "/items",
      CborRequest(id: 4, name: "nim", payload: @[0'u8, 2], active: true),
      CborReply
    )
    check seenMethod == rmPost
    check seenContentType == CborMediaType
    check seenAccept == CborMediaType
    check reply == CborReply(accepted: true, count: 2, label: "nim")

  test "GET sends Accept without a request Content-Type or body":
    var seenBody = "unexpected"
    var seenContentType = "unexpected"
    var seenAccept = ""
    let handler = proc(request: Request): Future[Response] {.async.} =
      seenBody = request.body
      seenContentType = request.headers.get("content-type")
      seenAccept = request.headers.get("accept")
      return cborResponse(request, cborBody(7'u64))
    let value = waitFor newClient(newInProcessTransport(handler)).getCbor(
      "/value", uint64
    )
    check value == 7'u64
    check seenBody.len == 0
    check seenContentType.len == 0
    check seenAccept == CborMediaType

  test "caller Content-Type and Accept take precedence":
    var seenContentType = ""
    var seenAccept = ""
    let handler = proc(request: Request): Future[Response] {.async.} =
      seenContentType = request.headers.get("content-type")
      seenAccept = request.headers.get("accept")
      return cborResponse(request, cborBody("ok"),
        contentType = "application/vnd.example+cbor")
    var headers = initHeaders()
    headers.set("content-type", "application/vnd.request+cbor")
    headers.set("accept", "application/vnd.response+cbor")
    check waitFor(newClient(newInProcessTransport(handler)).postCbor(
      "/", "request", string, headers
    )) == "ok"
    check seenContentType == "application/vnd.request+cbor"
    check seenAccept == "application/vnd.response+cbor"

  test "structured-suffix and parameterized response media types are accepted":
    for mediaType in ["application/cbor; profile=example",
        "application/problem+cbor", "Application/CBOR"]:
      let handler = proc(request: Request): Future[Response] {.async.} =
        return cborResponse(request, cborBody(true), contentType = mediaType)
      check waitFor(newClient(newInProcessTransport(handler)).getCbor(
        "/", bool
      ))

  test "present incompatible Content-Type fails with response context":
    let handler = proc(request: Request): Future[Response] {.async.} =
      return cborResponse(request, cborBody(true), contentType = "text/plain")
    let outcome = waitOutcome newClient(newInProcessTransport(handler)).getCbor(
      "/wrong-type", bool
    )
    check outcome.isErr
    check outcome.error.codecCode == "cbor_content_type"
    check outcome.error.url == "/wrong-type"
    check outcome.error.status == 200
    check outcome.error.hasResponse

  test "missing Content-Type is configurable":
    let handler = proc(request: Request): Future[Response] {.async.} =
      return cborResponse(request, cborBody(true), contentType = "")
    let client = newClient(newInProcessTransport(handler))
    check waitFor(client.getCbor("/lenient", bool))
    var options = defaultCborCodecOptions()
    options.requireContentType = true
    let outcome = waitOutcome client.getCbor(
      "/strict", bool, codecOptions = options
    )
    check outcome.isErr
    check outcome.error.codecCode == "cbor_content_type"

  test "HTTP status is returned before CBOR decoding":
    let handler = proc(request: Request): Future[Response] {.async.} =
      return cborResponse(request, "not-cbor", status = 503)
    let outcome = waitOutcome newClient(newInProcessTransport(handler)).getCbor(
      "/unavailable", bool
    )
    check outcome.isErr
    check outcome.error.kind == jeHttpStatus
    check outcome.error.codecCode.len == 0

  test "malformed HTTP response retains body status URL and offset":
    let handler = proc(request: Request): Future[Response] {.async.} =
      return cborResponse(request, "\x18")
    let outcome = waitOutcome newClient(newInProcessTransport(handler)).getCbor(
      "/truncated", uint64
    )
    check outcome.isErr
    check outcome.error.kind == jeCodec
    check outcome.error.codecCode == "cbor_decode"
    check outcome.error.url == "/truncated"
    check outcome.error.status == 200
    check outcome.error.hasResponse
    check outcome.error.response.body == "\x18"

  test "request byte limit is applied to encoded CBOR":
    var dispatched = false
    let handler = proc(request: Request): Future[Response] {.async.} =
      dispatched = true
      return cborResponse(request, request.body)
    let encoded = encodeCborPayload("request")
    var options = defaultRequestOptions()
    options.maxRequestBytes = encoded.len - 1
    let outcome = waitOutcome newClient(newInProcessTransport(handler)).postCbor(
      "/limit", "request", string, options = options
    )
    check outcome.isErr
    check outcome.error.kind == jeBodyTooLarge
    check not dispatched

  test "response byte limit is applied before CBOR decoding":
    let handler = proc(request: Request): Future[Response] {.async.} =
      return cborResponse(request, cborBody("response"))
    let encoded = encodeCborPayload("response")
    var options = defaultRequestOptions()
    options.maxResponseBytes = encoded.len - 1
    let outcome = waitOutcome newClient(newInProcessTransport(handler)).getCbor(
      "/limit", string, options = options
    )
    check outcome.isErr
    check outcome.error.kind == jeBodyTooLarge

  test "PUT PATCH and arbitrary methods are dispatched":
    var methods: seq[RequestMethod]
    let handler = proc(request: Request): Future[Response] {.async.} =
      methods.add request.httpMethod
      return cborResponse(request, cborBody(true))
    let client = newClient(newInProcessTransport(handler))
    discard waitFor client.putCbor("/", 1, bool)
    discard waitFor client.patchCbor("/", 2, bool)
    discard waitFor client.sendCbor(rmDelete, "/", 3, bool)
    check methods == @[rmPut, rmPatch, rmDelete]

  test "transport failures are not rewritten as codec failures":
    let handler = proc(request: Request): Future[Response] {.async.} =
      raise newException(IOError, "offline")
    let outcome = waitOutcome newClient(newInProcessTransport(handler)).getCbor(
      "/offline", bool
    )
    check outcome.isErr
    check outcome.error.kind == jeTransport
    check outcome.error.codecCode.len == 0
