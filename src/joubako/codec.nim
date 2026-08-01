import std/asyncdispatch
import ./[client, result, types]

type
  Encoder*[T] = proc(value: T): string {.closure.}
  AsyncEncoder*[T] = proc(value: T): Future[string] {.closure.}
  Decoder*[T] = proc(payload: string): T {.closure.}
  ResponseDecoder*[T] = proc(response: Response): T {.closure.}
  AsyncResponseDecoder*[T] =
    proc(response: Response): Future[T] {.closure.}

  Codec*[TBody, TResponse] = object
    mediaType*: string
    ## Configure exactly one encoder and one decoder. Payload-only callbacks
    ## remain available for small synchronous codecs; response decoders can
    ## inspect status and headers, and asynchronous callbacks are settled into
    ## JResult errors without exposing failed Futures.
    encode*: Encoder[TBody]
    encodeAsync*: AsyncEncoder[TBody]
    decode*: Decoder[TResponse]
    decodeResponse*: ResponseDecoder[TResponse]
    decodeResponseAsync*: AsyncResponseDecoder[TResponse]

func configuredEncoderCount[TBody, TResponse](
    codec: Codec[TBody, TResponse]
): int =
  ord(not codec.encode.isNil) + ord(not codec.encodeAsync.isNil)

func configuredDecoderCount[TBody, TResponse](
    codec: Codec[TBody, TResponse]
): int =
  ord(not codec.decode.isNil) + ord(not codec.decodeResponse.isNil) +
    ord(not codec.decodeResponseAsync.isNil)

proc invalidCodec[T](path, message: string): Future[JResult[T]] =
  completedResult(err[T](newJoubakoError(
    jeInvalidRequest, message, path
  )))

proc normalizeDecodeError(
    error: ref Exception;
    response: Response
): ref JoubakoError =
  result = error.asJoubakoError(jeCodec, response.request.url)
  if result.url.len == 0:
    result.url = response.request.url
  result.attachResponse(response)

proc decodeWithCodec[TBody, TResponse](
    codec: Codec[TBody, TResponse];
    response: Response
): Future[JResult[TResponse]] {.async.} =
  if not codec.decode.isNil:
    try:
      return ok(codec.decode(response.body))
    except CatchableError as error:
      return err[TResponse](error.normalizeDecodeError(response))
  if not codec.decodeResponse.isNil:
    try:
      return ok(codec.decodeResponse(response))
    except CatchableError as error:
      return err[TResponse](error.normalizeDecodeError(response))

  var pending: Future[TResponse]
  try:
    pending = codec.decodeResponseAsync(response)
  except CatchableError as error:
    return err[TResponse](error.normalizeDecodeError(response))
  if pending == nil:
    let decoderError = newJoubakoError(
      jeCodec,
      "asynchronous decoder returned a nil Future",
      response.request.url,
      response.status
    )
    decoderError.attachResponse(response)
    return err[TResponse](decoderError)
  let decoded = asyncdispatch.await settle(
    fallible(pending), jeCodec, response.request.url
  )
  if decoded.isErr:
    decoded.error.attachResponse(response)
  return decoded

proc sendWithCodec*[TBody, TResponse](
    client: Client;
    httpMethod: RequestMethod;
    path: string;
    value: TBody;
    codec: Codec[TBody, TResponse];
    headers = initHeaders();
    options = RequestOptions()
): Future[JResult[TResponse]] {.async.} =
  if codec.configuredEncoderCount != 1:
    return err[TResponse](newJoubakoError(
      jeInvalidRequest, "codec must configure exactly one encoder", path
    ))
  if codec.configuredDecoderCount != 1:
    return err[TResponse](newJoubakoError(
      jeInvalidRequest, "codec must configure exactly one decoder", path
    ))
  if codec.mediaType.contains({'\r', '\n'}):
    return err[TResponse](newJoubakoError(
      jeInvalidRequest, "codec media type contains a line break", path
    ))
  var encodedHeaders = headers
  if codec.mediaType.len > 0 and not encodedHeaders.contains("content-type"):
    encodedHeaders.set("content-type", codec.mediaType)

  var body: string
  if not codec.encode.isNil:
    try:
      body = codec.encode(value)
    except CatchableError as error:
      return err[TResponse](error.asJoubakoError(jeCodec, path))
  else:
    var pending: Future[string]
    try:
      pending = codec.encodeAsync(value)
    except CatchableError as error:
      return err[TResponse](error.asJoubakoError(jeCodec, path))
    if pending == nil:
      return err[TResponse](newJoubakoError(
        jeCodec, "asynchronous encoder returned a nil Future", path
      ))
    let encoded = asyncdispatch.await settle(
      fallible(pending), jeCodec, path
    )
    if encoded.isErr:
      return err[TResponse](encoded.error)
    body = encoded.value

  let response = asyncdispatch.await client.request(
    httpMethod, path, body, encodedHeaders, options
  )
  if response.isErr:
    return err[TResponse](response.error)
  return asyncdispatch.await codec.decodeWithCodec(response.value)

proc getWithCodec*[T](
    client: Client;
    path: string;
    decoder: Decoder[T];
    headers = initHeaders();
    options = RequestOptions()
): Future[JResult[T]] =
  if decoder.isNil:
    return invalidCodec[T](path, "decoder must not be nil")
  let codec = Codec[string, T](
    encode: proc(_: string): string = "",
    decode: decoder
  )
  client.sendWithCodec(rmGet, path, "", codec, headers, options)

proc getWithCodec*[T](
    client: Client;
    path: string;
    decoder: ResponseDecoder[T];
    headers = initHeaders();
    options = RequestOptions()
): Future[JResult[T]] =
  if decoder.isNil:
    return invalidCodec[T](path, "decoder must not be nil")
  let codec = Codec[string, T](
    encode: proc(_: string): string = "",
    decodeResponse: decoder
  )
  client.sendWithCodec(rmGet, path, "", codec, headers, options)

proc getWithCodecAsync*[T](
    client: Client;
    path: string;
    decoder: AsyncResponseDecoder[T];
    headers = initHeaders();
    options = RequestOptions()
): Future[JResult[T]] =
  if decoder.isNil:
    return invalidCodec[T](path, "decoder must not be nil")
  let codec = Codec[string, T](
    encode: proc(_: string): string = "",
    decodeResponseAsync: decoder
  )
  client.sendWithCodec(rmGet, path, "", codec, headers, options)
