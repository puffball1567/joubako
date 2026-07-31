import std/[asyncdispatch, unittest]
import joubako
import ./result_test_helpers

type
  User = object
    id: int
    name: string

proc successfulHandler(request: Request): Future[Response] {.async.} =
  return Response(
    status: 200,
    statusText: "200 OK",
    body: """{"id":42,"name":"Murasaki"}""",
    request: request
  )

proc failingHandler(request: Request): Future[Response] {.async.} =
  return Response(
    status: 503,
    statusText: "503 Service Unavailable",
    body: """{"error":"unavailable"}""",
    request: request
  )

suite "Joubako":
  test "a request can be awaited and decoded":
    let client = newClient(
      newInProcessTransport(successfulHandler),
      "https://api.example.com/"
    )

    let user = waitFor client.getJson("users/42", User)
    check user.id == 42
    check user.name == "Murasaki"

  test "then transforms a successful value":
    let client = newClient(newInProcessTransport(successfulHandler))

    let name = waitFor client.getJson("/users/42", User)
      .then(proc(user: User): string = user.name)

    check name == "Murasaki"

  test "catch can recover from a structured HTTP error":
    let client = newClient(newInProcessTransport(failingHandler))

    let status = waitFor client.get("/unavailable")
      .then(proc(response: Response): int = response.status)
      .catch(proc(requestError: ref JoubakoError): int =
        check requestError.kind == jeHttpStatus
        requestError.status
      )

    check status == 503

  test "finally runs after a chained request":
    let client = newClient(newInProcessTransport(successfulHandler))
    var finalized = false

    discard waitFor client.get("/users/42")
      .finally(proc() = finalized = true)

    check finalized

  test "catch handles an error for a callback-oriented chain":
    let client = newClient(newInProcessTransport(failingHandler))
    var caughtStatus = 0
    var finalized = false

    waitFor client.get("/unavailable")
      .then(proc(response: Response) = discard)
      .catch(proc(error: ref JoubakoError) =
        caughtStatus = error.status
      )
      .finally(proc() = finalized = true)

    check caughtStatus == 503
    check finalized

  test "a cancelled request fails before transport dispatch":
    let token = newCancellationToken()
    token.cancel("view removed")
    var options = defaultRequestOptions()
    options.cancellation = token
    let client = newClient(newInProcessTransport(successfulHandler))

    expect JoubakoError:
      discard waitFor client.get("/users/42", options = options)

  test "query parameters are encoded and repeated":
    var seenUrl = ""
    let handler = proc(request: Request): Future[Response] {.async.} =
      seenUrl = request.url
      return Response(status: 200, body: "{}", request: request)
    let client = newClient(
      newInProcessTransport(handler),
      "https://api.example.com/"
    )

    discard waitFor client.get(
      "search?existing=1#section",
      [
        (name: "term", value: "nim client"),
        (name: "tag", value: "a"),
        (name: "tag", value: "b")
      ]
    )

    check seenUrl ==
      "https://api.example.com/search?existing=1&term=nim+client&tag=a&tag=b#section"

  test "typed JSON POST encodes the body and decodes the response":
    var seenContentType = ""
    var seenBody = ""
    let handler = proc(request: Request): Future[Response] {.async.} =
      seenContentType = request.headers.get("content-type")
      seenBody = request.body
      return Response(
        status: 200,
        body: request.body,
        request: request
      )
    let client = newClient(newInProcessTransport(handler))
    let sent = User(id: 9, name: "Typed JSON")

    let received = waitFor client.postJson("/users", sent, User)

    check seenContentType == "application/json"
    check seenBody == """{"id":9,"name":"Typed JSON"}"""
    check received == sent

  test "request and response interceptors run in registration order":
    var order: seq[string]
    let handler = proc(request: Request): Future[Response] {.async.} =
      order.add "transport:" & request.headers.get("authorization")
      return Response(
        status: 200,
        body: "original",
        request: request
      )
    let client = newClient(newInProcessTransport(handler))

    let requestId = client.useRequestInterceptor(
      proc(request: Request): Request =
        order.add "request-sync"
        result = request
        result.headers.set("authorization", "Bearer token")
    )
    discard client.useRequestInterceptor(
      proc(request: Request): Future[Request] {.async.} =
        await sleepAsync(1)
        order.add "request-async"
        return request
    )
    let responseId = client.useResponseInterceptor(
      proc(response: Response): Response =
        order.add "response"
        result = response
        result.body = "intercepted"
    )

    let response = waitFor client.get("/intercepted")

    check response.body == "intercepted"
    check order == @[
      "request-sync",
      "request-async",
      "transport:Bearer token",
      "response"
    ]
    check client.ejectRequestInterceptor(requestId)
    check client.ejectResponseInterceptor(responseId)
    check not client.ejectRequestInterceptor(requestId)

  test "request body limits are enforced before transport dispatch":
    var dispatched = false
    let handler = proc(request: Request): Future[Response] {.async.} =
      dispatched = true
      return Response(status: 200, request: request)
    let client = newClient(newInProcessTransport(handler))
    var options = defaultRequestOptions()
    options.maxRequestBytes = 3

    expect JoubakoError:
      discard waitFor client.post("/upload", "four", options = options)
    check not dispatched

  test "per-request headers replace client defaults":
    var seenValues: seq[string]
    let handler = proc(request: Request): Future[Response] {.async.} =
      seenValues = request.headers.getAll("x-mode")
      return Response(status: 200, request: request)
    var defaults = initHeaders()
    defaults.set("x-mode", "default")
    let client = newClient(
      newInProcessTransport(handler),
      defaultHeaders = defaults
    )
    var headers = initHeaders()
    headers.set("x-mode", "request")

    discard waitFor client.get("/", headers)

    check seenValues == @["request"]

  test "line breaks in URLs and headers are rejected":
    let client = newClient(newInProcessTransport(successfulHandler))

    expect JoubakoError:
      discard waitFor client.get("/users\r\nx-injected: true")

    var headers = initHeaders()
    headers.set("x-test", "safe\r\nx-injected: true")
    expect JoubakoError:
      discard waitFor client.get("/users", headers)
