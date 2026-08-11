import std/[asyncdispatch, json, options, strutils, unittest]
import joubako

type
  SumResult = object
    total: int

proc rpcResponse(request: Request; body: string;
    contentType = "application/json; charset=utf-8"; status = 200): Response =
  var headers = initHeaders()
  if contentType.len > 0:
    headers.set("content-type", contentType)
  Response(status: status, headers: headers, body: body, request: request)

suite "JSON-RPC 2.0 calls":
  test "sends a positional request and decodes a typed result":
    var dispatched = 0
    let transport = newInProcessTransport(proc(request: Request): Future[Response] {.async.} =
      inc dispatched
      check request.httpMethod == rmPost
      check request.headers.get("content-type") == "application/json"
      check request.headers.get("accept") == "application/json"
      let body = request.body.parseJson
      check body["jsonrpc"].getStr == "2.0"
      check body["method"].getStr == "sum"
      check body["params"][0].getInt == 2
      check body["id"].getInt == 7
      return request.rpcResponse(
        """{"jsonrpc":"2.0","result":{"total":5},"id":7}"""
      )
    )
    let outcome = waitFor newClient(transport).callJsonRpc(
      "/rpc", "sum", %*[2, 3], SumResult, jsonRpcId(7)
    )
    check outcome.isOk
    check outcome.value.isResult
    check outcome.value.result.total == 5
    check outcome.value.id == jsonRpcId(7)
    check dispatched == 1

  test "supports named params and string ids":
    let transport = newInProcessTransport(proc(request: Request): Future[Response] {.async.} =
      let body = request.body.parseJson
      check body["params"]["name"].getStr == "Ada"
      check body["id"].getStr == "user-42"
      return request.rpcResponse(
        """{"jsonrpc":"2.0","result":"hello Ada","id":"user-42"}"""
      )
    )
    let outcome = waitFor newClient(transport).callJsonRpc(
      "/rpc", "hello", %*{"name": "Ada"}, string, jsonRpcId("user-42")
    )
    check outcome.isOk
    check outcome.value.result == "hello Ada"

  test "omits params and uses the default integer id":
    let transport = newInProcessTransport(proc(request: Request): Future[Response] {.async.} =
      let body = request.body.parseJson
      check not body.hasKey("params")
      check body["id"].getInt == 1
      return request.rpcResponse(
        """{"jsonrpc":"2.0","result":true,"id":1}"""
      )
    )
    let outcome = waitFor newClient(transport).callJsonRpc(
      "/rpc", "healthy", bool
    )
    check outcome.isOk
    check outcome.value.result

  test "preserves a valid JSON-RPC method error as a response value":
    let transport = newInProcessTransport(proc(request: Request): Future[Response] {.async.} =
      return request.rpcResponse("""{
        "jsonrpc":"2.0",
        "error":{"code":-32602,"message":"Invalid params","data":{"field":"id"}},
        "id":9
      }""")
    )
    let outcome = waitFor newClient(transport).callJsonRpc(
      "/rpc", "user", %*{"id": -1}, JsonNode, jsonRpcId(9)
    )
    check outcome.isOk
    check outcome.value.isError
    check outcome.value.error.code == -32602
    check outcome.value.error.message == "Invalid params"
    check outcome.value.error.data.isSome
    check outcome.value.error.data.get["field"].getStr == "id"

  test "accepts application plus-json response media types":
    let transport = newInProcessTransport(proc(request: Request): Future[Response] {.async.} =
      return request.rpcResponse(
        """{"jsonrpc":"2.0","result":3,"id":1}""",
        "application/vnd.example+json"
      )
    )
    let outcome = waitFor newClient(transport).callJsonRpc("/rpc", "sum", int)
    check outcome.isOk
    check outcome.value.result == 3

  test "allows absent content type and preserves caller headers":
    var seenType = ""
    var seenAccept = ""
    let transport = newInProcessTransport(proc(request: Request): Future[Response] {.async.} =
      seenType = request.headers.get("content-type")
      seenAccept = request.headers.get("accept")
      return request.rpcResponse(
        """{"jsonrpc":"2.0","result":3,"id":1}""", ""
      )
    )
    var headers = initHeaders()
    headers.set("content-type", "application/custom+json")
    headers.set("accept", "application/custom+json")
    let outcome = waitFor newClient(transport).callJsonRpc(
      "/rpc", "sum", int, headers = headers
    )
    check outcome.isOk
    check seenType == "application/custom+json"
    check seenAccept == "application/custom+json"

  test "rejects an empty method and scalar params before dispatch":
    var dispatched = 0
    let transport = newInProcessTransport(proc(request: Request): Future[Response] {.async.} =
      inc dispatched
      return request.rpcResponse("")
    )
    let client = newClient(transport)
    let empty = waitFor client.callJsonRpc("/rpc", "", int)
    let scalar = waitFor client.callJsonRpc("/rpc", "sum", %*3, int)
    check empty.isErr
    check empty.error.kind == jeInvalidRequest
    check scalar.isErr
    check scalar.error.kind == jeInvalidRequest
    check dispatched == 0

  test "rejects invalid JSON and attaches the response":
    let transport = newInProcessTransport(proc(request: Request): Future[Response] {.async.} =
      return request.rpcResponse("not-json")
    )
    let outcome = waitFor newClient(transport).callJsonRpc("/rpc", "sum", int)
    check outcome.isErr
    check outcome.error.kind == jeCodec
    check outcome.error.hasResponse
    check outcome.error.response.body == "not-json"

  test "rejects unsupported response media types":
    let transport = newInProcessTransport(proc(request: Request): Future[Response] {.async.} =
      return request.rpcResponse(
        """{"jsonrpc":"2.0","result":3,"id":1}""", "text/plain"
      )
    )
    let outcome = waitFor newClient(transport).callJsonRpc("/rpc", "sum", int)
    check outcome.isErr
    check outcome.error.kind == jeCodec

  test "rejects a mismatched id":
    let transport = newInProcessTransport(proc(request: Request): Future[Response] {.async.} =
      return request.rpcResponse(
        """{"jsonrpc":"2.0","result":3,"id":2}"""
      )
    )
    let outcome = waitFor newClient(transport).callJsonRpc("/rpc", "sum", int)
    check outcome.isErr
    check "does not match" in outcome.error.msg

  for example in [
    """{"jsonrpc":"1.0","result":3,"id":1}""",
    """{"jsonrpc":"2.0","id":1}""",
    """{"jsonrpc":"2.0","result":3,"error":{"code":1,"message":"x"},"id":1}""",
    """{"jsonrpc":"2.0","result":3}""",
    """{"jsonrpc":"2.0","result":3,"id":null}""",
    """{"jsonrpc":"2.0","result":3,"id":1.5}""",
    """{"jsonrpc":"2.0","error":{"code":"bad","message":"x"},"id":1}""",
    """{"jsonrpc":"2.0","error":{"code":-1,"message":9},"id":1}""",
    "[]"
  ]:
    test "rejects malformed response: " & example:
      let body = example
      let transport = newInProcessTransport(proc(request: Request): Future[Response] {.async.} =
        return request.rpcResponse(body)
      )
      let outcome = waitFor newClient(transport).callJsonRpc(
        "/rpc", "sum", JsonNode
      )
      check outcome.isErr
      check outcome.error.kind == jeCodec

  test "rejects a result that cannot decode into the requested type":
    let transport = newInProcessTransport(proc(request: Request): Future[Response] {.async.} =
      return request.rpcResponse(
        """{"jsonrpc":"2.0","result":"three","id":1}"""
      )
    )
    let outcome = waitFor newClient(transport).callJsonRpc("/rpc", "sum", int)
    check outcome.isErr
    check outcome.error.kind == jeCodec

  test "inherits response size enforcement from the client":
    let transport = newInProcessTransport(proc(request: Request): Future[Response] {.async.} =
      return request.rpcResponse(
        """{"jsonrpc":"2.0","result":"too large","id":1}"""
      )
    )
    let outcome = waitFor newClient(transport).callJsonRpc(
      "/rpc", "sum", string,
      options = RequestOptions(maxResponseBytes: 8)
    )
    check outcome.isErr
    check outcome.error.kind == jeBodyTooLarge

