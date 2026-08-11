## JSON-RPC 2.0 requests over any request/response Joubako transport.
##
## Transport and decoding failures are returned as `JResult` errors. A valid
## JSON-RPC error response is instead represented by `JsonRpcResponse.kind ==
## jrrError`, preserving the protocol error code and optional data.

import std/[asyncdispatch, json, jsonutils, options, sets, strutils]
import ./[client, result, types]

type
  JsonRpcIdKind* = enum
    jriString,
    jriInteger

  JsonRpcId* = object
    case kind*: JsonRpcIdKind
    of jriString:
      stringValue*: string
    of jriInteger:
      integerValue*: int64

  JsonRpcError* = object
    code*: int
    message*: string
    data*: Option[JsonNode]

  JsonRpcResponseKind* = enum
    jrrResult,
    jrrError

  JsonRpcResponse*[T] = object
    id*: JsonRpcId
    case kind*: JsonRpcResponseKind
    of jrrResult:
      result*: T
    of jrrError:
      error*: JsonRpcError

  JsonRpcBatchRequest* = object
    methodName*: string
    params*: JsonNode
    id*: Option[JsonRpcId]

func jsonRpcId*(value: string): JsonRpcId =
  JsonRpcId(kind: jriString, stringValue: value)

func jsonRpcId*(value: SomeSignedInt): JsonRpcId =
  JsonRpcId(kind: jriInteger, integerValue: int64(value))

func `==`*(left, right: JsonRpcId): bool =
  if left.kind != right.kind:
    return false
  case left.kind
  of jriString:
    left.stringValue == right.stringValue
  of jriInteger:
    left.integerValue == right.integerValue

func jsonRpcCall*(methodName: string; id: JsonRpcId;
    params: JsonNode = nil): JsonRpcBatchRequest =
  JsonRpcBatchRequest(methodName: methodName, params: params, id: some(id))

func jsonRpcNotification*(methodName: string;
    params: JsonNode = nil): JsonRpcBatchRequest =
  JsonRpcBatchRequest(methodName: methodName, params: params)

func isResult*[T](response: JsonRpcResponse[T]): bool =
  response.kind == jrrResult

func isError*[T](response: JsonRpcResponse[T]): bool =
  response.kind == jrrError

func toJsonNode(id: JsonRpcId): JsonNode =
  case id.kind
  of jriString:
    newJString(id.stringValue)
  of jriInteger:
    newJInt(id.integerValue)

func idKey(id: JsonRpcId): string =
  case id.kind
  of jriString:
    "s:" & id.stringValue
  of jriInteger:
    "i:" & $id.integerValue

proc codecError(message: string; response: Response): ref JoubakoError =
  result = newJoubakoError(
    jeCodec, "invalid JSON-RPC response: " & message,
    response.request.url, response.status
  )
  result.attachResponse(response)

proc validateParams(params: JsonNode; path: string): ref JoubakoError =
  if params != nil and params.kind notin {JObject, JArray}:
    newJoubakoError(
      jeInvalidRequest,
      "JSON-RPC params must be an object or array",
      path
    )
  else:
    nil

proc requestNode(item: JsonRpcBatchRequest): JsonNode =
  result = newJObject()
  result["jsonrpc"] = newJString("2.0")
  result["method"] = newJString(item.methodName)
  if item.params != nil:
    result["params"] = item.params
  if item.id.isSome:
    result["id"] = item.id.get.toJsonNode

proc responseId(node: JsonNode; response: Response): JResult[JsonRpcId] =
  if not node.hasKey("id"):
    return err[JsonRpcId](codecError("missing id", response))
  let id = node["id"]
  case id.kind
  of JString:
    ok(jsonRpcId(id.getStr))
  of JInt:
    ok(jsonRpcId(id.getBiggestInt))
  else:
    err[JsonRpcId](codecError("id must be a string or integer", response))

