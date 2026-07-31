import std/asyncdispatch
import ../[chunkconsumer, transport, types]

type
  InProcessHandler* = proc(request: Request): Future[Response] {.closure.}

  InProcessTransport* = ref object of Transport
    handler: InProcessHandler

func newInProcessTransport*(handler: InProcessHandler): InProcessTransport =
  InProcessTransport(handler: handler)

method send*(
    transport: InProcessTransport;
    request: Request
): Future[Response] {.async.} =
  if request.options.cancellation != nil and
      request.options.cancellation.cancelled:
    raise newJoubakoError(
      jeCancelled,
      request.options.cancellation.reason,
      request.url
    )
  if transport.handler == nil:
    raise newJoubakoError(
      jeInvalidRequest, "in-process transport has no handler", request.url
    )

  if not request.options.onUploadProgress.isNil:
    request.options.onUploadProgress(
      int64(request.body.len), int64(request.body.len)
    )
  result = await transport.handler(request)
  if request.options.maxResponseBytes >= 0 and
      result.body.len > request.options.maxResponseBytes:
    raise newJoubakoError(
      jeBodyTooLarge,
      "in-process response body exceeded the configured limit",
      request.url,
      result.status
    )
  if result.body.len > 0:
    await request.consumeDownloadChunk(result.body)
  if not request.options.onDownloadProgress.isNil:
    request.options.onDownloadProgress(
      int64(result.body.len), int64(result.body.len)
    )
  if request.options.streamResponse:
    result.body = ""
