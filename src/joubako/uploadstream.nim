## Bounded, producer-driven HTTP upload streams.
##
## The producer-facing API is push based while transports consume it through
## `UploadSource`. This keeps queued memory bounded and gives `send` genuine
## asynchronous backpressure.

import std/asyncdispatch
import ./[client, result, types]

type
  UploadState = ref object
    chunks: seq[string]
    headOffset: int
    queuedBytes: int
    acceptedBytes: int64
    maxBufferedBytes: int
    maxRequestBytes: int
    closed: bool
    terminal: bool
    sending: bool
    failure: ref JoubakoError
    wake: UploadWakeProc
    spaceSignal: Future[void]

  UploadStream* = ref object
    ## A single-producer asynchronous upload. Only one `send` may be in flight.
    state: UploadState
    response: Future[JResult[Response]]
    cancellation: CancellationToken
    url: string

proc notifySpace(state: UploadState) =
  if state.spaceSignal != nil and not state.spaceSignal.finished:
    state.spaceSignal.complete()

proc notifyTransport(state: UploadState) =
  if state.wake != nil:
    state.wake()

proc failState(state: UploadState; error: ref JoubakoError) =
  if state.failure == nil:
    state.failure = error
  state.closed = true
  state.notifySpace()
  state.notifyTransport()

proc sourceFor(state: UploadState): UploadSource =
  result = UploadSource()
  result.read = proc(buffer: pointer; capacity: int): int =
    if state.failure != nil:
      return UploadReadAbort
    if capacity <= 0:
      return UploadReadPause
    if state.chunks.len == 0:
      if state.closed:
        return UploadReadEof
      return UploadReadPause
    let available = state.chunks[0].len - state.headOffset
    result = min(available, capacity)
    copyMem(buffer, state.chunks[0][state.headOffset].unsafeAddr, result)
    state.headOffset += result
    state.queuedBytes -= result
    if state.headOffset == state.chunks[0].len:
      state.chunks.delete(0)
      state.headOffset = 0
    state.notifySpace()
  result.setWake = proc(wake: UploadWakeProc) =
    state.wake = wake

proc openUpload*(
    client: Client;
    httpMethod: RequestMethod;
    path: string;
    headers = initHeaders();
    options = RequestOptions();
    maxBufferedBytes = 256 * 1024
): UploadStream =
  ## Starts a streaming request. `send` waits once the bounded queue is full;
  ## `finish` emits end-of-stream and returns the response.
  let state = UploadState(
    maxBufferedBytes: maxBufferedBytes,
    maxRequestBytes: options.maxRequestBytes
  )
  var effectiveOptions = options
  if effectiveOptions.cancellation == nil:
    effectiveOptions.cancellation = newCancellationToken()
  result = UploadStream(
    state: state,
    cancellation: effectiveOptions.cancellation,
    url: path
  )
  if maxBufferedBytes <= 0:
    let failure = newJoubakoError(
      jeInvalidRequest, "upload buffer limit must be positive", path
    )
    state.failState(failure)
    result.response = completedResult(err[Response](failure))
    return
  let source = state.sourceFor()
  result.response = client.requestUploadSource(
    httpMethod, path, source, headers, effectiveOptions
  )
  let pending = result.response
  pending.addCallback(proc() {.gcsafe.} =
    state.terminal = true
    state.closed = true
    state.notifySpace()
    state.notifyTransport()
  )

proc send*(stream: UploadStream; chunk: sink string): Future[JResult[void]] {.async.} =
  ## Queues bytes without exceeding `maxBufferedBytes`. A chunk larger than
  ## the queue is split internally while preserving byte order.
  if stream == nil or stream.state == nil:
    return err[void](newJoubakoError(
      jeInvalidRequest, "upload stream is nil"
    ))
  let state = stream.state
  if state.sending:
    return err[void](newJoubakoError(
      jeInvalidRequest, "concurrent send calls are not supported", stream.url
    ))
  if state.failure != nil:
    return err[void](state.failure)
  if state.closed or state.terminal:
    return err[void](newJoubakoError(
      jeStream, "upload stream is already closed", stream.url
    ))
  if state.maxRequestBytes > 0 and
      (state.acceptedBytes > state.maxRequestBytes.int64 or
       chunk.len.int64 > state.maxRequestBytes.int64 - state.acceptedBytes):
    let failure = newJoubakoError(
      jeBodyTooLarge, "streaming upload exceeded the configured limit", stream.url
    )
    state.failState(failure)
    return err[void](failure)

  state.sending = true
  defer: state.sending = false
  var offset = 0
  while offset < chunk.len:
    if state.failure != nil:
      return err[void](state.failure)
    if state.terminal or state.closed:
      return err[void](newJoubakoError(
        jeStream, "upload ended before all bytes were sent", stream.url
      ))
    let available = state.maxBufferedBytes - state.queuedBytes
    if available <= 0:
      if state.spaceSignal == nil or state.spaceSignal.finished:
        state.spaceSignal = newFuture[void]("Joubako.UploadStream.space")
      await state.spaceSignal
      continue
    let count = min(available, chunk.len - offset)
    state.chunks.add(chunk[offset ..< offset + count])
    state.queuedBytes += count
    state.acceptedBytes += count.int64
    offset += count
    state.notifyTransport()
  return ok()

proc finish*(stream: UploadStream): Future[JResult[Response]] {.async.} =
  ## Closes the request body and waits for the peer response.
  if stream == nil or stream.state == nil or stream.response == nil:
    return err[Response](newJoubakoError(
      jeInvalidRequest, "upload stream is nil"
    ))
  let state = stream.state
  if not state.closed:
    state.closed = true
    state.notifyTransport()
  let outcome = await stream.response
  stream.response.clearCallbacks()
  return outcome

proc cancel*(stream: UploadStream; reason = "upload cancelled") =
  if stream == nil or stream.state == nil:
    return
  stream.state.failState(newJoubakoError(
    jeCancelled, reason, stream.url
  ))
  stream.cancellation.cancel(reason)

func queuedBytes*(stream: UploadStream): int =
  if stream == nil or stream.state == nil: 0 else: stream.state.queuedBytes

func acceptedBytes*(stream: UploadStream): int64 =
  if stream == nil or stream.state == nil: 0 else: stream.state.acceptedBytes
