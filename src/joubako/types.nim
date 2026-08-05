import std/[asyncdispatch, strutils, tables, times]
import flowbrigade/[backoff, retry]

type
  ProgressProc* = proc(transferred, total: int64) {.closure.}
  DownloadChunkProc* = proc(chunk: string) {.closure.}
  AsyncDownloadChunkProc* =
    proc(chunk: string): Future[void] {.closure.}
  ResponseHeadersProc* =
    proc(status: int; headers: Headers) {.closure.}

  IdempotencyMode* = enum
    imDefault,
    imIdempotent,
    imNonIdempotent

  HttpRetryOptions* = object
    ## Values below 2 disable retry.
    maxAttempts*: int
    backoff*: BackoffPolicy
    observer*: RetryObserverProc
    ## Optional injectable async sleeper for deterministic tests.
    sleep*: AsyncSleepProc
    idempotency*: IdempotencyMode

  RequestMethod* = enum
    rmGet, rmHead, rmPost, rmPut, rmPatch, rmDelete, rmOptions

  MultipartPart* = object
    ## Buffered parts use `body`. A non-empty `filePath` is opened and streamed
    ## by transports that support file-backed multipart requests.
    name*: string
    filename*: string
    contentType*: string
    body*: string
    filePath*: string

  Headers* = object
    values: OrderedTable[string, seq[string]]

  CancellationToken* = ref object
    cancelled*: bool
    reason*: string
    signal: Future[void]

  RequestOptions* = object
    ## Total time allowed across attempts and retry waits. A value below zero
    ## disables the deadline.
    timeoutMs*: int
    ## Time allowed to connect and receive response headers. The standard
    ## transport exposes these as one asynchronous operation.
    connectTimeoutMs*: int
    ## Maximum wait between response body chunks.
    readTimeoutMs*: int
    ## Maximum buffered response body size. A value below zero disables the
    ## limit.
    maxResponseBytes*: int
    ## Maximum request body size. A value below zero disables the limit.
    maxRequestBytes*: int
    cancellation*: CancellationToken
    retry*: HttpRetryOptions
    ## Empty permits every host. Entries are exact host names or explicit
    ## wildcards such as `*.example.com`.
    allowedHosts*: seq[string]
    onUploadProgress*: ProgressProc
    onDownloadProgress*: ProgressProc
    onDownloadChunk*: DownloadChunkProc
    ## Awaited before reading the next chunk, providing asynchronous
    ## backpressure for file and pipeline consumers.
    onDownloadChunkAsync*: AsyncDownloadChunkProc
    ## Runs after response headers arrive and before the first body chunk.
    ## Streaming protocols can validate status and content type without
    ## buffering or prematurely delivering a response body.
    onResponseHeaders*: ResponseHeadersProc
    ## Delivers chunks without retaining them in `Response.body`.
    streamResponse*: bool

  Request* = object
    httpMethod*: RequestMethod
    url*: string
    headers*: Headers
    body*: string
    multipartParts*: seq[MultipartPart]
    options*: RequestOptions

  Response* = object
    status*: int
    statusText*: string
    ## Negotiated protocol reported by the transport, for example
    ## `HTTP/1.1` or `HTTP/2`. Empty when a custom transport does not report it.
    httpVersion*: string
    headers*: Headers
    body*: string
    request*: Request
    ## Number of transport attempts used by the logical request.
    attempts*: int
    fromCache*: bool
    cacheRevalidated*: bool

  ErrorResponse* = object
    ## Bounded response data retained for an HTTP status error. This omits the
    ## originating Request so credentials and request bodies are not retained.
    status*: int
    statusText*: string
    headers*: Headers
    body*: string

  ErrorKind* = enum
    jeInvalidRequest,
    jeTransport,
    jeTimeout,
    jeCancelled,
    jeHttpStatus,
    jeBodyTooLarge,
    jeCodec,
    jeCompression,
    jeStream,
    jeCircuitOpen,
    jeRateLimited,
    jeBulkheadRejected

  JoubakoError* = object of CatchableError
    kind*: ErrorKind
    status*: int
    url*: string
    ## Optional machine-readable code and byte offset supplied by a codec.
    ## `codecOffset` is -1 when the codec did not identify a byte position.
    codecCode*: string
    codecOffset*: int
    ## Parsed Retry-After delay in milliseconds, or -1 when absent/invalid.
    retryAfterMs*: int64
    ## True when `response` contains an HTTP response received from the peer.
    hasResponse*: bool
    response*: ErrorResponse
    ## Number of transport attempts completed for this logical request.
    attempts*: int

