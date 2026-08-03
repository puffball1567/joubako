# Framework integration demos

One ARC-powered Joubako client communicates with seven real server-side web
frameworks across five ecosystems: Express, NestJS, Flask, FastAPI, Laravel,
Prologue, and nim-basolato.

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

The complete client scenario was run against all seven real framework servers
on 2026-08-03. The client used Nim 2.2.10 with ARC and `-d:ssl`.

| Server | Verified environment | Health | User | Message | Invalid | Missing | Result |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| Express | Node.js 23.3.0, Express 5.2.1 | `200` | `200` | `201` | `422` | `404` | Passed |
| NestJS | Node.js 23.3.0, NestJS 11.1.28 | `200` | `200` | `201` | `422` | `404` | Passed |
| Flask | Python 3.12.8, Flask 3.1.3 | `200` | `200` | `201` | `422` | `404` | Passed |
| FastAPI | Python 3.12.8, FastAPI 0.141.1, Uvicorn 0.52.1 | `200` | `200` | `201` | `422` | `404` | Passed |
| Laravel | PHP 8.3.13, Laravel Framework 12.64.0 | `200` | `200` | `201` | `422` | `404` | Passed |
| Prologue | Nim 2.2.10, Prologue 0.6.10 | `200` | `200` | `201` | `422` | `404` | Passed |
| nim-basolato | Nim 2.2.10, nim-basolato 0.16.1 | `200` | `200` | `201` | `422` | `404` | Passed |

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

Joubako successfully called Prologue
User: Prologue User <prologue@example.test>
Message accepted by Prologue

Joubako successfully called nim-basolato
User: nim-basolato User <basolato@example.test>
Message accepted by nim-basolato
```

The Joubako test suite passed after these runs, and CI compiles the shared demo
client with ARC both with and without SSL enabled.

These servers are development examples. Production deployments still need the
framework's normal authentication, HTTPS termination, logging, rate limiting,
and production server configuration.
