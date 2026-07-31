## Shared download-consumer dispatch for streaming transports.

import std/asyncdispatch
import ./[result, types]

proc consumeDownloadChunk*(
    request: Request;
    chunk: string
): Future[void] {.async.} =
  ## Synchronous delivery runs first for compatibility. The asynchronous
  ## consumer is then awaited before the transport reads another chunk.
  try:
    if not request.options.onDownloadChunk.isNil:
      request.options.onDownloadChunk(chunk)
  except CatchableError as error:
    raise error.asJoubakoError(jeStream, request.url)

  if not request.options.onDownloadChunkAsync.isNil:
    var pending: Future[void]
    try:
      pending = request.options.onDownloadChunkAsync(chunk)
    except CatchableError as error:
      raise error.asJoubakoError(jeStream, request.url)
    if pending == nil:
      raise newJoubakoError(
        jeStream,
        "asynchronous download consumer returned a nil Future",
        request.url
      )
    let consumed = await settle(fallible(pending), jeStream, request.url)
    if consumed.isErr:
      raise consumed.error

  if request.options.cancellation != nil and
      request.options.cancellation.cancelled:
    raise newJoubakoError(
      jeCancelled,
      request.options.cancellation.reason,
      request.url
    )