func normalizeHeader(name: string): string =
  name.strip.toLowerAscii

func isHostAllowed*(host: string; allowedHosts: openArray[string]): bool =
  ## Exact hosts and explicit `*.example.com` subdomain rules are supported.
  if allowedHosts.len == 0:
    return true
  let normalized = host.strip.toLowerAscii
  for entry in allowedHosts:
    let rule = entry.strip.toLowerAscii
    if rule == normalized:
      return true
    if rule.startsWith("*.") and normalized.endsWith(rule[1 .. ^1]) and
        normalized.len > rule.len - 1:
      return true

func initHeaders*(): Headers =
  Headers(values: initOrderedTable[string, seq[string]]())

proc add*(headers: var Headers; name, value: string) =
  let key = normalizeHeader(name)
  if key in headers.values:
    headers.values[key].add value
  else:
    headers.values[key] = @[value]

proc set*(headers: var Headers; name, value: string) =
  headers.values[normalizeHeader(name)] = @[value]

proc del*(headers: var Headers; name: string) =
  headers.values.del(normalizeHeader(name))

func contains*(headers: Headers; name: string): bool =
  normalizeHeader(name) in headers.values

func getAll*(headers: Headers; name: string): seq[string] =
  headers.values.getOrDefault(normalizeHeader(name))

func get*(headers: Headers; name: string; default = ""): string =
  let found = headers.getAll(name)
  if found.len == 0: default else: found[0]

iterator pairs*(headers: Headers): tuple[name, value: string] =
  for name, values in headers.values:
    for value in values:
      yield (name, value)

proc merge*(target: var Headers; source: Headers) =
  for name, value in source.pairs:
    target.add(name, value)

proc toErrorResponse*(response: Response): ErrorResponse =
  ## Creates an independent response snapshot without retaining its Request.
  result.status = response.status
  result.statusText = response.statusText
  result.headers = initHeaders()
  result.headers.merge(response.headers)
  result.body = response.body

proc overlay*(target: var Headers; source: Headers) =
  ## Replaces matching target headers while retaining multiple source values.
  for name, values in source.values:
    if values.len > 0:
      target.set(name, values[0])
      for index in 1 ..< values.len:
        target.add(name, values[index])

func defaultRequestOptions*(): RequestOptions =
  RequestOptions(
    timeoutMs: 30_000,
    connectTimeoutMs: 10_000,
    readTimeoutMs: 10_000,
    maxResponseBytes: 16 * 1024 * 1024,
    maxRequestBytes: 16 * 1024 * 1024
  )

proc defaultHttpRetryOptions*(): HttpRetryOptions =
  HttpRetryOptions(
    maxAttempts: 3,
    backoff: expBackoff(
      initial = initDuration(milliseconds = 100),
      factor = 2.0,
      maxDelay = initDuration(seconds = 2),
      jitter = fullJitter
    )
  )

proc newCancellationToken*(): CancellationToken =
  CancellationToken(signal: newFuture[void]("Joubako.CancellationToken"))

proc cancel*(token: CancellationToken; reason = "request cancelled") =
  if token == nil or token.cancelled:
    return
  token.cancelled = true
  token.reason = reason
  if token.signal != nil and not token.signal.finished:
    token.signal.complete()

proc cancellationFuture*(token: CancellationToken): Future[void] =
  if token.signal == nil:
    token.signal = newFuture[void]("Joubako.CancellationToken")
    if token.cancelled:
      token.signal.complete()
  token.signal

proc newJoubakoError*(
    kind: ErrorKind;
    message: string;
    url = "";
    status = 0;
    retryAfterMs = -1'i64
): ref JoubakoError =
  result = newException(JoubakoError, message)
  result.kind = kind
  result.url = url
  result.status = status
  result.retryAfterMs = retryAfterMs
  result.codecOffset = -1

proc attachResponse*(error: ref JoubakoError; response: Response) =
  ## Retains bounded peer response data without the originating Request.
  if error == nil:
    return
  error.hasResponse = true
  error.response = response.toErrorResponse()
  error.status = response.status

func `$`*(httpMethod: RequestMethod): string =
  case httpMethod
  of rmGet: "GET"
  of rmHead: "HEAD"
  of rmPost: "POST"
  of rmPut: "PUT"
  of rmPatch: "PATCH"
  of rmDelete: "DELETE"
  of rmOptions: "OPTIONS"
