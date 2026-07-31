import std/[asyncdispatch, times, unittest]
import flowbrigade/[backoff, retry]

suite "FlowBrigade dependency":
  test "the declared async retry API is available":
    var attempts = 0
    let policy = fixedBackoff(initDuration(milliseconds = 1))

    proc operation(): Future[int] {.async.} =
      inc attempts
      return 42

    let value = waitFor retryAsync(
      policy = policy,
      maxAttempts = 1,
      operation = operation
    )

    check value == 42
    check attempts == 1