proc decodeResponse[T](node: JsonNode; response: Response;
    _: typedesc[T]): JResult[JsonRpcResponse[T]] =
  if node.kind != JObject:
    return err[JsonRpcResponse[T]](codecError(
      "response entry must be an object", response
    ))
  if not node.hasKey("jsonrpc") or node["jsonrpc"].kind != JString or
      node["jsonrpc"].getStr != "2.0":
    return err[JsonRpcResponse[T]](codecError(
      "jsonrpc must be exactly \"2.0\"", response
    ))
  let decodedId = responseId(node, response)
  if decodedId.isErr:
    return err[JsonRpcResponse[T]](decodedId.error)

  let hasResult = node.hasKey("result")
  let hasError = node.hasKey("error")
  if hasResult == hasError:
    return err[JsonRpcResponse[T]](codecError(
      "response must contain exactly one of result or error", response
    ))

  if hasError:
    let errorNode = node["error"]
    if errorNode.kind != JObject or not errorNode.hasKey("code") or
        errorNode["code"].kind != JInt or
        not errorNode.hasKey("message") or
        errorNode["message"].kind != JString:
      return err[JsonRpcResponse[T]](codecError(
        "error must contain an integer code and string message", response
      ))
    var protocolError = JsonRpcError(
      code: int(errorNode["code"].getBiggestInt),
      message: errorNode["message"].getStr
    )
    if errorNode.hasKey("data"):
      protocolError.data = some(errorNode["data"])
    return ok(JsonRpcResponse[T](
      id: decodedId.value,
      kind: jrrError,
      error: protocolError
    ))

  try:
    return ok(JsonRpcResponse[T](
      id: decodedId.value,
      kind: jrrResult,
      result: node["result"].jsonTo(T)
    ))
  except CatchableError as error:
    return err[JsonRpcResponse[T]](codecError(
      "could not decode result: " & error.msg, response
    ))

proc validateContentType(response: Response): ref JoubakoError =
  if not response.headers.contains("content-type"):
    return nil
  let mediaType = response.headers.get("content-type").split(';', 1)[0]
    .strip.toLowerAscii
  if mediaType == "application/json" or
      (mediaType.startsWith("application/") and mediaType.endsWith("+json")):
    return nil
  codecError("unsupported content type " & mediaType, response)

proc sendPayload(client: Client; path, body: string; headers: Headers;
    options: RequestOptions): Future[JResult[Response]] =
  var requestHeaders = headers
  if not requestHeaders.contains("content-type"):
    requestHeaders.set("content-type", "application/json")
  if not requestHeaders.contains("accept"):
    requestHeaders.set("accept", "application/json")
  client.request(rmPost, path, body, requestHeaders, options)

proc callJsonRpc*[T](client: Client; path, methodName: string;
    params: JsonNode; _: typedesc[T]; id = jsonRpcId(1);
    headers = initHeaders(); options = RequestOptions()
): Future[JResult[JsonRpcResponse[T]]] {.async.} =
  if methodName.len == 0:
    return err[JsonRpcResponse[T]](newJoubakoError(
      jeInvalidRequest, "JSON-RPC method must not be empty", path
    ))
  let paramsError = validateParams(params, path)
  if paramsError != nil:
    return err[JsonRpcResponse[T]](paramsError)
  let body = $requestNode(jsonRpcCall(methodName, id, params))
  let received = asyncdispatch.await sendPayload(
    client, path, body, headers, options
  )
  if received.isErr:
    return err[JsonRpcResponse[T]](received.error)
  let response = received.value
  let typeError = validateContentType(response)
  if typeError != nil:
    return err[JsonRpcResponse[T]](typeError)
  var root: JsonNode
  try:
    root = response.body.parseJson
  except CatchableError as error:
    return err[JsonRpcResponse[T]](codecError(
      "could not parse JSON: " & error.msg, response
    ))
  let decoded = decodeResponse(root, response, T)
  if decoded.isErr:
    return decoded
  if decoded.value.id != id:
    return err[JsonRpcResponse[T]](codecError(
      "response id does not match request id", response
    ))
  decoded

proc callJsonRpc*[T](client: Client; path, methodName: string;
    _: typedesc[T]; id = jsonRpcId(1); headers = initHeaders();
    options = RequestOptions()
): Future[JResult[JsonRpcResponse[T]]] =
  callJsonRpc(client, path, methodName, nil, T, id, headers, options)

