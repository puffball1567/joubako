## Incremental NDJSON and RFC 7464 JSON Text Sequence codecs.

import std/[asyncdispatch, json, jsonutils, options, strutils, unicode]
import ./[client, result, types]

const
  NdjsonMediaType* = "application/x-ndjson"
  JsonSequenceMediaType* = "application/json-seq"
  DefaultMaxJsonRecordBytes* = 1024 * 1024
  JsonRecordSeparator* = '\x1e'

type
  JsonStreamFormat* = enum
    jsfNdjson,
    jsfJsonSequence

  JsonStreamParserOptions* = object
    maxRecordBytes*: int
    ## NDJSON permits parsers to ignore empty lines when documented and
    ## configurable. Joubako does so by default.
    ignoreEmptyNdjsonLines*: bool
    ## The NDJSON encoder requires a final LF. Enable this only for peers that
    ## emit a final JSON text at EOF without its required delimiter.
    allowUnterminatedNdjsonRecord*: bool
    ## Invalid records fail closed by default. Explicitly enabling recovery
    ## skips malformed records and resumes at the next format delimiter.
    skipInvalidRecords*: bool

  JsonStreamParser* = ref object
    format*: JsonStreamFormat
    options*: JsonStreamParserOptions
    pending: string
    sequenceStarted: bool
    sequenceRecordComplete: bool
    finished: bool

  JsonRecordProc*[T] = proc(record: T) {.closure.}
  AsyncJsonRecordProc*[T] = proc(record: T): Future[void] {.closure.}

  JsonStreamOptions* = object
    parser*: JsonStreamParserOptions
    requireContentType*: bool

  JsonStreamRequestState[T] = ref object
    parser: JsonStreamParser
    handler: AsyncJsonRecordProc[T]
    active: bool
    validationError: ref JoubakoError
    path: string

func defaultJsonStreamParserOptions*(): JsonStreamParserOptions =
  JsonStreamParserOptions(
    maxRecordBytes: DefaultMaxJsonRecordBytes,
    ignoreEmptyNdjsonLines: true
  )

func defaultJsonStreamOptions*(): JsonStreamOptions =
  JsonStreamOptions(
    parser: defaultJsonStreamParserOptions(),
    requireContentType: true
  )

func newJsonStreamParser*(format: JsonStreamFormat;
    options = defaultJsonStreamParserOptions()): JsonStreamParser =
  JsonStreamParser(format: format, options: options)

func mediaType*(format: JsonStreamFormat): string =
  case format
  of jsfNdjson: NdjsonMediaType
  of jsfJsonSequence: JsonSequenceMediaType

proc streamError(kind: ErrorKind; message: string): ref JoubakoError =
  newJoubakoError(kind, message)

proc checkPendingLimit(parser: JsonStreamParser): ref JoubakoError =
  let delimiterBytes =
    if parser.pending.len > 0 and parser.pending[^1] == '\n': 1 else: 0
  if parser.options.maxRecordBytes >= 0 and
      parser.pending.len - delimiterBytes > parser.options.maxRecordBytes:
    streamError(jeBodyTooLarge, "JSON stream record exceeded the configured limit")
  else:
    nil

proc decodeRecord(parser: JsonStreamParser; payload: string;
    requireNumberLf = false): JResult[Option[JsonNode]] =
  var source = payload
  if source.len > 0 and source[^1] == '\n':
    source.setLen(source.len - 1)
  if source.len > 0 and source[^1] == '\r':
    source.setLen(source.len - 1)
  if source.validateUtf8 >= 0:
    if parser.options.skipInvalidRecords:
      return ok(none(JsonNode))
    return err[Option[JsonNode]](streamError(
      jeCodec, "JSON stream record is not valid UTF-8"
    ))
  source = strutils.strip(source)
  if source.len == 0:
    if parser.format == jsfNdjson and
        not parser.options.ignoreEmptyNdjsonLines:
      return err[Option[JsonNode]](streamError(
        jeCodec, "empty NDJSON record is not allowed"
      ))
    return ok(none(JsonNode))
  try:
    let decoded = source.parseJson
    if requireNumberLf and decoded.kind in {JInt, JFloat} and
        not payload.endsWith("\n"):
      if parser.options.skipInvalidRecords:
        return ok(none(JsonNode))
      return err[Option[JsonNode]](streamError(
        jeCodec, "JSON Sequence number may be truncated because LF is missing"
      ))
    ok(some(decoded))
  except CatchableError as error:
    if parser.options.skipInvalidRecords:
      return ok(none(JsonNode))
    err[Option[JsonNode]](streamError(
      jeCodec, "could not decode JSON stream record: " & error.msg
    ))

