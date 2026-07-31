import std/[asyncdispatch, math, parseutils, times]
import flowbrigade/[retry, timeout]
import ./types

const DefaultRetryStatuses* = [
  408, 425, 429, 500, 502, 503, 504
]

func isMethodIdempotent*(
    httpMethod: RequestMethod;
    mode = imDefault
): bool =
  case mode
  of imIdempotent:
    true
  of imNonIdempotent:
    false
  of imDefault:
    httpMethod in {rmGet, rmHead, rmPut, rmDelete, rmOptions}

func isRetryStatus*(status: int): bool =
  status in DefaultRetryStatuses

func shouldRetryHttpError*(
    request: Request;
    error: ref CatchableError;
    attempt: int
): bool =
  discard attempt
  if not request.httpMethod.isMethodIdempotent(request.options.retry.idempotency):
    return false
  if not (error of JoubakoError):
    return false

  let requestError = cast[ref JoubakoError](error)
  case requestError.kind
  of jeTransport, jeTimeout:
    true
  of jeHttpStatus:
    requestError.status.isRetryStatus
  else:
    false

proc parseRetryAfterMs*(value: string; now = getTime()): int64 =
  ## Parses either delta-seconds or the IMF-fixdate form used by HTTP.
  if value.len == 0:
    return -1

  var seconds: int
  let parsed = parseInt(value, seconds)
  if parsed == value.len and seconds >= 0:
    return int64(seconds) * 1_000

  try:
    let retryAt = parse(
      value,
      "ddd, dd MMM yyyy HH:mm:ss 'GMT'",
      utc()
    ).toTime
    return max(0'i64, (retryAt - now).inMilliseconds)
  except TimeParseError:
    return -1

proc durationMillisecondsCeil*(duration: Duration): int =
  let nanos = duration.inNanoseconds
  if nanos <= 0:
    return 0
  int(min(int64(high(int)), (nanos + 999_999'i64) div 1_000_000'i64))

proc retrySleep*(
    delay: Duration;
    retryAfterMs: int64;
    cancellation: CancellationToken;
    sleep: AsyncSleepProc = sleepDurationAsync;
    deadline = Deadline()
): Future[void] {.async.} =
  let policyMs = delay.durationMillisecondsCeil
  var waitMs = max(
    policyMs,
    int(min(int64(high(int)), max(0'i64, retryAfterMs)))
  )
  if deadline.isInitialized:
    waitMs = min(waitMs, deadline.remaining.durationMillisecondsCeil)
  if waitMs <= 0:
    return

  let sleeping = sleep(initDuration(milliseconds = waitMs))
  if cancellation == nil:
    await sleeping
    return

  let cancelled = cancellation.cancellationFuture()
  await (sleeping or cancelled)
  if cancellation.cancelled and not sleeping.finished:
    raise newJoubakoError(
      jeCancelled,
      cancellation.reason
    )
