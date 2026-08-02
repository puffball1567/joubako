# Docker E2E suite

This suite proves Joubako across process, package, DNS, and container-network
boundaries. It complements the protocol-focused loopback tests; it does not
replace them.

```text
client (Nim 2.2.10 + Joubako, ARC)
  | HTTP over the Compose network
  +--> backend (independent Python HTTP server)
  +--> redirect (independent second origin)
```

The client image starts from a clean Nim image, copies the repository without
local `nimble.paths` or `nimble.develop`, resolves pinned dependency releases,
and compiles the E2E program inside the image. Neither backend imports or
reuses Joubako implementation code.

Run the suite with a working Docker daemon:

```sh
nimble e2e
```

When Docker is unavailable, run the same HTTP scenarios across independent
host processes and real loopback TCP sockets:

```sh
nimble e2eHost
```

The host runner selects unused ports, starts separate backend and redirect
Python processes, compiles the client with ARC, and stops only those processes
when the suite finishes. It does not require elevated privileges or modify
existing services. The Docker suite remains the release/CI check for container
DNS and network isolation.

The task always removes its containers, network, and volumes. The services do
not publish host ports.

## Covered flows

- typed JSON POST and response decoding;
- Unicode and repeated query values;
- repeated response headers;
- binary request/response bodies containing NUL and non-UTF-8 bytes;
- gzip decoding and chunked streaming without response buffering;
- HTTP 503 to 200 retry using `Retry-After`;
- cross-origin redirect credential and caller `Host` stripping;
- bounded cookie storage and replay;
- file-backed multipart upload and direct file download;
- response-size rejection at one byte over the configured limit;
- NIF text to BIF v5 wire data and back;
- concurrent requests; and
- total timeout against a deliberately slow backend.

For custom troubleshooting, `client.nim` accepts
`JOUBAKO_E2E_BASE_URL` and `JOUBAKO_E2E_REDIRECT_HOST`. `server.py` accepts
`JOUBAKO_E2E_HOST`, `JOUBAKO_E2E_PORT`, `JOUBAKO_E2E_ROLE`, and
`JOUBAKO_E2E_REDIRECT_URL`. CI always uses the Compose topology.