proc addDecoded(records: var seq[JsonNode];
    decoded: JResult[Option[JsonNode]]): ref JoubakoError =
  if decoded.isErr:
    return decoded.error
  if decoded.value.isSome:
    records.add(decoded.value.get)
  nil

proc feedNdjson(parser: JsonStreamParser; chunk: string):
    JResult[seq[JsonNode]] =
  parser.pending.add(chunk)
  var records: seq[JsonNode]
  var lineStart = 0
  for index, character in parser.pending:
    if character != '\n':
      continue
    let line = parser.pending[lineStart .. index]
    var recordBytes = line.len - 1
    if recordBytes > 0 and line[recordBytes - 1] == '\r':
      dec recordBytes
    if parser.options.maxRecordBytes >= 0 and
        recordBytes > parser.options.maxRecordBytes:
      return err[seq[JsonNode]](streamError(
        jeBodyTooLarge, "JSON stream record exceeded the configured limit"
      ))
    let failure = records.addDecoded(parser.decodeRecord(line))
    if failure != nil:
      return err[seq[JsonNode]](failure)
    lineStart = index + 1
  if lineStart > 0:
    parser.pending.delete(0 .. lineStart - 1)
  let limitError = parser.checkPendingLimit()
  if limitError != nil:
    return err[seq[JsonNode]](limitError)
  ok(move(records))

proc tryCompleteSequenceRecord(parser: JsonStreamParser;
    records: var seq[JsonNode]): ref JoubakoError =
  ## LF is an encoder terminator. A successful parse here permits immediate
  ## delivery; an unsuccessful parse may simply be pretty-printed JSON whose
  ## later lines have not arrived yet, so it is deferred until RS or EOF.
  if parser.pending.len == 0 or parser.pending[^1] != '\n':
    return nil
  var source = parser.pending
  source.setLen(source.len - 1)
  if source.validateUtf8 >= 0:
    return nil
  if strutils.strip(source).len == 0:
    return nil
  try:
    records.add(source.parseJson)
    parser.pending.setLen(0)
    parser.sequenceRecordComplete = true
  except CatchableError:
    discard
  nil

proc completeSequenceAtDelimiter(parser: JsonStreamParser;
    records: var seq[JsonNode]): ref JoubakoError =
  if parser.sequenceRecordComplete or parser.pending.len == 0:
    parser.pending.setLen(0)
    parser.sequenceRecordComplete = false
    return nil
  let decoded = parser.decodeRecord(parser.pending, requireNumberLf = true)
  parser.pending.setLen(0)
  parser.sequenceRecordComplete = false
  records.addDecoded(decoded)

proc feedJsonSequence(parser: JsonStreamParser; chunk: string):
    JResult[seq[JsonNode]] =
  var records: seq[JsonNode]
  for character in chunk:
    if character == JsonRecordSeparator:
      if parser.sequenceStarted:
        let failure = parser.completeSequenceAtDelimiter(records)
        if failure != nil:
          return err[seq[JsonNode]](failure)
      else:
        parser.sequenceStarted = true
      continue
    if not parser.sequenceStarted:
      return err[seq[JsonNode]](streamError(
        jeCodec, "JSON Sequence data appeared before the first record separator"
      ))
    if parser.sequenceRecordComplete:
      if character in {' ', '\t', '\r', '\n'}:
        continue
      return err[seq[JsonNode]](streamError(
        jeCodec, "JSON Sequence data appeared after a completed record"
      ))
    parser.pending.add(character)
    if character == '\n':
      let failure = parser.tryCompleteSequenceRecord(records)
      if failure != nil:
        return err[seq[JsonNode]](failure)
    let limitError = parser.checkPendingLimit()
    if limitError != nil:
      return err[seq[JsonNode]](limitError)
  ok(move(records))

