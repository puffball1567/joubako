## Single-consumer Future helpers used only inside Joubako.

import std/asyncdispatch

proc takeFutureValue*[T](future: Future[T]): T =
  ## Consume the value of a successful, completed Future without duplicating
  ## a potentially large Response or Request graph. Callers must own the
  ## Future, clear its callbacks first, and never expose it to another reader.
  assert future != nil and future.finished and not future.failed,
    "cannot take the value of an incomplete or failed Future"
  for name, field in fieldPairs(future[]):
    when name == "value":
      result = move(field)
