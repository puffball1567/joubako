import std/[asyncdispatch, strutils, unittest]
import joubako
import ./result_test_helpers

type
  Item = object
    id: int
    label: string

proc okResponse(request: Request): Future[Response] {.async.} =
  return Response(status: 200, body: "ok", request: request)

suite "Client URL and configuration":
  test "relative paths resolve against a base URL":
    var seen = ""
    let handler = proc(request: Request): Future[Response] {.async.} =
      seen = request.url
      return Response(status: 200, request: request)
    let client = newClient(
      newInProcessTransport(handler),
      "https://example.test/api/"
    )
    discard waitFor client.get("users")
    check seen == "https://example.test/api/users"

  test "leading slash paths resolve from the origin root":
    var seen = ""
    let handler = proc(request: Request): Future[Response] {.async.} =
      seen = request.url
      return Response(status: 200, request: request)
    let client = newClient(
      newInProcessTransport(handler),
      "https://example.test/api/"
    )
    discard waitFor client.get("/users")
    check seen == "https://example.test/users"

  test "absolute request URLs override the base URL":
    var seen = ""
    let handler = proc(request: Request): Future[Response] {.async.} =
      seen = request.url
      return Response(status: 200, request: request)
    let client = newClient(
      newInProcessTransport(handler),
      "https://example.test/api/"
    )
    discard waitFor client.get("https://other.test/users")
    check seen == "https://other.test/users"

  test "empty paths use the base URL":
    var seen = ""
    let handler = proc(request: Request): Future[Response] {.async.} =
      seen = request.url
      return Response(status: 200, request: request)
    let client = newClient(
      newInProcessTransport(handler),
      "https://example.test/api/"
    )
    discard waitFor client.get("")
    check seen == "https://example.test/api/"

  test "an empty path and empty base URL are rejected":
    let client = newClient(newInProcessTransport(okResponse))
    try:
      discard waitFor client.get("")
      fail()
    except JoubakoError as error:
      check error.kind == jeInvalidRequest

  test "a nil transport is rejected":
    let client = newClient(nil, "https://example.test/")
    try:
      discard waitFor client.get("users")
      fail()
    except JoubakoError as error:
      check error.kind == jeInvalidRequest

  test "default options reach the transport":
    var seenTimeout = 0
    var defaults = defaultRequestOptions()
    defaults.timeoutMs = 1234
    let handler = proc(request: Request): Future[Response] {.async.} =
      seenTimeout = request.options.timeoutMs
      return Response(status: 200, request: request)
    let client = newClient(
      newInProcessTransport(handler),
      defaultOptions = defaults
    )
    discard waitFor client.get("/")
    check seenTimeout == 1234

  test "per-request timeout overrides the client default":
    var seenTimeout = 0
    var defaults = defaultRequestOptions()
    defaults.timeoutMs = 1234
    var options = RequestOptions(timeoutMs: 55)
    let handler = proc(request: Request): Future[Response] {.async.} =
      seenTimeout = request.options.timeoutMs
      return Response(status: 200, request: request)
    let client = newClient(
      newInProcessTransport(handler),
      defaultOptions = defaults
    )
    discard waitFor client.get("/", options = options)
    check seenTimeout == 55

  test "responses retain the logical request":
    let client = newClient(newInProcessTransport(okResponse))
    let response = waitFor client.post("/items", "body")
    check response.request.httpMethod == rmPost
    check response.request.url == "/items"
    check response.request.body == "body"

