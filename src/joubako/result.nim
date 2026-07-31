## Result-valued asynchronous boundaries for Joubako.
##
## Operational failures are values. Futures carrying `JResult` are expected
## to complete normally; `Defect` remains outside this contract.

import std/asyncdispatch
import ./types

type
  JResult*[T] = object
    error: ref JoubakoError
    when T isnot void:
      value: T

  FallibleFuture*[T] = object
    ## A single-consumer Future that must pass through `settle` before await.
    raw: Future[T]

func ok*[T](value: sink T): JResult[T] =
  result.value = move(value)

func ok*(): JResult[void] =
  discard

func err*[T](error: ref JoubakoError): JResult[T] =
  assert error != nil
  result.error = error

func isOk*[T](outcome: JResult[T]): bool =
  outcome.error == nil

func isErr*[T](outcome: JResult[T]): bool =
  outcome.error != nil

func get*[T](outcome: JResult[T]): lent T =
  ## Returns a successful value. Prefer checking `isErr` at public boundaries.
  assert outcome.isOk, "cannot get the value of an error JResult"
  outcome.value

func getError*[T](outcome: JResult[T]): ref JoubakoError =
  ## Returns the structured error, or nil for a successful result.
  outcome.error

template value*[T](outcome: JResult[T]): untyped =
  outcome.get()

template error*[T](outcome: JResult[T]): untyped =
  outcome.getError()

proc fallible*[T](future: sink Future[T]): FallibleFuture[T] =
  ## Marks a raw Future as single-consumer and non-awaitable.
  result.raw = move(future)

proc asJoubakoError*(
    error: ref Exception;
    kind: ErrorKind;
    url: string
): ref JoubakoError =
  if error of JoubakoError:
    cast[ref JoubakoError](error)
  else:
    newJoubakoError(kind, error.msg, url)

proc settle*[T](
    source: sink FallibleFuture[T];
    kind = jeTransport;
    url = ""
): Future[JResult[T]] =
  ## Converts a possibly failed Future into a normally completed Result Future.
  ## The source is consumed and must not be observed again.
  result = newFuture[JResult[T]]("Joubako.settle")
  let destination = result
  var pending = move(source.raw)
  pending.addCallback(proc() =
    if destination.finished:
      return
    pending.clearCallbacks()
    if pending.failed:
      var failure = move(pending.error)
      pending.errorStackTrace.setLen(0)
      destination.complete(err[T](failure.asJoubakoError(kind, url)))
    else:
      when T is void:
        pending.read()
        destination.complete(ok())
      else:
        destination.complete(ok(pending.read()))
    pending = nil
  )

proc settleResult*[T](
    source: sink FallibleFuture[JResult[T]];
    kind = jeTransport;
    url = ""
): Future[JResult[T]] =
  ## Guards a Result Future against an unexpected CatchableError and flattens
  ## it back to the same public type.
  result = newFuture[JResult[T]]("Joubako.settleResult")
  let destination = result
  var pending = move(source.raw)
  pending.addCallback(proc() =
    if destination.finished:
      return
    pending.clearCallbacks()
    if pending.failed:
      var failure = move(pending.error)
      pending.errorStackTrace.setLen(0)
      destination.complete(err[T](failure.asJoubakoError(kind, url)))
    else:
      destination.complete(pending.read())
    pending = nil
  )

proc completedResult*[T](value: sink JResult[T]): Future[JResult[T]] =
  result = newFuture[JResult[T]]("Joubako.completedResult")
  result.complete(move(value))
