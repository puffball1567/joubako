# Framework integration demos

One shared Joubako client communicates with eleven real server-side web
frameworks across eight ecosystems: Express, NestJS, Flask, FastAPI, Laravel,
Spring Boot, ASP.NET Core, Gin, Axum, Prologue, and nim-basolato.

Joubako does not need framework-specific adapters. These servers are
interoperability evidence for the same framework-agnostic HTTP client API.

This is a live compatibility suite, not a collection of static payload
examples. Every server receives the same requests over a TCP socket and must
satisfy the same API contract.

| Route | Purpose |
| --- | --- |
| `GET /api/health` | Typed health response |
| `GET /api/users/1` | Typed JSON decoding |
| `POST /api/messages` | JSON encoding, custom headers, validation, and `201` |
| `POST /api/messages` with priority `0` | Typed HTTP `422` validation failure |
| `GET /api/users/999` | Typed HTTP `404` failure |

The shared client is [`client.nim`](client.nim). Compile it with ARC and SSL;
SSL may stay enabled even though these local servers use plaintext HTTP.
For a framework-by-framework adoption walkthrough, see the
[`backend integration guides`](../../docs/framework-integrations/README.md).

## Express

Requires Node.js 18 or newer:

```sh
cd examples/frameworks/express
npm ci
npm start
```

In another terminal, from the repository root:

```sh
JOUBAKO_DEMO_BASE_URL=http://127.0.0.1:3000/ \
  nim c -r --mm:arc -d:ssl --path:src examples/frameworks/client.nim
```

## Flask

Create an isolated Python environment and start the development server:

```sh
cd examples/frameworks/flask
python3 -m venv .venv
. .venv/bin/activate
python -m pip install -r requirements.txt
python app.py
```

In another terminal, from the repository root:

```sh
JOUBAKO_DEMO_BASE_URL=http://127.0.0.1:5000/ \
  nim c -r --mm:arc -d:ssl --path:src examples/frameworks/client.nim
```

## NestJS

Requires Node.js 20 or newer. The example uses NestJS controllers, a concrete
DTO, and a global validation pipe:

```sh
cd examples/frameworks/nestjs
npm ci
npm start
```

In another terminal, from the repository root:

```sh
JOUBAKO_DEMO_BASE_URL=http://127.0.0.1:3001/ \
  nim c -r --mm:arc -d:ssl --path:src examples/frameworks/client.nim
```

## FastAPI

Create an isolated Python environment and start Uvicorn:

```sh
cd examples/frameworks/fastapi
python3 -m venv .venv
. .venv/bin/activate
python -m pip install -r requirements.txt
python app.py
```

In another terminal, from the repository root:

```sh
JOUBAKO_DEMO_BASE_URL=http://127.0.0.1:8001/ \
  nim c -r --mm:arc -d:ssl --path:src examples/frameworks/client.nim
```

## Laravel

Laravel uses a small drop-in route file rather than committing a generated
application skeleton. Follow the [Laravel instructions](laravel/README.md) to
create a standard application, install API routing, and copy the demo routes.

## Spring Boot

Requires Java 21 and Maven 3.9 or newer:

```sh
cd examples/frameworks/spring-boot
mvn package
java -jar target/joubako-spring-boot-demo-0.1.0.jar
```

In another terminal, from the repository root:

```sh
JOUBAKO_DEMO_BASE_URL=http://127.0.0.1:8085/ \
  JOUBAKO_DEMO_EXPECTED_FRAMEWORK="Spring Boot" \
  nim c -r --mm:arc -d:ssl --path:src examples/frameworks/client.nim
```

## ASP.NET Core

Requires the .NET 8 SDK or newer:

```sh
cd examples/frameworks/aspnet
dotnet run --configuration Release
```

In another terminal, from the repository root:

```sh
JOUBAKO_DEMO_BASE_URL=http://127.0.0.1:8083/ \
  JOUBAKO_DEMO_EXPECTED_FRAMEWORK="ASP.NET Core" \
  nim c -r --mm:arc -d:ssl --path:src examples/frameworks/client.nim
```

## Gin

Requires Go 1.25 or newer:

```sh
cd examples/frameworks/gin
go run .
```

In another terminal, from the repository root:

```sh
JOUBAKO_DEMO_BASE_URL=http://127.0.0.1:8082/ \
  JOUBAKO_DEMO_EXPECTED_FRAMEWORK=Gin \
  nim c -r --mm:arc -d:ssl --path:src examples/frameworks/client.nim
```

## Axum

Requires Rust 1.80 or newer:

```sh
cd examples/frameworks/axum
cargo run --release --locked
```

In another terminal, from the repository root:

```sh
JOUBAKO_DEMO_BASE_URL=http://127.0.0.1:8084/ \
  JOUBAKO_DEMO_EXPECTED_FRAMEWORK=Axum \
  nim c -r --mm:arc -d:ssl --path:src examples/frameworks/client.nim
```

## Prologue

Install Prologue and start the Nim server with ARC:

```sh
nimble install prologue@0.6.10
nim c -r --mm:arc examples/frameworks/prologue/server.nim
```

In another terminal:

```sh
JOUBAKO_DEMO_BASE_URL=http://127.0.0.1:8081/ \
  nim c -r --mm:arc -d:ssl --path:src examples/frameworks/client.nim
```

