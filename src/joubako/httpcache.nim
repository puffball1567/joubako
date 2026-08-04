## RFC-aware, bounded private HTTP caching as a composable transport.

import std/[asyncdispatch, options, parseutils, sets, strutils, times, uri]
import ./[chunkconsumer, result, transport, types]

type
  HttpCacheEntry* = object
    url*: string
    status*: int
    statusText*: string
    headers*: Headers
    body*: string
    varyNames*: seq[string]
    varyValues*: seq[string]
    storedAt*: Time
    initialAgeSeconds*: int64
    freshnessLifetimeSeconds*: int64
    requiresRevalidation*: bool

  HttpCacheStore* = ref object of RootObj

  MemoryCacheRecord = object
    entry: HttpCacheEntry
    lastAccess: uint64

  MemoryHttpCache* = ref object of HttpCacheStore
    records: seq[MemoryCacheRecord]
    maxEntries*: int
    maxBytes*: int64
    maxEntryBytes*: int64
    totalBytes: int64
    accessCounter: uint64

  HttpCacheOptions* = object
    ## Authorization, Cookie, and Set-Cookie are bypassed by default to avoid
    ## persisting credentials or personalized responses accidentally.
    cacheAuthenticatedRequests*: bool
    cacheSetCookieResponses*: bool

  HttpCacheClockProc* = proc(): Time {.closure.}

  CachingTransport* = ref object of Transport
    delegate*: Transport
    store*: HttpCacheStore
    options*: HttpCacheOptions
    clock: HttpCacheClockProc

  CacheDirectives = object
    noStore: bool
    noCache: bool
    onlyIfCached: bool
    hasMaxAge: bool
    maxAgeSeconds: int64

method lookup*(
    store: HttpCacheStore;
    request: Request
): Option[HttpCacheEntry] {.base.} =
  discard store
  discard request
  none(HttpCacheEntry)

method put*(store: HttpCacheStore; entry: HttpCacheEntry) {.base.} =
  discard store
  discard entry

method invalidate*(store: HttpCacheStore; url: string) {.base.} =
  discard store
  discard url

