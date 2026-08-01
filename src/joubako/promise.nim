## Promise-style composition for normally completed Result Futures.
##
## `then` handles only `Ok`; `catch` handles only `Err`. Neither procedure
## uses a failed Future for ordinary errors.

import std/asyncdispatch
import ./[result, types]

proc addResultCallback(source: FutureBase; callback: proc() {.closure.}) =
  type SafeCallback = proc() {.closure, gcsafe.}
  {.cast(gcsafe).}:
    source.addCallback(cast[SafeCallback](callback))

proc callbackFailure(error: ref Exception): ref JoubakoError =
  error.asJoubakoError(jeCodec, "")

proc forward[T](source: Future[JResult[T]]; destination: Future[JResult[T]]) =
  if source.isNil:
    destination.complete(err[T](newJoubakoError(
      jeCodec,
      "asynchronous Promise callback returned a nil Future"
    )))
    return
  source.addResultCallback(proc() =
    if destination.finished:
      return
    if source.failed:
      var failure = move(source.error)
      source.errorStackTrace.setLen(0)
      destination.complete(err[T](failure.callbackFailure()))
    else:
      destination.complete(source.read())
  )

proc thenClosure[T, U](
    source: Future[JResult[T]];
    onFulfilled: proc(value: T): U {.closure.}
): Future[JResult[U]] =
  result = newFuture[JResult[U]]("Joubako.then")
  let destination = result
  source.addResultCallback(proc() =
    if destination.finished:
      return
    if source.failed:
      var failure = move(source.error)
      source.errorStackTrace.setLen(0)
      destination.complete(err[U](failure.callbackFailure()))
      return
    let outcome = source.read()
    if outcome.isErr:
      destination.complete(err[U](outcome.error))
      return
    try:
      destination.complete(ok(onFulfilled(outcome.value)))
    except CatchableError as error:
      destination.complete(err[U](error.callbackFailure()))
  )

proc then*[T, U](
    source: Future[JResult[T]];
    onFulfilled: proc(value: T): U {.closure.}
): Future[JResult[U]] {.discardable.} =
  thenClosure(source, onFulfilled)

proc then*[T, U](
    source: Future[JResult[T]];
    onFulfilled: proc(value: T): U {.nimcall.}
): Future[JResult[U]] {.discardable.} =
  let callback = proc(value: T): U = onFulfilled(value)
  thenClosure(source, callback)

proc thenVoidClosure[T](
    source: Future[JResult[T]];
    onFulfilled: proc(value: T) {.closure.}
): Future[JResult[void]] =
  result = newFuture[JResult[void]]("Joubako.then")
  let destination = result
  source.addResultCallback(proc() =
    if destination.finished:
      return
    if source.failed:
      var failure = move(source.error)
      source.errorStackTrace.setLen(0)
      destination.complete(err[void](failure.callbackFailure()))
      return
    let outcome = source.read()
    if outcome.isErr:
      destination.complete(err[void](outcome.error))
      return
    try:
      onFulfilled(outcome.value)
      destination.complete(ok())
    except CatchableError as error:
      destination.complete(err[void](error.callbackFailure()))
  )

proc then*[T](
    source: Future[JResult[T]];
    onFulfilled: proc(value: T) {.closure.}
): Future[JResult[void]] {.discardable.} =
  thenVoidClosure(source, onFulfilled)

proc then*[T](
    source: Future[JResult[T]];
    onFulfilled: proc(value: T) {.nimcall.}
): Future[JResult[void]] {.discardable.} =
  let callback = proc(value: T) = onFulfilled(value)
  thenVoidClosure(source, callback)

proc thenAsyncClosure[T, U](
    source: Future[JResult[T]];
    onFulfilled: proc(value: T): Future[JResult[U]] {.closure.}
): Future[JResult[U]] =
  result = newFuture[JResult[U]]("Joubako.thenAsync")
  let destination = result
  source.addResultCallback(proc() =
    if destination.finished:
      return
    if source.failed:
      var failure = move(source.error)
      source.errorStackTrace.setLen(0)
      destination.complete(err[U](failure.callbackFailure()))
      return
    let outcome = source.read()
    if outcome.isErr:
      destination.complete(err[U](outcome.error))
      return
    try:
      onFulfilled(outcome.value).forward(destination)
    except CatchableError as error:
      destination.complete(err[U](error.callbackFailure()))
  )

