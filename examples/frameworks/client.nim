import std/[asyncdispatch, os]
import joubako

type
  HealthResponse = object
    ok: bool
    framework: string

  UserResponse = object
    id: int
    name: string
    email: string

  MessageRequest = object
    text: string
    priority: int

  MessageResponse = object
    accepted: bool
    text: string
    priority: int
    framework: string
    client: string

proc requireOk[T](outcome: JResult[T]; operation: string): T =
  if outcome.isErr:
    raise newException(
      IOError,
      operation & " failed: " & $outcome.error.kind & ": " &
        outcome.error.msg
    )
  outcome.value

proc main() {.async.} =
  let baseUrl = getEnv("JOUBAKO_DEMO_BASE_URL", "http://127.0.0.1:3000/")
  let transport = newHttpTransport()
  let api = newClient(transport, baseUrl)

  var headers = initHeaders()
  headers.set("x-joubako-demo", "framework-client")

  let health = requireOk(
    await api.getJson("api/health", HealthResponse, headers),
    "health check"
  )
  doAssert health.ok

  let user = requireOk(
    await api.getJson("api/users/1", UserResponse, headers),
    "typed user request"
  )
  doAssert user.id == 1

  let created = requireOk(
    await api.postJson(
      "api/messages",
      MessageRequest(text: "Hello from Joubako", priority: 2),
      MessageResponse,
      headers
    ),
    "typed message request"
  )
  doAssert created.accepted
  doAssert created.client == "framework-client"

  let missing = await api.get("api/users/999", headers)
  doAssert missing.isErr
  doAssert missing.error.kind == jeHttpStatus
  doAssert missing.error.status == 404

  transport.closeIdleConnections()
  echo "Joubako successfully called " & health.framework
  echo "User: " & user.name & " <" & user.email & ">"
  echo "Message accepted by " & created.framework

when isMainModule:
  waitFor main()
