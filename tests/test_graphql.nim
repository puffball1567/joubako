import std/[asyncdispatch, json, options, strutils, unittest]
import joubako

type
  User = object
    id: string
    name: string

  UserData = object
    user: User

proc userDocument(): GraphqlDocument =
  gqlQuery(
    "User",
    variables = [gqlVariableDefinition("id", "ID!")],
    selection = [
      gqlField(
        "user",
        arguments = [gqlArgument("id", gqlVariable("id"))],
        selection = [gqlField("id"), gqlField("name")]
      )
    ]
  )

proc rendered(document: GraphqlDocument): string =
  let outcome = document.renderGraphql()
  doAssert outcome.isOk, outcome.error.msg
  outcome.value

proc invalid(document: GraphqlDocument): ErrorKind =
  let outcome = document.renderGraphql()
  doAssert outcome.isErr
  outcome.error.kind

proc responseFor(request: Request; body: string; contentType = "application/json"):
    Response =
  var headers = initHeaders()
  if contentType.len > 0:
    headers.set("content-type", contentType)
  Response(
    status: 200,
    headers: headers,
    body: body,
    request: request
  )

suite "GraphQL document builder":
  test "renders typed variables and nested selections":
    check userDocument().rendered ==
      "query User($id: ID!) { user(id: $id) { id name } }"

  test "renders mutations aliases and scalar values":
    let document = gqlMutation(
      "UpdateUser",
      selection = [gqlField(
        "updateUser",
        alias = "updated",
        arguments = [
          gqlArgument("id", gqlInt(42)),
          gqlArgument("name", gqlString("A\n\"B")),
          gqlArgument("active", gqlBool(true)),
          gqlArgument("score", gqlFloat(1.5)),
          gqlArgument("missing", gqlNull()),
          gqlArgument("role", gqlEnum("ADMIN"))
        ],
        selection = [gqlField("id")]
      )]
    )
    let source = document.rendered
    check source.startsWith("mutation UpdateUser")
    check "updated: updateUser" in source
    check "name: \"A\\n\\\"B\"" in source
    check "role: ADMIN" in source

  test "renders lists and input objects":
    let document = gqlQuery("Search", selection = [gqlField(
      "search",
      arguments = [gqlArgument("filter", gqlObject([
        gqlArgument("tags", gqlList([gqlString("nim"), gqlString("arc")])),
        gqlArgument("limit", gqlInt(10))
      ]))],
      selection = [gqlField("id")]
    )])
    check "filter: {tags: [\"nim\", \"arc\"], limit: 10}" in document.rendered

  test "renders directives fragments and inline fragments":
    let document = gqlQuery(
      "Node",
      variables = [gqlVariableDefinition(
        "includeName", "Boolean!", gqlBool(true)
      )],
      selection = [gqlField(
        "node",
        selection = [
          gqlFragmentSpread("Identity"),
          gqlInlineFragment(
            "User",
            directives = [gqlDirective("include", [
              gqlArgument("if", gqlVariable("includeName"))
            ])],
            selection = [gqlField("name")]
          )
        ]
      )],
      fragments = [gqlFragment(
        "Identity", "Node", selection = [gqlField("id")]
      )]
    )
    let source = document.rendered
    check "$includeName: Boolean! = true" in source
    check "...Identity" in source
    check "... on User @include(if: $includeName) { name }" in source
    check "fragment Identity on Node { id }" in source

  test "renders multiple named operations":
    let document = gqlDocument([
      gqlOperation(gokQuery, "A", selection = [gqlField("a")]),
      gqlOperation(gokMutation, "B", selection = [gqlField("b")])
    ])
    check document.rendered == "query A { a }\nmutation B { b }"

  test "rejects duplicate operation and fragment names":
    check gqlDocument([
      gqlOperation(gokQuery, "Same", selection = [gqlField("a")]),
      gqlOperation(gokQuery, "Same", selection = [gqlField("b")])
    ]).invalid == jeInvalidRequest
    check gqlQuery("Q", selection = [gqlField("a")], fragments = [
      gqlFragment("Same", "User", selection = [gqlField("id")]),
      gqlFragment("Same", "User", selection = [gqlField("name")])
    ]).invalid == jeInvalidRequest

  test "accepts a valid raw executable document":
    check gqlSource("query Health { health }").rendered ==
      "query Health { health }"

  test "rejects malformed raw source":
    check gqlSource("query Broken {").invalid == jeInvalidRequest

  test "rejects an empty document":
    check gqlDocument([]).invalid == jeInvalidRequest

  test "rejects an empty selection":
    check gqlQuery("Empty").invalid == jeInvalidRequest

  test "rejects empty inline fragments":
    check gqlQuery("Q", selection = [gqlInlineFragment("User")]).invalid ==
      jeInvalidRequest

  test "rejects field name injection":
    check gqlQuery("Q", selection = [gqlField("id } mutation Evil { x")])
      .invalid == jeInvalidRequest

  test "rejects operation argument and alias injection":
    check gqlQuery("Q bad", selection = [gqlField("id")]).invalid ==
      jeInvalidRequest
    check gqlQuery("Q", selection = [gqlField("id", alias = "x: y")])
      .invalid == jeInvalidRequest
    check gqlQuery("Q", selection = [gqlField(
      "id", arguments = [gqlArgument("x) { evil", gqlInt(1))]
    )]).invalid == jeInvalidRequest

  test "rejects variable and type injection":
    check gqlQuery(
      "Q",
      variables = [gqlVariableDefinition("bad-name", "ID!")],
      selection = [gqlField("id")]
    ).invalid == jeInvalidRequest
    check gqlQuery(
      "Q",
      variables = [gqlVariableDefinition("id", "ID!) { evil")],
      selection = [gqlField("id")]
    ).invalid == jeInvalidRequest

  test "rejects invalid enum and directive names":
    check gqlQuery("Q", selection = [gqlField(
      "f", arguments = [gqlArgument("x", gqlEnum("null"))]
    )]).invalid == jeInvalidRequest
    check gqlQuery("Q", directives = [gqlDirective("bad-name")],
      selection = [gqlField("id")]).invalid == jeInvalidRequest

  test "rejects the reserved fragment name on":
    check gqlQuery("Q", selection = [gqlFragmentSpread("on")], fragments = [
      gqlFragment("on", "User", selection = [gqlField("id")])
    ]).invalid == jeInvalidRequest

