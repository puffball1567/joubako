## Bounded Server-Sent Events parsing and reconnecting subscriptions.

import std/[asyncdispatch, strutils, times]
import flowbrigade/retry
import ./[client, http_retry, result, types]

const
  DefaultSseRetryMs* = 3_000
  DefaultMaxSseEventBytes* = 1024 * 1024

type
  ServerSentEvent* = object
    event*: string
    data*: string
    id*: string
    retryMs*: int

  SseEventProc* = proc(event: ServerSentEvent) {.closure.}
  AsyncSseEventProc* =
    proc(event: ServerSentEvent): Future[void] {.closure.}

  SseOptions* = object
    ## Number of reconnects after the initial connection. A negative value
    ## permits reconnecting until cancellation or a terminal response.
    maxReconnects*: int
    initialRetryMs*: int
    maxEventBytes*: int
    ## Injectable sleeper used by deterministic tests and UI runtimes.
    sleep*: AsyncSleepProc

  SseParser* = ref object
    pending: string
    dataBuffer: string
    eventType: string
    pendingId: string
    lastEventId: string
    reconnectMs: int
    eventBytes: int
    maxEventBytes: int
    atStart: bool

  SseAttemptState = ref object
    parser: SseParser
    active: bool
    terminal: bool
    validationError: ref JoubakoError

func defaultSseOptions*(): SseOptions =
  SseOptions(
    maxReconnects: -1,
    initialRetryMs: DefaultSseRetryMs,
    maxEventBytes: DefaultMaxSseEventBytes,
    sleep: sleepDurationAsync
  )

func newSseParser*(
    maxEventBytes = DefaultMaxSseEventBytes;
    initialRetryMs = DefaultSseRetryMs
): SseParser =
  SseParser(
    reconnectMs: max(0, initialRetryMs),
    maxEventBytes: maxEventBytes,
    atStart: true
  )

func lastEventId*(parser: SseParser): string =
  if parser == nil: "" else: parser.lastEventId

func reconnectDelayMs*(parser: SseParser): int =
  if parser == nil: DefaultSseRetryMs else: parser.reconnectMs

proc resetConnection*(parser: SseParser) =
  ## Retains Last-Event-ID and the server-provided reconnect delay while
  ## dropping an incomplete event from the disconnected response.
  if parser == nil:
    return
  parser.pending.setLen(0)
  parser.dataBuffer.setLen(0)
  parser.eventType.setLen(0)
  parser.pendingId = parser.lastEventId
  parser.eventBytes = 0
  parser.atStart = true

func asciiDigits(value: string): bool =
  if value.len == 0:
    return false
  for character in value:
    if character notin {'0' .. '9'}:
      return false
  true

proc processLine(
    parser: SseParser;
    line: string;
    events: var seq[ServerSentEvent]
): ref JoubakoError =
  if line.len == 0:
    parser.eventBytes = 0
    if parser.dataBuffer.len == 0:
      parser.eventType.setLen(0)
      return nil
    parser.dataBuffer.setLen(parser.dataBuffer.len - 1)
    parser.lastEventId = parser.pendingId
    events.add ServerSentEvent(
      event: if parser.eventType.len == 0: "message" else: parser.eventType,
      data: move(parser.dataBuffer),
      id: parser.lastEventId,
      retryMs: parser.reconnectMs
    )
    parser.dataBuffer = ""
    parser.eventType.setLen(0)
    return nil

  if parser.maxEventBytes >= 0 and
      (parser.eventBytes > parser.maxEventBytes or
       line.len + 1 > parser.maxEventBytes - parser.eventBytes):
    return newJoubakoError(
      jeStream,
      "SSE event exceeded the configured limit"
    )
  parser.eventBytes += line.len + 1

  if line[0] == ':':
    return nil

  let separator = line.find(':')
  let field = if separator < 0: line else: line[0 ..< separator]
  var value = if separator < 0: "" else: line[separator + 1 .. ^1]
  if value.len > 0 and value[0] == ' ':
    value.delete(0 .. 0)

  case field
  of "event":
    parser.eventType = value
  of "data":
    parser.dataBuffer.add value
    parser.dataBuffer.add '\n'
  of "id":
    if '\0' notin value:
      parser.pendingId = value
  of "retry":
    if value.asciiDigits:
      try:
        parser.reconnectMs = min(parseInt(value), high(int))
      except ValueError:
        discard
  else:
    discard
  nil

proc feed*(parser: SseParser; chunk: string): JResult[seq[ServerSentEvent]] =
  if parser == nil:
    return err[seq[ServerSentEvent]](newJoubakoError(
      jeInvalidRequest, "SSE parser is nil"
    ))

  parser.pending.add chunk
  if parser.atStart:
    const Utf8Bom = "\xEF\xBB\xBF"
    if parser.pending.len < Utf8Bom.len and
        Utf8Bom.startsWith(parser.pending):
      return ok(newSeq[ServerSentEvent]())
    if parser.pending.startsWith(Utf8Bom):
      parser.pending.delete(0 .. Utf8Bom.high)
    parser.atStart = false

  var events: seq[ServerSentEvent]
  var lineStart = 0
  var index = 0
  while index < parser.pending.len:
    let character = parser.pending[index]
    if character notin {'\r', '\n'}:
      inc index
      continue
    if character == '\r' and index == parser.pending.high:
      break

    let line = parser.pending[lineStart ..< index]
    let failure = parser.processLine(line, events)
    if failure != nil:
      return err[seq[ServerSentEvent]](failure)
    if character == '\r' and parser.pending[index + 1] == '\n':
      inc index
    inc index
    lineStart = index

  if lineStart > 0:
    parser.pending.delete(0 .. lineStart - 1)
  ok(move(events))

