# Joubako with Prologue

This integration uses Joubako and Prologue in separate Nim processes. It
demonstrates that Joubako does not require the client and server to share an
HTTP framework or memory model.

## Backend implementation

```nim
import std/[httpcore, json]
import prologue

proc health(ctx: Context) {.async.} =
  resp jsonResponse(%*{"ok": true, "framework": "Prologue"})

proc message(ctx: Context) {.async.} =
  try:
    let payload = ctx.request.body.parseJson()
    let text = payload["text"].getStr()
    let priority = payload["priority"].getInt()
    if text.len == 0 or priority < 1 or priority > 5:
      raise newException(ValueError, "invalid message")
    resp jsonResponse(%*{
      "accepted": true,
      "text": text,
      "priority": priority,
      "framework": "Prologue"
    }, Http201)
  except JsonParsingError, KeyError, ValueError:
    resp jsonResponse(%*{"error": "invalid message"}, Http422)
```

See the complete [`server.nim`](../../examples/frameworks/prologue/server.nim).

## Run Prologue

```sh
nimble install prologue@0.6.10
nim c -r --mm:arc examples/frameworks/prologue/server.nim
```

## Call Prologue from Joubako

```sh
JOUBAKO_DEMO_BASE_URL=http://127.0.0.1:8081/ \
  JOUBAKO_DEMO_EXPECTED_FRAMEWORK=Prologue \
  nim c -r --mm:arc -d:ssl --path:src examples/frameworks/client.nim
```

Joubako v0.2.3 also exercised its C11 JSON ABI against Prologue for three
hours: 2,540,805 requests completed with zero failures and stable descriptor
counts. See the [soak report](../c-abi-prologue-soak.md).

## Production notes

Use Prologue's production configuration for secrets, middleware, logging,
request limits, and deployment. A Joubako client and Prologue server may use
ARC or ORC independently because their ownership boundary is HTTP.
