import std/[asyncdispatch, json, options]
import joubako

type
  ProbeUser = object
    id: string
    name: string

  ProbeData = object
    user: ProbeUser

const Iterations = 500

proc document(): GraphqlDocument =
  gqlQuery(
    "User",
    variables = [gqlVariableDefinition("id", "ID!")],
    selection = [gqlField(
      "user",
      arguments = [gqlArgument("id", gqlVariable("id"))],
      selection = [gqlField("id"), gqlField("name")]
    )]
  )

proc handler(request: Request): Future[Response] {.async.} =
  let payload = request.body.parseJson
  let id = payload["variables"]["id"].getStr
  var headers = initHeaders()
  headers.set("content-type", "application/graphql-response+json")
  let body =
    if id == "partial":
      """{"data":{"user":{"id":"partial","name":"P"}},"errors":[{"message":"partial","path":["user"]}]}"""
    elif id == "malformed":
      "not-json"
    else:
      """{"data":{"user":{"id":"ok","name":"Nim"}}}"""
  return Response(status: 200, headers: headers, body: body, request: request)

proc main(): Future[void] {.async.} =
  let client = newClient(newInProcessTransport(handler))
  let query = document()
  for _ in 0 ..< Iterations:
    let rendered = query.renderGraphql()
    doAssert rendered.isOk

    let success = await client.executeGraphql(
      "/graphql", query, ProbeData, %*{"id": "ok"}
    )
    doAssert success.isOk
    doAssert success.value.data.get.user.name == "Nim"

    let partial = await client.executeGraphql(
      "/graphql", query, ProbeData, %*{"id": "partial"}
    )
    doAssert partial.isOk
    doAssert partial.value.hasErrors

    let malformed = await client.executeGraphql(
      "/graphql", query, ProbeData, %*{"id": "malformed"}
    )
    doAssert malformed.isErr
    doAssert malformed.error.kind == jeCodec

    let invalid = await client.executeGraphql(
      "/graphql", gqlSource("query {"), ProbeData
    )
    doAssert invalid.isErr
    doAssert invalid.error.kind == jeInvalidRequest

let probe = main()
waitFor probe
probe.clearCallbacks()
doAssert not hasPendingOperations()
setGlobalDispatcher(nil)