## nim-basolato

Install nim-basolato and start its server with ARC. Basolato 0.16.1's server
callback currently requires Nim's thread-safety analysis to be disabled; that
flag applies only to this demo server, not to the Joubako client:

```sh
nimble --legacy install basolato@0.16.1
SECRET_KEY=joubako-demo-only \
  nim c -r --mm:arc --threadAnalysis:off \
  examples/frameworks/basolato/server.nim
```

In another terminal:

```sh
JOUBAKO_DEMO_BASE_URL=http://127.0.0.1:8002/ \
  nim c -r --mm:arc -d:ssl --path:src examples/frameworks/client.nim
```

## Verified results

The complete client scenario was run against the original seven framework
servers with ARC on 2026-08-03. The four additional server ecosystems were
verified with both ARC and ORC on 2026-08-25. All runs used Nim 2.2.10 and
`-d:ssl`.

| Server | Guide | Verified environment | Health | User | Message | Invalid | Missing | Result |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| Express | [Guide](../../docs/framework-integrations/express.md) | Node.js 23.3.0, Express 5.2.1 | `200` | `200` | `201` | `422` | `404` | Passed |
| NestJS | [Guide](../../docs/framework-integrations/nestjs.md) | Node.js 23.3.0, NestJS 11.1.28 | `200` | `200` | `201` | `422` | `404` | Passed |
| Flask | [Guide](../../docs/framework-integrations/flask.md) | Python 3.12.8, Flask 3.1.3 | `200` | `200` | `201` | `422` | `404` | Passed |
| FastAPI | [Guide](../../docs/framework-integrations/fastapi.md) | Python 3.12.8, FastAPI 0.141.1, Uvicorn 0.52.1 | `200` | `200` | `201` | `422` | `404` | Passed |
| Laravel | [Guide](../../docs/framework-integrations/laravel.md) | PHP 8.3.13, Laravel Framework 12.64.0 | `200` | `200` | `201` | `422` | `404` | Passed |
| Spring Boot | [Guide](../../docs/framework-integrations/spring-boot.md) | Temurin 21.0.12.1, Spring Boot 4.1.1 | `200` | `200` | `201` | `422` | `404` | Passed |
| ASP.NET Core | [Guide](../../docs/framework-integrations/aspnet-core.md) | .NET SDK 8.0.130, ASP.NET Core 8.0.30 | `200` | `200` | `201` | `422` | `404` | Passed |
| Gin | [Guide](../../docs/framework-integrations/gin.md) | Go 1.25.0, Gin 1.12.0 | `200` | `200` | `201` | `422` | `404` | Passed |
| Axum | [Guide](../../docs/framework-integrations/axum.md) | Rust 1.93.1, Axum 0.8.9 | `200` | `200` | `201` | `422` | `404` | Passed |
| Prologue | [Guide](../../docs/framework-integrations/prologue.md) | Nim 2.2.10, Prologue 0.6.10 | `200` | `200` | `201` | `422` | `404` | Passed |
| nim-basolato | [Guide](../../docs/framework-integrations/nim-basolato.md) | Nim 2.2.10, nim-basolato 0.16.1 | `200` | `200` | `201` | `422` | `404` | Passed |

Each run also verified typed JSON decoding, JSON request encoding, propagation
of the `X-Joubako-Demo` header, validation of the message payload, and mapping
both validation and missing-user responses to `jeHttpStatus` with statuses
`422` and `404`.

The observed client output was:

```text
Joubako successfully called Express
User: Express User <express@example.test>
Message accepted by Express

Joubako successfully called NestJS
User: NestJS User <nestjs@example.test>
Message accepted by NestJS

Joubako successfully called Flask
User: Flask User <flask@example.test>
Message accepted by Flask

Joubako successfully called FastAPI
User: FastAPI User <fastapi@example.test>
Message accepted by FastAPI

Joubako successfully called Laravel
User: Laravel User <laravel@example.test>
Message accepted by Laravel

Joubako successfully called Spring Boot
User: Spring Boot User <spring@example.test>
Message accepted by Spring Boot

Joubako successfully called ASP.NET Core
User: ASP.NET Core User <aspnet@example.test>
Message accepted by ASP.NET Core

Joubako successfully called Gin
User: Gin User <gin@example.test>
Message accepted by Gin

Joubako successfully called Axum
User: Axum User <axum@example.test>
Message accepted by Axum

Joubako successfully called Prologue
User: Prologue User <prologue@example.test>
Message accepted by Prologue

Joubako successfully called nim-basolato
User: nim-basolato User <basolato@example.test>
Message accepted by nim-basolato
```

The Joubako test suite passed after these runs. CI compiles the shared demo
client with ARC and ORC, both with and without SSL enabled, and runs the four
additional server integrations against both memory-manager builds.

Joubako v0.2.3 additionally exercised its compiled C11 JSON ABI against the
Prologue 0.6.10 server for three hours. It completed 2,540,805 real HTTP
requests across the same `200`, `201`, `422`, and `404` routes with zero
failures. Client and server file-descriptor counts remained fixed throughout;
the complete RSS and FD measurements are published in the
[C ABI and Prologue soak report](../../docs/c-abi-prologue-soak.md).

These servers are development examples. Production deployments still need the
framework's normal authentication, HTTPS termination, logging, rate limiting,
and production server configuration.
