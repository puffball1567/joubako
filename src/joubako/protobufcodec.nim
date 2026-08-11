## Typed Protocol Buffers binary encoding and HTTP integration.
##
## `protobuf_serialization` owns schema validation and wire encoding. Joubako
## adds HTTP media-type policy, payload limits, and structured Result errors.

import std/[asyncdispatch, strutils]
import pkg/protobuf_serialization
import ./[client, codec, types]
import ./result as jresult

export protobuf_serialization

const ProtobufMediaType* = "application/protobuf"

type ProtobufCodecOptions* = object
  ## Reject a response without Content-Type. A present, incompatible type is
  ## always rejected. Disabled by default for compatibility with simple APIs.
  requireContentType*: bool
  ## Also accept common pre-standard application/x-protobuf and
  ## application/vnd.google.protobuf response media types.
  acceptLegacyMediaTypes*: bool
  ## Additional bound for direct encode/decode helpers. HTTP request/response
  ## limits are enforced independently by the client and transport.
  maxPayloadBytes*: int

func defaultProtobufCodecOptions*(): ProtobufCodecOptions =
  ProtobufCodecOptions(
    requireContentType: false,
    acceptLegacyMediaTypes: true,
    maxPayloadBytes: 16 * 1024 * 1024
  )

proc protobufError(
    code, message: string;
    url = "";
    status = 0
): ref JoubakoError =
  result = newJoubakoError(jeCodec, message, url, status)
  result.codecCode = code
  result.codecOffset = -1

proc payloadLimitError(
    operation: string;
    actual, maximum: int;
    url = "";
    status = 0
): ref JoubakoError =
  protobufError(
    "protobuf_payload_too_large",
    operation & " is " & $actual & " bytes; limit is " & $maximum,
    url,
    status
  )

proc bytesToString(bytes: openArray[byte]): string =
  result = newString(bytes.len)
  if bytes.len > 0:
    copyMem(addr result[0], unsafeAddr bytes[0], bytes.len)

proc validateProtobufMediaType(
    value: string;
    acceptLegacy: bool
): string =
  let parts = value.split(';')
  let mediaType = parts[0].strip.toLowerAscii
  let accepted = mediaType == ProtobufMediaType or
    (acceptLegacy and mediaType in [
      "application/x-protobuf", "application/vnd.google.protobuf"
    ])
  if not accepted:
    return "unsupported Protobuf response Content-Type: " & value

  for index in 1 ..< parts.len:
    let parameter = parts[index].strip
    if parameter.len == 0:
      continue
    let pair = parameter.split('=', 1)
    let name = pair[0].strip.toLowerAscii
    let parameterValue =
      if pair.len == 2: pair[1].strip(chars = {' ', '\t', '"'}).toLowerAscii
      else: ""
    case name
    of "encoding":
      if parameterValue != "binary":
        return "invalid Protobuf binary encoding parameter: " & parameter
    of "charset":
      return "charset is not valid for binary Protobuf"
    of "version":
      return "unsupported Protobuf wire-format version: " & parameterValue
    else:
      discard

proc tryEncodeProtobufPayload*[T](
    value: T;
    options = defaultProtobufCodecOptions();
    url = ""
): jresult.JResult[string] =
  try:
    let encoded = Protobuf.encode(value)
    if options.maxPayloadBytes >= 0 and
        encoded.len > options.maxPayloadBytes:
      return jresult.err[string](payloadLimitError(
        "encoded Protobuf payload", encoded.len, options.maxPayloadBytes, url
      ))
    result = jresult.ok(bytesToString(encoded))
  except CatchableError as error:
    result = jresult.err[string](protobufError(
      "protobuf_encode",
      "could not encode Protobuf request: " & error.msg,
      url
    ))

proc tryDecodeProtobufPayload*[T](
    payload: string;
    _: typedesc[T];
    options = defaultProtobufCodecOptions();
    url = "";
    status = 0
): jresult.JResult[T] =
  if options.maxPayloadBytes >= 0 and payload.len > options.maxPayloadBytes:
    return jresult.err[T](payloadLimitError(
      "Protobuf response", payload.len, options.maxPayloadBytes, url, status
    ))
  try:
    result = jresult.ok(Protobuf.decode(payload, T))
  except SerializationError as error:
    result = jresult.err[T](protobufError(
      "protobuf_decode",
      "could not decode Protobuf response: " & error.msg,
      url,
      status
    ))
  except CatchableError as error:
    result = jresult.err[T](protobufError(
      "protobuf_decode",
      "could not decode Protobuf response: " & error.msg,
      url,
      status
    ))

