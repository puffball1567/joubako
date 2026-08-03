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

## Expected output

The framework name changes, but each server produces the same result shape:

```text
Joubako successfully called Express
User: Express User <express@example.test>
Message accepted by Express
```

These servers are development examples. Production deployments still need the
framework's normal authentication, HTTPS termination, logging, rate limiting,
and production server configuration.
