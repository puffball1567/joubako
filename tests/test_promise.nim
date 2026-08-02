import std/[asyncdispatch, strutils, unittest]
import joubako

proc safeValue[T](value: T): Future[JResult[T]] =
  completedResult(ok(value))

proc delayedText(value: int): Future[JResult[string]] {.async.} =
  await sleepAsync(1)
  return ok($value)

proc delayedRecovery(error: ref JoubakoError): Future[JResult[int]] {.async.} =
  await sleepAsync(1)
  return ok(error.msg.len)

proc delayedCleanup(): Future[JResult[void]] {.async.} =
  await sleepAsync(1)
  return ok()

proc failedResultFuture[T](message: string): Future[JResult[T]] =
  result = newFuture[JResult[T]]("failedResultFuture")
  result.fail(newException(IOError, message))

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

  test "async catch callbacks are flattened":
    let source = completedResult(err[int](
      newJoubakoError(jeTransport, "offline")
    ))
    let outcome = waitFor source.catch(delayedRecovery)
    check outcome.isOk
    check outcome.value == "offline".len

  test "async catch is skipped for a successful source":
    var called = false
    let outcome = waitFor safeValue(8).catch(
      proc(error: ref JoubakoError): Future[JResult[int]] =
        discard error
        called = true
        safeValue(0)
    )
    check outcome.isOk
    check outcome.value == 8
    check not called

  test "async catch preserves an error returned by recovery":
    let source = completedResult(err[int](
      newJoubakoError(jeTransport, "offline")
    ))
    let outcome = waitFor source.catch(
      proc(error: ref JoubakoError): Future[JResult[int]] =
        discard error
        completedResult(err[int](newJoubakoError(jeCodec, "bad cache")))
    )
    check outcome.isErr
    check outcome.error.kind == jeCodec
    check outcome.error.msg == "bad cache"

  test "failed Futures from async catch become Result errors":
    let source = completedResult(err[int](
      newJoubakoError(jeTransport, "offline")
    ))
    let chained = source.catch(
      proc(error: ref JoubakoError): Future[JResult[int]] =
        discard error
        failedResultFuture[int]("cache failure")
    )
    let outcome = waitFor chained
    check not chained.failed
    check outcome.isErr
    check outcome.error.msg == "cache failure"

  test "async catch supports void Result chains":
    let source = completedResult(err[void](
      newJoubakoError(jeTransport, "offline")
    ))
    let outcome = waitFor source.catch(
      proc(error: ref JoubakoError): Future[JResult[void]] =
        check error.kind == jeTransport
        completedResult(ok())
    )
    check outcome.isOk

  test "finally preserves success and runs once":
    var calls = 0
    let outcome = waitFor safeValue(11).finally(proc() = inc calls)
    check outcome.isOk
    check outcome.value == 11
    check calls == 1

  test "async finally waits and preserves success":
    var calls = 0
    let outcome = waitFor safeValue(13).finally(
      proc(): Future[JResult[void]] =
        inc calls
        delayedCleanup()
    )
    check outcome.isOk
    check outcome.value == 13
    check calls == 1

  test "async finally cleanup errors replace the source outcome":
    let outcome = waitFor safeValue(13).finally(
      proc(): Future[JResult[void]] =
        completedResult(err[void](newJoubakoError(jeStream, "cleanup")))
    )
    check outcome.isErr
    check outcome.error.kind == jeStream
    check outcome.error.msg == "cleanup"

  test "async finally preserves a source error after successful cleanup":
    let source = completedResult(err[int](
      newJoubakoError(jeTransport, "source")
    ))
    let outcome = waitFor source.finally(delayedCleanup)
    check outcome.isErr
    check outcome.error.kind == jeTransport
    check outcome.error.msg == "source"

  test "failed Futures from async finally become Result errors":
    let chained = safeValue(13).finally(
      proc(): Future[JResult[void]] =
        failedResultFuture[void]("cleanup failure")
    )
    let outcome = waitFor chained
    check not chained.failed
    check outcome.isErr
    check outcome.error.msg == "cleanup failure"

  test "exceptions before async cleanup creation become Result errors":
    let chained = safeValue(13).finally(
      proc(): Future[JResult[void]] =
        raise newException(IOError, "cleanup creation")
    )
    let outcome = waitFor chained
    check not chained.failed
    check outcome.isErr
    check outcome.error.msg == "cleanup creation"

  test "async finally supports void Result chains":
    let outcome = waitFor completedResult(ok()).finally(delayedCleanup)
    check outcome.isOk

  test "async then rejects a nil callback Future without failing":
    let chained = safeValue(1).then(
      proc(value: int): Future[JResult[string]] =
        discard value
        nil
    )
    let outcome = waitFor chained
    check not chained.failed
    check outcome.isErr
    check outcome.error.kind == jeCodec
    check outcome.error.msg.contains("nil Future")

  test "async catch rejects a nil callback Future without failing":
    let source = completedResult(err[int](
      newJoubakoError(jeTransport, "offline")
    ))
    let chained = source.catch(
      proc(error: ref JoubakoError): Future[JResult[int]] =
        discard error
        nil
    )
    let outcome = waitFor chained
    check not chained.failed
    check outcome.isErr
    check outcome.error.kind == jeCodec
    check outcome.error.msg.contains("nil Future")

  test "async finally rejects a nil callback Future without failing":
    let chained = safeValue(1).finally(
      proc(): Future[JResult[void]] = nil
    )
    let outcome = waitFor chained
    check not chained.failed
    check outcome.isErr
    check outcome.error.kind == jeCodec
    check outcome.error.msg.contains("nil Future")

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
