import std/[asyncdispatch, httpcore, json]
import basolato
import basolato/controller


proc health(context: Context): Future[Response] {.async.} =
  return render(%*{"ok": true, "framework": "nim-basolato"})

proc user(context: Context): Future[Response] {.async.} =
  let id = context.params.getInt("id")
  if id != 1:
    return render(Http404, %*{"error": "user not found"})

  return render(%*{
    "id": id,
    "name": "nim-basolato User",
    "email": "basolato@example.test"
  })

proc message(context: Context): Future[Response] {.async.} =
  try:
    let payload = context.request.body.parseJson()
    let text = payload["text"].getStr()
    let priority = payload["priority"].getInt()
    if text.len == 0 or text.len > 200 or priority < 1 or priority > 5:
      raise newException(ValueError, "invalid message")

    let client = context.request.headers.getOrDefault("x-joubako-demo")
    return render(Http201, %*{
      "accepted": true,
      "text": text,
      "priority": priority,
      "framework": "nim-basolato",
      "client": if client.len == 0: "unknown" else: client
    })
  except JsonParsingError, KeyError, ValueError:
    return render(Http422, %*{"error": "invalid message"})


let routes = @[
  Route.get("/api/health", health),
  Route.get("/api/users/{id:int}", user),
  Route.post("/api/messages", message)
]
let settings = Settings.new(port = 8002, logToFile = false)
serve(routes, settings)
