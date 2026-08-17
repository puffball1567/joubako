# JSON C ABI

Joubako exposes a versioned C ABI for C and C++ applications that need its
bounded HTTP/1.1 JSON client without importing Nim APIs. The native Nim API
remains asynchronous. The C ABI is deliberately synchronous: each request
drives Joubako's standard `asyncdispatch` client on the calling thread and
returns a structured result.

The ABI is JSON-only. NIF/BIF conversion remains a typed Nim integration with
NIFKit and is not exported through this boundary.

## Build

Build the shared library with the recommended ARC memory manager and TLS
support:

```sh
nimble buildCAbi
```

The output is `build/libjoubako.so` on Linux,
`build/libjoubako.dylib` on macOS, or `build/joubako.dll` on Windows. Use
`nimble buildCAbiOrc` when the embedding application prefers ORC.

The equivalent direct command is:

```sh
nim c --app:lib -d:release -d:ssl --mm:arc --path:src \
  --out:build/libjoubako.so src/joubako/cabi.nim
```

Include [`include/joubako.h`](../include/joubako.h) from C or C++. The precise
linker command depends on the platform and compiler. A Linux example is:

```sh
cc -std=c11 -Iinclude examples/cabi/client.c -Lbuild \
  -Wl,-rpath,'$ORIGIN/../build' -ljoubako -o build/joubako-c-example
```

## Usage

```c
JoubakoClient *client = NULL;
JoubakoResponse *response = NULL;

if (joubako_client_create("https://api.example.com/", &client) != JOUBAKO_OK) {
  return 1;
}

JoubakoErrorCode code = joubako_request_json(
  client,
  "POST",
  "messages",
  "{\"text\":\"hello\"}",
  &response
);

if (response != NULL) {
  printf("status=%d body=%s\n",
    (int)joubako_response_status(response),
    joubako_response_body(response));
  joubako_response_free(response);
}
joubako_client_free(client);
```

Supported methods are `GET`, `HEAD`, `POST`, `PUT`, `PATCH`, `DELETE`, and
`OPTIONS`. A non-empty request body must be valid JSON. A non-empty response
body must also be valid JSON, including bodies attached to HTTP error statuses;
otherwise the request returns `JOUBAKO_ERROR_CODEC` while preserving the status
and original body for diagnosis.

Use `joubako_client_set_header`, `joubako_client_set_timeout_ms`, and
`joubako_client_set_max_response_bytes` to configure a client. Defaults remain
bounded, so ordinary users do not need to define a complete policy before the
first request.

## Ownership and error contract

- `joubako_client_create` returns an owned client handle through `out_client`.
- `joubako_request_json` returns an owned response handle for successful
  requests and structured failures whenever one can be constructed.
- Free every response with `joubako_response_free` and every client with
  `joubako_client_free`. Both functions accept `NULL`.
- Body and error-message pointers are borrowed. They remain valid only until
  their response handle is freed. Size accessors are provided alongside both
  pointers.
- Handles must be created, used, and freed on the same thread. If multiple
  threads need clients, create a separate client per thread.
- No Nim exception crosses the ABI. Unexpected exceptions become
  `JOUBAKO_ERROR_INTERNAL`.
- Check `joubako_abi_version()` against `JOUBAKO_ABI_VERSION` before using a
  dynamically discovered library. ABI version 1 is the first public contract.

The integer error values in the header are stable for ABI version 1. HTTP
statuses such as `404` and `422` return `JOUBAKO_ERROR_HTTP_STATUS`; inspect
the response status, body, and message for details.

## Verification

The ordinary ARC and ORC suites exercise validation, success responses,
bounded HTTP error bodies, malformed success/error JSON, and explicit handle
ownership. CI also builds the shared library on Linux, macOS, and Windows,
compiles the header as both C11 and C++17, loads the exported ABI-version
symbol, and runs its lifecycle paths under the platform-appropriate sanitizer
matrix. Linux additionally checks ARC and ORC with standalone LeakSanitizer
and Valgrind.

The real-server integration uses Prologue 0.6.10 and the C compiler boundary,
not a direct Nim import. It repeatedly verifies JSON `200`, `201`, `422`, and
`404` exchanges, custom headers, malformed local input rejection, handle
release, process RSS, and open-file-descriptor stability. See
[`c-abi-prologue-soak.md`](c-abi-prologue-soak.md) for the release run.
