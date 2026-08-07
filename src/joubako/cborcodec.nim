## Typed RFC 8949 CBOR encoding and HTTP integration.
##
## `cbor_serialization` owns the wire-format implementation. Joubako adds
## bounded decoding, strict single-item framing, media-type validation, and
## structured transport/codec errors.

import std/[asyncdispatch, strutils]
import pkg/cbor_serialization except ok, err
import pkg/faststreams/inputs
import ./[client, codec, types]
import ./result as jresult

export cbor_serialization except ok, err

const CborMediaType* = "application/cbor"

type CborCodecOptions* = object
  ## Parser limits applied while materializing the decoded Nim value. Zero
  ## retains cbor_serialization's meaning of unlimited for collection/string
  ## limits; nesting and bignum limits remain finite by default.
  readerConf*: CborReaderConf
  ## Reject a response without Content-Type. A present, incompatible type is
  ## always rejected. Disabled by default for compatibility with simple APIs.
  requireContentType*: bool
  ## Reject a second CBOR data item or any other trailing byte.
  rejectTrailingData*: bool
  ## Additional bound for direct encode/decode helpers. HTTP request/response
  ## limits are enforced independently by the client and transport.
  maxPayloadBytes*: int

func defaultCborCodecOptions*(): CborCodecOptions =
  CborCodecOptions(
    readerConf: defaultCborReaderConf,
    requireContentType: false,
    rejectTrailingData: true,
    maxPayloadBytes: 16 * 1024 * 1024
  )

func isCborMediaType(value: string): bool =
  let mediaType = value.split(';', 1)[0].strip.toLowerAscii
  mediaType == CborMediaType or
    (mediaType.startsWith("application/") and mediaType.endsWith("+cbor"))

proc cborError(
    code, message: string;
    url = "";
    status = 0;
    offset = -1
): ref JoubakoError =
  result = newJoubakoError(jeCodec, message, url, status)
  result.codecCode = code
  result.codecOffset = offset

proc payloadLimitError(
    operation: string;
    actual, maximum: int;
    url = "";
    status = 0
): ref JoubakoError =
  cborError(
    "cbor_payload_too_large",
    operation & " is " & $actual & " bytes; limit is " & $maximum,
    url,
    status
  )

proc bytesToString(bytes: openArray[byte]): string =
  result = newString(bytes.len)
  if bytes.len > 0:
    copyMem(addr result[0], unsafeAddr bytes[0], bytes.len)

proc tryEncodeCborPayload*[T](
    value: T;
    options = defaultCborCodecOptions();
    url = ""
): jresult.JResult[string] =
  try:
    let encoded = Cbor.encode(value)
    if options.maxPayloadBytes >= 0 and
        encoded.len > options.maxPayloadBytes:
      return jresult.err[string](payloadLimitError(
        "encoded CBOR payload", encoded.len, options.maxPayloadBytes, url
      ))
    result = jresult.ok(bytesToString(encoded))
  except CatchableError as error:
    result = jresult.err[string](cborError(
      "cbor_encode", "could not encode CBOR request: " & error.msg, url
    ))

proc tryDecodeCborPayload*[T](
    payload: string;
    _: typedesc[T];
    options = defaultCborCodecOptions();
    url = "";
    status = 0
): jresult.JResult[T] =
  if options.maxPayloadBytes >= 0 and payload.len > options.maxPayloadBytes:
    return jresult.err[T](payloadLimitError(
      "CBOR response", payload.len, options.maxPayloadBytes, url, status
    ))
  try:
    var stream = unsafeMemoryInput(payload)
    var reader = CborReader[DefaultFlavor].init(stream, options.readerConf)
    let decoded = reader.readValue(T)
    if options.rejectTrailingData and stream.readable:
      return jresult.err[T](cborError(
        "cbor_trailing_data",
        "CBOR response contains trailing data",
        url,
        status,
        stream.pos
      ))
    result = jresult.ok(decoded)
  except CborReaderError as error:
    result = jresult.err[T](cborError(
      "cbor_decode",
      "could not decode CBOR response: " & error.msg,
      url,
      status,
      error.pos
    ))
  except SerializationError as error:
    result = jresult.err[T](cborError(
      "cbor_decode", "could not decode CBOR response: " & error.msg, url, status
    ))
  except CatchableError as error:
    result = jresult.err[T](cborError(
      "cbor_decode", "could not decode CBOR response: " & error.msg, url, status
    ))