proc newMemoryHttpCache*(
    maxEntries = 256;
    maxBytes = 64'i64 * 1024 * 1024;
    maxEntryBytes = 16'i64 * 1024 * 1024
): MemoryHttpCache =
  MemoryHttpCache(
    maxEntries: max(0, maxEntries),
    maxBytes: max(0'i64, maxBytes),
    maxEntryBytes: max(0'i64, maxEntryBytes)
  )

func entryBytes(entry: HttpCacheEntry): int64 =
  result = int64(entry.url.len + entry.statusText.len + entry.body.len)
  for name, value in entry.headers.pairs:
    result += int64(name.len + value.len)
  for value in entry.varyNames:
    result += int64(value.len)
  for value in entry.varyValues:
    result += int64(value.len)

func varyValue(headers: Headers; name: string): string =
  headers.getAll(name).join("\x00")

func matches(entry: HttpCacheEntry; request: Request): bool =
  if entry.url != request.url or entry.varyNames.len != entry.varyValues.len:
    return false
  for index, name in entry.varyNames:
    if request.headers.varyValue(name) != entry.varyValues[index]:
      return false
  true

proc removeRecord(store: MemoryHttpCache; index: int) =
  store.totalBytes -= store.records[index].entry.entryBytes
  store.records.delete(index)

proc evict(store: MemoryHttpCache) =
  while store.records.len > store.maxEntries or
      store.totalBytes > store.maxBytes:
    if store.records.len == 0:
      break
    var oldest = 0
    for index in 1 ..< store.records.len:
      if store.records[index].lastAccess < store.records[oldest].lastAccess:
        oldest = index
    store.removeRecord(oldest)

method lookup*(
    store: MemoryHttpCache;
    request: Request
): Option[HttpCacheEntry] =
  if store == nil:
    return none(HttpCacheEntry)
  for index in 0 ..< store.records.len:
    if store.records[index].entry.matches(request):
      inc store.accessCounter
      store.records[index].lastAccess = store.accessCounter
      return some(store.records[index].entry)
  none(HttpCacheEntry)

method put*(store: MemoryHttpCache; entry: HttpCacheEntry) =
  if store == nil or store.maxEntries == 0 or store.maxBytes == 0 or
      entry.entryBytes > store.maxEntryBytes or
      entry.entryBytes > store.maxBytes:
    return
  for index in countdown(store.records.high, 0):
    let current = store.records[index].entry
    if current.url == entry.url and current.varyNames == entry.varyNames and
        current.varyValues == entry.varyValues:
      store.removeRecord(index)
  inc store.accessCounter
  store.records.add MemoryCacheRecord(
    entry: entry,
    lastAccess: store.accessCounter
  )
  store.totalBytes += entry.entryBytes
  store.evict()

method invalidate*(store: MemoryHttpCache; url: string) =
  if store == nil:
    return
  for index in countdown(store.records.high, 0):
    if store.records[index].entry.url == url:
      store.removeRecord(index)

func len*(store: MemoryHttpCache): int =
  if store == nil: 0 else: store.records.len

func bytes*(store: MemoryHttpCache): int64 =
  if store == nil: 0 else: store.totalBytes

func defaultHttpCacheOptions*(): HttpCacheOptions =
  HttpCacheOptions()

proc systemCacheClock(): Time =
  getTime()

proc newCachingTransport*(
    delegate: Transport;
    store: HttpCacheStore;
    options = defaultHttpCacheOptions();
    clock: HttpCacheClockProc = systemCacheClock
): CachingTransport =
  CachingTransport(
    delegate: delegate,
    store: store,
    options: options,
    clock: clock
  )

proc newCachingTransport*(
    delegate: Transport;
    options = defaultHttpCacheOptions()
): CachingTransport =
  newCachingTransport(delegate, newMemoryHttpCache(), options)

func parseNonNegative(value: string): Option[int64] =
  var parsed: BiggestInt
  if parseBiggestInt(value.strip, parsed) == value.strip.len and parsed >= 0:
    some(int64(parsed))
  else:
    none(int64)

func unquote(value: string): string =
  let stripped = value.strip
  if stripped.len >= 2 and stripped[0] == '"' and stripped[^1] == '"':
    stripped[1 .. ^2]
  else:
    stripped

func parseCacheDirectives(headers: Headers): CacheDirectives =
  for fieldValue in headers.getAll("cache-control"):
    for rawDirective in fieldValue.split(','):
      let pieces = rawDirective.strip.split('=', 1)
      let name = pieces[0].strip.toLowerAscii
      let value = if pieces.len == 2: pieces[1].unquote else: ""
      case name
      of "no-store": result.noStore = true
      of "no-cache": result.noCache = true
      of "only-if-cached": result.onlyIfCached = true
      of "max-age":
        let seconds = value.parseNonNegative
        if seconds.isSome:
          result.hasMaxAge = true
          result.maxAgeSeconds = seconds.get
      else: discard
  if headers.get("pragma").toLowerAscii.contains("no-cache"):
    result.noCache = true

proc parseHttpDate(value: string): Option[Time] =
  if value.len == 0:
    return none(Time)
  for format in [
    "ddd, dd MMM yyyy HH:mm:ss 'GMT'",
    "dddd, dd-MMM-yy HH:mm:ss 'GMT'",
    "ddd MMM  d HH:mm:ss yyyy",
    "ddd MMM dd HH:mm:ss yyyy"
  ]:
    try:
      return some(parse(value, format, utc()).toTime)
    except TimeParseError:
      discard
  none(Time)

proc responseFreshnessLifetime(
    headers: Headers;
    responseTime: Time
): int64 =
  let directives = headers.parseCacheDirectives
  if directives.hasMaxAge:
    return directives.maxAgeSeconds
  let expires = headers.get("expires").parseHttpDate
  if expires.isNone:
    return 0
  let date = headers.get("date").parseHttpDate
  max(0'i64, (expires.get - (if date.isSome: date.get else: responseTime)).inSeconds)

proc initialAge(headers: Headers; responseTime: Time): int64 =
  let age = headers.get("age").parseNonNegative
  let date = headers.get("date").parseHttpDate
  let apparentAge =
    if date.isSome: max(0'i64, (responseTime - date.get).inSeconds)
    else: 0'i64
  max(apparentAge, if age.isSome: age.get else: 0'i64)

func currentAge(entry: HttpCacheEntry; now: Time): int64 =
  entry.initialAgeSeconds + max(0'i64, (now - entry.storedAt).inSeconds)

func isFresh(
    entry: HttpCacheEntry;
    requestDirectives: CacheDirectives;
    now: Time
): bool =
  if entry.requiresRevalidation or requestDirectives.noCache:
    return false
  let allowedLifetime =
    if requestDirectives.hasMaxAge:
      min(entry.freshnessLifetimeSeconds, requestDirectives.maxAgeSeconds)
    else:
      entry.freshnessLifetimeSeconds
  entry.currentAge(now) < allowedLifetime

func cloneHeaders(source: Headers): Headers =
  result = initHeaders()
  result.merge(source)

func varyNames(headers: Headers): seq[string] =
  var seen = initHashSet[string]()
  for fieldValue in headers.getAll("vary"):
    for rawName in fieldValue.split(','):
      let name = rawName.strip.toLowerAscii
      if name.len > 0 and name notin seen:
        seen.incl name
        result.add name

func cacheableStatus(status: int): bool =
  status in [200, 203, 204, 300, 301, 308, 404, 405, 410, 414, 501]

func canUseCache(
    request: Request;
    options: HttpCacheOptions;
    implicitCredentials: bool
): bool =
  request.httpMethod == rmGet and
    not request.options.streamResponse and
    not request.headers.contains("range") and
    (options.cacheAuthenticatedRequests or
      (not implicitCredentials and
       not request.headers.contains("authorization") and
       not request.headers.contains("cookie")))

func effectivePort(parsed: Uri): string =
  if parsed.port.len > 0:
    parsed.port
  elif parsed.scheme.toLowerAscii == "https":
    "443"
  else:
    "80"

func sameOrigin(first, second: Uri): bool =
  first.scheme.toLowerAscii == second.scheme.toLowerAscii and
    first.hostname.toLowerAscii == second.hostname.toLowerAscii and
    first.effectivePort == second.effectivePort

proc invalidateRelated(
    store: HttpCacheStore;
    requestUrl: string;
    responseHeaders: Headers
) =
  store.invalidate(requestUrl)
  try:
    let base = parseUri(requestUrl)
    for fieldName in ["location", "content-location"]:
      let value = responseHeaders.get(fieldName)
      if value.len == 0:
        continue
      let target = combine(base, parseUri(value))
      if base.sameOrigin(target):
        store.invalidate($target)
  except ValueError:
    discard

proc makeEntry(
    request: Request;
    response: Response;
    responseTime: Time;
    options: HttpCacheOptions
): Option[HttpCacheEntry] =
  if not response.status.cacheableStatus or request.options.streamResponse:
    return none(HttpCacheEntry)
  let directives = response.headers.parseCacheDirectives
  if directives.noStore or
      (not options.cacheSetCookieResponses and
       response.headers.contains("set-cookie")):
    return none(HttpCacheEntry)
  var names = response.headers.varyNames
  if "*" in names:
    return none(HttpCacheEntry)
  let freshness = response.headers.responseFreshnessLifetime(responseTime)
  let validatorPresent = response.headers.contains("etag") or
    response.headers.contains("last-modified")
  if freshness <= 0 and not validatorPresent:
    return none(HttpCacheEntry)
  var values: seq[string]
  for name in names:
    values.add request.headers.varyValue(name)
  some(HttpCacheEntry(
    url: request.url,
    status: response.status,
    statusText: response.statusText,
    headers: response.headers.cloneHeaders,
    body: response.body,
    varyNames: move(names),
    varyValues: move(values),
    storedAt: responseTime,
    initialAgeSeconds: response.headers.initialAge(responseTime),
    freshnessLifetimeSeconds: freshness,
    requiresRevalidation: directives.noCache
  ))

proc mergeNotModified(
    entry: HttpCacheEntry;
    response: Response;
    responseTime: Time;
    options: HttpCacheOptions
): HttpCacheEntry =
  result = entry
  var replaced = initHashSet[string]()
  for name, value in response.headers.pairs:
    if name in ["content-length", "transfer-encoding"] or
        (name == "set-cookie" and not options.cacheSetCookieResponses):
      continue
    if name notin replaced:
      result.headers.set(name, value)
      replaced.incl name
    else:
      result.headers.add(name, value)
  result.storedAt = responseTime
  result.initialAgeSeconds = result.headers.initialAge(responseTime)
  result.freshnessLifetimeSeconds =
    result.headers.responseFreshnessLifetime(responseTime)
  result.requiresRevalidation = result.headers.parseCacheDirectives.noCache

proc deliverCached(
    entry: HttpCacheEntry;
    request: Request;
    ageSeconds: int64;
    revalidated: bool
): Future[Response] {.async.} =
  if request.options.maxResponseBytes >= 0 and
      entry.body.len > request.options.maxResponseBytes:
    raise newJoubakoError(
      jeBodyTooLarge,
      "cached response body exceeded the configured limit",
      request.url,
      entry.status
    )
  var responseHeaders = entry.headers.cloneHeaders
  responseHeaders.set("age", $max(0'i64, ageSeconds))
  if not request.options.onResponseHeaders.isNil:
    try:
      request.options.onResponseHeaders(entry.status, responseHeaders)
    except CatchableError as error:
      raise error.asJoubakoError(jeStream, request.url)
  if entry.body.len > 0:
    await request.consumeDownloadChunk(entry.body)
  if not request.options.onDownloadProgress.isNil:
    request.options.onDownloadProgress(
      int64(entry.body.len), int64(entry.body.len)
    )
  return Response(
    status: entry.status,
    statusText: entry.statusText,
    headers: responseHeaders,
    body: if request.options.streamResponse: "" else: entry.body,
    request: request,
    fromCache: true,
    cacheRevalidated: revalidated
  )

method send*(
    transport: CachingTransport;
    request: Request
): Future[Response] {.async.} =
  if transport == nil or transport.delegate == nil:
    raise newJoubakoError(
      jeInvalidRequest, "cache transport has no delegate", request.url
    )
  if transport.store == nil:
    raise newJoubakoError(
      jeInvalidRequest, "cache transport has no store", request.url
    )

  let now = if transport.clock.isNil: getTime() else: transport.clock()
  let requestDirectives = request.headers.parseCacheDirectives
  let usable = request.canUseCache(
    transport.options,
    transport.delegate.usesImplicitCredentials
  ) and
    not requestDirectives.noStore

  var cached = none(HttpCacheEntry)
  if usable:
    try:
      cached = transport.store.lookup(request)
    except CatchableError:
      cached = none(HttpCacheEntry)
    if cached.isSome and cached.get.isFresh(requestDirectives, now):
      return await deliverCached(
        cached.get, request, cached.get.currentAge(now), false
      )
    if requestDirectives.onlyIfCached:
      return Response(
        status: 504,
        statusText: "Gateway Timeout",
        headers: initHeaders(),
        request: request
      )

  var outgoing = request
  var revalidating = false
  if usable and cached.isSome:
    if not outgoing.headers.contains("if-none-match") and
        cached.get.headers.contains("etag"):
      outgoing.headers.set("if-none-match", cached.get.headers.get("etag"))
      revalidating = true
    elif not outgoing.headers.contains("if-modified-since") and
        cached.get.headers.contains("last-modified"):
      outgoing.headers.set(
        "if-modified-since", cached.get.headers.get("last-modified")
      )
      revalidating = true

  result = await transport.delegate.send(outgoing)
  let receivedAt = if transport.clock.isNil: getTime() else: transport.clock()

  if revalidating and result.status == 304:
    let refreshed = mergeNotModified(
      cached.get, result, receivedAt, transport.options
    )
    if result.headers.parseCacheDirectives.noStore:
      try:
        transport.store.invalidate(request.url)
      except CatchableError:
        discard
    else:
      try:
        transport.store.put(refreshed)
      except CatchableError:
        discard
    return await deliverCached(
      refreshed, request, refreshed.currentAge(receivedAt), true
    )

  result.request = request
  if usable:
    let entry = makeEntry(request, result, receivedAt, transport.options)
    if entry.isSome:
      try:
        transport.store.put(entry.get)
      except CatchableError:
        discard
    elif result.headers.parseCacheDirectives.noStore:
      try:
        transport.store.invalidate(request.url)
      except CatchableError:
        discard

  if request.httpMethod in {rmPost, rmPut, rmPatch, rmDelete} and
      result.status >= 200 and result.status < 400:
    try:
      transport.store.invalidateRelated(request.url, result.headers)
    except CatchableError:
      discard
