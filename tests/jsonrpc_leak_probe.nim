import std/[asyncdispatch, json]
import joubako

type Total = object
  value: int

proc responseFor(request: Request): Response =
  let payload = request.body.parseJson
  var body = ""
  if payload.kind == JArray:
    body = """[
      {"jsonrpc":"2.0","result":2,"id":"b"},
      {"jsonrpc":"2.0","error":{"code":-32601,"message":"missing"},"id":1}
    ]"""
  elif payload.hasKey("id"):
    if payload["method"].getStr == "fail":
      body = """{"jsonrpc":"2.0","error":{"code":-32000,"message":"failed"},"id":1}"""
    else:
      body = """{"jsonrpc":"2.0","result":{"value":3},"id":1}"""
  var headers = initHeaders()
  if body.len > 0:
    headers.set("content-type", "application/json")
  Response(
    status: (if body.len == 0: 204 else: 200),
    headers: headers,
    body: body,
    request: request
  )

proc main(): Future[void] {.async.} =
  let transport = newInProcessTransport(proc(request: Request): Future[Response] {.async.} =
    return request.responseFor()
  )
  let client = newClient(transport)
  for _ in 0 ..< 300:
    let success = await client.callJsonRpc("/rpc", "sum", %*[1, 2], Total)
    doAssert success.isOk
    doAssert success.value.result.value == 3

    let protocolFailure = await client.callJsonRpc("/rpc", "fail", JsonNode)
    doAssert protocolFailure.isOk
    doAssert protocolFailure.value.error.code == -32000

    let notification = await client.notifyJsonRpc("/rpc", "audit", %*{"ok": true})
    doAssert notification.isOk

    let batch = await client.sendJsonRpcBatch("/rpc", [
      jsonRpcCall("a", jsonRpcId(1)),
      jsonRpcNotification("audit"),
      jsonRpcCall("b", jsonRpcId("b"))
    ])
    doAssert batch.isOk
    doAssert batch.value.len == 2

waitFor main()
