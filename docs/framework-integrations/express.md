# Joubako with Express

This integration pairs a Nim client using Joubako with an Express JSON API.
It is suitable when a native Nim application or service consumes an existing
Node.js backend.

## Backend implementation

The demo uses ordinary Express routes and does not install a Joubako-specific
server package:

```js
app.get("/api/health", (_request, response) => {
  response.json({ ok: true, framework: "Express" });
});

app.post("/api/messages", (request, response) => {
  const { text, priority } = request.body ?? {};
  if (typeof text !== "string" || !Number.isInteger(priority)) {
    return response.status(422).json({ error: "invalid message" });
  }

  return response.status(201).json({
    accepted: true,
    text,
    priority,
    framework: "Express",
    client: request.get("x-joubako-demo") ?? "unknown",
  });
});
```

The runnable implementation also bounds JSON input to 16 KiB and validates the
message length and priority. See [`server.mjs`](../../examples/frameworks/express/server.mjs).

## Run Express

Node.js 18 or newer is required.

```sh
cd examples/frameworks/express
npm ci
npm start
```

## Call Express from Joubako

From the repository root, in another terminal:

```sh
JOUBAKO_DEMO_BASE_URL=http://127.0.0.1:3000/ \
  JOUBAKO_DEMO_EXPECTED_FRAMEWORK=Express \
  nim c -r --mm:arc -d:ssl --path:src examples/frameworks/client.nim
```

The client performs typed health and user reads, sends a typed JSON message and
custom header, and verifies both `422` and `404` as structured Joubako errors.

## Production notes

Keep Express's JSON body limit finite, add the application's authentication and
authorization middleware, and run behind the deployment server or proxy used by
the service. Joubako can point at the resulting HTTPS origin without changing
the typed request code.
