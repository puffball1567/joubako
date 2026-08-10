## Native gRPC over Joubako's HTTP/2 transport.
##
## This module implements Protobuf unary calls and backpressured server
## streams. HTTP/2 framing remains owned by the transport; this layer owns the
## gRPC message envelope, completion trailers, metadata, and status mapping.

import std/[asyncdispatch, base64, strutils]
import ./[client, protobufcodec, result, types]

const
  GrpcMediaType* = "application/grpc+proto"
  GrpcBaseMediaType* = "application/grpc"

type
  GrpcStatusCode* = enum
    gsOk = 0,
    gsCancelled = 1,
    gsUnknown = 2,
    gsInvalidArgument = 3,
    gsDeadlineExceeded = 4,
    gsNotFound = 5,
    gsAlreadyExists = 6,
    gsPermissionDenied = 7,
    gsResourceExhausted = 8,
    gsFailedPrecondition = 9,
    gsAborted = 10,
    gsOutOfRange = 11,
    gsUnimplemented = 12,
    gsInternal = 13,
    gsUnavailable = 14,
    gsDataLoss = 15,
    gsUnauthenticated = 16

  GrpcOptions* = object
    ## Maximum decoded Protobuf bytes in one gRPC message.
    maxMessageBytes*: int
    ## Maximum messages accepted in one response stream.
    maxResponseMessages*: int
    ## Require the transport to report negotiated HTTP/2.
    requireHttp2*: bool
    ## Require application/grpc or application/grpc+proto on responses.
    requireContentType*: bool

  GrpcCompletion* = object
    code*: GrpcStatusCode
    message*: string
    ## Decoded grpc-status-details-bin bytes, when present and valid.
    details*: string
    metadata*: Headers

  GrpcResponse*[T] = object
    message*: T
    headers*: Headers
    trailers*: Headers
    completion*: GrpcCompletion

  GrpcFrameDecoder*[T] = ref object
    buffer: string
    maxMessageBytes: int
    maxMessages: int
    messagesSeen: int
    url: string
    status: int
    failed: bool

  GrpcMessageProc*[T] = proc(message: T): Future[void] {.closure.}

  GrpcStreamContext[T] = ref object
    decoder: GrpcFrameDecoder[T]
    onMessage: GrpcMessageProc[T]
    previousHeaders: ResponseHeadersProc
    previousAsync: AsyncDownloadChunkProc
    options: GrpcOptions
    path: string

func defaultGrpcOptions*(): GrpcOptions =
  GrpcOptions(
    maxMessageBytes: 16 * 1024 * 1024,
    maxResponseMessages: 65_536,
    requireHttp2: true,
    requireContentType: true
  )

proc grpcError(
    code, message: string;
    url = "";
    status = 0;
    kind = jeCodec
): ref JoubakoError =
  result = newJoubakoError(kind, message, url, status)
  result.codecCode = code
  result.codecOffset = -1

func isIdentifier(value: string): bool =
  if value.len == 0 or not (value[0].isAlphaAscii or value[0] == '_'):
    return false
  for character in value:
    if not (character.isAlphaNumeric or character == '_'):
      return false
  true

func isServiceName(value: string): bool =
  if value.len == 0:
    return false
  for part in value.split('.'):
    if not part.isIdentifier:
      return false
  true

proc grpcMethodPath*(service, methodName: string): string =
  if not service.isServiceName:
    raise grpcError(
      "grpc_invalid_service", "invalid gRPC service name: " & service,
      kind = jeInvalidRequest
    )
  if not methodName.isIdentifier:
    raise grpcError(
      "grpc_invalid_method", "invalid gRPC method name: " & methodName,
      kind = jeInvalidRequest
    )
  "/" & service & "/" & methodName

