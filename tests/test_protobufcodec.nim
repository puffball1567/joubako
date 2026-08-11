import std/[asyncdispatch, asyncnet, net, strutils, unittest]
from pkg/protobuf_serialization/proto_parser import import_proto3
import joubako
import ./result_test_helpers

import_proto3 "fixtures/joubako_codec.proto3"

type
  ScalarMessage {.proto3.} = object
    id {.fieldNumber: 1, pint.}: uint32
    name {.fieldNumber: 2.}: string
    payload {.fieldNumber: 3.}: seq[byte]
    active {.fieldNumber: 4.}: bool
    values {.fieldNumber: 5, sint.}: seq[int32]

  ChildMessage {.proto3.} = object
    value {.fieldNumber: 1, pint.}: int64

  NestedMessage {.proto3.} = object
    child {.fieldNumber: 1.}: ChildMessage
    labels {.fieldNumber: 2.}: seq[string]

  RequiredMessage {.proto2.} = object
    id {.fieldNumber: 1, required, pint.}: int32

  ReplyMessage {.proto3.} = object
    accepted {.fieldNumber: 1.}: bool
    count {.fieldNumber: 2, pint.}: uint32

proc waitOutcome[T](future: Future[JResult[T]]): JResult[T] =
  asyncdispatch.waitFor(future)

proc protobufResponse(request: Request; body: string; status = 200;
    contentType = ProtobufMediaType): Response =
  var headers = initHeaders()
  if contentType.len > 0:
    headers.set("content-type", contentType)
  Response(status: status, headers: headers, body: body, request: request)

proc serveProtobufOnce(server: AsyncSocket; body: string): Future[void] {.async.} =
  let socket = await server.accept()
  defer:
    socket.close()
  var request = ""
  while "\r\n\r\n" notin request:
    let chunk = await socket.recv(4096)
    if chunk.len == 0:
      return
    request.add chunk
  doAssert "accept: application/protobuf" in request.toLowerAscii
  await socket.send(
    "HTTP/1.1 200 OK\r\n" &
    "Content-Type: application/protobuf; encoding=binary\r\n" &
    "X-Content-Type-Options: nosniff\r\n" &
    "Content-Length: " & $body.len & "\r\n" &
    "Connection: close\r\n\r\n" & body
  )

proc exerciseRealProtobuf(): Future[ReplyMessage] {.async.} =
  let server = newAsyncSocket(buffered = false)
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(Port(0), "127.0.0.1")
  server.listen()
  defer:
    server.close()
  let (_, port) = server.getLocalAddr()
  let serving = server.serveProtobufOnce(encodeProtobufPayload(ReplyMessage(
    accepted: true, count: 42
  )))
  let client = newClient(
    newHttpTransport(), "http://127.0.0.1:" & $int(port) & "/"
  )
  let outcome = asyncdispatch.await client.getProtobuf("value", ReplyMessage)
  doAssert outcome.isOk, outcome.error.msg
  await serving
  return outcome.value