proc encodeProtobufPayload*[T](
    value: T;
    options = defaultProtobufCodecOptions();
    url = ""
): string =
  let encoded = tryEncodeProtobufPayload(value, options, url)
  if encoded.isErr:
    raise encoded.error
  encoded.value

proc decodeProtobufPayload*[T](
    payload: string;
    _: typedesc[T];
    options = defaultProtobufCodecOptions();
    url = "";
    status = 0
): T =
  let decoded = tryDecodeProtobufPayload(payload, T, options, url, status)
  if decoded.isErr:
    raise decoded.error
  decoded.value

proc tryDecodeProtobufResponse[T](
    response: Response;
    _: typedesc[T];
    options: ProtobufCodecOptions
): jresult.JResult[T] =
  if response.headers.contains("content-type"):
    let value = response.headers.get("content-type")
    let mediaTypeError = validateProtobufMediaType(
      value, options.acceptLegacyMediaTypes
    )
    if mediaTypeError.len > 0:
      return jresult.err[T](protobufError(
        "protobuf_content_type",
        mediaTypeError,
        response.request.url,
        response.status
      ))
  elif options.requireContentType:
    return jresult.err[T](protobufError(
      "protobuf_content_type",
      "Protobuf response is missing Content-Type",
      response.request.url,
      response.status
    ))
  tryDecodeProtobufPayload(
    response.body, T, options, response.request.url, response.status
  )

proc protobufCodec*[TBody, TResponse](
    _: typedesc[TBody];
    _: typedesc[TResponse];
    options = defaultProtobufCodecOptions()
): Codec[TBody, TResponse] =
  Codec[TBody, TResponse](
    mediaType: ProtobufMediaType,
    encodeResult: proc(value: TBody): jresult.JResult[string] =
      tryEncodeProtobufPayload(value, options),
    decodeResponseResult: proc(response: Response): jresult.JResult[TResponse] =
      tryDecodeProtobufResponse(response, TResponse, options)
  )

proc getProtobuf*[T](
    client: Client;
    path: string;
    _: typedesc[T];
    headers = initHeaders();
    options = RequestOptions();
    codecOptions = defaultProtobufCodecOptions()
): Future[jresult.JResult[T]] =
  var requestHeaders = headers
  if not requestHeaders.contains("accept"):
    requestHeaders.set("accept", ProtobufMediaType)
  client.getWithCodec(
    path,
    proc(response: Response): jresult.JResult[T] =
      tryDecodeProtobufResponse(response, T, codecOptions),
    requestHeaders,
    options
  )

proc sendProtobuf*[TBody, TResponse](
    client: Client;
    httpMethod: RequestMethod;
    path: string;
    value: TBody;
    _: typedesc[TResponse];
    headers = initHeaders();
    options = RequestOptions();
    codecOptions = defaultProtobufCodecOptions()
): Future[jresult.JResult[TResponse]] =
  var requestHeaders = headers
  if not requestHeaders.contains("accept"):
    requestHeaders.set("accept", ProtobufMediaType)
  client.sendWithCodec(
    httpMethod,
    path,
    value,
    protobufCodec(TBody, TResponse, codecOptions),
    requestHeaders,
    options
  )

proc postProtobuf*[TBody, TResponse](
    client: Client;
    path: string;
    value: TBody;
    _: typedesc[TResponse];
    headers = initHeaders();
    options = RequestOptions();
    codecOptions = defaultProtobufCodecOptions()
): Future[jresult.JResult[TResponse]] =
  client.sendProtobuf(
    rmPost, path, value, TResponse, headers, options, codecOptions
  )

proc putProtobuf*[TBody, TResponse](
    client: Client;
    path: string;
    value: TBody;
    _: typedesc[TResponse];
    headers = initHeaders();
    options = RequestOptions();
    codecOptions = defaultProtobufCodecOptions()
): Future[jresult.JResult[TResponse]] =
  client.sendProtobuf(
    rmPut, path, value, TResponse, headers, options, codecOptions
  )

proc patchProtobuf*[TBody, TResponse](
    client: Client;
    path: string;
    value: TBody;
    _: typedesc[TResponse];
    headers = initHeaders();
    options = RequestOptions();
    codecOptions = defaultProtobufCodecOptions()
): Future[jresult.JResult[TResponse]] =
  client.sendProtobuf(
    rmPatch, path, value, TResponse, headers, options, codecOptions
  )