suite "Client errors and limits":
  test "non-success statuses become structured errors":
    var responseHeaders = initHeaders()
    responseHeaders.add("content-type", "application/problem+json")
    responseHeaders.add("x-trace", "first")
    responseHeaders.add("x-trace", "second")
    let handler = proc(request: Request): Future[Response] {.async.} =
      return Response(
        status: 404,
        statusText: "Not Found",
        headers: responseHeaders,
        body: "{\"error\":\"missing\"}\0tail",
        request: request
      )
    let client = newClient(newInProcessTransport(handler))
    try:
      discard waitFor client.get("/missing")
      fail()
    except JoubakoError as error:
      check error.kind == jeHttpStatus
      check error.status == 404
      check error.url == "/missing"
      check error.hasResponse
      check error.response.status == 404
      check error.response.statusText == "Not Found"
      check error.response.headers.get("content-type") ==
        "application/problem+json"
      check error.response.headers.getAll("x-trace") == @[
        "first", "second"
      ]
      check error.response.body == "{\"error\":\"missing\"}\0tail"
      check error.attempts == 1

    responseHeaders.set("x-trace", "mutated")

  test "transport errors do not claim to contain an HTTP response":
    let handler = proc(request: Request): Future[Response] {.async.} =
      raise newException(IOError, "offline")
    let client = newClient(newInProcessTransport(handler))
    try:
      discard waitFor client.get("/offline")
      fail()
    except JoubakoError as error:
      check error.kind == jeTransport
      check not error.hasResponse
      check error.response.status == 0
      check error.attempts == 1

  test "a custom status validator can accept 404":
    let handler = proc(request: Request): Future[Response] {.async.} =
      return Response(status: 404, request: request)
    let client = newClient(
      newInProcessTransport(handler),
      validateStatus = proc(status: int): bool = status == 404
    )
    check waitFor(client.get("/missing")).status == 404

  test "a custom status validator can reject 200":
    let client = newClient(
      newInProcessTransport(okResponse),
      validateStatus = proc(status: int): bool =
        discard status
        false
    )
    expect JoubakoError:
      discard waitFor client.get("/")

  test "ordinary transport errors are wrapped":
    let handler = proc(request: Request): Future[Response] {.async.} =
      discard request
      raise newException(IOError, "offline")
    let client = newClient(newInProcessTransport(handler))
    try:
      discard waitFor client.get("/")
      fail()
    except JoubakoError as error:
      check error.kind == jeTransport
      check error.msg.startsWith("offline")

  test "structured transport errors are preserved":
    let handler = proc(request: Request): Future[Response] {.async.} =
      raise newJoubakoError(jeTimeout, "slow", request.url)
    let client = newClient(newInProcessTransport(handler))
    try:
      discard waitFor client.get("/slow")
      fail()
    except JoubakoError as error:
      check error.kind == jeTimeout

  test "a response exactly at the size limit is accepted":
    let handler = proc(request: Request): Future[Response] {.async.} =
      return Response(status: 200, body: "1234", request: request)
    let client = newClient(newInProcessTransport(handler))
    var options = RequestOptions(maxResponseBytes: 4)
    check waitFor(client.get("/", options = options)).body == "1234"

  test "a response one byte over the size limit is rejected":
    let handler = proc(request: Request): Future[Response] {.async.} =
      return Response(status: 200, body: "12345", request: request)
    let client = newClient(newInProcessTransport(handler))
    var options = RequestOptions(maxResponseBytes: 4)
    try:
      discard waitFor client.get("/", options = options)
      fail()
    except JoubakoError as error:
      check error.kind == jeBodyTooLarge

  test "negative response limits disable the check":
    let handler = proc(request: Request): Future[Response] {.async.} =
      return Response(status: 200, body: "large enough", request: request)
    let client = newClient(newInProcessTransport(handler))
    var options = RequestOptions(maxResponseBytes: -1)
    check waitFor(client.get("/", options = options)).body == "large enough"

  test "a request exactly at the size limit is accepted":
    let client = newClient(newInProcessTransport(okResponse))
    var options = RequestOptions(maxRequestBytes: 4)
    discard waitFor client.post("/", "1234", options = options)

  test "a request one byte over the size limit is rejected":
    var dispatched = false
    let handler = proc(request: Request): Future[Response] {.async.} =
      dispatched = true
      return Response(status: 200, request: request)
    let client = newClient(newInProcessTransport(handler))
    var options = RequestOptions(maxRequestBytes: 4)
    expect JoubakoError:
      discard waitFor client.post("/", "12345", options = options)
    check not dispatched

  test "negative request limits disable the check":
    let client = newClient(newInProcessTransport(okResponse))
    var options = RequestOptions(maxRequestBytes: -1)
    discard waitFor client.post("/", "unbounded", options = options)

  test "cancellation occurring inside the transport is observed":
    let token = newCancellationToken()
    let handler = proc(request: Request): Future[Response] {.async.} =
      token.cancel("removed")
      return Response(status: 200, request: request)
    let client = newClient(newInProcessTransport(handler))
    var options = RequestOptions(cancellation: token)
    try:
      discard waitFor client.get("/", options = options)
      fail()
    except JoubakoError as error:
      check error.kind == jeCancelled

