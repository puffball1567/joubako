import std/[httpcore, json, os, strutils]
import prologue


proc health(ctx: Context) {.async.} =
  resp jsonResponse(%*{"ok": true, "framework": "Prologue"})

proc user(ctx: Context) {.async.} =
  let id = ctx.getPathParams("id", 0)
  if id != 1:
    resp jsonResponse(%*{"error": "user not found"}, Http404)
    return

  resp jsonResponse(%*{
    "id": id,
    "name": "Prologue User",
    "email": "prologue@example.test"
  })

proc message(ctx: Context) {.async.} =
  try:
    let payload = ctx.request.body.parseJson()
    let text = payload["text"].getStr()
    let priority = payload["priority"].getInt()
    if text.len == 0 or text.len > 200 or priority < 1 or priority > 5:
      raise newException(ValueError, "invalid message")

    let client = ctx.request.getHeaderOrDefault(
      "x-joubako-demo", @["unknown"]
    )[0]
    resp jsonResponse(%*{
      "accepted": true,
      "text": text,
      "priority": priority,
      "framework": "Prologue",
      "client": client
    }, Http201)
  except JsonParsingError, KeyError, ValueError:
    resp jsonResponse(%*{"error": "invalid message"}, Http422)


let configuredPort = getEnv("JOUBAKO_DEMO_PORT", "8081").parseInt
if configuredPort < 1 or configuredPort > 65_535:
  raise newException(ValueError, "JOUBAKO_DEMO_PORT must be between 1 and 65535")

let settings = newSettings(
  appName = "Joubako Prologue demo",
  debug = false,
  port = Port(configuredPort)
)
var app = newApp(settings = settings)
app.addRoute("/api/health", health, HttpGet)
app.addRoute("/api/users/{id}", user, HttpGet)
app.addRoute("/api/messages", message, HttpPost)
app.run()
