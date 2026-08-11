## High-level streaming helpers.

import std/[asyncdispatch, os, strutils]
when defined(windows):
  import std/asyncfile
import ./[client, result, types]

type FileDownloadConsumerState = ref object
  when defined(windows):
    output: AsyncFile
  else:
    output: File
  previous: AsyncDownloadChunkProc
  requestPath: string

type ResumeHeaderState = ref object
  expectedOffset: int64
  requestPath: string
  previous: ResponseHeadersProc

type ResumeProgressState = ref object
  offset: int64
  previous: ProgressProc

proc newFileDownloadConsumer(
    state: FileDownloadConsumerState
): AsyncDownloadChunkProc =
  ## Construct outside the owning request's async frame so ARC has no
  ## frame -> options -> callback -> frame cycle.
  result = proc(chunk: string): Future[void] {.async.} =
    if not state.previous.isNil:
      let previousPending = state.previous(chunk)
      if previousPending == nil:
        raise newJoubakoError(
          jeStream,
          "asynchronous download consumer returned a nil Future",
          state.requestPath
        )
      let previousResult = await settle(
        fallible(previousPending), jeStream, state.requestPath
      )
      if previousResult.isErr:
        raise previousResult.error
    when defined(windows):
      await state.output.write(chunk)
    else:
      # POSIX asyncfile performs the regular-file write immediately too, but
      # additionally retains the process-global async dispatcher under ARC.
      # A bounded response chunk keeps this equivalent write small and avoids
      # taking ownership of application-global event-loop state.
      state.output.write(chunk)

proc invalidResume(state: ResumeHeaderState; message: string): ref JoubakoError =
  newJoubakoError(jeStream, message, state.requestPath)

proc validateContentRange(state: ResumeHeaderState; value: string) =
  let fields = value.strip.splitWhitespace()
  if fields.len != 2 or fields[0].toLowerAscii != "bytes":
    raise state.invalidResume("resume response has an invalid Content-Range")
  let rangeAndTotal = fields[1].split('/', 1)
  if rangeAndTotal.len != 2:
    raise state.invalidResume("resume response has an invalid Content-Range")
  let bounds = rangeAndTotal[0].split('-', 1)
  if bounds.len != 2 or bounds[0].len == 0 or bounds[1].len == 0:
    raise state.invalidResume("resume response has an invalid Content-Range")
  var first, last: int64
  try:
    first = bounds[0].parseBiggestInt
    last = bounds[1].parseBiggestInt
  except ValueError:
    raise state.invalidResume("resume response has an invalid Content-Range")
  if first != state.expectedOffset:
    raise state.invalidResume(
      "resume response starts at " & $first & " instead of " &
        $state.expectedOffset
    )
  if last < first:
    raise state.invalidResume("resume response has reversed byte bounds")
  if rangeAndTotal[1] != "*":
    var total: int64
    try:
      total = rangeAndTotal[1].parseBiggestInt
    except ValueError:
      raise state.invalidResume("resume response has an invalid total size")
    if total <= last:
      raise state.invalidResume("resume response total does not exceed its last byte")

proc newResumeHeaderValidator(state: ResumeHeaderState): ResponseHeadersProc =
  result = proc(status: int; headers: Headers) =
    if not state.previous.isNil:
      state.previous(status, headers)
    if status != 206:
      raise state.invalidResume(
        "server did not honor the resume Range request (expected HTTP 206, got " &
          $status & ")"
      )
    let contentEncoding = headers.get("content-encoding").strip.toLowerAscii
    if contentEncoding.len > 0 and contentEncoding != "identity":
      raise state.invalidResume(
        "resume response must use identity content encoding"
      )
    state.validateContentRange(headers.get("content-range"))

proc newResumeProgress(state: ResumeProgressState): ProgressProc =
  result = proc(received, total: int64) =
    state.previous(
      state.offset + received,
      if total < 0: total else: state.offset + total
    )

