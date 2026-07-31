import std/asyncdispatch
import ./[client, promise, result, types]

type
  Encoder*[T] = proc(value: T): string {.closure.}
  Decoder*[T] = proc(payload: string): T {.closure.}

  Codec*[TBody, TResponse] = object
    mediaType*: string
    encode*: Encoder[TBody]
    decode*: Decoder[TResponse]

proc sendWithCodec*[TBody, TResponse](
    client: Client;
    httpMethod: RequestMethod;
    path: string;
    value: TBody;
    codec: Codec[TBody, TResponse];
    headers = initHeaders();
    options = RequestOptions()
): Future[JResult[TResponse]] =
  if codec.encode.isNil or codec.decode.isNil:
    return completedResult(err[TResponse](newJoubakoError(
      jeInvalidRequest, "codec callbacks must not be nil", path
    )))
  var encodedHeaders = headers
  if codec.mediaType.len > 0 and not encodedHeaders.contains("content-type"):
    encodedHeaders.set("content-type", codec.mediaType)
  var body: string
  try:
    body = codec.encode(value)
  except CatchableError as error:
    return completedResult(err[TResponse](newJoubakoError(
      jeCodec,
      "could not encode request: " & error.msg,
      path
    )))
  client.request(
    httpMethod,
    path,
    body,
    encodedHeaders,
    options
  ).then(proc(response: Response): TResponse = codec.decode(response.body))

proc getWithCodec*[T](
    client: Client;
    path: string;
    decoder: Decoder[T];
    headers = initHeaders();
    options = RequestOptions()
): Future[JResult[T]] =
  if decoder.isNil:
    return completedResult(err[T](newJoubakoError(
      jeInvalidRequest, "decoder must not be nil", path
    )))
  client.get(path, headers, options).then(
    proc(response: Response): T = decoder(response.body)
  )