suite "GraphQL client execution":
  test "posts the standard envelope and decodes typed data":
    var dispatched = 0
    let transport = newInProcessTransport(proc(request: Request): Future[Response] {.async.} =
      inc dispatched
      check request.httpMethod == rmPost
      check request.headers.get("content-type") == "application/json"
      check "application/graphql-response+json" in request.headers.get("accept")
      let payload = request.body.parseJson
      check payload["query"].getStr == userDocument().rendered
      check payload["variables"]["id"].getStr == "42"
      check not payload.hasKey("operationName")
      return request.responseFor("""{"data":{"user":{"id":"42","name":"Ada"}}}""")
    )
    let client = newClient(transport, "https://example.test/")
    let outcome = waitFor client.executeGraphql(
      "graphql", userDocument(), UserData, %*{"id": "42"}
    )
    check outcome.isOk
    check outcome.value.data.isSome
    check outcome.value.data.get.user.name == "Ada"
    check not outcome.value.hasErrors
    check dispatched == 1

  test "sends operationName for multiple-operation documents":
    let transport = newInProcessTransport(proc(request: Request): Future[Response] {.async.} =
      check request.body.parseJson["operationName"].getStr == "A"
      return request.responseFor("""{"data":{"user":{"id":"1","name":"A"}}}""")
    )
    let document = gqlDocument([
      gqlOperation(gokQuery, "A", selection = [gqlField("user", selection = [
        gqlField("id"), gqlField("name")
      ])]),
      gqlOperation(gokQuery, "B", selection = [gqlField("other")])
    ])
    let outcome = waitFor newClient(transport).executeGraphql(
      "/graphql", document, UserData, operationName = "A"
    )
    check outcome.isOk

  test "requires and validates operationName for builder documents":
    var dispatched = false
    let transport = newInProcessTransport(proc(request: Request): Future[Response] {.async.} =
      dispatched = true
      return request.responseFor("""{"data":{"user":{"id":"1","name":"A"}}}""")
    )
    let document = gqlDocument([
      gqlOperation(gokQuery, "A", selection = [gqlField("a")]),
      gqlOperation(gokQuery, "B", selection = [gqlField("b")])
    ])
    let client = newClient(transport)
    let missing = waitFor client.executeGraphql("/graphql", document, UserData)
    check missing.isErr
    check missing.error.kind == jeInvalidRequest
    let unknown = waitFor client.executeGraphql(
      "/graphql", document, UserData, operationName = "Unknown"
    )
    check unknown.isErr
    check unknown.error.kind == jeInvalidRequest
    check not dispatched

  test "preserves partial data and structured GraphQL errors":
    let transport = newInProcessTransport(proc(request: Request): Future[Response] {.async.} =
      return request.responseFor("""{
        "data":{"user":{"id":"1","name":"partial"}},
        "errors":[{
          "message":"name is stale",
          "locations":[{"line":2,"column":3}],
          "path":["user","name"],
          "extensions":{"code":"STALE"}
        }],
        "extensions":{"traceId":"abc"}
      }""")
    )
    let outcome = waitFor newClient(transport).executeGraphql(
      "/graphql", userDocument(), UserData
    )
    check outcome.isOk
    check outcome.value.data.get.user.name == "partial"
    check outcome.value.hasErrors
    check outcome.value.errors[0].message == "name is stale"
    check outcome.value.errors[0].locations[0] == GraphqlLocation(line: 2, column: 3)
    check outcome.value.errors[0].path[1].getStr == "name"
    check outcome.value.errors[0].extensions["code"].getStr == "STALE"
    check outcome.value.extensions["traceId"].getStr == "abc"

  test "accepts null data when errors are present":
    let transport = newInProcessTransport(proc(request: Request): Future[Response] {.async.} =
      return request.responseFor("""{"data":null,"errors":[{"message":"denied"}]}""")
    )
    let outcome = waitFor newClient(transport).executeGraphql(
      "/graphql", userDocument(), UserData
    )
    check outcome.isOk
    check outcome.value.data.isNone
    check outcome.value.errors[0].message == "denied"

  test "accepts the GraphQL response JSON media type":
    let transport = newInProcessTransport(proc(request: Request): Future[Response] {.async.} =
      return request.responseFor(
        """{"data":{"user":{"id":"1","name":"A"}}}""",
        "application/graphql-response+json; charset=utf-8"
      )
    )
    check waitFor(newClient(transport).executeGraphql(
      "/graphql", userDocument(), UserData
    )).isOk

  test "allows omitted response content type for custom transports":
    let transport = newInProcessTransport(proc(request: Request): Future[Response] {.async.} =
      return request.responseFor(
        """{"data":{"user":{"id":"1","name":"A"}}}""", ""
      )
    )
    check waitFor(newClient(transport).executeGraphql(
      "/graphql", userDocument(), UserData
    )).isOk

  test "rejects invalid variables before dispatch":
    var dispatched = false
    let transport = newInProcessTransport(proc(request: Request): Future[Response] {.async.} =
      dispatched = true
      return request.responseFor("{}")
    )
    let outcome = waitFor newClient(transport).executeGraphql(
      "/graphql", userDocument(), UserData, %*[1, 2]
    )
    check outcome.isErr
    check outcome.error.kind == jeInvalidRequest
    check not dispatched

  test "rejects malformed operationName before dispatch":
    var dispatched = false
    let transport = newInProcessTransport(proc(request: Request): Future[Response] {.async.} =
      dispatched = true
      return request.responseFor("{}")
    )
    let outcome = waitFor newClient(transport).executeGraphql(
      "/graphql", userDocument(), UserData, operationName = "A B"
    )
    check outcome.isErr
    check outcome.error.kind == jeInvalidRequest
    check not dispatched

  test "invalid documents never dispatch":
    var dispatched = false
    let transport = newInProcessTransport(proc(request: Request): Future[Response] {.async.} =
      dispatched = true
      return request.responseFor("{}")
    )
    let outcome = waitFor newClient(transport).executeGraphql(
      "/graphql", gqlSource("query {"), UserData
    )
    check outcome.isErr
    check outcome.error.kind == jeInvalidRequest
    check not dispatched

  test "transport errors retain their kind":
    let transport = newInProcessTransport(proc(_: Request): Future[Response] {.async.} =
      raise newJoubakoError(jeTimeout, "late", "/graphql")
    )
    let outcome = waitFor newClient(transport).executeGraphql(
      "/graphql", userDocument(), UserData
    )
    check outcome.isErr
    check outcome.error.kind == jeTimeout

  test "malformed JSON is a codec error with response context":
    let transport = newInProcessTransport(proc(request: Request): Future[Response] {.async.} =
      return request.responseFor("not-json")
    )
    let outcome = waitFor newClient(transport).executeGraphql(
      "/graphql", userDocument(), UserData
    )
    check outcome.isErr
    check outcome.error.kind == jeCodec
    check outcome.error.hasResponse
    check outcome.error.response.body == "not-json"

  test "rejects non-object and empty GraphQL envelopes":
    var body = "[]"
    let transport = newInProcessTransport(proc(request: Request): Future[Response] {.async.} =
      return request.responseFor(body)
    )
    let client = newClient(transport)
    check (waitFor client.executeGraphql(
      "/graphql", userDocument(), UserData
    )).error.kind == jeCodec
    body = "{}"
    check (waitFor client.executeGraphql(
      "/graphql", userDocument(), UserData
    )).error.kind == jeCodec

  test "rejects empty or malformed errors arrays":
    var body = """{"errors":[]}"""
    let transport = newInProcessTransport(proc(request: Request): Future[Response] {.async.} =
      return request.responseFor(body)
    )
    let client = newClient(transport)
    check (waitFor client.executeGraphql(
      "/graphql", userDocument(), UserData
    )).error.kind == jeCodec
    body = """{"errors":[{}]}"""
    check (waitFor client.executeGraphql(
      "/graphql", userDocument(), UserData
    )).error.kind == jeCodec

  test "rejects malformed error metadata":
    var body = """{"errors":[{"message":"x","locations":{}}]}"""
    let transport = newInProcessTransport(proc(request: Request): Future[Response] {.async.} =
      return request.responseFor(body)
    )
    let client = newClient(transport)
    check (waitFor client.executeGraphql(
      "/graphql", userDocument(), UserData
    )).error.kind == jeCodec
    body = """{"errors":[{"message":"x","path":"bad"}]}"""
    check (waitFor client.executeGraphql(
      "/graphql", userDocument(), UserData
    )).error.kind == jeCodec
    body = """{"errors":[{"message":"x","extensions":[]}]}"""
    check (waitFor client.executeGraphql(
      "/graphql", userDocument(), UserData
    )).error.kind == jeCodec

  test "rejects unexpected response media types":
    let transport = newInProcessTransport(proc(request: Request): Future[Response] {.async.} =
      return request.responseFor(
        """{"data":{"user":{"id":"1","name":"A"}}}""", "text/html"
      )
    )
    check (waitFor newClient(transport).executeGraphql(
      "/graphql", userDocument(), UserData
    )).error.kind == jeCodec

  test "rejects typed data mismatches":
    let transport = newInProcessTransport(proc(request: Request): Future[Response] {.async.} =
      return request.responseFor("""{"data":{"user":{"id":1,"name":false}}}""")
    )
    check (waitFor newClient(transport).executeGraphql(
      "/graphql", userDocument(), UserData
    )).error.kind == jeCodec

  test "caller headers are preserved":
    let transport = newInProcessTransport(proc(request: Request): Future[Response] {.async.} =
      check request.headers.get("authorization") == "Bearer token"
      check request.headers.get("content-type") == "application/custom+json"
      check request.headers.get("accept") == "application/json"
      return request.responseFor("""{"data":{"user":{"id":"1","name":"A"}}}""")
    )
    var headers = initHeaders()
    headers.set("authorization", "Bearer token")
    headers.set("content-type", "application/custom+json")
    headers.set("accept", "application/json")
    check waitFor(newClient(transport).executeGraphql(
      "/graphql", userDocument(), UserData, headers = headers
    )).isOk

  test "request limits apply to the encoded envelope":
    var dispatched = false
    let transport = newInProcessTransport(proc(request: Request): Future[Response] {.async.} =
      dispatched = true
      return request.responseFor("{}")
    )
    var options = defaultRequestOptions()
    options.maxRequestBytes = 5
    let outcome = waitFor newClient(transport).executeGraphql(
      "/graphql", userDocument(), UserData, options = options
    )
    check outcome.isErr
    check outcome.error.kind == jeBodyTooLarge
    check not dispatched
