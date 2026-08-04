## OpenTelemetry-compatible HTTP client spans and W3C trace propagation.
##
## Joubako deliberately does not force a specific telemetry SDK. Completed
## spans use stable OpenTelemetry HTTP semantic fields and are handed to an
## observer that can enqueue them for any SDK or OTLP exporter.

import std/[monotimes, strutils, sysrand, times, uri]
import ./types

type
  OpenTelemetrySpanStatus* = enum
    otelUnset,
    otelOk,
    otelError

  OpenTelemetryAttributeKind* = enum
    otelAttributeString,
    otelAttributeInt

  OpenTelemetryAttribute* = object
    key*: string
    case kind*: OpenTelemetryAttributeKind
    of otelAttributeString:
      stringValue*: string
    of otelAttributeInt:
      intValue*: int64

  OpenTelemetrySpan* = ref object
    traceId*: string
    spanId*: string
    parentSpanId*: string
    traceFlags*: string
    traceState*: string
    name*: string
    kind*: string
    httpRequestMethod*: string
    urlFull*: string
    serverAddress*: string
    serverPort*: int
    httpResponseStatusCode*: int
    errorType*: string
    attemptCount*: int
    retryCount*: int
    startTimeUnixNano*: int64
    endTimeUnixNano*: int64
    durationNano*: int64
    status*: OpenTelemetrySpanStatus
    startedMono: MonoTime

  OpenTelemetryObserverProc* =
    proc(span: OpenTelemetrySpan) {.closure.}

  OpenTelemetryOptions* = object
    ## Query strings can contain credentials and identifiers, so they are
    ## excluded from url.full unless explicitly enabled.
    captureQuery*: bool
    propagateTraceContext*: bool
    sampled*: bool

  OpenTelemetryConfig* = ref object
    observer*: OpenTelemetryObserverProc
    options*: OpenTelemetryOptions

func defaultOpenTelemetryOptions*(): OpenTelemetryOptions =
  OpenTelemetryOptions(
    captureQuery: false,
    propagateTraceContext: true,
    sampled: true
  )

func newOpenTelemetryConfig*(
    observer: OpenTelemetryObserverProc;
    options = defaultOpenTelemetryOptions()
): OpenTelemetryConfig =
  OpenTelemetryConfig(observer: observer, options: options)

func isHex(value: string): bool =
  if value.len == 0:
    return false
  for character in value:
    if character notin {'0' .. '9', 'a' .. 'f', 'A' .. 'F'}:
      return false
  true

func isAllZero(value: string): bool =
  for character in value:
    if character != '0':
      return false
  true

func validTraceParent*(value: string): bool =
  let parts = value.toLowerAscii.split('-')
  if parts.len != 4 or parts[0].len != 2 or parts[0] == "ff" or
      parts[1].len != 32 or parts[2].len != 16 or parts[3].len != 2:
    return false
  for part in parts:
    if not part.isHex:
      return false
  not parts[1].isAllZero and not parts[2].isAllZero

proc semanticAttributes*(span: OpenTelemetrySpan): seq[OpenTelemetryAttribute] =
  ## Returns the current stable HTTP client semantic attributes plus bounded
  ## Joubako retry diagnostics. Empty or unavailable attributes are omitted.
  if span == nil:
    return
  result.add OpenTelemetryAttribute(
    key: "http.request.method",
    kind: otelAttributeString,
    stringValue: span.httpRequestMethod
  )
  if span.urlFull.len > 0:
    result.add OpenTelemetryAttribute(
      key: "url.full",
      kind: otelAttributeString,
      stringValue: span.urlFull
    )
  if span.serverAddress.len > 0:
    result.add OpenTelemetryAttribute(
      key: "server.address",
      kind: otelAttributeString,
      stringValue: span.serverAddress
    )
  if span.serverPort > 0:
    result.add OpenTelemetryAttribute(
      key: "server.port",
      kind: otelAttributeInt,
      intValue: int64(span.serverPort)
    )
  if span.httpResponseStatusCode > 0:
    result.add OpenTelemetryAttribute(
      key: "http.response.status_code",
      kind: otelAttributeInt,
      intValue: int64(span.httpResponseStatusCode)
    )
  if span.errorType.len > 0:
    result.add OpenTelemetryAttribute(
      key: "error.type",
      kind: otelAttributeString,
      stringValue: span.errorType
    )
  result.add OpenTelemetryAttribute(
    key: "joubako.request.attempt_count",
    kind: otelAttributeInt,
    intValue: int64(span.attemptCount)
  )
  result.add OpenTelemetryAttribute(
    key: "joubako.request.retry_count",
    kind: otelAttributeInt,
    intValue: int64(span.retryCount)
  )

