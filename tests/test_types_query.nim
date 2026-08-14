import std/[asyncdispatch, unittest]
import joubako

suite "Headers":
  test "new headers do not contain arbitrary names":
    let headers = initHeaders()
    check not headers.contains("x-test")

  test "set and get are case insensitive":
    var headers = initHeaders()
    headers.set("Content-Type", "application/json")
    check headers.get("content-type") == "application/json"
    check headers.get("CONTENT-TYPE") == "application/json"

  test "header names are trimmed":
    var headers = initHeaders()
    headers.set("  x-mode  ", "strict")
    check headers.get("x-mode") == "strict"

  test "parsed headers retain normalized names without changing semantics":
    var headers = initHeaders()
    headers.addParsedHeader("x-fast", "one")
    headers.addParsedHeader("X-Fast", "two")
    headers.addParsedHeader("  x-fast  ", "three")
    check headers.getAll("x-fast") == @["one", "two", "three"]

  test "add retains repeated values":
    var headers = initHeaders()
    headers.add("set-cookie", "a=1")
    headers.add("Set-Cookie", "b=2")
    check headers.getAll("SET-COOKIE") == @["a=1", "b=2"]

  test "get returns the first repeated value":
    var headers = initHeaders()
    headers.add("accept", "application/json")
    headers.add("accept", "text/plain")
    check headers.get("accept") == "application/json"

  test "set replaces every previous value":
    var headers = initHeaders()
    headers.add("accept", "application/json")
    headers.add("accept", "text/plain")
    headers.set("accept", "application/cbor")
    check headers.getAll("accept") == @["application/cbor"]

  test "get returns an empty default for a missing header":
    check initHeaders().get("missing") == ""

  test "get returns a caller supplied default":
    check initHeaders().get("missing", "fallback") == "fallback"

  test "getAll returns an empty sequence for a missing header":
    check initHeaders().getAll("missing").len == 0

  test "contains uses normalized names":
    var headers = initHeaders()
    headers.set("X-Trace-ID", "42")
    check headers.contains(" x-trace-id ")

  test "merge appends values from the source":
    var target = initHeaders()
    target.add("accept", "application/json")
    var source = initHeaders()
    source.add("accept", "text/plain")
    target.merge(source)
    check target.getAll("accept") == @["application/json", "text/plain"]

  test "merge retains unrelated target headers":
    var target = initHeaders()
    target.set("x-one", "1")
    var source = initHeaders()
    source.set("x-two", "2")
    target.merge(source)
    check target.get("x-one") == "1"
    check target.get("x-two") == "2"

  test "overlay replaces matching values":
    var target = initHeaders()
    target.add("accept", "application/json")
    target.add("accept", "text/plain")
    var source = initHeaders()
    source.set("accept", "application/cbor")
    target.overlay(source)
    check target.getAll("accept") == @["application/cbor"]

  test "overlay preserves repeated source values":
    var target = initHeaders()
    target.set("accept", "old")
    var source = initHeaders()
    source.add("accept", "application/json")
    source.add("accept", "text/plain")
    target.overlay(source)
    check target.getAll("accept") == @["application/json", "text/plain"]

  test "overlay retains unrelated target values":
    var target = initHeaders()
    target.set("authorization", "secret")
    var source = initHeaders()
    source.set("accept", "application/json")
    target.overlay(source)
    check target.get("authorization") == "secret"

  test "pairs yields every repeated value":
    var headers = initHeaders()
    headers.add("x-one", "1")
    headers.add("x-many", "a")
    headers.add("x-many", "b")
    var seen: seq[(string, string)]
    for name, value in headers.pairs:
      seen.add((name, value))
    check seen == @[
      ("x-one", "1"),
      ("x-many", "a"),
      ("x-many", "b")
    ]

  test "separately initialized headers do not share storage":
    var first = initHeaders()
    var second = initHeaders()
    first.set("x-only", "first")
    check second.get("x-only") == ""

suite "CancellationToken":
  test "a new token is not cancelled":
    let token = newCancellationToken()
    check not token.cancelled
    check token.reason == ""

  test "cancel records state and reason":
    let token = newCancellationToken()
    token.cancel("view removed")
    check token.cancelled
    check token.reason == "view removed"

  test "cancel uses a default reason":
    let token = newCancellationToken()
    token.cancel()
    check token.reason == "request cancelled"

  test "cancellation completes its future":
    let token = newCancellationToken()
    let pending = token.cancellationFuture()
    check not pending.finished
    token.cancel("done")
    check pending.finished

  test "requesting a future after cancellation returns a completed future":
    let token = newCancellationToken()
    token.cancel("done")
    check token.cancellationFuture().finished

  test "cancelling nil is safe":
    let token: CancellationToken = nil
    token.cancel("ignored")
    check token == nil

  test "repeated cancellation preserves the first reason":
    let token = newCancellationToken()
    token.cancel("first")
    token.cancel("second")
    check token.reason == "first"

