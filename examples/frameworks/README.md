# Framework integration demos

These demos call the same JSON API contract from one Joubako client while the
server implementation changes between Express, Flask, and Laravel.

| Route | Purpose |
| --- | --- |
| `GET /api/health` | Typed health response |
| `GET /api/users/1` | Typed JSON decoding |
| `POST /api/messages` | JSON encoding, custom headers, validation, and `201` |
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

## Laravel

Laravel uses a small drop-in route file rather than committing a generated
application skeleton. Follow the [Laravel instructions](laravel/README.md) to
create a standard application, install API routing, and copy the demo routes.

## Verified results

The complete client scenario was run against all three real framework servers
on 2026-08-03. The client used Nim 2.2.10 with ARC and `-d:ssl`.

| Server | Verified environment | Health | User | Message | Missing user | Result |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| Express | Node.js 23.3.0, Express 5.2.1 | `200` | `200` | `201` | `404` | Passed |
| Flask | Python 3.12.8, Flask 3.1.3 | `200` | `200` | `201` | `404` | Passed |
| Laravel | PHP 8.3.13, Laravel Framework 12.64.0 | `200` | `200` | `201` | `404` | Passed |

Each run also verified typed JSON decoding, JSON request encoding, propagation
of the `X-Joubako-Demo` header, validation of the message payload, and mapping
the missing-user response to `jeHttpStatus` with status `404`.

The observed client output was:

```text
Joubako successfully called Express
User: Express User <express@example.test>
Message accepted by Express

Joubako successfully called Flask
User: Flask User <flask@example.test>
Message accepted by Flask

Joubako successfully called Laravel
User: Laravel User <laravel@example.test>
Message accepted by Laravel
```

The Joubako test suite passed after these runs, and CI compiles the shared demo
client with ARC both with and without SSL enabled.

These servers are development examples. Production deployments still need the
framework's normal authentication, HTTPS termination, logging, rate limiting,
and production server configuration.