proc then*[T, U](
    source: Future[JResult[T]];
    onFulfilled: proc(value: T): Future[JResult[U]] {.closure.}
): Future[JResult[U]] {.discardable.} =
  thenAsyncClosure(source, onFulfilled)

proc then*[T, U](
    source: Future[JResult[T]];
    onFulfilled: proc(value: T): Future[JResult[U]] {.nimcall.}
): Future[JResult[U]] {.discardable.} =
  let callback = proc(value: T): Future[JResult[U]] = onFulfilled(value)
  thenAsyncClosure(source, callback)

proc catchClosure[T](
    source: Future[JResult[T]];
    onRejected: proc(error: ref JoubakoError): T {.closure.}
): Future[JResult[T]] =
  result = newFuture[JResult[T]]("Joubako.catch")
  let destination = result
  source.addResultCallback(proc() =
    if destination.finished:
      return
    if source.failed:
      var failure = move(source.error)
      source.errorStackTrace.setLen(0)
      destination.complete(err[T](failure.callbackFailure()))
      return
    let outcome = source.read()
    if outcome.isOk:
      destination.complete(outcome)
      return
    try:
      destination.complete(ok(onRejected(outcome.error)))
    except CatchableError as error:
      destination.complete(err[T](error.callbackFailure()))
  )

proc catch*[T](
    source: Future[JResult[T]];
    onRejected: proc(error: ref JoubakoError): T {.closure.}
): Future[JResult[T]] {.discardable.} =
  catchClosure(source, onRejected)

proc catch*[T](
    source: Future[JResult[T]];
    onRejected: proc(error: ref JoubakoError): T {.nimcall.}
): Future[JResult[T]] {.discardable.} =
  let callback = proc(error: ref JoubakoError): T = onRejected(error)
  catchClosure(source, callback)

proc catchAsyncClosure[T](
    source: Future[JResult[T]];
    onRejected: proc(error: ref JoubakoError): Future[JResult[T]] {.closure.}
): Future[JResult[T]] =
  result = newFuture[JResult[T]]("Joubako.catchAsync")
  let destination = result
  source.addResultCallback(proc() =
    if destination.finished:
      return
    if source.failed:
      var failure = move(source.error)
      source.errorStackTrace.setLen(0)
      destination.complete(err[T](failure.callbackFailure()))
      return
    let outcome = source.read()
    if outcome.isOk:
      destination.complete(outcome)
      return
    try:
      onRejected(outcome.error).forward(destination)
    except CatchableError as error:
      destination.complete(err[T](error.callbackFailure()))
  )

proc catch*[T](
    source: Future[JResult[T]];
    onRejected: proc(
      error: ref JoubakoError
    ): Future[JResult[T]] {.closure.}
): Future[JResult[T]] {.discardable.} =
  catchAsyncClosure(source, onRejected)

proc catch*[T](
    source: Future[JResult[T]];
    onRejected: proc(
      error: ref JoubakoError
    ): Future[JResult[T]] {.nimcall.}
): Future[JResult[T]] {.discardable.} =
  let callback = proc(
    error: ref JoubakoError
  ): Future[JResult[T]] = onRejected(error)
  catchAsyncClosure(source, callback)

proc catchVoidClosure(
    source: Future[JResult[void]];
    onRejected: proc(error: ref JoubakoError) {.closure.}
): Future[JResult[void]] =
  result = newFuture[JResult[void]]("Joubako.catch")
  let destination = result
  source.addResultCallback(proc() =
    if destination.finished:
      return
    if source.failed:
      var failure = move(source.error)
      source.errorStackTrace.setLen(0)
      destination.complete(err[void](failure.callbackFailure()))
      return
    let outcome = source.read()
    if outcome.isOk:
      destination.complete(ok())
      return
    try:
      onRejected(outcome.error)
      destination.complete(ok())
    except CatchableError as error:
      destination.complete(err[void](error.callbackFailure()))
  )

proc catch*(
    source: Future[JResult[void]];
    onRejected: proc(error: ref JoubakoError) {.closure.}
): Future[JResult[void]] {.discardable.} =
  catchVoidClosure(source, onRejected)

proc catch*(
    source: Future[JResult[void]];
    onRejected: proc(error: ref JoubakoError) {.nimcall.}
): Future[JResult[void]] {.discardable.} =
  let callback = proc(error: ref JoubakoError) = onRejected(error)
  catchVoidClosure(source, callback)