suite "Core types":
  test "request methods use uppercase HTTP spellings":
    check $rmGet == "GET"
    check $rmHead == "HEAD"
    check $rmPost == "POST"
    check $rmPut == "PUT"
    check $rmPatch == "PATCH"
    check $rmDelete == "DELETE"
    check $rmOptions == "OPTIONS"

  test "default request timeout is finite":
    check defaultRequestOptions().timeoutMs == 30_000

  test "default request body limit is sixteen MiB":
    check defaultRequestOptions().maxRequestBytes == 16 * 1024 * 1024

  test "default response body limit is sixteen MiB":
    check defaultRequestOptions().maxResponseBytes == 16 * 1024 * 1024

  test "retry is disabled in default request options":
    check defaultRequestOptions().retry.maxAttempts == 0

  test "default retry options use three attempts":
    check defaultHttpRetryOptions().maxAttempts == 3

  test "new errors retain structured fields":
    let error = newJoubakoError(
      jeHttpStatus,
      "unavailable",
      "https://example.test",
      503,
      2_000
    )
    check error.kind == jeHttpStatus
    check error.url == "https://example.test"
    check error.status == 503
    check error.retryAfterMs == 2_000
    check not error.hasResponse
    check error.attempts == 0
    check error.grpcStatus == -1

  test "new errors default to no Retry-After":
    check newJoubakoError(jeTransport, "offline").retryAfterMs == -1

  test "error response snapshots omit requests and copy headers":
    var headers = initHeaders()
    headers.add("x-value", "one")
    var trailers = initHeaders()
    trailers.add("x-final", "done")
    let request = Request(
      url: "https://example.test/private",
      body: "secret"
    )
    let response = Response(
      status: 403,
      statusText: "Forbidden",
      headers: headers,
      trailers: trailers,
      body: "denied",
      request: request
    )
    let snapshot = response.toErrorResponse()
    headers.set("x-value", "changed")
    trailers.set("x-final", "changed")

    check snapshot.status == 403
    check snapshot.statusText == "Forbidden"
    check snapshot.headers.get("x-value") == "one"
    check snapshot.trailers.get("x-final") == "done"
    check snapshot.body == "denied"

suite "Query serialization":
  test "empty parameters leave a path unchanged":
    check withQuery("/users", newSeq[QueryParam]()) == "/users"

  test "a simple parameter is appended":
    check withQuery("/users", [(name: "page", value: "2")]) ==
      "/users?page=2"

  test "spaces use form-style plus encoding":
    check withQuery("/search", [(name: "q", value: "nim client")]) ==
      "/search?q=nim+client"

  test "reserved characters are percent encoded":
    check withQuery("/search", [(name: "q", value: "a/b?c=d")]) ==
      "/search?q=a%2Fb%3Fc%3Dd"

  test "unicode values are UTF-8 percent encoded":
    check withQuery("/search", [(name: "q", value: "状箱")]) ==
      "/search?q=%E7%8A%B6%E7%AE%B1"

  test "existing query parameters are retained":
    check withQuery("/users?active=true", [(name: "page", value: "2")]) ==
      "/users?active=true&page=2"

  test "fragments remain after the new query":
    check withQuery("/users#top", [(name: "page", value: "2")]) ==
      "/users?page=2#top"

  test "existing query and fragment are both retained":
    check withQuery(
      "/users?active=true#top",
      [(name: "page", value: "2")]
    ) == "/users?active=true&page=2#top"

  test "repeated names remain repeated":
    check withQuery(
      "/users",
      [
        (name: "tag", value: "nim"),
        (name: "tag", value: "native")
      ]
    ) == "/users?tag=nim&tag=native"

  test "empty values are represented explicitly":
    check withQuery("/search", [(name: "q", value: "")]) == "/search?q="

  test "empty names are encoded without crashing":
    check withQuery("/search", [(name: "", value: "value")]) ==
      "/search?=value"

  test "absolute URLs retain their origin":
    check withQuery(
      "https://example.test/users",
      [(name: "page", value: "2")]
    ) == "https://example.test/users?page=2"

  test "a fragment-only reference receives a query before the fragment":
    check withQuery("#top", [(name: "page", value: "2")]) ==
      "?page=2#top"
