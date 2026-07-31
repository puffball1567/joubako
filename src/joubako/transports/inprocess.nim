import std/asyncdispatch
import ../[transport, types]

type
  InProcessHandler* = proc(request: Request): Future[Response] {.closure.}

  InProcessTransport* = ref object of Transport
    handler: InProcessHandler

func newInProcessTransport*(handler: InProcessHandler): InProcessTransport =
  InProcessTransport(handler: handler)

method send*(
    transport: InProcessTransport;
    request: Request
): Future[Response] =
  if request.options.cancellation != nil and
      request.options.cancellation.cancelled:
    result = newFuture[Response]("Joubako.InProcessTransport.cancelled")
    result.fail(newJoubakoError(
      jeCancelled,
      request.options.cancellation.reason,
      request.url
    ))
  else:
    result = transport.handler(request)