proc randomHex(byteCount: int): string =
  const Hex = "0123456789abcdef"
  var bytes = urandom(byteCount)
  var anyNonZero = false
  result = newString(byteCount * 2)
  for index, value in bytes:
    anyNonZero = anyNonZero or value != 0
    result[index * 2] = Hex[int(value shr 4)]
    result[index * 2 + 1] = Hex[int(value and 0x0f)]
  if not anyNonZero and result.len > 0:
    result[^1] = '1'

func unixNano(now: Time): int64 =
  now.toUnix * 1_000_000_000'i64 + int64(now.nanosecond)

proc safeUrl(
    value: string;
    captureQuery: bool
): tuple[full, address: string; port: int] =
  try:
    var parsed = parseUri(value)
    result.address = parsed.hostname
    if parsed.port.len > 0:
      try:
        result.port = parseInt(parsed.port)
      except ValueError:
        discard
    parsed.username.setLen(0)
    parsed.password.setLen(0)
    parsed.anchor.setLen(0)
    if not captureQuery:
      parsed.query.setLen(0)
    result.full = $parsed
  except ValueError:
    result.full = value.split({'?', '#'}, 1)[0]

proc startHttpClientSpan*(
    config: OpenTelemetryConfig;
    httpMethod: RequestMethod;
    url: string;
    propagationHeaders: Headers;
    targetHeaders: var Headers
): OpenTelemetrySpan =
  if config == nil:
    return nil

  try:
    let existingParent = propagationHeaders.get("traceparent").toLowerAscii
    let parentParts = existingParent.split('-')
    let continued = existingParent.validTraceParent
    let traceId = if continued: parentParts[1] else: randomHex(16)
    let parentSpanId = if continued: parentParts[2] else: ""
    let traceFlags =
      if continued: parentParts[3]
      elif config.options.sampled: "01"
      else: "00"
    let spanId = randomHex(8)
    let urlFields = safeUrl(url, config.options.captureQuery)
    let startedAt = getTime()
    result = OpenTelemetrySpan(
      traceId: traceId,
      spanId: spanId,
      parentSpanId: parentSpanId,
      traceFlags: traceFlags,
      traceState: propagationHeaders.get("tracestate"),
      name: $httpMethod,
      kind: "CLIENT",
      httpRequestMethod: $httpMethod,
      urlFull: urlFields.full,
      serverAddress: urlFields.address,
      serverPort: urlFields.port,
      startTimeUnixNano: startedAt.unixNano,
      startedMono: getMonoTime(),
      status: otelUnset
    )
    if config.options.propagateTraceContext:
      targetHeaders.set(
        "traceparent",
        "00-" & traceId & "-" & spanId & "-" & traceFlags
      )
  except CatchableError:
    ## Observability must never prevent an application request.
    return nil

proc finishHttpClientSpan*(
    config: OpenTelemetryConfig;
    span: OpenTelemetrySpan;
    finalUrl: string;
    statusCode: int;
    attempts: int;
    failure: ref JoubakoError = nil
) =
  if config == nil or span == nil:
    return
  let endedAt = getTime()
  span.endTimeUnixNano = endedAt.unixNano
  span.durationNano = max(0'i64, (getMonoTime() - span.startedMono).inNanoseconds)
  span.httpResponseStatusCode = statusCode
  span.attemptCount = max(0, attempts)
  span.retryCount = max(0, attempts - 1)
  if finalUrl.len > 0:
    let urlFields = safeUrl(finalUrl, config.options.captureQuery)
    span.urlFull = urlFields.full
    span.serverAddress = urlFields.address
    span.serverPort = urlFields.port

  if failure != nil:
    span.errorType = $failure.kind
    span.status = otelError
  elif statusCode >= 400:
    span.errorType = $statusCode
    span.status = otelError
  else:
    span.status = otelOk

  if not config.observer.isNil:
    try:
      config.observer(span)
    except CatchableError:
      ## Export queues and SDK adapters are isolated from request outcomes.
      discard
