# Backend integration guides

These guides show a Nim application using Joubako to call equivalent JSON APIs
implemented by eleven server-side web frameworks. The framework is the remote
backend; Joubako remains the client inside the Nim application.

No framework-specific Joubako adapter is required. Each example uses the same
request, response, timeout, size-limit, and structured-error contracts.

## Shared API contract

| Request | Expected result | Joubako behavior demonstrated |
| --- | --- | --- |
| `GET /api/health` | `200` JSON | Typed response decoding |
| `GET /api/users/1` | `200` JSON | Typed model decoding |
| `POST /api/messages` | `201` JSON | Typed request encoding and custom headers |
| Invalid `POST /api/messages` | `422` JSON | HTTP status represented as `jeHttpStatus` |
| `GET /api/users/999` | `404` JSON | Structured missing-resource failure |

The complete shared client is
[`examples/frameworks/client.nim`](../../examples/frameworks/client.nim). Its
core setup is the same for every backend:

```nim
import std/asyncdispatch
import joubako

type HealthResponse = object
  ok: bool
  framework: string

proc main() {.async.} =
  let transport = newHttpTransport()
  let api = newClient(transport, "http://127.0.0.1:3000/")
  let result = await api.getJson("api/health", HealthResponse)

  if result.isErr:
    echo result.error.kind, ": ", result.error.msg
  else:
    echo result.value.framework

  transport.closeIdleConnections()

waitFor main()
```

Applications normally keep one transport and client alive for an origin so
HTTP/1.1 connections can be reused. Use `-d:ssl` for applications that call
HTTPS endpoints.

## Guides

| Ecosystem | Backend | Guide | Runnable server |
| --- | --- | --- | --- |
| Node.js | Express | [Joubako with Express](express.md) | [`server.mjs`](../../examples/frameworks/express/server.mjs) |
| Node.js | NestJS | [Joubako with NestJS](nestjs.md) | [`src`](../../examples/frameworks/nestjs/src) |
| Python | Flask | [Joubako with Flask](flask.md) | [`app.py`](../../examples/frameworks/flask/app.py) |
| Python | FastAPI | [Joubako with FastAPI](fastapi.md) | [`app.py`](../../examples/frameworks/fastapi/app.py) |
| PHP | Laravel | [Joubako with Laravel](laravel.md) | [`routes/api.php`](../../examples/frameworks/laravel/routes/api.php) |
| Java | Spring Boot | [Joubako with Spring Boot](spring-boot.md) | [`DemoApplication.java`](../../examples/frameworks/spring-boot/src/main/java/dev/joubako/examples/DemoApplication.java) |
| .NET | ASP.NET Core | [Joubako with ASP.NET Core](aspnet-core.md) | [`Program.cs`](../../examples/frameworks/aspnet/Program.cs) |
| Go | Gin | [Joubako with Gin](gin.md) | [`main.go`](../../examples/frameworks/gin/main.go) |
| Rust | Axum | [Joubako with Axum](axum.md) | [`main.rs`](../../examples/frameworks/axum/src/main.rs) |
| Nim | Prologue | [Joubako with Prologue](prologue.md) | [`server.nim`](../../examples/frameworks/prologue/server.nim) |
| Nim | nim-basolato | [Joubako with nim-basolato](nim-basolato.md) | [`server.nim`](../../examples/frameworks/basolato/server.nim) |

## Run any guide with ARC or ORC

Start the selected backend, then compile the shared client with the backend's
base URL. For example:

```sh
JOUBAKO_DEMO_BASE_URL=http://127.0.0.1:3000/ \
  JOUBAKO_DEMO_EXPECTED_FRAMEWORK=Express \
  nim c -r --mm:arc -d:ssl --path:src examples/frameworks/client.nim
```

Replace `--mm:arc` with `--mm:orc` to exercise the same client under ORC. The
individual guides provide the correct port and expected framework name.

## Moving from the demo to production

The examples intentionally isolate HTTP interoperability. A production service
must additionally configure its normal authentication, authorization, TLS
termination, request-size limits, rate limiting, logging, observability, and
deployment server. On the client, retain Joubako's finite response and codec
limits and select retry behavior only for operations that are safe to repeat.

The recorded compatibility results are maintained in the
[runnable demo README](../../examples/frameworks/README.md#verified-results).