proc encodeCborPayload*[T](
    value: T;
    options = defaultCborCodecOptions();
    url = ""
): string =
  let encoded = tryEncodeCborPayload(value, options, url)
  if encoded.isErr:
    raise encoded.error
  encoded.value

proc decodeCborPayload*[T](
    payload: string;
    _: typedesc[T];
    options = defaultCborCodecOptions();
    url = "";
    status = 0
): T =
  let decoded = tryDecodeCborPayload(payload, T, options, url, status)
  if decoded.isErr:
    raise decoded.error
  decoded.value

proc tryDecodeCborResponse[T](
    response: Response;
    _: typedesc[T];
    options: CborCodecOptions
): jresult.JResult[T] =
  if response.headers.contains("content-type"):
    let value = response.headers.get("content-type")
    if not value.isCborMediaType:
      return jresult.err[T](cborError(
        "cbor_content_type",
        "unsupported CBOR response Content-Type: " & value,
        response.request.url,
        response.status
      ))
  elif options.requireContentType:
    return jresult.err[T](cborError(
      "cbor_content_type",
      "CBOR response is missing Content-Type",
      response.request.url,
      response.status
    ))
  tryDecodeCborPayload(
    response.body, T, options, response.request.url, response.status
  )

proc cborCodec*[TBody, TResponse](
    _: typedesc[TBody];
    _: typedesc[TResponse];
    options = defaultCborCodecOptions()
): Codec[TBody, TResponse] =
  Codec[TBody, TResponse](
    mediaType: CborMediaType,
    encodeResult: proc(value: TBody): jresult.JResult[string] =
      tryEncodeCborPayload(value, options),
    decodeResponseResult: proc(response: Response): jresult.JResult[TResponse] =
      tryDecodeCborResponse(response, TResponse, options)
  )

proc getCbor*[T](
    client: Client;
    path: string;
    _: typedesc[T];
    headers = initHeaders();
    options = RequestOptions();
    codecOptions = defaultCborCodecOptions()
): Future[jresult.JResult[T]] =
  var requestHeaders = headers
  if not requestHeaders.contains("accept"):
    requestHeaders.set("accept", CborMediaType)
  client.getWithCodec(
    path,
    proc(response: Response): jresult.JResult[T] =
      tryDecodeCborResponse(response, T, codecOptions),
    requestHeaders,
    options
  )

proc sendCbor*[TBody, TResponse](
    client: Client;
    httpMethod: RequestMethod;
    path: string;
    value: TBody;
    _: typedesc[TResponse];
    headers = initHeaders();
    options = RequestOptions();
    codecOptions = defaultCborCodecOptions()
): Future[jresult.JResult[TResponse]] =
  var requestHeaders = headers
  if not requestHeaders.contains("accept"):
    requestHeaders.set("accept", CborMediaType)
  client.sendWithCodec(
    httpMethod,
    path,
    value,
    cborCodec(TBody, TResponse, codecOptions),
    requestHeaders,
    options
  )

proc postCbor*[TBody, TResponse](
    client: Client;
    path: string;
    value: TBody;
    _: typedesc[TResponse];
    headers = initHeaders();
    options = RequestOptions();
    codecOptions = defaultCborCodecOptions()
): Future[jresult.JResult[TResponse]] =
  client.sendCbor(
    rmPost, path, value, TResponse, headers, options, codecOptions
  )

proc putCbor*[TBody, TResponse](
    client: Client;
    path: string;
    value: TBody;
    _: typedesc[TResponse];
    headers = initHeaders();
    options = RequestOptions();
    codecOptions = defaultCborCodecOptions()
): Future[jresult.JResult[TResponse]] =
  client.sendCbor(
    rmPut, path, value, TResponse, headers, options, codecOptions
  )

proc patchCbor*[TBody, TResponse](
    client: Client;
    path: string;
    value: TBody;
    _: typedesc[TResponse];
    headers = initHeaders();
    options = RequestOptions();
    codecOptions = defaultCborCodecOptions()
): Future[jresult.JResult[TResponse]] =
  client.sendCbor(
    rmPatch, path, value, TResponse, headers, options, codecOptions
  )