suite "Protobuf codec":
  test "real HTTP transport preserves binary Protobuf and headers":
    check waitFor(exerciseRealProtobuf()) == ReplyMessage(
      accepted: true, count: 42
    )

  test "wire bytes match protoc-compatible scalar encodings":
    check encodeProtobufPayload(ScalarMessage(id: 150)) == "\x08\x96\x01"
    check encodeProtobufPayload(ScalarMessage(name: "nim")) == "\x12\x03nim"
    check encodeProtobufPayload(ScalarMessage(
      payload: @[0'u8, 255, 1]
    )) == "\x1a\x03\x00\xff\x01"
    check encodeProtobufPayload(ScalarMessage(active: true)) == "\x20\x01"

  test "proto3 schema macro generates types usable by the HTTP codec":
    let value = GeneratedMessage(
      id: 17,
      label: "generated",
      values: @[-2'i32, 0, 3],
      payload: @[0'u8, 255]
    )
    check decodeProtobufPayload(
      encodeProtobufPayload(value), GeneratedMessage
    ) == value

  test "typed proto3 message round trips Unicode binary and packed values":
    let value = ScalarMessage(
      id: uint32.high,
      name: "箱庭🌱",
      payload: @[0'u8, 1, 255, 0],
      active: true,
      values: @[int32.low, -1'i32, 0'i32, 1'i32, int32.high]
    )
    check decodeProtobufPayload(
      encodeProtobufPayload(value), ScalarMessage
    ) == value

  test "nested and repeated messages round trip":
    let value = NestedMessage(
      child: ChildMessage(value: int64.high),
      labels: @["one", "two", "三"]
    )
    check decodeProtobufPayload(
      encodeProtobufPayload(value), NestedMessage
    ) == value

  test "proto3 empty payload produces defaults":
    check decodeProtobufPayload("", ScalarMessage) == ScalarMessage()

  test "proto2 required fields are enforced":
    let missing = tryDecodeProtobufPayload("", RequiredMessage)
    check missing.isErr
    check missing.error.codecCode == "protobuf_decode"
    let present = RequiredMessage(id: 7)
    check decodeProtobufPayload(
      encodeProtobufPayload(present), RequiredMessage
    ) == present

  test "unknown fields are consumed without changing known values":
    let known = encodeProtobufPayload(ScalarMessage(id: 7))
    # Field 99, varint value 123.
    let withUnknown = known & "\x98\x06\x7b"
    check decodeProtobufPayload(withUnknown, ScalarMessage) ==
      ScalarMessage(id: 7)

  test "a later duplicate singular field wins":
    check decodeProtobufPayload("\x08\x01\x08\x02", ScalarMessage).id == 2

  test "malformed lengths varints headers wire types and UTF-8 fail":
    for payload in [
      "\x0a\x80\x80\x80\x80\x10",
      "\x1a\x05ab",
      "\x80",
      "\x0f",
      "\x08\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\x01",
      "\x12\x03\xe2\x28\xa1"
    ]:
      let outcome = tryDecodeProtobufPayload(payload, ScalarMessage)
      check outcome.isErr
      check outcome.error.kind == jeCodec
      check outcome.error.codecCode == "protobuf_decode"
      check outcome.error.codecOffset == -1

  test "truncated fixed-width fields fail":
    type FixedMessage {.proto3.} = object
      value {.fieldNumber: 1, fixed.}: uint64
    let outcome = tryDecodeProtobufPayload("\x09\x01\x02", FixedMessage)
    check outcome.isErr
    check outcome.error.codecCode == "protobuf_decode"

  test "payload limit accepts boundary and rejects one more":
    let value = ScalarMessage(name: "boundary")
    let encoded = encodeProtobufPayload(value)
    var options = defaultProtobufCodecOptions()
    options.maxPayloadBytes = encoded.len
    check decodeProtobufPayload(encoded, ScalarMessage, options) == value
    options.maxPayloadBytes = encoded.len - 1
    let decodeFailure = tryDecodeProtobufPayload(
      encoded, ScalarMessage, options
    )
    check decodeFailure.isErr
    check decodeFailure.error.codecCode == "protobuf_payload_too_large"
    let encodeFailure = tryEncodeProtobufPayload(value, options)
    check encodeFailure.isErr
    check encodeFailure.error.codecCode == "protobuf_payload_too_large"

  test "negative codec payload limit disables that bound":
    var options = defaultProtobufCodecOptions()
    options.maxPayloadBytes = -1
    let value = ScalarMessage(name: "ok")
    check decodeProtobufPayload(
      encodeProtobufPayload(value, options), ScalarMessage, options
    ) == value

  test "POST sets standard Content-Type and Accept and decodes response":
    var seenMethod = rmGet
    var seenContentType = ""
    var seenAccept = ""
    let handler = proc(request: Request): Future[Response] {.async.} =
      seenMethod = request.httpMethod
      seenContentType = request.headers.get("content-type")
      seenAccept = request.headers.get("accept")
      let decoded = decodeProtobufPayload(request.body, ScalarMessage)
      return protobufResponse(request, encodeProtobufPayload(ReplyMessage(
        accepted: decoded.active,
        count: decoded.payload.len.uint32
      )))
    let client = newClient(newInProcessTransport(handler))
    let reply = waitFor client.postProtobuf(
      "/items",
      ScalarMessage(payload: @[0'u8, 2], active: true),
      ReplyMessage
    )
    check seenMethod == rmPost
    check seenContentType == ProtobufMediaType
    check seenAccept == ProtobufMediaType
    check reply == ReplyMessage(accepted: true, count: 2)

  test "GET sends Accept without a request Content-Type or body":
    var seenBody = "unexpected"
    var seenContentType = "unexpected"
    var seenAccept = ""
    let handler = proc(request: Request): Future[Response] {.async.} =
      seenBody = request.body
      seenContentType = request.headers.get("content-type")
      seenAccept = request.headers.get("accept")
      return protobufResponse(
        request, encodeProtobufPayload(ReplyMessage(count: 7))
      )
    let value = waitFor newClient(newInProcessTransport(handler)).getProtobuf(
      "/value", ReplyMessage
    )
    check value.count == 7
    check seenBody.len == 0
    check seenContentType.len == 0
    check seenAccept == ProtobufMediaType

  test "caller Content-Type and Accept take precedence":
    var seenContentType = ""
    var seenAccept = ""
    let handler = proc(request: Request): Future[Response] {.async.} =
      seenContentType = request.headers.get("content-type")
      seenAccept = request.headers.get("accept")
      return protobufResponse(
        request,
        encodeProtobufPayload(ReplyMessage(accepted: true)),
        contentType = "application/x-protobuf"
      )
    var headers = initHeaders()
    headers.set("content-type", "application/x-protobuf")
    headers.set("accept", "application/vnd.google.protobuf")
    check waitFor(newClient(newInProcessTransport(handler)).postProtobuf(
      "/", ScalarMessage(), ReplyMessage, headers
    )).accepted
    check seenContentType == "application/x-protobuf"
    check seenAccept == "application/vnd.google.protobuf"

  test "standard binary media parameters and custom metadata are accepted":
    for mediaType in [
      "application/protobuf",
      "Application/Protobuf; encoding=binary",
      "application/protobuf; type=example.Message"
    ]:
      let handler = proc(request: Request): Future[Response] {.async.} =
        return protobufResponse(
          request,
          encodeProtobufPayload(ReplyMessage(accepted: true)),
          contentType = mediaType
        )
      check waitFor(newClient(newInProcessTransport(handler)).getProtobuf(
        "/", ReplyMessage
      )).accepted

  test "illegal binary media parameters fail closed":
    for mediaType in [
      "application/protobuf; encoding=json",
      "application/protobuf; charset=utf-8",
      "application/protobuf; version=1"
    ]:
      let handler = proc(request: Request): Future[Response] {.async.} =
        return protobufResponse(
          request,
          encodeProtobufPayload(ReplyMessage()),
          contentType = mediaType
        )
      let outcome = waitOutcome newClient(
        newInProcessTransport(handler)
      ).getProtobuf("/invalid-parameter", ReplyMessage)
      check outcome.isErr
      check outcome.error.codecCode == "protobuf_content_type"

  test "legacy response media types can be disabled":
    let handler = proc(request: Request): Future[Response] {.async.} =
      return protobufResponse(
        request,
        encodeProtobufPayload(ReplyMessage()),
        contentType = "application/x-protobuf"
      )
    let client = newClient(newInProcessTransport(handler))
    check waitOutcome(client.getProtobuf("/legacy", ReplyMessage)).isOk
    var options = defaultProtobufCodecOptions()
    options.acceptLegacyMediaTypes = false
    let strict = waitOutcome client.getProtobuf(
      "/standard-only", ReplyMessage, codecOptions = options
    )
    check strict.isErr
    check strict.error.codecCode == "protobuf_content_type"

  test "missing Content-Type is configurable":
    let handler = proc(request: Request): Future[Response] {.async.} =
      return protobufResponse(
        request, encodeProtobufPayload(ReplyMessage()), contentType = ""
      )
    let client = newClient(newInProcessTransport(handler))
    check waitOutcome(client.getProtobuf("/lenient", ReplyMessage)).isOk
    var options = defaultProtobufCodecOptions()
    options.requireContentType = true
    let strict = waitOutcome client.getProtobuf(
      "/strict", ReplyMessage, codecOptions = options
    )
    check strict.isErr
    check strict.error.codecCode == "protobuf_content_type"

  test "incompatible Content-Type retains response context":
    let handler = proc(request: Request): Future[Response] {.async.} =
      return protobufResponse(request, "bad", contentType = "text/plain")
    let outcome = waitOutcome newClient(
      newInProcessTransport(handler)
    ).getProtobuf("/wrong-type", ReplyMessage)
    check outcome.isErr
    check outcome.error.codecCode == "protobuf_content_type"
    check outcome.error.url == "/wrong-type"
    check outcome.error.status == 200
    check outcome.error.hasResponse

  test "HTTP status is returned before Protobuf decoding":
    let handler = proc(request: Request): Future[Response] {.async.} =
      return protobufResponse(request, "not-protobuf", status = 503)
    let outcome = waitOutcome newClient(
      newInProcessTransport(handler)
    ).getProtobuf("/unavailable", ReplyMessage)
    check outcome.isErr
    check outcome.error.kind == jeHttpStatus
    check outcome.error.codecCode.len == 0

  test "malformed HTTP response retains body status and URL":
    let handler = proc(request: Request): Future[Response] {.async.} =
      return protobufResponse(request, "\x80")
    let outcome = waitOutcome newClient(
      newInProcessTransport(handler)
    ).getProtobuf("/truncated", ReplyMessage)
    check outcome.isErr
    check outcome.error.kind == jeCodec
    check outcome.error.codecCode == "protobuf_decode"
    check outcome.error.url == "/truncated"
    check outcome.error.status == 200
    check outcome.error.hasResponse
    check outcome.error.response.body == "\x80"

  test "request byte limit is applied to encoded Protobuf":
    var dispatched = false
    let handler = proc(request: Request): Future[Response] {.async.} =
      dispatched = true
      return protobufResponse(request, request.body)
    let value = ScalarMessage(name: "request")
    let encoded = encodeProtobufPayload(value)
    var options = defaultRequestOptions()
    options.maxRequestBytes = encoded.len - 1
    let outcome = waitOutcome newClient(
      newInProcessTransport(handler)
    ).postProtobuf("/limit", value, ScalarMessage, options = options)
    check outcome.isErr
    check outcome.error.kind == jeBodyTooLarge
    check not dispatched

  test "response byte limit is applied before Protobuf decoding":
    let encoded = encodeProtobufPayload(ReplyMessage(count: 9))
    let handler = proc(request: Request): Future[Response] {.async.} =
      return protobufResponse(request, encoded)
    var options = defaultRequestOptions()
    options.maxResponseBytes = encoded.len - 1
    let outcome = waitOutcome newClient(
      newInProcessTransport(handler)
    ).getProtobuf("/limit", ReplyMessage, options = options)
    check outcome.isErr
    check outcome.error.kind == jeBodyTooLarge

  test "PUT PATCH and arbitrary methods are dispatched":
    var methods: seq[RequestMethod]
    let handler = proc(request: Request): Future[Response] {.async.} =
      methods.add request.httpMethod
      return protobufResponse(
        request, encodeProtobufPayload(ReplyMessage(accepted: true))
      )
    let client = newClient(newInProcessTransport(handler))
    discard waitFor client.putProtobuf("/", ScalarMessage(), ReplyMessage)
    discard waitFor client.patchProtobuf("/", ScalarMessage(), ReplyMessage)
    discard waitFor client.sendProtobuf(
      rmDelete, "/", ScalarMessage(), ReplyMessage
    )
    check methods == @[rmPut, rmPatch, rmDelete]

  test "transport failures are not rewritten as codec failures":
    let handler = proc(request: Request): Future[Response] {.async.} =
      raise newException(IOError, "offline")
    let outcome = waitOutcome newClient(
      newInProcessTransport(handler)
    ).getProtobuf("/offline", ReplyMessage)
    check outcome.isErr
    check outcome.error.kind == jeTransport
    check outcome.error.codecCode.len == 0