func grpcTimeoutHeader*(milliseconds: int64): string =
  ## Encodes a finite deadline using the coarsest exact-enough gRPC unit whose
  ## integer component fits the protocol's eight-digit limit.
  if milliseconds < 0:
    return ""
  if milliseconds == 0:
    return "1n"
  if milliseconds <= 99_999_999:
    return $milliseconds & "m"
  let seconds = (milliseconds + 999) div 1_000
  if seconds <= 99_999_999:
    return $seconds & "S"
  let minutes = (seconds + 59) div 60
  if minutes <= 99_999_999:
    return $minutes & "M"
  let hours = min(99_999_999'i64, (minutes + 59) div 60)
  $hours & "H"

proc setGrpcBinaryMetadata*(
    headers: var Headers;
    name: string;
    value: string
) =
  let normalized = name.strip.toLowerAscii
  if not normalized.endsWith("-bin") or normalized.len <= 4:
    raise grpcError(
      "grpc_invalid_metadata",
      "binary gRPC metadata names must end in -bin",
      kind = jeInvalidRequest
    )
  for character in normalized:
    if not (character.isAlphaNumeric or character in {'_', '-', '.'}):
      raise grpcError(
        "grpc_invalid_metadata",
        "binary gRPC metadata name contains an invalid character",
        kind = jeInvalidRequest
      )
  if normalized.startsWith("grpc-"):
    raise grpcError(
      "grpc_reserved_metadata",
      "application metadata must not use the reserved grpc- prefix",
      kind = jeInvalidRequest
    )
  headers.set(normalized, base64.encode(value).strip(chars = {'='}))

proc decodeGrpcBinaryMetadata*(
    headers: Headers;
    name: string
): JResult[seq[string]] =
  let normalized = name.strip.toLowerAscii
  if not normalized.endsWith("-bin") or normalized.len <= 4:
    return err[seq[string]](grpcError(
      "grpc_invalid_metadata",
      "binary gRPC metadata names must end in -bin",
      kind = jeInvalidRequest
    ))
  var decoded: seq[string]
  try:
    for combined in headers.getAll(normalized):
      for item in combined.split(','):
        var encoded = item.strip
        while encoded.len mod 4 != 0:
          encoded.add '='
        decoded.add base64.decode(encoded)
    ok(decoded)
  except ValueError as error:
    err[seq[string]](grpcError(
      "grpc_invalid_binary_metadata",
      "invalid Base64 gRPC metadata: " & error.msg
    ))

proc tryEncodeGrpcFrame*[T](
    value: T;
    options = defaultGrpcOptions();
    url = ""
): JResult[string] =
  var protobufOptions = defaultProtobufCodecOptions()
  protobufOptions.maxPayloadBytes = -1
  let encoded = tryEncodeProtobufPayload(value, protobufOptions, url)
  if encoded.isErr:
    return err[string](encoded.error)
  if options.maxMessageBytes >= 0 and
      encoded.value.len > options.maxMessageBytes:
    return err[string](grpcError(
      "grpc_message_too_large",
      "encoded gRPC message is " & $encoded.value.len &
        " bytes; limit is " & $options.maxMessageBytes,
      url
    ))
  if encoded.value.len.uint64 > uint32.high.uint64:
    return err[string](grpcError(
      "grpc_message_too_large",
      "encoded gRPC message exceeds the 32-bit framing limit",
      url
    ))
  let length = encoded.value.len.uint32
  var frame = newString(5 + encoded.value.len)
  frame[0] = '\0'
  frame[1] = char((length shr 24) and 0xff)
  frame[2] = char((length shr 16) and 0xff)
  frame[3] = char((length shr 8) and 0xff)
  frame[4] = char(length and 0xff)
  if encoded.value.len > 0:
    copyMem(frame[5].addr, encoded.value[0].unsafeAddr, encoded.value.len)
  ok(move(frame))

proc encodeGrpcFrame*[T](
    value: T;
    options = defaultGrpcOptions();
    url = ""
): string =
  let encoded = tryEncodeGrpcFrame(value, options, url)
  if encoded.isErr:
    raise encoded.error
  encoded.value

proc newGrpcFrameDecoder*[T](
    _: typedesc[T];
    options = defaultGrpcOptions();
    url = "";
    status = 0
): GrpcFrameDecoder[T] =
  GrpcFrameDecoder[T](
    maxMessageBytes: options.maxMessageBytes,
    maxMessages: options.maxResponseMessages,
    url: url,
    status: status
  )

proc feed*[T](
    decoder: GrpcFrameDecoder[T];
    chunk: string
): JResult[seq[T]] =
  if decoder == nil or decoder.failed:
    return err[seq[T]](grpcError(
      "grpc_decoder_state", "gRPC frame decoder is not usable"
    ))
  decoder.buffer.add chunk
  var consumed = 0
  var messages: seq[T]
  while decoder.buffer.len - consumed >= 5:
    let flag = ord(decoder.buffer[consumed])
    if flag notin [0, 1]:
      decoder.failed = true
      return err[seq[T]](grpcError(
        "grpc_invalid_compression_flag",
        "gRPC compressed flag must be zero or one",
        decoder.url,
        decoder.status
      ))
    let messageLength =
      (uint32(ord(decoder.buffer[consumed + 1])) shl 24) or
      (uint32(ord(decoder.buffer[consumed + 2])) shl 16) or
      (uint32(ord(decoder.buffer[consumed + 3])) shl 8) or
      uint32(ord(decoder.buffer[consumed + 4]))
    if decoder.maxMessageBytes >= 0 and
        messageLength.uint64 > decoder.maxMessageBytes.uint64:
      decoder.failed = true
      return err[seq[T]](grpcError(
        "grpc_message_too_large",
        "gRPC frame declares " & $messageLength &
          " bytes; limit is " & $decoder.maxMessageBytes,
        decoder.url,
        decoder.status
      ))
    if messageLength.uint64 > high(int).uint64:
      decoder.failed = true
      return err[seq[T]](grpcError(
        "grpc_message_too_large",
        "gRPC frame length is not representable on this platform",
        decoder.url,
        decoder.status
      ))
    let frameLength = 5 + messageLength.int
    if decoder.buffer.len - consumed < frameLength:
      break
    if flag == 1:
      decoder.failed = true
      return err[seq[T]](grpcError(
        "grpc_compression_unsupported",
        "compressed gRPC messages are not enabled",
        decoder.url,
        decoder.status
      ))
    if decoder.maxMessages >= 0 and
        decoder.messagesSeen >= decoder.maxMessages:
      decoder.failed = true
      return err[seq[T]](grpcError(
        "grpc_too_many_messages",
        "gRPC response exceeded the configured message count",
        decoder.url,
        decoder.status
      ))
    let start = consumed + 5
    let payload = decoder.buffer[start ..< start + messageLength.int]
    var protobufOptions = defaultProtobufCodecOptions()
    protobufOptions.maxPayloadBytes = -1
    let decoded = tryDecodeProtobufPayload(
      payload, T, protobufOptions, decoder.url, decoder.status
    )
    if decoded.isErr:
      decoder.failed = true
      decoded.error.codecCode = "grpc_message_decode"
      return err[seq[T]](decoded.error)
    messages.add decoded.value
    inc decoder.messagesSeen
    consumed += frameLength
  if consumed > 0:
    if consumed == decoder.buffer.len:
      decoder.buffer.setLen(0)
    else:
      decoder.buffer = decoder.buffer[consumed .. ^1]
  ok(move(messages))

proc finish*[T](decoder: GrpcFrameDecoder[T]): JResult[void] =
  if decoder == nil or decoder.failed:
    return err[void](grpcError(
      "grpc_decoder_state", "gRPC frame decoder is not usable"
    ))
  if decoder.buffer.len > 0:
    decoder.failed = true
    return err[void](grpcError(
      "grpc_truncated_frame",
      "gRPC response ended inside a length-prefixed message",
      decoder.url,
      decoder.status
    ))
  ok()

proc tryDecodeGrpcFrames*[T](
    payload: string;
    _: typedesc[T];
    options = defaultGrpcOptions();
    url = "";
    status = 0
): JResult[seq[T]] =
  let decoder = newGrpcFrameDecoder(T, options, url, status)
  let decoded = decoder.feed(payload)
  if decoded.isErr:
    return decoded
  let completed = decoder.finish()
  if completed.isErr:
    return err[seq[T]](completed.error)
  decoded

proc decodeGrpcFrames*[T](
    payload: string;
    _: typedesc[T];
    options = defaultGrpcOptions();
    url = "";
    status = 0
): seq[T] =
  let decoded = tryDecodeGrpcFrames(payload, T, options, url, status)
  if decoded.isErr:
    raise decoded.error
  decoded.value

func hexValue(character: char): int =
  if character in {'0' .. '9'}:
    ord(character) - ord('0')
  elif character in {'a' .. 'f'}:
    ord(character) - ord('a') + 10
  elif character in {'A' .. 'F'}:
    ord(character) - ord('A') + 10
  else:
    -1

func decodeGrpcMessage(value: string): string =
  var index = 0
  while index < value.len:
    if value[index] == '%' and index + 2 < value.len:
      let highNibble = value[index + 1].hexValue
      let lowNibble = value[index + 2].hexValue
      if highNibble >= 0 and lowNibble >= 0:
        result.add char(highNibble * 16 + lowNibble)
        index += 3
        continue
    result.add value[index]
    inc index

proc validateGrpcResponse(
    response: Response;
    options: GrpcOptions
): JResult[void] =
  if options.requireHttp2 and response.httpVersion != "HTTP/2":
    return err[void](grpcError(
      "grpc_requires_http2",
      "gRPC requires a negotiated HTTP/2 transport",
      response.request.url,
      response.status,
      jeTransport
    ))
  if response.headers.contains("content-type"):
    let mediaType = response.headers.get("content-type").split(';', 1)[0]
      .strip.toLowerAscii
    if mediaType notin [GrpcBaseMediaType, GrpcMediaType]:
      return err[void](grpcError(
        "grpc_content_type",
        "unsupported gRPC response Content-Type: " &
          response.headers.get("content-type"),
        response.request.url,
        response.status
      ))
  elif options.requireContentType:
    return err[void](grpcError(
      "grpc_content_type",
      "gRPC response is missing Content-Type",
      response.request.url,
      response.status
    ))
  ok()

proc decodeStatusDetails(value: string): string =
  if value.len == 0:
    return ""
  var encoded = value.strip
  while encoded.len mod 4 != 0:
    encoded.add '='
  try:
    base64.decode(encoded)
  except ValueError:
    ""

proc grpcCompletion*(response: Response): JResult[GrpcCompletion] =
  let trailerValues = response.trailers.getAll("grpc-status")
  let headerValues = response.headers.getAll("grpc-status")
  if trailerValues.len > 0 and headerValues.len > 0:
    return err[GrpcCompletion](grpcError(
      "grpc_duplicate_status",
      "gRPC status appeared in both headers and trailers",
      response.request.url,
      response.status
    ))
  if headerValues.len > 0 and response.body.len > 0:
    return err[GrpcCompletion](grpcError(
      "grpc_trailers_only_body",
      "a trailers-only gRPC response must not contain a message body",
      response.request.url,
      response.status
    ))
  let source = if trailerValues.len > 0: response.trailers else: response.headers
  let values = source.getAll("grpc-status")
  if values.len != 1:
    let errorCode =
      if values.len == 0: "grpc_missing_status"
      else: "grpc_duplicate_status"
    return err[GrpcCompletion](grpcError(
      errorCode,
      "gRPC response must contain exactly one grpc-status value",
      response.request.url,
      response.status
    ))
  let raw = values[0]
  if raw.len == 0 or (raw.len > 1 and raw[0] == '0'):
    return err[GrpcCompletion](grpcError(
      "grpc_invalid_status", "invalid grpc-status: " & raw,
      response.request.url, response.status
    ))
  var numeric = 0
  for character in raw:
    if character notin {'0' .. '9'}:
      return err[GrpcCompletion](grpcError(
        "grpc_invalid_status", "invalid grpc-status: " & raw,
        response.request.url, response.status
      ))
    numeric = numeric * 10 + ord(character) - ord('0')
    if numeric > ord(GrpcStatusCode.high):
      return err[GrpcCompletion](grpcError(
        "grpc_invalid_status", "unknown grpc-status: " & raw,
        response.request.url, response.status
      ))
  if numeric == ord(gsOk) and source.contains("grpc-status-details-bin"):
    return err[GrpcCompletion](grpcError(
      "grpc_invalid_status_details",
      "grpc-status-details-bin is not valid for an OK status",
      response.request.url,
      response.status
    ))
  ok(GrpcCompletion(
    code: GrpcStatusCode(numeric),
    message: source.get("grpc-message").decodeGrpcMessage,
    details: source.get("grpc-status-details-bin").decodeStatusDetails,
    metadata: source
  ))

proc grpcStatusError(
    completion: GrpcCompletion;
    response: Response
): ref JoubakoError =
  let message =
    if completion.message.len > 0: completion.message
    else: "gRPC call failed with status " & $ord(completion.code)
  result = grpcError(
    "grpc_status_" & $ord(completion.code),
    message,
    response.request.url,
    response.status,
    jeRpcStatus
  )
  result.grpcStatus = ord(completion.code)
  result.grpcMessage = completion.message
  result.grpcDetails = completion.details
  result.attachResponse(response)

proc prepareGrpcHeaders(
    client: Client;
    headers: Headers;
    options: RequestOptions
): Headers =
  result = headers
  result.set("content-type", GrpcMediaType)
  if not result.contains("accept"):
    result.set("accept", GrpcMediaType)
  result.set("te", "trailers")
  if not result.contains("grpc-accept-encoding"):
    result.set("grpc-accept-encoding", "identity")
  let timeout =
    if options.timeoutMs != 0: options.timeoutMs
    elif client != nil: client.defaultOptions.timeoutMs
    else: -1
  let encoded = grpcTimeoutHeader(timeout.int64)
  if encoded.len > 0:
    result.set("grpc-timeout", encoded)
  else:
    result.del("grpc-timeout")

proc streamHeadersCallback[T](
    context: GrpcStreamContext[T]
): ResponseHeadersProc =
  result = proc(status: int; responseHeaders: Headers) =
    if context.previousHeaders != nil:
      context.previousHeaders(status, responseHeaders)
    let preview = Response(
      status: status,
      httpVersion: "HTTP/2",
      headers: responseHeaders,
      request: Request(url: context.path)
    )
    let valid = validateGrpcResponse(preview, context.options)
    if valid.isErr:
      raise valid.error

proc streamChunkCallback[T](
    context: GrpcStreamContext[T]
): AsyncDownloadChunkProc =
  result = proc(chunk: string): Future[void] {.async.} =
    if context.previousAsync != nil:
      await context.previousAsync(chunk)
    let messages = context.decoder.feed(chunk)
    if messages.isErr:
      raise messages.error
    for message in messages.value:
      await context.onMessage(message)

proc grpcUnaryCall*[TRequest, TResponse](
    client: Client;
    service, methodName: string;
    value: TRequest;
    _: typedesc[TResponse];
    headers = initHeaders();
    options = RequestOptions();
    grpcOptions = defaultGrpcOptions()
): Future[JResult[GrpcResponse[TResponse]]] {.async.} =
  var path: string
  try:
    path = grpcMethodPath(service, methodName)
  except JoubakoError as error:
    return err[GrpcResponse[TResponse]](error)
  let encoded = tryEncodeGrpcFrame(value, grpcOptions, path)
  if encoded.isErr:
    return err[GrpcResponse[TResponse]](encoded.error)
  let response = await client.post(
    path,
    encoded.value,
    prepareGrpcHeaders(client, headers, options),
    options
  )
  if response.isErr:
    return err[GrpcResponse[TResponse]](response.error)
  let valid = validateGrpcResponse(response.value, grpcOptions)
  if valid.isErr:
    valid.error.attachResponse(response.value)
    return err[GrpcResponse[TResponse]](valid.error)
  let completion = grpcCompletion(response.value)
  if completion.isErr:
    completion.error.attachResponse(response.value)
    return err[GrpcResponse[TResponse]](completion.error)
  if completion.value.code != gsOk:
    return err[GrpcResponse[TResponse]](grpcStatusError(
      completion.value, response.value
    ))
  let decoded = tryDecodeGrpcFrames(
    response.value.body,
    TResponse,
    grpcOptions,
    response.value.request.url,
    response.value.status
  )
  if decoded.isErr:
    decoded.error.attachResponse(response.value)
    return err[GrpcResponse[TResponse]](decoded.error)
  if decoded.value.len != 1:
    let protocolError = grpcError(
      "grpc_unary_message_count",
      "unary gRPC response must contain exactly one message; received " &
        $decoded.value.len,
      response.value.request.url,
      response.value.status
    )
    protocolError.attachResponse(response.value)
    return err[GrpcResponse[TResponse]](protocolError)
  ok(GrpcResponse[TResponse](
    message: decoded.value[0],
    headers: response.value.headers,
    trailers: response.value.trailers,
    completion: completion.value
  ))

proc grpcUnary*[TRequest, TResponse](
    client: Client;
    service, methodName: string;
    value: TRequest;
    responseType: typedesc[TResponse];
    headers = initHeaders();
    options = RequestOptions();
    grpcOptions = defaultGrpcOptions()
): Future[JResult[TResponse]] {.async.} =
  let response = await client.grpcUnaryCall(
    service, methodName, value, responseType,
    headers, options, grpcOptions
  )
  if response.isErr:
    return err[TResponse](response.error)
  ok(response.value.message)

proc grpcServerStream*[TRequest, TResponse](
    client: Client;
    service, methodName: string;
    value: TRequest;
    _: typedesc[TResponse];
    onMessage: GrpcMessageProc[TResponse];
    headers = initHeaders();
    options = RequestOptions();
    grpcOptions = defaultGrpcOptions()
): Future[JResult[void]] {.async.} =
  if onMessage.isNil:
    return err[void](grpcError(
      "grpc_nil_handler", "gRPC message handler must not be nil",
      kind = jeInvalidRequest
    ))
  var path: string
  try:
    path = grpcMethodPath(service, methodName)
  except JoubakoError as error:
    return err[void](error)
  let encoded = tryEncodeGrpcFrame(value, grpcOptions, path)
  if encoded.isErr:
    return err[void](encoded.error)
  let decoder = newGrpcFrameDecoder(TResponse, grpcOptions, path)
  var streamOptions = options
  let context = GrpcStreamContext[TResponse](
    decoder: decoder,
    onMessage: onMessage,
    previousHeaders: streamOptions.onResponseHeaders,
    previousAsync: streamOptions.onDownloadChunkAsync,
    options: grpcOptions,
    path: path
  )
  streamOptions.onResponseHeaders = context.streamHeadersCallback()
  streamOptions.onDownloadChunkAsync = context.streamChunkCallback()
  streamOptions.streamResponse = true
  let response = await client.post(
    path,
    encoded.value,
    prepareGrpcHeaders(client, headers, options),
    streamOptions
  )
  if response.isErr:
    return err[void](response.error)
  let valid = validateGrpcResponse(response.value, grpcOptions)
  if valid.isErr:
    valid.error.attachResponse(response.value)
    return err[void](valid.error)
  let finished = decoder.finish()
  if finished.isErr:
    finished.error.attachResponse(response.value)
    return err[void](finished.error)
  let completion = grpcCompletion(response.value)
  if completion.isErr:
    completion.error.attachResponse(response.value)
    return err[void](completion.error)
  if response.value.trailers.getAll("grpc-status").len == 0 and
      decoder.messagesSeen > 0:
    let protocolError = grpcError(
      "grpc_trailers_only_body",
      "a trailers-only gRPC response must not contain streamed messages",
      response.value.request.url,
      response.value.status
    )
    protocolError.attachResponse(response.value)
    return err[void](protocolError)
  if completion.value.code != gsOk:
    return err[void](grpcStatusError(completion.value, response.value))
  ok()

proc grpcServerStream*[TRequest, TResponse](
    client: Client;
    service, methodName: string;
    value: TRequest;
    responseType: typedesc[TResponse];
    onMessage: proc(message: TResponse) {.closure.};
    headers = initHeaders();
    options = RequestOptions();
    grpcOptions = defaultGrpcOptions()
): Future[JResult[void]] =
  if onMessage.isNil:
    return completedResult(err[void](grpcError(
      "grpc_nil_handler", "gRPC message handler must not be nil",
      kind = jeInvalidRequest
    )))
  let wrapped = proc(message: TResponse): Future[void] {.async.} =
    onMessage(message)
  client.grpcServerStream(
    service, methodName, value, responseType, wrapped,
    headers, options, grpcOptions
  )