proc downloadToFile*(
    client: Client;
    path: string;
    outputPath: string;
    headers = initHeaders();
    options = RequestOptions()
): Future[JResult[Response]] {.async.} =
  ## Streams a response directly to a newly truncated file. A partial file is
  ## retained when the request or write fails so callers can inspect or resume
  ## it explicitly.
  if outputPath.len == 0:
    return err[Response](newJoubakoError(
      jeInvalidRequest, "download output path is empty", path
    ))

  when defined(windows):
    var output: AsyncFile
    try:
      output = openAsync(outputPath, fmWrite)
    except CatchableError as error:
      return err[Response](error.asJoubakoError(jeStream, path))
  else:
    var output: File
    try:
      if not open(output, outputPath, fmWrite):
        return err[Response](newJoubakoError(
          jeStream, "could not open download output file", path
        ))
    except CatchableError as error:
      return err[Response](error.asJoubakoError(jeStream, path))
  defer:
    output.close()

  var streamingOptions = options
  # A transport retry after bytes have reached the file could write the same
  # representation twice. Callers can safely retry through resumeDownloadToFile.
  streamingOptions.retry.maxAttempts = 1
  let previousConsumer = options.onDownloadChunkAsync
  streamingOptions.streamResponse = true
  let consumerState = FileDownloadConsumerState(
    output: output,
    previous: previousConsumer,
    requestPath: path
  )
  streamingOptions.onDownloadChunkAsync =
    newFileDownloadConsumer(consumerState)

  let outcome = await client.get(path, headers, streamingOptions)
  if outcome.isErr:
    return err[Response](outcome.error)

  var response = outcome.value
  response.request.options.onDownloadChunkAsync = previousConsumer
  return ok(response)

proc resumeDownloadToFile*(
    client: Client;
    path: string;
    outputPath: string;
    ifRange = "";
    headers = initHeaders();
    options = RequestOptions()
): Future[JResult[Response]] {.async.} =
  ## Continues an existing partial file with a validated HTTP Range request.
  ## A non-empty `ifRange` should be the ETag or Last-Modified value retained
  ## with the partial download. The existing file is never truncated when the
  ## peer ignores Range or returns inconsistent response metadata.
  if outputPath.len == 0:
    return err[Response](newJoubakoError(
      jeInvalidRequest, "download output path is empty", path
    ))
  if not fileExists(outputPath):
    return await client.downloadToFile(path, outputPath, headers, options)

  var offset: int64
  try:
    offset = getFileSize(outputPath)
  except CatchableError as error:
    return err[Response](error.asJoubakoError(jeStream, path))
  if offset == 0:
    return await client.downloadToFile(path, outputPath, headers, options)

  when defined(windows):
    var output: AsyncFile
    try:
      output = openAsync(outputPath, fmAppend)
    except CatchableError as error:
      return err[Response](error.asJoubakoError(jeStream, path))
  else:
    var output: File
    try:
      if not open(output, outputPath, fmAppend):
        return err[Response](newJoubakoError(
          jeStream, "could not open partial download file", path
        ))
    except CatchableError as error:
      return err[Response](error.asJoubakoError(jeStream, path))
  defer:
    output.close()

  var resumeHeaders = initHeaders()
  resumeHeaders.merge(headers)
  resumeHeaders.set("range", "bytes=" & $offset & "-")
  resumeHeaders.set("accept-encoding", "identity")
  if ifRange.len > 0:
    resumeHeaders.set("if-range", ifRange)

  var streamingOptions = options
  streamingOptions.retry.maxAttempts = 1
  streamingOptions.streamResponse = true
  let previousConsumer = options.onDownloadChunkAsync
  let previousHeaders = options.onResponseHeaders
  let consumerState = FileDownloadConsumerState(
    output: output,
    previous: previousConsumer,
    requestPath: path
  )
  streamingOptions.onDownloadChunkAsync =
    newFileDownloadConsumer(consumerState)
  let headerState = ResumeHeaderState(
    expectedOffset: offset,
    requestPath: path,
    previous: previousHeaders
  )
  streamingOptions.onResponseHeaders = newResumeHeaderValidator(headerState)

  if not options.onDownloadProgress.isNil:
    streamingOptions.onDownloadProgress = newResumeProgress(
      ResumeProgressState(offset: offset, previous: options.onDownloadProgress)
    )

  let outcome = await client.get(path, resumeHeaders, streamingOptions)
  if outcome.isErr:
    return err[Response](outcome.error)

  var response = outcome.value
  response.request.options.onDownloadChunkAsync = previousConsumer
  response.request.options.onResponseHeaders = previousHeaders
  response.request.options.onDownloadProgress = options.onDownloadProgress
  return ok(response)