proc notifyJsonRpc*(client: Client; path, methodName: string;
    params: JsonNode = nil; headers = initHeaders();
    options = RequestOptions()
): Future[JResult[void]] {.async.} =
  if methodName.len == 0:
    return err[void](newJoubakoError(
      jeInvalidRequest, "JSON-RPC method must not be empty", path
    ))
  let paramsError = validateParams(params, path)
  if paramsError != nil:
    return err[void](paramsError)
  let body = $requestNode(jsonRpcNotification(methodName, params))
  let received = asyncdispatch.await sendPayload(
    client, path, body, headers, options
  )
  if received.isErr:
    return err[void](received.error)
  if received.value.body.strip.len != 0:
    return err[void](codecError(
      "notification received a JSON-RPC response", received.value
    ))
  ok()

proc sendJsonRpcBatchImpl(client: Client; path: string;
    requests: seq[JsonRpcBatchRequest]; headers: Headers;
    options: RequestOptions
): Future[JResult[seq[JsonRpcResponse[JsonNode]]]] {.async.} =
  if requests.len == 0:
    return err[seq[JsonRpcResponse[JsonNode]]](newJoubakoError(
      jeInvalidRequest, "JSON-RPC batch must not be empty", path
    ))
  var payload = newJArray()
  var expected = initHashSet[string]()
  for item in requests:
    if item.methodName.len == 0:
      return err[seq[JsonRpcResponse[JsonNode]]](newJoubakoError(
        jeInvalidRequest, "JSON-RPC method must not be empty", path
      ))
    let paramsError = validateParams(item.params, path)
    if paramsError != nil:
      return err[seq[JsonRpcResponse[JsonNode]]](paramsError)
    if item.id.isSome:
      let key = item.id.get.idKey
      if key in expected:
        return err[seq[JsonRpcResponse[JsonNode]]](newJoubakoError(
          jeInvalidRequest, "JSON-RPC batch contains duplicate ids", path
        ))
      expected.incl(key)
    payload.add(requestNode(item))

  let received = asyncdispatch.await sendPayload(
    client, path, $payload, headers, options
  )
  if received.isErr:
    return err[seq[JsonRpcResponse[JsonNode]]](received.error)
  let response = received.value
  if expected.len == 0:
    if response.body.strip.len == 0:
      return ok(newSeq[JsonRpcResponse[JsonNode]]())
    return err[seq[JsonRpcResponse[JsonNode]]](codecError(
      "notification-only batch received a JSON-RPC response", response
    ))
  let typeError = validateContentType(response)
  if typeError != nil:
    return err[seq[JsonRpcResponse[JsonNode]]](typeError)
  var root: JsonNode
  try:
    root = response.body.parseJson
  except CatchableError as error:
    return err[seq[JsonRpcResponse[JsonNode]]](codecError(
      "could not parse JSON: " & error.msg, response
    ))
  if root.kind != JArray or root.len == 0:
    return err[seq[JsonRpcResponse[JsonNode]]](codecError(
      "batch response must be a non-empty array", response
    ))

  var seen = initHashSet[string]()
  var decodedResponses: seq[JsonRpcResponse[JsonNode]]
  for node in root:
    let decoded = decodeResponse(node, response, JsonNode)
    if decoded.isErr:
      return err[seq[JsonRpcResponse[JsonNode]]](decoded.error)
    let key = decoded.value.id.idKey
    if key notin expected:
      return err[seq[JsonRpcResponse[JsonNode]]](codecError(
        "batch response contains an unknown id", response
      ))
    if key in seen:
      return err[seq[JsonRpcResponse[JsonNode]]](codecError(
        "batch response contains a duplicate id", response
      ))
    seen.incl(key)
    decodedResponses.add(decoded.value)
  if seen.len != expected.len:
    return err[seq[JsonRpcResponse[JsonNode]]](codecError(
      "batch response is missing one or more ids", response
    ))
  ok(move(decodedResponses))

proc sendJsonRpcBatch*(client: Client; path: string;
    requests: openArray[JsonRpcBatchRequest]; headers = initHeaders();
    options = RequestOptions()
): Future[JResult[seq[JsonRpcResponse[JsonNode]]]] =
  sendJsonRpcBatchImpl(client, path, @requests, headers, options)
