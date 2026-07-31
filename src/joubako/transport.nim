import std/asyncdispatch
import ./types

type
  Transport* = ref object of RootObj

method send*(transport: Transport; request: Request): Future[Response] {.base.} =
  result = newFuture[Response]("Joubako.Transport.send")
  result.fail(newJoubakoError(
    jeTransport,
    "transport does not implement send",
    request.url
  ))
