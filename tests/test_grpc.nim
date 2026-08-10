import std/[asyncdispatch, strutils, unittest]
import joubako

const
  h2Base = "http://127.0.0.1:18942"
  service = "joubako.test.Echo"

type
  EchoMessage {.proto3.} = object
    id {.fieldNumber: 1, pint.}: uint32
    text {.fieldNumber: 2.}: string
    payload {.fieldNumber: 3.}: seq[byte]

proc grpcResponse(
    request: Request;
    body: string;
    statusValue = "0";
    contentType = GrpcMediaType;
    useTrailers = true
): Response =
  var headers = initHeaders()
  var trailers = initHeaders()
  if contentType.len > 0:
    headers.set("content-type", contentType)
  if useTrailers:
    trailers.set("grpc-status", statusValue)
  else:
    headers.set("grpc-status", statusValue)
  Response(
    status: 200,
    httpVersion: "HTTP/2",
    headers: headers,
    trailers: trailers,
    body: body,
    request: request
  )

proc unaryOutcome(
    handler: proc(request: Request): Future[Response] {.closure.}
): JResult[EchoMessage] =
  waitFor newClient(newInProcessTransport(handler)).grpcUnary(
    service, "Unary", EchoMessage(id: 7), EchoMessage
  )

suite "gRPC framing":
  test "an uncompressed Protobuf message uses the five-byte envelope":
    check encodeGrpcFrame(EchoMessage(id: 150)) ==
      "\x00\x00\x00\x00\x03\x08\x96\x01"

  test "empty Protobuf messages retain a zero-length frame":
    check encodeGrpcFrame(EchoMessage()) == "\x00\x00\x00\x00\x00"
    check decodeGrpcFrames(
      "\x00\x00\x00\x00\x00", EchoMessage
    ) == @[EchoMessage()]

  test "multiple messages decode in wire order":
    let first = EchoMessage(id: 1, text: "one")
    let second = EchoMessage(id: 2, text: "二")
    check decodeGrpcFrames(
      encodeGrpcFrame(first) & encodeGrpcFrame(second), EchoMessage
    ) == @[first, second]

  test "every split point is accepted by the incremental decoder":
    let value = EchoMessage(id: 42, text: "箱庭", payload: @[0'u8, 255])
    let frame = encodeGrpcFrame(value)
    for split in 0 .. frame.len:
      let decoder = newGrpcFrameDecoder(EchoMessage)
      var messages: seq[EchoMessage]
      let first = decoder.feed(frame[0 ..< split])
      check first.isOk
      if first.isOk:
        messages.add first.value
      let second = decoder.feed(frame[split ..< frame.len])
      check second.isOk
      if second.isOk:
        messages.add second.value
      check decoder.finish().isOk
      check messages == @[value]

  test "truncated headers and bodies fail only at finish":
    for payload in ["\x00", "\x00\x00\x00\x00", "\x00\x00\x00\x00\x03x"]:
      let decoder = newGrpcFrameDecoder(EchoMessage)
      check decoder.feed(payload).isOk
      let completed = decoder.finish()
      check completed.isErr
      check completed.error.codecCode == "grpc_truncated_frame"

  test "invalid flags and compressed frames without negotiation are rejected":
    let invalid = tryDecodeGrpcFrames(
      "\x02\x00\x00\x00\x00", EchoMessage
    )
    check invalid.isErr
    check invalid.error.codecCode == "grpc_invalid_compression_flag"
    let compressed = tryDecodeGrpcFrames(
      "\x01\x00\x00\x00\x00", EchoMessage
    )
    check compressed.isErr
    check compressed.error.codecCode == "grpc_compression_missing_encoding"

  test "gzip frames round trip across every incremental split point":
    let value = EchoMessage(
      id: 77, text: repeat("compressible-", 128), payload: @[0'u8, 255]
    )
    var options = defaultGrpcOptions()
    options.requestEncoding = geGzip
    let frame = encodeGrpcFrame(value, options)
    check frame[0] == '\1'
    check frame.len < encodeGrpcFrame(value).len
    for split in 0 .. frame.len:
      let decoder = newGrpcFrameDecoder(
        EchoMessage, options, encoding = geGzip
      )
      var messages: seq[EchoMessage]
      let first = decoder.feed(frame[0 ..< split])
      check first.isOk
      if first.isOk:
        messages.add first.value
      let second = decoder.feed(frame[split ..< frame.len])
      check second.isOk
      if second.isOk:
        messages.add second.value
      check decoder.finish().isOk
      check messages == @[value]

  test "one gzip stream may mix compressed and uncompressed messages":
    let plain = EchoMessage(id: 1, text: "plain")
    let compressed = EchoMessage(id: 2, text: repeat("gzip-", 64))
    var options = defaultGrpcOptions()
    options.requestEncoding = geGzip
    let decoded = tryDecodeGrpcFrames(
      encodeGrpcFrame(plain) & encodeGrpcFrame(compressed, options),
      EchoMessage,
      options,
      encoding = geGzip
    )
    check decoded.isOk
    if decoded.isOk:
      check decoded.value == @[plain, compressed]

  test "gzip supports empty messages and bounds wire and expanded sizes":
    var options = defaultGrpcOptions()
    options.requestEncoding = geGzip
    let emptyFrame = encodeGrpcFrame(EchoMessage(), options)
    check decodeGrpcFrames(
      emptyFrame, EchoMessage, options, encoding = geGzip
    ) == @[EchoMessage()]

    options.maxFrameBytes = emptyFrame.len - 6
    let wireBound = tryEncodeGrpcFrame(EchoMessage(), options)
    check wireBound.isErr
    check wireBound.error.codecCode == "grpc_frame_too_large"

    var expandedOptions = defaultGrpcOptions()
    expandedOptions.requestEncoding = geGzip
    let expandedFrame = encodeGrpcFrame(
      EchoMessage(text: repeat('x', 64 * 1024)), expandedOptions
    )
    expandedOptions.maxMessageBytes = 1024
    let expanded = tryDecodeGrpcFrames(
      expandedFrame, EchoMessage, expandedOptions, encoding = geGzip
    )
    check expanded.isErr
    check expanded.error.codecCode == "grpc_message_too_large"
    check expanded.error.kind == jeBodyTooLarge

  test "corrupt gzip frames are structured compression errors":
    var options = defaultGrpcOptions()
    options.requestEncoding = geGzip
    var frame = encodeGrpcFrame(EchoMessage(text: "checksum"), options)
    frame[^1] = char(ord(frame[^1]) xor 0xff)
    let corrupt = tryDecodeGrpcFrames(
      frame, EchoMessage, options, encoding = geGzip
    )
    check corrupt.isErr
    check corrupt.error.kind == jeCompression
    check corrupt.error.codecCode == "grpc_decompression_failed"

  test "declared message limits fail before a body is present":
    var options = defaultGrpcOptions()
    options.maxMessageBytes = 3
    let outcome = tryDecodeGrpcFrames(
      "\x00\x00\x00\x00\x04", EchoMessage, options
    )
    check outcome.isErr
    check outcome.error.codecCode == "grpc_message_too_large"
    options.maxFrameBytes = 3
    let compressed = tryDecodeGrpcFrames(
      "\x01\x00\x00\x00\x04", EchoMessage, options, encoding = geGzip
    )
    check compressed.isErr
    check compressed.error.codecCode == "grpc_frame_too_large"

  test "encoded message limits include exact boundaries":
    let value = EchoMessage(text: "bounded")
    let wireBytes = encodeProtobufPayload(value).len
    var options = defaultGrpcOptions()
    options.maxMessageBytes = wireBytes
    check tryEncodeGrpcFrame(value, options).isOk
    options.maxMessageBytes = wireBytes - 1
    let outcome = tryEncodeGrpcFrame(value, options)
    check outcome.isErr
    check outcome.error.codecCode == "grpc_message_too_large"

  test "message count limits apply to empty frames":
    var options = defaultGrpcOptions()
    options.maxResponseMessages = 1
    let outcome = tryDecodeGrpcFrames(
      "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",
      EchoMessage,
      options
    )
    check outcome.isErr
    check outcome.error.codecCode == "grpc_too_many_messages"

  test "malformed Protobuf inside a complete frame is structured":
    let outcome = tryDecodeGrpcFrames(
      "\x00\x00\x00\x00\x01\x80", EchoMessage
    )
    check outcome.isErr
    check outcome.error.codecCode == "grpc_message_decode"

suite "gRPC names deadlines and metadata":
  test "service and method names build the canonical path":
    check grpcMethodPath("package.v1.Greeter", "SayHello") ==
      "/package.v1.Greeter/SayHello"

  test "invalid service and method names are rejected":
    for (serviceName, methodName) in [
      ("", "Call"), ("bad..Service", "Call"),
      ("bad/Service", "Call"), ("Good.Service", "bad/method")
    ]:
      expect JoubakoError:
        discard grpcMethodPath(serviceName, methodName)

  test "deadlines use valid eight-digit gRPC timeout values":
    check grpcTimeoutHeader(-1) == ""
    check grpcTimeoutHeader(0) == "1n"
    check grpcTimeoutHeader(30_000) == "30000m"
    check grpcTimeoutHeader(99_999_999) == "99999999m"
    check grpcTimeoutHeader(100_000_000) == "100000S"

  test "binary metadata emits unpadded Base64 and accepts either form":
    var headers = initHeaders()
    headers.setGrpcBinaryMetadata("trace-bin", "\x00\xff")
    check headers.get("trace-bin") == "AP8"
    headers.add("trace-bin", "YQ==")
    let decoded = headers.decodeGrpcBinaryMetadata("trace-bin")
    check decoded.isOk
    if decoded.isOk:
      check decoded.value == @["\x00\xff", "a"]

  test "binary metadata rejects bad names and malformed Base64":
    var headers = initHeaders()
    expect JoubakoError:
      headers.setGrpcBinaryMetadata("trace", "value")
    expect JoubakoError:
      headers.setGrpcBinaryMetadata("grpc-private-bin", "value")
    expect JoubakoError:
      headers.setGrpcBinaryMetadata("bad name-bin", "value")
    headers.set("trace-bin", "%%%")
    let decoded = headers.decodeGrpcBinaryMetadata("trace-bin")
    check decoded.isErr
    check decoded.error.codecCode == "grpc_invalid_binary_metadata"

suite "gRPC protocol validation":
  test "request and response gzip negotiation is strict":
    var gzipOptions = defaultGrpcOptions()
    gzipOptions.requestEncoding = geGzip
    let value = EchoMessage(id: 81, text: repeat("gzip", 32))
    let handler = proc(request: Request): Future[Response] {.async.} =
      check request.headers.get("grpc-encoding") == "gzip"
      check request.headers.get("grpc-accept-encoding") ==
        (if geGzip in gzipOptions.acceptedEncodings:
          "identity,gzip"
        else:
          "identity")
      var response = grpcResponse(
        request, encodeGrpcFrame(value, gzipOptions)
      )
      response.headers.set("grpc-encoding", "gzip")
      return response
    let accepted = waitFor newClient(newInProcessTransport(handler)).grpcUnary(
      service, "Unary", value, EchoMessage, grpcOptions = gzipOptions
    )
    check accepted.isOk
    if accepted.isOk:
      check accepted.value == value

    gzipOptions.acceptedEncodings = {geIdentity}
    let rejected = waitFor newClient(newInProcessTransport(handler)).grpcUnary(
      service, "Unary", value, EchoMessage, grpcOptions = gzipOptions
    )
    check rejected.isErr
    check rejected.error.codecCode == "grpc_encoding_not_accepted"

  test "unknown and duplicate response encodings fail closed":
    for encodings in [@["br"], @["gzip", "gzip"], @["gzip,br"]]:
      let handler = proc(request: Request): Future[Response] {.async.} =
        var response = grpcResponse(
          request, encodeGrpcFrame(EchoMessage())
        )
        for encoding in encodings:
          response.headers.add("grpc-encoding", encoding)
        return response
      let outcome = unaryOutcome(handler)
      check outcome.isErr
      check outcome.error.codecCode in [
        "grpc_encoding_unsupported", "grpc_duplicate_encoding"
      ]
  test "trailers-only failures are accepted without a message body":
    let handler = proc(request: Request): Future[Response] {.async.} =
      var response = grpcResponse(
        request, "", statusValue = "7", useTrailers = false
      )
      response.headers.set("grpc-message", "denied")
      return response
    let outcome = unaryOutcome(handler)
    check outcome.isErr
    check outcome.error.kind == jeRpcStatus
    check outcome.error.grpcStatus == ord(gsPermissionDenied)

  test "trailers-only responses reject message bodies":
    let handler = proc(request: Request): Future[Response] {.async.} =
      return grpcResponse(
        request, encodeGrpcFrame(EchoMessage(id: 8)), useTrailers = false
      )
    let outcome = unaryOutcome(handler)
    check outcome.isErr
    check outcome.error.codecCode == "grpc_trailers_only_body"

  test "OK status rejects error details":
    let handler = proc(request: Request): Future[Response] {.async.} =
      var response = grpcResponse(
        request, encodeGrpcFrame(EchoMessage())
      )
      response.trailers.set("grpc-status-details-bin", "AA")
      return response
    let outcome = unaryOutcome(handler)
    check outcome.isErr
    check outcome.error.codecCode == "grpc_invalid_status_details"

  test "rich unary calls expose successful initial and final metadata":
    let handler = proc(request: Request): Future[Response] {.async.} =
      var response = grpcResponse(
        request, encodeGrpcFrame(EchoMessage(id: 10))
      )
      response.headers.set("request-id", "abc")
      response.trailers.set("quota-left", "9")
      return response
    let outcome = waitFor newClient(
      newInProcessTransport(handler)
    ).grpcUnaryCall(service, "Unary", EchoMessage(), EchoMessage)
    check outcome.isOk
    if outcome.isOk:
      check outcome.value.message.id == 10
      check outcome.value.headers.get("request-id") == "abc"
      check outcome.value.trailers.get("quota-left") == "9"
      check outcome.value.completion.code == gsOk

  test "non-gRPC content types fail with response context":
    let handler = proc(request: Request): Future[Response] {.async.} =
      return grpcResponse(
        request, encodeGrpcFrame(EchoMessage()), contentType = "text/plain"
      )
    let outcome = unaryOutcome(handler)
    check outcome.isErr
    check outcome.error.codecCode == "grpc_content_type"
    check outcome.error.hasResponse

  test "HTTP/2 is required by default and explicitly configurable":
    let handler = proc(request: Request): Future[Response] {.async.} =
      var response = grpcResponse(
        request, encodeGrpcFrame(EchoMessage(id: 9))
      )
      response.httpVersion = "HTTP/1.1"
      return response
    let strict = unaryOutcome(handler)
    check strict.isErr
    check strict.error.codecCode == "grpc_requires_http2"
    var options = defaultGrpcOptions()
    options.requireHttp2 = false
    let relaxed = waitFor newClient(
      newInProcessTransport(handler)
    ).grpcUnary(service, "Unary", EchoMessage(), EchoMessage,
      grpcOptions = options)
    check relaxed.isOk

  test "missing duplicate malformed and unknown statuses fail closed":
    for values in [@[], @["0", "0"], @["00"], @["x"], @["17"]]:
      let handler = proc(request: Request): Future[Response] {.async.} =
        var response = grpcResponse(
          request, encodeGrpcFrame(EchoMessage()), statusValue = ""
        )
        response.trailers = initHeaders()
        for value in values:
          response.trailers.add("grpc-status", value)
        return response
      let outcome = unaryOutcome(handler)
      check outcome.isErr
      check outcome.error.codecCode in [
        "grpc_missing_status", "grpc_duplicate_status", "grpc_invalid_status"
      ]

  test "unary calls require exactly one response message":
    for body in [
      "",
      encodeGrpcFrame(EchoMessage(id: 1)) &
        encodeGrpcFrame(EchoMessage(id: 2))
    ]:
      let handler = proc(request: Request): Future[Response] {.async.} =
        return grpcResponse(request, body)
      let outcome = unaryOutcome(handler)
      check outcome.isErr
      check outcome.error.codecCode == "grpc_unary_message_count"

  test "non-OK status maps message details and final metadata":
    let handler = proc(request: Request): Future[Response] {.async.} =
      var response = grpcResponse(request, "", statusValue = "14")
      response.trailers.set("grpc-message", "try%20later%ZZ")
      response.trailers.set("grpc-status-details-bin", "ZGV0YWls")
      return response
    let outcome = unaryOutcome(handler)
    check outcome.isErr
    check outcome.error.kind == jeRpcStatus
    check outcome.error.grpcStatus == ord(gsUnavailable)
    check outcome.error.grpcMessage == "try later%ZZ"
    check outcome.error.grpcDetails == "detail"
    check outcome.error.response.trailers.get("grpc-status") == "14"

suite "gRPC over real HTTP/2":
  test "gzip messages interoperate with Node zlib over real HTTP/2":
    let transport = newHttp2Transport(allowH2c = true)
    let client = newClient(transport, h2Base)
    var options = defaultGrpcOptions()
    options.requestEncoding = geGzip
    let value = EchoMessage(
      id: 909,
      text: repeat("native-gzip-", 256),
      payload: @[0'u8, 1, 2, 255]
    )
    let outcome = waitFor client.grpcUnary(
      service, "CompressedUnary", value, EchoMessage,
      grpcOptions = options
    )
    check outcome.isOk
    if outcome.isOk:
      check outcome.value == value
    waitFor transport.close()

  test "gzip is shared by server client and bidirectional streams":
    let transport = newHttp2Transport(allowH2c = true)
    let client = newClient(transport, h2Base)
    var options = defaultGrpcOptions()
    options.requestEncoding = geGzip

    let serverValue = EchoMessage(id: 301, text: repeat("server-", 64))
    var serverReceived: seq[EchoMessage]
    let receiveServer = proc(message: EchoMessage) =
      serverReceived.add message
    let serverResult = waitFor client.grpcServerStream(
      service,
      "Stream",
      serverValue,
      EchoMessage,
      receiveServer,
      grpcOptions = options
    )
    check serverResult.isOk
    check serverReceived == @[serverValue, serverValue]

    let clientStream = client.openGrpcClientStream(
      service, "ClientStream", EchoMessage, EchoMessage,
      grpcOptions = options,
      maxBufferedBytes = 13
    )
    for index in 1 .. 8:
      check (waitFor clientStream.send(EchoMessage(
        id: index.uint32, text: repeat("client-", index)
      ))).isOk
    let clientResult = waitFor clientStream.finish()
    check clientResult.isOk
    if clientResult.isOk:
      check clientResult.value.message == EchoMessage(
        id: 8, text: repeat("client-", 8)
      )

    var bidiReceived: seq[EchoMessage]
    let receive = proc(message: EchoMessage): Future[void] {.async.} =
      await sleepAsync(1)
      bidiReceived.add message
    let bidi = client.openGrpcBidiStream(
      service, "Bidi", EchoMessage, EchoMessage, receive,
      grpcOptions = options,
      maxBufferedBytes = 15
    )
    for index in 1 .. 6:
      check (waitFor bidi.send(EchoMessage(
        id: index.uint32, text: repeat("bidi-", 32)
      ))).isOk
    let bidiResult = waitFor bidi.finish()
    check bidiResult.isOk
    check bidiReceived.len == 6
    for index, message in bidiReceived:
      check message.id == (index + 1).uint32
      check message.text == repeat("bidi-", 32)
    waitFor transport.close()

  test "client streaming sends many framed messages and receives one reply":
    let transport = newHttp2Transport(allowH2c = true)
    let client = newClient(transport, h2Base)
    let stream = client.openGrpcClientStream(
      service, "ClientStream", EchoMessage, EchoMessage,
      maxBufferedBytes = 11
    )
    for index in 1 .. 32:
      let sent = waitFor stream.send(EchoMessage(id: index.uint32, text: $index))
      check sent.isOk
    let outcome = waitFor stream.finish()
    check outcome.isOk
    if outcome.isOk:
      check outcome.value.message == EchoMessage(id: 32, text: "32")
      check outcome.value.completion.code == gsOk
    waitFor transport.close()

  test "bidirectional streaming receives messages before request completion":
    let transport = newHttp2Transport(allowH2c = true)
    let client = newClient(transport, h2Base)
    var received: seq[EchoMessage]
    let receive = proc(message: EchoMessage): Future[void] {.async.} =
      await sleepAsync(1)
      received.add message
    let stream = client.openGrpcBidiStream(
      service,
      "Bidi",
      EchoMessage,
      EchoMessage,
      receive,
      maxBufferedBytes = 9
    )
    for index in 1 .. 12:
      let sent = waitFor stream.send(EchoMessage(id: index.uint32, text: "bidi"))
      check sent.isOk
    for _ in 0 ..< 100:
      if received.len > 0:
        break
      waitFor sleepAsync(2)
    check received.len > 0
    let completion = waitFor stream.finish()
    check completion.isOk
    if completion.isOk:
      check completion.value.metadata.get("x-bidi-finished") == "yes"
    check received.len == 12
    for index, message in received:
      check message == EchoMessage(id: (index + 1).uint32, text: "bidi")
    waitFor transport.close()

  test "unary request negotiates HTTP/2 and validates final trailers":
    let transport = newHttp2Transport(allowH2c = true)
    let client = newClient(transport, h2Base)
    let value = EchoMessage(
      id: 42, text: "native gRPC 箱庭", payload: @[0'u8, 255]
    )
    let outcome = waitFor client.grpcUnary(service, "Unary", value, EchoMessage)
    check outcome.isOk
    if outcome.isOk:
      check outcome.value == value
    waitFor transport.close()

  test "server streams decode split frames with awaited backpressure":
    let transport = newHttp2Transport(allowH2c = true)
    let client = newClient(transport, h2Base)
    let value = EchoMessage(id: 5, text: "stream")
    var received: seq[EchoMessage]
    let outcome = waitFor client.grpcServerStream(
      service,
      "Stream",
      value,
      EchoMessage,
      proc(message: EchoMessage): Future[void] {.async.} =
        await sleepAsync(1)
        received.add message
    )
    check outcome.isOk
    check received == @[value, value]
    waitFor transport.close()

  test "non-OK final trailers become structured RPC errors":
    let transport = newHttp2Transport(allowH2c = true)
    let outcome = waitFor newClient(transport, h2Base).grpcUnary(
      service, "Failure", EchoMessage(), EchoMessage
    )
    check outcome.isErr
    check outcome.error.kind == jeRpcStatus
    check outcome.error.grpcStatus == ord(gsUnavailable)
    check outcome.error.grpcMessage == "temporarily unavailable"
    check outcome.error.grpcDetails == "details"
    check outcome.error.response.trailers.get("grpc-status") == "14"
    waitFor transport.close()

  test "missing final status is rejected after a real exchange":
    let transport = newHttp2Transport(allowH2c = true)
    let outcome = waitFor newClient(transport, h2Base).grpcUnary(
      service, "MissingStatus", EchoMessage(), EchoMessage
    )
    check outcome.isErr
    check outcome.error.codecCode == "grpc_missing_status"
    check outcome.error.response.trailers.get("x-finished") == "yes"
    waitFor transport.close()
