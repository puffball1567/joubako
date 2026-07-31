import std/[asyncdispatch, unittest]
import joubako

proc rawSuccess(value: int): Future[int] =
  result = newFuture[int]("rawSuccess")
  result.complete(value)

proc rawFailure(message: string): Future[int] =
  result = newFuture[int]("rawFailure")
  result.fail(newException(IOError, message))

proc safeValue(value: int): Future[JResult[int]] =
  completedResult(ok(value))

proc safeError(message: string): Future[JResult[int]] =
  completedResult(err[int](newJoubakoError(jeTransport, message)))

suite "Result Future boundary":
  test "settle converts success without changing the value":
    let outcome = waitFor settle(fallible(rawSuccess(7)))
    check outcome.isOk
    check outcome.value == 7

  test "settle converts a failed Future into Err":
    let outcome = waitFor settle(fallible(rawFailure("offline")))
    check outcome.isErr
    check outcome.error.kind == jeTransport
    check outcome.error.msg == "offline"

  test "then transforms only successful values":
    let outcome = waitFor safeValue(4).then(proc(value: int): int = value * 2)
    check outcome.isOk
    check outcome.value == 8

  test "then propagates Err without invoking the callback":
    var called = false
    let outcome = waitFor safeError("source").then(
      proc(value: int): int =
        called = true
        value
    )
    check outcome.isErr
    check not called
    check outcome.error.msg == "source"

  test "callback exceptions become Err instead of failed Futures":
    let chained = safeValue(1).then(
      proc(value: int): int =
        discard value
        raise newException(ValueError, "callback")
    )
    let outcome = waitFor chained
    check not chained.failed
    check outcome.isErr
    check outcome.error.msg == "callback"

  test "catch recovers Result errors":
    let outcome = waitFor safeError("source").catch(
      proc(error: ref JoubakoError): int =
        check error.msg == "source"
        42
    )
    check outcome.isOk
    check outcome.value == 42

  test "discardable then still invokes its callback":
    var observed = 0
    safeValue(9).then(proc(value: int) = observed = value)
    check observed == 9

  test "all combines independently started Result Futures":
    let outcome = waitFor all(safeValue(3), completedResult(ok("four")))
    check outcome.isOk
    check outcome.value.first == 3
    check outcome.value.second == "four"

  test "all propagates a Result error":
    let outcome = waitFor all(safeValue(3), safeError("parallel"))
    check outcome.isErr
    check outcome.error.msg == "parallel"