proc feed*(parser: JsonStreamParser; chunk: string):
    JResult[seq[JsonNode]] =
  if parser == nil:
    return err[seq[JsonNode]](streamError(
      jeInvalidRequest, "JSON stream parser is nil"
    ))
  if parser.finished:
    return err[seq[JsonNode]](streamError(
      jeInvalidRequest, "JSON stream parser is already finished"
    ))
  case parser.format
  of jsfNdjson:
    parser.feedNdjson(chunk)
  of jsfJsonSequence:
    parser.feedJsonSequence(chunk)

proc finish*(parser: JsonStreamParser): JResult[seq[JsonNode]] =
  if parser == nil:
    return err[seq[JsonNode]](streamError(
      jeInvalidRequest, "JSON stream parser is nil"
    ))
  if parser.finished:
    return err[seq[JsonNode]](streamError(
      jeInvalidRequest, "JSON stream parser is already finished"
    ))
  parser.finished = true
  var records: seq[JsonNode]
  case parser.format
  of jsfNdjson:
    if parser.pending.len == 0:
      return ok(move(records))
    if not parser.options.allowUnterminatedNdjsonRecord:
      return err[seq[JsonNode]](streamError(
        jeCodec, "NDJSON stream ended before the required LF delimiter"
      ))
    let failure = records.addDecoded(parser.decodeRecord(parser.pending))
    parser.pending.setLen(0)
    if failure != nil:
      return err[seq[JsonNode]](failure)
  of jsfJsonSequence:
    if not parser.sequenceStarted:
      if parser.pending.len == 0:
        return ok(move(records))
      return err[seq[JsonNode]](streamError(
        jeCodec, "JSON Sequence is missing a record separator"
      ))
    let failure = parser.completeSequenceAtDelimiter(records)
    if failure != nil:
      return err[seq[JsonNode]](failure)
  ok(move(records))

proc encodeJsonStream*[T](records: openArray[T];
    format: JsonStreamFormat): JResult[string] =
  var stream: string
  try:
    for record in records:
      let encoded = $toJson(record)
      if encoded.validateUtf8 >= 0:
        return err[string](streamError(
          jeCodec, "encoded JSON stream record is not valid UTF-8"
        ))
      case format
      of jsfNdjson:
        stream.add encoded
        stream.add '\n'
      of jsfJsonSequence:
        stream.add JsonRecordSeparator
        stream.add encoded
        stream.add '\n'
  except CatchableError as error:
    return err[string](streamError(
      jeCodec, "could not encode JSON stream record: " & error.msg
    ))
  ok(move(stream))

proc encodeNdjson*[T](records: openArray[T]): JResult[string] =
  encodeJsonStream(records, jsfNdjson)

proc encodeJsonSequence*[T](records: openArray[T]): JResult[string] =
  encodeJsonStream(records, jsfJsonSequence)

func responseHasMediaType(headers: Headers; format: JsonStreamFormat): bool =
  let actual = headers.get("content-type").split(';', 1)[0]
    .strip.toLowerAscii
  case format
  of jsfNdjson:
    actual in [NdjsonMediaType, "application/ndjson"]
  of jsfJsonSequence:
    actual == JsonSequenceMediaType

proc deliver[T](state: JsonStreamRequestState[T];
    records: seq[JsonNode]): Future[void] {.async.} =
  for node in records:
    var record: T
    try:
      record = node.jsonTo(T)
    except CatchableError as error:
      raise newJoubakoError(
        jeCodec,
        "could not decode JSON stream record: " & error.msg,
        state.path
      )
    var pending: Future[void]
    try:
      pending = state.handler(move(record))
    except CatchableError as error:
      raise error.asJoubakoError(jeStream, state.path)
    if pending == nil:
      raise newJoubakoError(
        jeStream, "JSON stream handler returned a nil Future", state.path
      )
    let handled = await settle(fallible(pending), jeStream, state.path)
    if handled.isErr:
      raise handled.error

