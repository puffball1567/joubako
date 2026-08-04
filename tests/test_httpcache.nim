import std/[asyncdispatch, options, times, unittest]
import joubako

proc cacheHeaders(
    cacheControl = "max-age=60";
    etag = "";
    vary = ""
): Headers =
  result = initHeaders()
  if cacheControl.len > 0:
    result.set("cache-control", cacheControl)
  if etag.len > 0:
    result.set("etag", etag)
  if vary.len > 0:
    result.set("vary", vary)

proc cacheEntry(url, body: string; varyNames: seq[string] = @[];
    varyValues: seq[string] = @[]): HttpCacheEntry =
  HttpCacheEntry(
    url: url,
    status: 200,
    headers: cacheHeaders(),
    body: body,
    varyNames: varyNames,
    varyValues: varyValues,
    storedAt: fromUnix(1_700_000_000),
    freshnessLifetimeSeconds: 60
  )

type
  ThrowingStore = ref object of HttpCacheStore
  CredentialTransport = ref object of Transport
    calls: int

method usesImplicitCredentials(transport: CredentialTransport): bool =
  true

method send(
    transport: CredentialTransport;
    request: Request
): Future[Response] {.async.} =
  inc transport.calls
  return Response(
    status: 200,
    headers: cacheHeaders(),
    body: "personalized",
    request: request
  )

method lookup(
    store: ThrowingStore;
    request: Request
): Option[HttpCacheEntry] =
  discard store
  discard request
  raise newException(ValueError, "lookup failed")

method put(store: ThrowingStore; entry: HttpCacheEntry) =
  discard store
  discard entry
  raise newException(ValueError, "put failed")

method invalidate(store: ThrowingStore; url: string) =
  discard store
  discard url
  raise newException(ValueError, "invalidate failed")

suite "Memory HTTP cache":
  test "stores and retrieves a matching representation":
    let store = newMemoryHttpCache()
    let entry = cacheEntry("https://example.com/a", "cached")
    store.put(entry)
    let request = Request(url: entry.url, headers: initHeaders())

    let found = store.lookup(request)

    check found.isSome
    check found.get.body == "cached"
    check store.len == 1
    check store.bytes > 0

  test "Vary request fields select distinct representations":
    let store = newMemoryHttpCache()
    store.put(cacheEntry(
      "https://example.com/a", "english", @["accept-language"], @["en"]
    ))
    store.put(cacheEntry(
      "https://example.com/a", "japanese", @["accept-language"], @["ja"]
    ))
    var headers = initHeaders()
    headers.set("accept-language", "ja")

    let found = store.lookup(Request(
      url: "https://example.com/a", headers: headers
    ))

    check found.isSome
    check found.get.body == "japanese"
    check store.len == 2

  test "replacing one variant does not duplicate it":
    let store = newMemoryHttpCache()
    store.put(cacheEntry("https://example.com/a", "old"))
    store.put(cacheEntry("https://example.com/a", "new"))

    check store.len == 1
    check store.lookup(Request(
      url: "https://example.com/a", headers: initHeaders()
    )).get.body == "new"

  test "entry count uses least-recently-used eviction":
    let store = newMemoryHttpCache(maxEntries = 2)
    store.put(cacheEntry("https://example.com/a", "a"))
    store.put(cacheEntry("https://example.com/b", "b"))
    discard store.lookup(Request(
      url: "https://example.com/a", headers: initHeaders()
    ))
    store.put(cacheEntry("https://example.com/c", "c"))

    check store.lookup(Request(
      url: "https://example.com/a", headers: initHeaders()
    )).isSome
    check store.lookup(Request(
      url: "https://example.com/b", headers: initHeaders()
    )).isNone
    check store.lookup(Request(
      url: "https://example.com/c", headers: initHeaders()
    )).isSome

  test "oversized entries are never retained":
    let store = newMemoryHttpCache(maxEntryBytes = 8)
    store.put(cacheEntry("https://example.com/a", "too large"))

    check store.len == 0
    check store.bytes == 0

  test "byte capacity evicts older entries":
    let sample = cacheEntry("a", "1234")
    let oneEntryBytes = sample.url.len + sample.body.len +
      sample.headers.get("cache-control").len + "cache-control".len
    let store = newMemoryHttpCache(
      maxEntries = 10,
      maxBytes = int64(oneEntryBytes * 2 + 4),
      maxEntryBytes = 1024
    )
    store.put(sample)
    store.put(cacheEntry("b", "5678"))
    store.put(cacheEntry("c", "9012"))

    check store.len <= 2

  test "invalidation removes every Vary representation":
    let store = newMemoryHttpCache()
    store.put(cacheEntry("https://example.com/a", "en", @["x"], @["en"]))
    store.put(cacheEntry("https://example.com/a", "ja", @["x"], @["ja"]))
    store.put(cacheEntry("https://example.com/b", "other"))

    store.invalidate("https://example.com/a")

    check store.len == 1

