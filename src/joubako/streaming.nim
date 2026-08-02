## High-level streaming helpers.

import std/asyncdispatch
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
