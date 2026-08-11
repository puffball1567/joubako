import std/asyncdispatch
import ./types

type
  Transport* = ref object of RootObj

method usesImplicitCredentials*(transport: Transport): bool {.base.} =
  ## True when a transport may add end-server credentials after request
  ## interceptors and outer transport wrappers have run.
  discard transport
  false

method supportsRuntimeMultipartLimits*(transport: Transport): bool {.base.} =
  ## True only when multipart totals and file-part limits are checked while
  ## bytes are read for transmission, not solely from preflight file sizes.
  discard transport
  false

method send*(transport: Transport; request: Request): Future[Response] {.base.} =
  result = newFuture[Response]("Joubako.Transport.send")
  result.fail(newJoubakoError(
    jeTransport,
    "transport does not implement send",
    request.url
  ))