proc jsonStreamHeadersHandler[T](state: JsonStreamRequestState[T];
    prior: ResponseHeadersProc; format: JsonStreamFormat;
    requireContentType: bool): ResponseHeadersProc =
  result = proc(status: int; headers: Headers) =
    if not prior.isNil:
      try:
        prior(status, headers)
      except CatchableError as error:
        state.validationError = error.asJoubakoError(jeStream, state.path)
        return
    if status < 200 or status >= 300:
      return
    if requireContentType and not headers.responseHasMediaType(format):
      state.validationError = newJoubakoError(
        jeCodec,
        "JSON stream response Content-Type does not match " & format.mediaType,
        state.path,
        status
      )
      return
    state.active = true

proc jsonStreamChunkHandler[T](state: JsonStreamRequestState[T];
    prior: AsyncDownloadChunkProc): AsyncDownloadChunkProc =
  result = proc(chunk: string): Future[void] {.async.} =
    if not prior.isNil:
      var pending: Future[void]
      try:
        pending = prior(chunk)
      except CatchableError as error:
        raise error.asJoubakoError(jeStream, state.path)
      if pending == nil:
        raise newJoubakoError(
          jeStream,
          "prior asynchronous download consumer returned a nil Future",
          state.path
        )
      let consumed = await settle(fallible(pending), jeStream, state.path)
      if consumed.isErr:
        raise consumed.error
    if not state.active:
      return
    let decoded = state.parser.feed(chunk)
    if decoded.isErr:
      raise decoded.error
    await state.deliver(decoded.value)

proc streamJsonRecordsAsync*[T](client: Client; httpMethod: RequestMethod;
    path, body: string; format: JsonStreamFormat; _: typedesc[T];
    handler: AsyncJsonRecordProc[T]; headers = initHeaders();
    requestOptions = RequestOptions();
    streamOptions = defaultJsonStreamOptions()
): Future[JResult[void]] {.async.} =
  if handler.isNil:
    return err[void](newJoubakoError(
      jeInvalidRequest, "JSON stream handler is nil", path
    ))
  if streamOptions.parser.maxRecordBytes < -1:
    return err[void](newJoubakoError(
      jeInvalidRequest, "JSON stream record limit must be -1 or greater", path
    ))

  var requestHeaders = headers
  if not requestHeaders.contains("accept"):
    requestHeaders.set("accept", format.mediaType)
  if body.len > 0 and not requestHeaders.contains("content-type"):
    requestHeaders.set("content-type", format.mediaType)

  let state = JsonStreamRequestState[T](
    parser: newJsonStreamParser(format, streamOptions.parser),
    handler: handler,
    path: path
  )
  var options = requestOptions
  options.streamResponse = true
  options.onResponseHeaders = jsonStreamHeadersHandler(
    state, requestOptions.onResponseHeaders, format,
    streamOptions.requireContentType
  )
  options.onDownloadChunkAsync = jsonStreamChunkHandler(
    state, requestOptions.onDownloadChunkAsync
  )

  let response = await client.request(
    httpMethod, path, body, requestHeaders, options
  )
  if state.validationError != nil:
    return err[void](move(state.validationError))
  if response.isErr:
    return err[void](response.error)
  let finalRecords = state.parser.finish()
  if finalRecords.isErr:
    if finalRecords.error.url.len == 0:
      finalRecords.error.url = path
    return err[void](finalRecords.error)
  let delivered = await settle(
    fallible(state.deliver(finalRecords.value)), jeStream, path
  )
  if delivered.isErr:
    return err[void](delivered.error)
  ok()

proc streamJsonRecords*[T](client: Client; httpMethod: RequestMethod;
    path, body: string; format: JsonStreamFormat; _: typedesc[T];
    handler: JsonRecordProc[T]; headers = initHeaders();
    requestOptions = RequestOptions();
    streamOptions = defaultJsonStreamOptions()
): Future[JResult[void]] =
  if handler.isNil:
    return completedResult(err[void](newJoubakoError(
      jeInvalidRequest, "JSON stream handler is nil", path
    )))
  let asyncHandler = proc(record: T): Future[void] {.async.} =
    handler(record)
  streamJsonRecordsAsync(
    client, httpMethod, path, body, format, T, asyncHandler,
    headers, requestOptions, streamOptions
  )