func isEventStream(headers: Headers): bool =
  let value = headers.get("content-type").split(';', 1)[0].strip.toLowerAscii
  value == "text/event-stream"

proc responseHeadersHandler(
    state: SseAttemptState;
    prior: ResponseHeadersProc;
    path: string
): ResponseHeadersProc =
  result = proc(status: int; responseHeaders: Headers) =
    if not prior.isNil:
      try:
        prior(status, responseHeaders)
      except CatchableError as error:
        state.validationError = error.asJoubakoError(jeStream, path)
        return
    state.terminal = status == 204
    if status >= 200 and status < 300 and not state.terminal and
        not responseHeaders.isEventStream:
      state.validationError = newJoubakoError(
        jeStream,
        "SSE response Content-Type must be text/event-stream",
        path,
        status
      )
      return
    state.active = status >= 200 and status < 300 and not state.terminal

proc downloadChunkHandler(
    state: SseAttemptState;
    prior: AsyncDownloadChunkProc;
    handler: AsyncSseEventProc;
    path: string
): AsyncDownloadChunkProc =
  result = proc(chunk: string): Future[void] {.async.} =
    if not prior.isNil:
      await prior(chunk)
    if not state.active:
      return
    let parsed = state.parser.feed(chunk)
    if parsed.isErr:
      raise parsed.error
    for event in parsed.value:
      var handling: Future[void]
      try:
        handling = handler(event)
      except CatchableError as error:
        raise error.asJoubakoError(jeStream, path)
      if handling == nil:
        raise newJoubakoError(
          jeStream, "SSE event handler returned a nil Future", path
        )
      let handled = await settle(fallible(handling), jeStream, path)
      if handled.isErr:
        raise handled.error

proc subscribeSseResult(
    client: Client;
    path: string;
    handler: AsyncSseEventProc;
    headers: Headers;
    requestOptions: RequestOptions;
    sseOptions: SseOptions
): Future[JResult[void]] {.async.} =
  if handler.isNil:
    return err[void](newJoubakoError(
      jeInvalidRequest, "SSE event handler is nil", path
    ))

  let parser = newSseParser(
    sseOptions.maxEventBytes,
    if sseOptions.initialRetryMs < 0:
      DefaultSseRetryMs
    else:
      sseOptions.initialRetryMs
  )
  var reconnects = 0

  while true:
    var attemptHeaders = initHeaders()
    attemptHeaders.merge(headers)
    if not attemptHeaders.contains("accept"):
      attemptHeaders.set("accept", "text/event-stream")
    if parser.lastEventId.len > 0:
      attemptHeaders.set("last-event-id", parser.lastEventId)

    var options = requestOptions
    options.streamResponse = true
    let priorChunk = options.onDownloadChunkAsync
    let priorHeaders = options.onResponseHeaders
    let state = SseAttemptState(parser: parser)
    options.onResponseHeaders = responseHeadersHandler(
      state, priorHeaders, path
    )
    options.onDownloadChunkAsync = downloadChunkHandler(
      state, priorChunk, handler, path
    )

    let response = await client.get(path, attemptHeaders, options)
    if state.validationError != nil:
      let validationError = move(state.validationError)
      return err[void](validationError)
    if state.terminal:
      return ok()
    if response.isErr:
      if response.error.kind == jeCancelled:
        return err[void](response.error)
      if response.error.kind notin {jeTransport, jeTimeout}:
        return err[void](response.error)

    if sseOptions.maxReconnects >= 0 and
        reconnects >= sseOptions.maxReconnects:
      if response.isErr:
        return err[void](response.error)
      return ok()

    inc reconnects
    parser.resetConnection()
    let sleeper =
      if sseOptions.sleep.isNil: sleepDurationAsync else: sseOptions.sleep
    let waiting = retrySleep(
      initDuration(milliseconds = parser.reconnectDelayMs),
      -1,
      requestOptions.cancellation,
      sleeper
    )
    let waited = await settle(fallible(waiting), jeTimeout, path)
    if waited.isErr:
      return err[void](waited.error)

proc subscribeSse*(
    client: Client;
    path: string;
    handler: AsyncSseEventProc;
    headers = initHeaders();
    requestOptions = RequestOptions();
    sseOptions = defaultSseOptions()
): Future[JResult[void]] =
  settleResult(
    fallible(client.subscribeSseResult(
      path, handler, headers, requestOptions, sseOptions
    )),
    jeStream,
    path
  )

proc subscribeSse*(
    client: Client;
    path: string;
    handler: SseEventProc;
    headers = initHeaders();
    requestOptions = RequestOptions();
    sseOptions = defaultSseOptions()
): Future[JResult[void]] =
  let asynchronous = proc(event: ServerSentEvent): Future[void] {.async.} =
    handler(event)
  client.subscribeSse(
    path, asynchronous, headers, requestOptions, sseOptions
  )