suite "Caching transport":
  test "serves a fresh max-age response without another dispatch":
    var calls = 0
    let handler = proc(request: Request): Future[Response] {.async.} =
      inc calls
      return Response(
        status: 200,
        headers: cacheHeaders("max-age=60"),
        body: "payload",
        request: request
      )
    let client = newClient(newCachingTransport(newInProcessTransport(handler)))

    let first = waitFor client.get("https://example.com/data")
    let second = waitFor client.get("https://example.com/data")

    check first.isOk
    check not first.value.fromCache
    check second.isOk
    check second.value.fromCache
    check not second.value.cacheRevalidated
    check second.value.body == "payload"
    check calls == 1

  test "freshness expiration sends an ETag conditional request":
    var now = fromUnix(1_700_000_000)
    var calls = 0
    var conditional = ""
    let clock = proc(): Time = now
    let handler = proc(request: Request): Future[Response] {.async.} =
      inc calls
      conditional = request.headers.get("if-none-match")
      if calls == 1:
        return Response(
          status: 200,
          headers: cacheHeaders("max-age=1", "\"v1\""),
          body: "version one",
          request: request
        )
      return Response(
        status: 304,
        headers: cacheHeaders("max-age=30", "\"v1\""),
        request: request
      )
    let store = newMemoryHttpCache()
    let transport = newCachingTransport(
      newInProcessTransport(handler), store, clock = clock
    )
    let client = newClient(transport)

    discard waitFor client.get("https://example.com/data")
    now += initDuration(seconds = 2)
    let refreshed = waitFor client.get("https://example.com/data")

    check refreshed.isOk
    check refreshed.value.fromCache
    check refreshed.value.cacheRevalidated
    check refreshed.value.body == "version one"
    check conditional == "\"v1\""
    check calls == 2
    now += initDuration(seconds = 2)
    discard waitFor client.get("https://example.com/data")
    check calls == 2

  test "Last-Modified is used when ETag is absent":
    var calls = 0
    var conditional = ""
    let handler = proc(request: Request): Future[Response] {.async.} =
      inc calls
      conditional = request.headers.get("if-modified-since")
      var headers = cacheHeaders("no-cache")
      headers.set("last-modified", "Sun, 06 Nov 1994 08:49:37 GMT")
      return Response(
        status: if calls == 1: 200 else: 304,
        headers: headers,
        body: if calls == 1: "body" else: "",
        request: request
      )
    let client = newClient(newCachingTransport(newInProcessTransport(handler)))

    discard waitFor client.get("https://example.com/data")
    let second = waitFor client.get("https://example.com/data")

    check second.isOk
    check second.value.cacheRevalidated
    check conditional == "Sun, 06 Nov 1994 08:49:37 GMT"

  test "request no-cache forces revalidation of a fresh entry":
    var calls = 0
    let handler = proc(request: Request): Future[Response] {.async.} =
      inc calls
      return Response(
        status: if calls == 1: 200 else: 304,
        headers: cacheHeaders("max-age=60", "\"tag\""),
        body: if calls == 1: "body" else: "",
        request: request
      )
    let client = newClient(newCachingTransport(newInProcessTransport(handler)))
    discard waitFor client.get("https://example.com/data")
    var headers = initHeaders()
    headers.set("cache-control", "no-cache")

    let second = waitFor client.get("https://example.com/data", headers)

    check second.isOk
    check second.value.cacheRevalidated
    check calls == 2

  test "Vary creates independent response variants":
    var calls = 0
    let handler = proc(request: Request): Future[Response] {.async.} =
      inc calls
      return Response(
        status: 200,
        headers: cacheHeaders("max-age=60", vary = "Accept-Language"),
        body: request.headers.get("accept-language"),
        request: request
      )
    let client = newClient(newCachingTransport(newInProcessTransport(handler)))
    var english = initHeaders()
    english.set("accept-language", "en")
    var japanese = initHeaders()
    japanese.set("accept-language", "ja")

    discard waitFor client.get("https://example.com/data", english)
    discard waitFor client.get("https://example.com/data", japanese)
    let cachedEnglish = waitFor client.get("https://example.com/data", english)

    check cachedEnglish.value.body == "en"
    check cachedEnglish.value.fromCache
    check calls == 2

  test "Vary star prevents storage":
    var calls = 0
    let handler = proc(request: Request): Future[Response] {.async.} =
      inc calls
      return Response(
        status: 200,
        headers: cacheHeaders("max-age=60", vary = "*"),
        body: "body",
        request: request
      )
    let client = newClient(newCachingTransport(newInProcessTransport(handler)))

    discard waitFor client.get("https://example.com/data")
    discard waitFor client.get("https://example.com/data")

    check calls == 2

  test "response no-store prevents storage":
    var calls = 0
    let handler = proc(request: Request): Future[Response] {.async.} =
      inc calls
      return Response(
        status: 200,
        headers: cacheHeaders("no-store, max-age=60"),
        body: "body",
        request: request
      )
    let client = newClient(newCachingTransport(newInProcessTransport(handler)))

    discard waitFor client.get("https://example.com/data")
    discard waitFor client.get("https://example.com/data")

    check calls == 2

  test "a no-store refresh removes an older cached representation":
    var now = fromUnix(1_700_000_000)
    var calls = 0
    let clock = proc(): Time = now
    let handler = proc(request: Request): Future[Response] {.async.} =
      inc calls
      let control = if calls == 1: "max-age=1" else: "no-store"
      return Response(
        status: 200,
        headers: cacheHeaders(control),
        body: $calls,
        request: request
      )
    let client = newClient(newCachingTransport(
      newInProcessTransport(handler), newMemoryHttpCache(), clock = clock
    ))
    discard waitFor client.get("https://example.com/data")
    now += initDuration(seconds = 2)
    discard waitFor client.get("https://example.com/data")
    discard waitFor client.get("https://example.com/data")

    check calls == 3

  test "request no-store bypasses lookup and storage":
    var calls = 0
    let handler = proc(request: Request): Future[Response] {.async.} =
      inc calls
      return Response(
        status: 200,
        headers: cacheHeaders(),
        body: $calls,
        request: request
      )
    let client = newClient(newCachingTransport(newInProcessTransport(handler)))
    var headers = initHeaders()
    headers.set("cache-control", "no-store")

    discard waitFor client.get("https://example.com/data", headers)
    discard waitFor client.get("https://example.com/data", headers)

    check calls == 2

  test "only-if-cached returns 504 without network access":
    var calls = 0
    let handler = proc(request: Request): Future[Response] {.async.} =
      inc calls
      return Response(status: 200, request: request)
    let client = newClient(newCachingTransport(newInProcessTransport(handler)))
    var headers = initHeaders()
    headers.set("cache-control", "only-if-cached")

    let outcome = waitFor client.get("https://example.com/missing", headers)

    check outcome.isErr
    check outcome.error.status == 504
    check calls == 0

  test "only-if-cached never revalidates a stale entry":
    var calls = 0
    let handler = proc(request: Request): Future[Response] {.async.} =
      inc calls
      return Response(
        status: 200,
        headers: cacheHeaders("max-age=0", "\"tag\""),
        body: "body",
        request: request
      )
    let client = newClient(newCachingTransport(newInProcessTransport(handler)))
    discard waitFor client.get("https://example.com/data")
    var headers = initHeaders()
    headers.set("cache-control", "only-if-cached")

    let outcome = waitFor client.get("https://example.com/data", headers)

    check outcome.isErr
    check outcome.error.status == 504
    check calls == 1

  test "Expires provides freshness when max-age is absent":
    var now = fromUnix(784_111_777)
    var calls = 0
    let clock = proc(): Time = now
    let handler = proc(request: Request): Future[Response] {.async.} =
      inc calls
      var headers = initHeaders()
      headers.set("date", "Sun, 06 Nov 1994 08:49:37 GMT")
      headers.set("expires", "Sun, 06 Nov 1994 08:50:37 GMT")
      return Response(status: 200, headers: headers, body: "body", request: request)
    let client = newClient(newCachingTransport(
      newInProcessTransport(handler), newMemoryHttpCache(), clock = clock
    ))

    discard waitFor client.get("https://example.com/data")
    now += initDuration(seconds = 30)
    let cached = waitFor client.get("https://example.com/data")

    check cached.isOk
    check cached.value.fromCache
    check calls == 1

  test "Age advances while a response is retained":
    var now = fromUnix(1_700_000_000)
    let clock = proc(): Time = now
    let handler = proc(request: Request): Future[Response] {.async.} =
      var headers = cacheHeaders("max-age=60")
      headers.set("age", "10")
      return Response(status: 200, headers: headers, body: "body", request: request)
    let client = newClient(newCachingTransport(
      newInProcessTransport(handler), newMemoryHttpCache(), clock = clock
    ))
    discard waitFor client.get("https://example.com/data")
    now += initDuration(seconds = 5)

    let cached = waitFor client.get("https://example.com/data")

    check cached.value.headers.get("age") == "15"

  test "Authorization and Cookie requests bypass by default":
    var calls = 0
    let handler = proc(request: Request): Future[Response] {.async.} =
      inc calls
      return Response(
        status: 200, headers: cacheHeaders(), body: "private", request: request
      )
    let client = newClient(newCachingTransport(newInProcessTransport(handler)))
    var headers = initHeaders()
    headers.set("authorization", "Bearer secret")

    discard waitFor client.get("https://example.com/private", headers)
    discard waitFor client.get("https://example.com/private", headers)

    check calls == 2

  test "authenticated caching requires explicit opt in":
    var calls = 0
    let handler = proc(request: Request): Future[Response] {.async.} =
      inc calls
      return Response(
        status: 200, headers: cacheHeaders(), body: "private", request: request
      )
    var cacheOptions = defaultHttpCacheOptions()
    cacheOptions.cacheAuthenticatedRequests = true
    let client = newClient(newCachingTransport(
      newInProcessTransport(handler), cacheOptions
    ))
    var headers = initHeaders()
    headers.set("cookie", "session=secret")

    discard waitFor client.get("https://example.com/private", headers)
    let second = waitFor client.get("https://example.com/private", headers)

    check calls == 1
    check second.value.fromCache

  test "implicit transport credentials bypass cache by default":
    let credentialTransport = CredentialTransport()
    let client = newClient(newCachingTransport(credentialTransport))

    discard waitFor client.get("https://example.com/private")
    discard waitFor client.get("https://example.com/private")

    check credentialTransport.calls == 2

  test "Set-Cookie responses are not retained by default":
    var calls = 0
    let handler = proc(request: Request): Future[Response] {.async.} =
      inc calls
      var headers = cacheHeaders()
      headers.add("set-cookie", "session=secret")
      return Response(status: 200, headers: headers, body: "body", request: request)
    let client = newClient(newCachingTransport(newInProcessTransport(handler)))

    discard waitFor client.get("https://example.com/private")
    discard waitFor client.get("https://example.com/private")

    check calls == 2

  test "streaming and Range requests bypass cache storage":
    var calls = 0
    let handler = proc(request: Request): Future[Response] {.async.} =
      inc calls
      return Response(
        status: 200, headers: cacheHeaders(), body: "body", request: request
      )
    let client = newClient(newCachingTransport(newInProcessTransport(handler)))
    var streamOptions = defaultRequestOptions()
    streamOptions.streamResponse = true
    discard waitFor client.get(
      "https://example.com/stream", options = streamOptions
    )
    discard waitFor client.get(
      "https://example.com/stream", options = streamOptions
    )
    var rangeHeaders = initHeaders()
    rangeHeaders.set("range", "bytes=0-3")
    discard waitFor client.get("https://example.com/range", rangeHeaders)
    discard waitFor client.get("https://example.com/range", rangeHeaders)

    check calls == 4

  test "successful unsafe methods invalidate the target URL":
    var calls = 0
    let handler = proc(request: Request): Future[Response] {.async.} =
      inc calls
      if request.httpMethod == rmPost:
        return Response(status: 204, request: request)
      return Response(
        status: 200, headers: cacheHeaders(), body: $calls, request: request
      )
    let client = newClient(newCachingTransport(newInProcessTransport(handler)))
    discard waitFor client.get("https://example.com/item")
    discard waitFor client.get("https://example.com/item")
    discard waitFor client.post("https://example.com/item", "changed")

    let refreshed = waitFor client.get("https://example.com/item")

    check refreshed.value.body == "3"
    check calls == 3

  test "unsafe methods invalidate same-origin Location targets":
    var itemCalls = 0
    let handler = proc(request: Request): Future[Response] {.async.} =
      if request.httpMethod == rmPost:
        var headers = initHeaders()
        headers.set("location", "/items/1")
        headers.set("content-location", "https://other.example/items/1")
        return Response(status: 201, headers: headers, request: request)
      inc itemCalls
      return Response(
        status: 200,
        headers: cacheHeaders(),
        body: $itemCalls,
        request: request
      )
    let client = newClient(newCachingTransport(newInProcessTransport(handler)))
    discard waitFor client.get("https://example.com/items/1")
    discard waitFor client.get("https://example.com/items/1")
    discard waitFor client.post("https://example.com/items", "new")

    let refreshed = waitFor client.get("https://example.com/items/1")

    check refreshed.value.body == "2"
    check itemCalls == 2

  test "cacheable error statuses can be reused":
    var calls = 0
    let handler = proc(request: Request): Future[Response] {.async.} =
      inc calls
      return Response(
        status: 404,
        headers: cacheHeaders(),
        body: "missing",
        request: request
      )
    let client = newClient(newCachingTransport(newInProcessTransport(handler)))

    let first = waitFor client.get("https://example.com/missing")
    let second = waitFor client.get("https://example.com/missing")

    check first.isErr
    check second.isErr
    check second.error.response.body == "missing"
    check calls == 1

  test "cached bodies still honor a smaller per-request limit":
    let handler = proc(request: Request): Future[Response] {.async.} =
      return Response(
        status: 200, headers: cacheHeaders(), body: "12345", request: request
      )
    let client = newClient(newCachingTransport(newInProcessTransport(handler)))
    discard waitFor client.get("https://example.com/data")
    var options = defaultRequestOptions()
    options.maxResponseBytes = 4

    let cached = waitFor client.get(
      "https://example.com/data", options = options
    )

    check cached.isErr
    check cached.error.kind == jeBodyTooLarge

  test "cache hits preserve streaming callbacks and progress":
    let handler = proc(request: Request): Future[Response] {.async.} =
      return Response(
        status: 200, headers: cacheHeaders(), body: "cached", request: request
      )
    let client = newClient(newCachingTransport(newInProcessTransport(handler)))
    discard waitFor client.get("https://example.com/data")
    var chunks: seq[string]
    var progress: tuple[current, total: int64]
    var options = defaultRequestOptions()
    options.onDownloadChunk = proc(chunk: string) = chunks.add chunk
    options.onDownloadProgress = proc(current, total: int64) =
      progress = (current, total)

    let cached = waitFor client.get(
      "https://example.com/data", options = options
    )

    check cached.isOk
    check chunks == @["cached"]
    check progress == (6'i64, 6'i64)

  test "cache store failures never break a network request":
    var calls = 0
    let handler = proc(request: Request): Future[Response] {.async.} =
      inc calls
      return Response(
        status: 200, headers: cacheHeaders(), body: "body", request: request
      )
    let transport = newCachingTransport(
      newInProcessTransport(handler), ThrowingStore()
    )
    let client = newClient(transport)

    let outcome = waitFor client.get("https://example.com/data")

    check outcome.isOk
    check calls == 1
