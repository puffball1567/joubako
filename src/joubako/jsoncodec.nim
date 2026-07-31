import std/[asyncdispatch, json, jsonutils]
import ./[client, promise, query, result, types]

proc decodeJson*[T](response: Response; _: typedesc[T]): T =
  try:
    result = response.body.parseJson.jsonTo(T)
  except CatchableError as error:
    raise newJoubakoError(
      jeCodec,
      "could not decode JSON response: " & error.msg,
      response.request.url,
      response.status
    )

proc getJson*[T](
    client: Client;
    path: string;
    headers = initHeaders();
    options = RequestOptions()
): Future[JResult[T]] =
  client.get(path, headers, options).then(
    proc(response: Response): T = response.decodeJson(T)
  )

proc getJson*[T](
    client: Client;
    path: string;
    _: typedesc[T];
    headers = initHeaders();
    options = RequestOptions()
): Future[JResult[T]] =
  ## Typedesc overload for client-first syntax:
  ## `await client.getJson("/users/42", User)`.
  getJson[T](client, path, headers, options)

proc getJson*[T](
    client: Client;
    path: string;
    query: openArray[QueryParam];
    _: typedesc[T];
    headers = initHeaders();
    options = RequestOptions()
): Future[JResult[T]] =
  getJson[T](client, path.withQuery(query), headers, options)

proc sendJson*[TBody, TResponse](
    client: Client;
    httpMethod: RequestMethod;
    path: string;
    value: TBody;
    headers = initHeaders();
    options = RequestOptions()
): Future[JResult[TResponse]] =
  var jsonHeaders = headers
  if not jsonHeaders.contains("content-type"):
    jsonHeaders.set("content-type", "application/json")
  var body: string
  try:
    body = $toJson(value)
  except CatchableError as error:
    return completedResult(err[TResponse](newJoubakoError(
      jeCodec, "could not encode JSON request: " & error.msg, path
    )))
  client.request(httpMethod, path, body, jsonHeaders, options).then(
    proc(response: Response): TResponse = response.decodeJson(TResponse)
  )

proc postJson*[TBody, TResponse](
    client: Client;
    path: string;
    value: TBody;
    headers = initHeaders();
    options = RequestOptions()
): Future[JResult[TResponse]] =
  sendJson[TBody, TResponse](
    client,
    rmPost,
    path,
    value,
    headers,
    options
  )

proc postJson*[TBody, TResponse](
    client: Client;
    path: string;
    value: TBody;
    _: typedesc[TResponse];
    headers = initHeaders();
    options = RequestOptions()
): Future[JResult[TResponse]] =
  sendJson[TBody, TResponse](
    client,
    rmPost,
    path,
    value,
    headers,
    options
  )

proc putJson*[TBody, TResponse](
    client: Client;
    path: string;
    value: TBody;
    _: typedesc[TResponse];
    headers = initHeaders();
    options = RequestOptions()
): Future[JResult[TResponse]] =
  sendJson[TBody, TResponse](
    client,
    rmPut,
    path,
    value,
    headers,
    options
  )

proc patchJson*[TBody, TResponse](
    client: Client;
    path: string;
    value: TBody;
    _: typedesc[TResponse];
    headers = initHeaders();
    options = RequestOptions()
): Future[JResult[TResponse]] =
  sendJson[TBody, TResponse](
    client,
    rmPatch,
    path,
    value,
    headers,
    options
  )