suite "Client interceptors":
  test "an unknown request interceptor ID is not ejected":
    let client = newClient(newInProcessTransport(okResponse))
    check not client.ejectRequestInterceptor(999)

  test "an unknown response interceptor ID is not ejected":
    let client = newClient(newInProcessTransport(okResponse))
    check not client.ejectResponseInterceptor(999)

  test "ejected request interceptors no longer run":
    var calls = 0
    let client = newClient(newInProcessTransport(okResponse))
    let id = client.useRequestInterceptor(
      proc(request: Request): Request =
        inc calls
        request
    )
    check client.ejectRequestInterceptor(id)
    discard waitFor client.get("/")
    check calls == 0

  test "ejected response interceptors no longer run":
    var calls = 0
    let client = newClient(newInProcessTransport(okResponse))
    let id = client.useResponseInterceptor(
      proc(response: Response): Response =
        inc calls
        response
    )
    check client.ejectResponseInterceptor(id)
    discard waitFor client.get("/")
    check calls == 0

  test "request interceptor failures stop transport dispatch":
    var dispatched = false
    let handler = proc(request: Request): Future[Response] {.async.} =
      dispatched = true
      return Response(status: 200, request: request)
    let client = newClient(newInProcessTransport(handler))
    discard client.useRequestInterceptor(
      proc(request: Request): Request =
        discard request
        raise newException(ValueError, "bad interceptor")
    )
    try:
      discard waitFor client.get("/")
      fail()
    except JoubakoError as error:
      check error.attempts == 0
    check not dispatched

  test "response interceptor failures propagate":
    let client = newClient(newInProcessTransport(okResponse))
    discard client.useResponseInterceptor(
      proc(response: Response): Response =
        discard response
        raise newException(ValueError, "bad response interceptor")
    )
    try:
      discard waitFor client.get("/")
      fail()
    except JoubakoError as error:
      check error.attempts == 1

  test "request interceptors cannot produce an empty URL":
    let client = newClient(newInProcessTransport(okResponse))
    discard client.useRequestInterceptor(
      proc(request: Request): Request =
        result = request
        result.url = ""
    )
    expect JoubakoError:
      discard waitFor client.get("/")

  test "request interceptors cannot inject header line breaks":
    let client = newClient(newInProcessTransport(okResponse))
    discard client.useRequestInterceptor(
      proc(request: Request): Request =
        result = request
        result.headers.set("x-test", "safe\r\ninjected: true")
    )
    expect JoubakoError:
      discard waitFor client.get("/")

  test "request interceptors cannot increase a body over the limit":
    let client = newClient(newInProcessTransport(okResponse))
    discard client.useRequestInterceptor(
      proc(request: Request): Request =
        result = request
        result.body = "12345"
    )
    var options = RequestOptions(maxRequestBytes: 4)
    expect JoubakoError:
      discard waitFor client.post("/", "1", options = options)

  test "response interceptors cannot increase a body over the limit":
    let client = newClient(newInProcessTransport(okResponse))
    discard client.useResponseInterceptor(
      proc(response: Response): Response =
        result = response
        result.body = "12345"
    )
    var options = RequestOptions(maxResponseBytes: 4)
    expect JoubakoError:
      discard waitFor client.get("/", options = options)

  test "multiple response interceptors run in registration order":
    var order: seq[int]
    let client = newClient(newInProcessTransport(okResponse))
    discard client.useResponseInterceptor(
      proc(response: Response): Response =
        order.add 1
        response
    )
    discard client.useResponseInterceptor(
      proc(response: Response): Response =
        order.add 2
        response
    )
    discard waitFor client.get("/")
    check order == @[1, 2]

  test "request and response interceptor IDs are unique":
    let client = newClient(newInProcessTransport(okResponse))
    let requestId = client.useRequestInterceptor(
      proc(request: Request): Request = request
    )
    let responseId = client.useResponseInterceptor(
      proc(response: Response): Response = response
    )
    check requestId != responseId

  test "interceptor header mutations do not alter client defaults":
    var observed: seq[string]
    let handler = proc(request: Request): Future[Response] {.async.} =
      observed.add request.headers.get("x-once")
      return Response(status: 200, request: request)
    let client = newClient(newInProcessTransport(handler))
    let id = client.useRequestInterceptor(
      proc(request: Request): Request =
        result = request
        result.headers.set("x-once", "set")
    )
    discard waitFor client.get("/first")
    discard client.ejectRequestInterceptor(id)
    discard waitFor client.get("/second")
    check observed == @["set", ""]

