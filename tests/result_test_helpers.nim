import std/asyncdispatch
import joubako/result

proc waitFor*[T](future: Future[JResult[T]]): T =
  ## Compatibility helper for pre-Result synchronous tests. Production async
  ## examples use standard `await` and inspect `JResult` explicitly.
  let outcome = asyncdispatch.waitFor(future)
  if outcome.isErr:
    raise outcome.error
  outcome.value

proc waitFor*(future: Future[JResult[void]]) =
  let outcome = asyncdispatch.waitFor(future)
  if outcome.isErr:
    raise outcome.error

template await*[T](future: Future[JResult[T]]): untyped =
  ## Test-only compatibility await for the former exception-based assertions.
  ## Production code uses Nim's standard await and inspects JResult.
  block:
    var pending: FutureBase = future
    yield pending
    let outcome = cast[typeof(future)](pending).read()
    if outcome.isErr:
      raise outcome.error
    when T isnot void:
      outcome.value