proc getNdjsonAsync*[T](client: Client; path: string; _: typedesc[T];
    handler: AsyncJsonRecordProc[T]; headers = initHeaders();
    requestOptions = RequestOptions();
    streamOptions = defaultJsonStreamOptions()
): Future[JResult[void]] =
  streamJsonRecordsAsync(
    client, rmGet, path, "", jsfNdjson, T, handler,
    headers, requestOptions, streamOptions
  )

proc getNdjson*[T](client: Client; path: string; _: typedesc[T];
    handler: JsonRecordProc[T]; headers = initHeaders();
    requestOptions = RequestOptions();
    streamOptions = defaultJsonStreamOptions()
): Future[JResult[void]] =
  streamJsonRecords(
    client, rmGet, path, "", jsfNdjson, T, handler,
    headers, requestOptions, streamOptions
  )

proc getJsonSequenceAsync*[T](client: Client; path: string; _: typedesc[T];
    handler: AsyncJsonRecordProc[T]; headers = initHeaders();
    requestOptions = RequestOptions();
    streamOptions = defaultJsonStreamOptions()
): Future[JResult[void]] =
  streamJsonRecordsAsync(
    client, rmGet, path, "", jsfJsonSequence, T, handler,
    headers, requestOptions, streamOptions
  )

proc getJsonSequence*[T](client: Client; path: string; _: typedesc[T];
    handler: JsonRecordProc[T]; headers = initHeaders();
    requestOptions = RequestOptions();
    streamOptions = defaultJsonStreamOptions()
): Future[JResult[void]] =
  streamJsonRecords(
    client, rmGet, path, "", jsfJsonSequence, T, handler,
    headers, requestOptions, streamOptions
  )

proc postNdjsonAsync*[TBody, TResponse](client: Client; path: string;
    records: openArray[TBody]; _: typedesc[TResponse];
    handler: AsyncJsonRecordProc[TResponse]; headers = initHeaders();
    requestOptions = RequestOptions();
    streamOptions = defaultJsonStreamOptions()
): Future[JResult[void]] =
  let encoded = encodeNdjson(records)
  if encoded.isErr:
    return completedResult(err[void](encoded.error))
  streamJsonRecordsAsync(
    client, rmPost, path, encoded.value, jsfNdjson, TResponse, handler,
    headers, requestOptions, streamOptions
  )

proc postNdjson*[TBody, TResponse](client: Client; path: string;
    records: openArray[TBody]; _: typedesc[TResponse];
    handler: JsonRecordProc[TResponse]; headers = initHeaders();
    requestOptions = RequestOptions();
    streamOptions = defaultJsonStreamOptions()
): Future[JResult[void]] =
  let encoded = encodeNdjson(records)
  if encoded.isErr:
    return completedResult(err[void](encoded.error))
  streamJsonRecords(
    client, rmPost, path, encoded.value, jsfNdjson, TResponse, handler,
    headers, requestOptions, streamOptions
  )

proc postJsonSequenceAsync*[TBody, TResponse](client: Client; path: string;
    records: openArray[TBody]; _: typedesc[TResponse];
    handler: AsyncJsonRecordProc[TResponse]; headers = initHeaders();
    requestOptions = RequestOptions();
    streamOptions = defaultJsonStreamOptions()
): Future[JResult[void]] =
  let encoded = encodeJsonSequence(records)
  if encoded.isErr:
    return completedResult(err[void](encoded.error))
  streamJsonRecordsAsync(
    client, rmPost, path, encoded.value, jsfJsonSequence, TResponse, handler,
    headers, requestOptions, streamOptions
  )

proc postJsonSequence*[TBody, TResponse](client: Client; path: string;
    records: openArray[TBody]; _: typedesc[TResponse];
    handler: JsonRecordProc[TResponse]; headers = initHeaders();
    requestOptions = RequestOptions();
    streamOptions = defaultJsonStreamOptions()
): Future[JResult[void]] =
  let encoded = encodeJsonSequence(records)
  if encoded.isErr:
    return completedResult(err[void](encoded.error))
  streamJsonRecords(
    client, rmPost, path, encoded.value, jsfJsonSequence, TResponse, handler,
    headers, requestOptions, streamOptions
  )