suite "Client concurrency":
  test "concurrent requests retain independent responses":
    let handler = proc(request: Request): Future[Response] {.async.} =
      if request.url == "/slow":
        await sleepAsync(2)
      return Response(
        status: 200,
        body: request.url,
        request: request
      )
    let client = newClient(newInProcessTransport(handler))
    let responses = waitFor all(
      client.get("/slow"),
      client.get("/fast"),
      client.get("/other")
    )
    check responses[0].isOk
    check responses[1].isOk
    check responses[2].isOk
    check responses[0].value.body == "/slow"
    check responses[1].value.body == "/fast"
    check responses[2].value.body == "/other"

  test "cancelling one request does not cancel another":
    let handler = proc(request: Request): Future[Response] {.async.} =
      await sleepAsync(2)
      return Response(status: 200, body: request.url, request: request)
    let client = newClient(newInProcessTransport(handler))
    let token = newCancellationToken()
    var cancelledOptions = RequestOptions(cancellation: token)
    let cancelledRequest = client.get("/cancelled", options = cancelledOptions)
    let successfulRequest = client.get("/successful")
    token.cancel("only one")

    expect JoubakoError:
      discard waitFor cancelledRequest
    check waitFor(successfulRequest).body == "/successful"

suite "JSON codec":
  test "integer JSON responses decode":
    let response = Response(status: 200, body: "42")
    check response.decodeJson(int) == 42

  test "string JSON responses decode":
    let response = Response(status: 200, body: "\"hello\"")
    check response.decodeJson(string) == "hello"

  test "array JSON responses decode":
    let response = Response(status: 200, body: "[1,2,3]")
    check response.decodeJson(seq[int]) == @[1, 2, 3]

  test "object JSON responses decode":
    let response = Response(
      status: 200,
      body: """{"id":3,"label":"three"}"""
    )
    check response.decodeJson(Item) == Item(id: 3, label: "three")

  test "malformed JSON becomes a codec error":
    let response = Response(
      status: 200,
      body: "{",
      request: Request(url: "/malformed")
    )
    try:
      discard response.decodeJson(Item)
      fail()
    except JoubakoError as error:
      check error.kind == jeCodec
      check error.url == "/malformed"

  test "type mismatches become codec errors":
    let response = Response(status: 200, body: "\"not an integer\"")
    try:
      discard response.decodeJson(int)
      fail()
    except JoubakoError as error:
      check error.kind == jeCodec

  test "empty response bodies become codec errors":
    let response = Response(status: 200, body: "")
    expect JoubakoError:
      discard response.decodeJson(Item)

  test "custom content type is retained for JSON requests":
    var contentType = ""
    let handler = proc(request: Request): Future[Response] {.async.} =
      contentType = request.headers.get("content-type")
      return Response(
        status: 200,
        body: request.body,
        request: request
      )
    let client = newClient(newInProcessTransport(handler))
    var headers = initHeaders()
    headers.set("content-type", "application/problem+json")
    discard waitFor client.postJson(
      "/items",
      Item(id: 1, label: "one"),
      Item,
      headers
    )
    check contentType == "application/problem+json"

  test "putJson uses PUT":
    var seenMethod = rmGet
    let handler = proc(request: Request): Future[Response] {.async.} =
      seenMethod = request.httpMethod
      return Response(status: 200, body: request.body, request: request)
    let client = newClient(newInProcessTransport(handler))
    discard waitFor client.putJson("/", Item(id: 1), Item)
    check seenMethod == rmPut

  test "patchJson uses PATCH":
    var seenMethod = rmGet
    let handler = proc(request: Request): Future[Response] {.async.} =
      seenMethod = request.httpMethod
      return Response(status: 200, body: request.body, request: request)
    let client = newClient(newInProcessTransport(handler))
    discard waitFor client.patchJson("/", Item(id: 1), Item)
    check seenMethod == rmPatch

  test "HTTP status validation occurs before JSON decoding":
    let handler = proc(request: Request): Future[Response] {.async.} =
      return Response(status: 500, body: "{", request: request)
    let client = newClient(newInProcessTransport(handler))
    try:
      discard waitFor client.getJson("/", Item)
      fail()
    except JoubakoError as error:
      check error.kind == jeHttpStatus

  test "typed GET supports query parameters":
    var seenUrl = ""
    let handler = proc(request: Request): Future[Response] {.async.} =
      seenUrl = request.url
      return Response(
        status: 200,
        body: """{"id":1,"label":"one"}""",
        request: request
      )
    let client = newClient(newInProcessTransport(handler))
    discard waitFor client.getJson(
      "/items",
      [(name: "active", value: "true")],
      Item
    )
    check seenUrl == "/items?active=true"