proc finallyClosure[T](
    source: Future[JResult[T]];
    onFinally: proc() {.closure.}
): Future[JResult[T]] =
  result = newFuture[JResult[T]]("Joubako.finally")
  let destination = result
  source.addResultCallback(proc() =
    if destination.finished:
      return
    var outcome: JResult[T]
    if source.failed:
      var failure = move(source.error)
      source.errorStackTrace.setLen(0)
      outcome = err[T](failure.callbackFailure())
    else:
      outcome = source.read()
    try:
      onFinally()
      destination.complete(outcome)
    except CatchableError as error:
      destination.complete(err[T](error.callbackFailure()))
  )

proc `finally`*[T](
    source: Future[JResult[T]];
    onFinally: proc() {.closure.}
): Future[JResult[T]] {.discardable.} =
  finallyClosure(source, onFinally)

proc `finally`*[T](
    source: Future[JResult[T]];
    onFinally: proc() {.nimcall.}
): Future[JResult[T]] {.discardable.} =
  let callback = proc() = onFinally()
  finallyClosure(source, callback)

proc finallyAsyncClosure[T](
    source: Future[JResult[T]];
    onFinally: proc(): Future[JResult[void]] {.closure.}
): Future[JResult[T]] =
  result = newFuture[JResult[T]]("Joubako.finallyAsync")
  let destination = result
  source.addResultCallback(proc() =
    if destination.finished:
      return
    var outcome: JResult[T]
    if source.failed:
      var failure = move(source.error)
      source.errorStackTrace.setLen(0)
      outcome = err[T](failure.callbackFailure())
    else:
      outcome = source.read()
    try:
      let cleanup = onFinally()
      if cleanup.isNil:
        destination.complete(err[T](newJoubakoError(
          jeCodec,
          "asynchronous finally callback returned a nil Future"
        )))
        return
      cleanup.addResultCallback(proc() =
        if destination.finished:
          return
        if cleanup.failed:
          var failure = move(cleanup.error)
          cleanup.errorStackTrace.setLen(0)
          destination.complete(err[T](failure.callbackFailure()))
          return
        let cleanupOutcome = cleanup.read()
        if cleanupOutcome.isErr:
          destination.complete(err[T](cleanupOutcome.error))
        else:
          destination.complete(outcome)
      )
    except CatchableError as error:
      destination.complete(err[T](error.callbackFailure()))
  )

proc `finally`*[T](
    source: Future[JResult[T]];
    onFinally: proc(): Future[JResult[void]] {.closure.}
): Future[JResult[T]] {.discardable.} =
  finallyAsyncClosure(source, onFinally)

proc `finally`*[T](
    source: Future[JResult[T]];
    onFinally: proc(): Future[JResult[void]] {.nimcall.}
): Future[JResult[T]] {.discardable.} =
  let callback = proc(): Future[JResult[void]] = onFinally()
  finallyAsyncClosure(source, callback)

type PairState[A, B] = ref object
  destination: Future[JResult[tuple[first: A, second: B]]]
  firstReady, secondReady: bool
  first: JResult[A]
  second: JResult[B]

proc finishPair[A, B](state: PairState[A, B]) =
  if not state.firstReady or not state.secondReady or
      state.destination.finished:
    return
  if state.first.isErr:
    state.destination.complete(err[tuple[first: A, second: B]](
      state.first.error
    ))
  elif state.second.isErr:
    state.destination.complete(err[tuple[first: A, second: B]](
      state.second.error
    ))
  else:
    state.destination.complete(ok((
      first: state.first.value,
      second: state.second.value
    )))

proc all*[A, B](
    first: Future[JResult[A]];
    second: Future[JResult[B]]
): Future[JResult[tuple[first: A, second: B]]] {.discardable.} =
  ## Starts no work itself: both input operations are already running. The
  ## returned Future completes after both Result Futures complete.
  result = newFuture[JResult[tuple[first: A, second: B]]]("Joubako.all")
  let state = PairState[A, B](destination: result)
  first.addResultCallback(proc() =
    if first.failed:
      var failure = move(first.error)
      first.errorStackTrace.setLen(0)
      state.first = err[A](failure.callbackFailure())
    else:
      state.first = first.read()
    state.firstReady = true
    state.finishPair()
  )
  second.addResultCallback(proc() =
    if second.failed:
      var failure = move(second.error)
      second.errorStackTrace.setLen(0)
      state.second = err[B](failure.callbackFailure())
    else:
      state.second = second.read()
    state.secondReady = true
    state.finishPair()
  )
