# Joubako with nim-basolato

This integration connects a Joubako client to a nim-basolato server. It is a
second all-Nim example with the same wire contract and no shared application
types between the two processes.

## Backend implementation

```nim
import std/[asyncdispatch, httpcore, json]
import basolato
import basolato/controller

proc health(context: Context): Future[Response] {.async.} =
  return render(%*{"ok": true, "framework": "nim-basolato"})

proc message(context: Context): Future[Response] {.async.} =
  try:
    let payload = context.request.body.parseJson()
    let priority = payload["priority"].getInt()
    if priority < 1 or priority > 5:
      raise newException(ValueError, "invalid message")
    return render(Http201, %*{
      "accepted": true,
      "priority": priority,
      "framework": "nim-basolato"
    })
  except JsonParsingError, KeyError, ValueError:
    return render(Http422, %*{"error": "invalid message"})
```

See the complete [`server.nim`](../../examples/frameworks/basolato/server.nim).

## Run nim-basolato

Basolato 0.16.1's server callback currently requires thread-safety analysis to
be disabled for this demo server. This does not apply to the Joubako client.

```sh
nimble --legacy install basolato@0.16.1
SECRET_KEY=joubako-demo-only \
  nim c -r --mm:arc --threadAnalysis:off \
  examples/frameworks/basolato/server.nim
```

## Call nim-basolato from Joubako

```sh
JOUBAKO_DEMO_BASE_URL=http://127.0.0.1:8002/ \
  JOUBAKO_DEMO_EXPECTED_FRAMEWORK=nim-basolato \
  nim c -r --mm:arc -d:ssl --path:src examples/frameworks/client.nim
```

## Production notes

Supply a real secret through the deployment's secret manager and configure
authentication, request limits, logging, and TLS for the application. Review
the server framework's supported Nim and memory-manager combinations separately
from Joubako's ARC/ORC client support.
