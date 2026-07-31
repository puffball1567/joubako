import std/[asyncdispatch, unittest]
import joubako

proc safeValue[T](value: T): Future[JResult[T]] =
  completedResult(ok(value))

proc delayedText(value: int): Future[JResult[string]] {.async.} =
  await sleepAsync(1)
  return ok($value)

suite "Result Promise composition":
  test "multiple then calls preserve order":
    var order: seq[string]
    let outcome = waitFor safeValue(2)
      .then(proc(value: int): int =
        order.add "first"
        value * 3
      )
      .then(proc(value: int): string =
        order.add "second"
        $value
      )
    check outcome.isOk
    check outcome.value == "6"
    check order == @["first", "second"]

  test "async callbacks are flattened":
    let outcome = waitFor safeValue(4).then(delayedText)
    check outcome.isOk
    check outcome.value == "4"

  test "catch recovers a Result error":
    let source = completedResult(err[int](
      newJoubakoError(jeTransport, "offline")
    ))
    let outcome = waitFor source.catch(
      proc(error: ref JoubakoError): int =
        check error.kind == jeTransport
        12
    )
    check outcome.isOk
    check outcome.value == 12

  test "finally preserves success and runs once":
    var calls = 0
    let outcome = waitFor safeValue(11).finally(proc() = inc calls)
    check outcome.isOk
    check outcome.value == 11
    check calls == 1

  test "callback failures become Err":
    let outcome = waitFor safeValue(1).then(
      proc(value: int): int =
        discard value
        raise newException(ValueError, "bad callback")
    )
    check outcome.isErr
    check outcome.error.msg == "bad callback"

  test "a standalone discardable chain executes":
    var seen = 0
    safeValue(7).then(proc(value: int) = seen = value)
    waitFor sleepAsync(1)
    check seen == 7