suite "JSON-RPC 2.0 notifications":
  test "omits id and accepts an empty HTTP response":
    let transport = newInProcessTransport(proc(request: Request): Future[Response] {.async.} =
      let body = request.body.parseJson
      check body["method"].getStr == "update"
      check not body.hasKey("id")
      check body["params"]["active"].getBool
      return request.rpcResponse("", "", 204)
    )
    let outcome = waitFor newClient(transport).notifyJsonRpc(
      "/rpc", "update", %*{"active": true}
    )
    check outcome.isOk

  test "rejects a protocol response to a notification":
    let transport = newInProcessTransport(proc(request: Request): Future[Response] {.async.} =
      return request.rpcResponse(
        """{"jsonrpc":"2.0","result":true,"id":1}"""
      )
    )
    let outcome = waitFor newClient(transport).notifyJsonRpc("/rpc", "update")
    check outcome.isErr
    check outcome.error.kind == jeCodec

suite "JSON-RPC 2.0 batches":
  test "accepts reordered responses and excludes notification replies":
    let transport = newInProcessTransport(proc(request: Request): Future[Response] {.async.} =
      let body = request.body.parseJson
      check body.kind == JArray
      check body.len == 3
      check not body[1].hasKey("id")
      return request.rpcResponse("""[
        {"jsonrpc":"2.0","result":4,"id":"second"},
        {"jsonrpc":"2.0","error":{"code":-32601,"message":"missing"},"id":1}
      ]""")
    )
    let outcome = waitFor newClient(transport).sendJsonRpcBatch("/rpc", [
      jsonRpcCall("first", jsonRpcId(1)),
      jsonRpcNotification("audit", %*{"event": "start"}),
      jsonRpcCall("second", jsonRpcId("second"), %*[2, 2])
    ])
    check outcome.isOk
    check outcome.value.len == 2
    check outcome.value[0].id == jsonRpcId("second")
    check outcome.value[0].result.getInt == 4
    check outcome.value[1].isError
    check outcome.value[1].error.code == -32601

  test "accepts no response for an all-notification batch":
    let transport = newInProcessTransport(proc(request: Request): Future[Response] {.async.} =
      return request.rpcResponse("", "", 204)
    )
    let outcome = waitFor newClient(transport).sendJsonRpcBatch("/rpc", [
      jsonRpcNotification("one"), jsonRpcNotification("two", %*[])
    ])
    check outcome.isOk
    check outcome.value.len == 0

  test "rejects empty batches and duplicate request ids before dispatch":
    var dispatched = 0
    let transport = newInProcessTransport(proc(request: Request): Future[Response] {.async.} =
      inc dispatched
      return request.rpcResponse("")
    )
    let client = newClient(transport)
    let empty: seq[JsonRpcBatchRequest] = @[]
    let emptyOutcome = waitFor client.sendJsonRpcBatch("/rpc", empty)
    let duplicateOutcome = waitFor client.sendJsonRpcBatch("/rpc", [
      jsonRpcCall("a", jsonRpcId(1)), jsonRpcCall("b", jsonRpcId(1))
    ])
    check emptyOutcome.isErr
    check duplicateOutcome.isErr
    check emptyOutcome.error.kind == jeInvalidRequest
    check duplicateOutcome.error.kind == jeInvalidRequest
    check dispatched == 0

  for (label, body) in [
    ("non-array", """{"jsonrpc":"2.0","result":1,"id":1}"""),
    ("empty response", "[]"),
    ("missing id", """[{"jsonrpc":"2.0","result":1,"id":1}]"""),
    ("unknown id", """[
      {"jsonrpc":"2.0","result":1,"id":1},
      {"jsonrpc":"2.0","result":2,"id":3}
    ]"""),
    ("duplicate id", """[
      {"jsonrpc":"2.0","result":1,"id":1},
      {"jsonrpc":"2.0","result":2,"id":1}
    ]""")
  ]:
    test "rejects malformed batch response: " & label:
      let responseBody = body
      let transport = newInProcessTransport(proc(request: Request): Future[Response] {.async.} =
        return request.rpcResponse(responseBody)
      )
      let outcome = waitFor newClient(transport).sendJsonRpcBatch("/rpc", [
        jsonRpcCall("a", jsonRpcId(1)), jsonRpcCall("b", jsonRpcId(2))
      ])
      check outcome.isErr
      check outcome.error.kind == jeCodec

  test "rejects a response to an all-notification batch":
    let transport = newInProcessTransport(proc(request: Request): Future[Response] {.async.} =
      return request.rpcResponse("[]")
    )
    let outcome = waitFor newClient(transport).sendJsonRpcBatch("/rpc", [
      jsonRpcNotification("audit")
    ])
    check outcome.isErr
    check outcome.error.kind == jeCodec
