import std/[asyncdispatch, times]
import ../[transport, types]

type
  FaultKind* = enum
    fkPassThrough,
    fkTransportError,
    fkTimeout,
    fkHttpStatus,
    fkDelay

  FaultStep* = object
    kind*: FaultKind
    message*: string
    status*: int
    statusText*: string
    headers*: Headers
    body*: string
    delay*: Duration

  FaultInjectingTransport* = ref object of Transport
    delegate*: Transport
    steps*: seq[FaultStep]
    repeatLast*: bool
    callCount*: int
    nextStep: int

func transportFault*(message = "injected transport failure"): FaultStep =
  FaultStep(kind: fkTransportError, message: message)

func timeoutFault*(message = "injected timeout"): FaultStep =
  FaultStep(kind: fkTimeout, message: message)

func statusFault*(status: int; body = ""; headers = initHeaders()): FaultStep =
  FaultStep(kind: fkHttpStatus, status: status, headers: headers, body: body)

func delayFault*(delay: Duration): FaultStep =
  FaultStep(kind: fkDelay, delay: delay)

func passThrough*(): FaultStep =
  FaultStep(kind: fkPassThrough)

func newFaultInjectingTransport*(
    delegate: Transport;
    steps: openArray[FaultStep];
    repeatLast = false
): FaultInjectingTransport =
  FaultInjectingTransport(
    delegate: delegate,
    steps: @steps,
    repeatLast: repeatLast
  )

method usesImplicitCredentials*(transport: FaultInjectingTransport): bool =
  transport != nil and transport.delegate != nil and
    transport.delegate.usesImplicitCredentials

proc chooseStep(transport: FaultInjectingTransport): FaultStep =
  inc transport.callCount
  if transport.steps.len == 0:
    return passThrough()
  if transport.nextStep < transport.steps.len:
    result = transport.steps[transport.nextStep]
    inc transport.nextStep
  elif transport.repeatLast:
    result = transport.steps[^1]
  else:
    result = passThrough()

method send*(
    transport: FaultInjectingTransport;
    request: Request
): Future[Response] {.async.} =
  if transport == nil:
    raise newJoubakoError(jeInvalidRequest, "fault transport is nil", request.url)
  let step = transport.chooseStep()
  case step.kind
  of fkTransportError:
    raise newJoubakoError(jeTransport, step.message, request.url)
  of fkTimeout:
    raise newJoubakoError(jeTimeout, step.message, request.url)
  of fkHttpStatus:
    return Response(
      status: step.status,
      statusText: step.statusText,
      headers: step.headers,
      body: step.body,
      request: request
    )
  of fkDelay:
    let delayMs = max(0, int(step.delay.inMilliseconds))
    let deadlineWins = request.options.timeoutMs >= 0 and
      delayMs > request.options.timeoutMs
    let waitMs =
      if deadlineWins: request.options.timeoutMs else: delayMs
    let sleeping = sleepAsync(waitMs)
    if request.options.cancellation != nil:
      let cancelled = request.options.cancellation.cancellationFuture()
      await (sleeping or cancelled)
      if request.options.cancellation.cancelled and not sleeping.finished:
        raise newJoubakoError(
          jeCancelled,
          request.options.cancellation.reason,
          request.url
        )
    else:
      await sleeping
    if deadlineWins:
      raise newJoubakoError(
        jeTimeout, "injected delay exceeded request deadline", request.url
      )
  of fkPassThrough:
    discard
  if transport.delegate == nil:
    raise newJoubakoError(
      jeInvalidRequest,
      "fault transport has no delegate for pass-through",
      request.url
    )
  return await transport.delegate.send(request)
