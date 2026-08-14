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

method supportsOwnedRequestDispatch*(transport: Transport): bool {.base.} =
  ## True when `sendOwned` moves the request into the eventual Response rather
  ## than retaining or copying the caller's value. The client uses this only
  ## for its single-attempt path; custom transports keep the compatible
  ## value-parameter dispatch below unless they explicitly opt in.
  discard transport
  false

method send*(transport: Transport; request: Request): Future[Response] {.base.} =
  result = newFuture[Response]("Joubako.Transport.send")
  result.fail(newJoubakoError(
    jeTransport,
    "transport does not implement send",
    request.url
  ))

method sendOwned*(
    transport: Transport;
    request: sink Request
): Future[Response] {.base.} =
  ## Ownership-aware dispatch hook. Its default deliberately delegates to the
  ## long-standing public method so existing third-party transports retain
  ## their source and behavioural compatibility.
  transport.send(request)
