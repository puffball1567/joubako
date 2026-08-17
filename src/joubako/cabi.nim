## Versioned, blocking C ABI for JSON over Joubako's HTTP/1.1 transport.
##
## This module is intentionally separate from the public Nim entry point. The
## native Nim API remains asynchronous; the C ABI drives that API synchronously
## on the calling thread and owns every cross-language lifetime explicitly.

import std/[asyncdispatch, json, strutils]
import ./[client, result, types]
import ./transports/http

const
  JoubakoAbiVersion* = 1'u32
  CabiOk = 0.cint
  CabiInvalidArgument = 1.cint
  CabiInternal = 100.cint

type
  CClient = ref object
    transport: HttpTransport
    client: Client
    defaultHeaders: Headers
    defaultOptions: RequestOptions

  CResponse = ref object
    errorCode: cint
    status: cint
    body: string
    errorMessage: string

func errorCode(kind: ErrorKind): cint =
  case kind
  of jeInvalidRequest: 10
  of jeTransport: 11
  of jeTimeout: 12
  of jeCancelled: 13
  of jeHttpStatus: 14
  of jeBodyTooLarge: 15
  of jeCodec: 16
  of jeCompression: 17
  of jeStream: 18
  of jeCircuitOpen: 19
  of jeRateLimited: 20
  of jeBulkheadRejected: 21
  of jeRpcStatus: 22

func parseMethod(value: string; outMethod: var RequestMethod): bool =
  case value.toUpperAscii
  of "GET": outMethod = rmGet
  of "HEAD": outMethod = rmHead
  of "POST": outMethod = rmPost
  of "PUT": outMethod = rmPut
  of "PATCH": outMethod = rmPatch
  of "DELETE": outMethod = rmDelete
  of "OPTIONS": outMethod = rmOptions
  else: return false
  true

proc retainClient(value: CClient): pointer {.raises: [].} =
  GC_ref(value)
  cast[pointer](value)

proc retainResponse(value: CResponse): pointer {.raises: [].} =
  GC_ref(value)
  cast[pointer](value)

proc releaseClient(handle: pointer) {.raises: [].} =
  if handle != nil:
    GC_unref(cast[CClient](handle))

proc releaseResponse(handle: pointer) {.raises: [].} =
  if handle != nil:
    GC_unref(cast[CResponse](handle))

proc makeResponse(
    code: cint;
    status = 0;
    body = "";
    message = ""
): pointer {.raises: [].} =
  retainResponse(CResponse(
    errorCode: code,
    status: status.cint,
    body: body,
    errorMessage: message
  ))

proc responseFromError(error: ref JoubakoError): pointer {.raises: [].} =
  if error == nil:
    return makeResponse(CabiInternal, message = "unknown Joubako error")
  let body = if error.hasResponse: error.response.body else: ""
  let status =
    if error.hasResponse: error.response.status
    else: error.status
  makeResponse(error.kind.errorCode, status, body, error.msg)

proc responseFromJsonError(error: ref JoubakoError): tuple[
    code: cint, response: pointer
] {.raises: [].} =
  if error != nil and error.hasResponse and error.response.body.len > 0:
    try:
      discard error.response.body.parseJson()
    except CatchableError as parseError:
      return (
        errorCode(jeCodec),
        makeResponse(
          errorCode(jeCodec),
          error.response.status,
          error.response.body,
          "invalid JSON response body: " & parseError.msg
        )
      )
  let code = if error == nil: CabiInternal else: error.kind.errorCode
  (code, responseFromError(error))

proc joubako_abi_version*(): uint32 {.
    cdecl, exportc, dynlib, raises: [].} =
  JoubakoAbiVersion

proc joubako_client_create*(
    baseUrl: cstring;
    outClient: ptr pointer
): cint {.cdecl, exportc, dynlib, raises: [].} =
  if outClient == nil:
    return CabiInvalidArgument
  outClient[] = nil
  if baseUrl == nil:
    return CabiInvalidArgument
  try:
    var headers = initHeaders()
    headers.set("accept", "application/json")
    headers.set("content-type", "application/json")
    let options = defaultRequestOptions()
    let transport = newHttpTransport()
    let value = CClient(
      transport: transport,
      client: newClient(
        transport,
        $baseUrl,
        defaultHeaders = headers,
        defaultOptions = options
      ),
      defaultHeaders: headers,
      defaultOptions: options
    )
    outClient[] = retainClient(value)
    CabiOk
  except Exception:
    CabiInternal

proc joubako_client_free*(handle: pointer) {.
    cdecl, exportc, dynlib, raises: [].} =
  if handle == nil:
    return
  try:
    let value = cast[CClient](handle)
    if value.transport != nil:
      value.transport.closeIdleConnections()
  except Exception:
    discard
  releaseClient(handle)

proc joubako_client_set_header*(
    handle: pointer;
    name, value: cstring
): cint {.cdecl, exportc, dynlib, raises: [].} =
  if handle == nil or name == nil or value == nil:
    return CabiInvalidArgument
  try:
    let client = cast[CClient](handle)
    client.defaultHeaders.set($name, $value)
    client.client.defaultHeaders = client.defaultHeaders
    CabiOk
  except CatchableError:
    CabiInvalidArgument
  except Exception:
    CabiInternal

proc joubako_client_set_timeout_ms*(
    handle: pointer;
    timeoutMs: int32
): cint {.cdecl, exportc, dynlib, raises: [].} =
  if handle == nil or timeoutMs < -1:
    return CabiInvalidArgument
  try:
    let client = cast[CClient](handle)
    client.defaultOptions.timeoutMs = timeoutMs.int
    client.client.defaultOptions = client.defaultOptions
    CabiOk
  except Exception:
    CabiInternal

proc joubako_client_set_max_response_bytes*(
    handle: pointer;
    maxResponseBytes: int64
): cint {.cdecl, exportc, dynlib, raises: [].} =
  if handle == nil or maxResponseBytes < -1 or
      maxResponseBytes > high(int).int64:
    return CabiInvalidArgument
  try:
    let client = cast[CClient](handle)
    client.defaultOptions.maxResponseBytes = maxResponseBytes.int
    client.client.defaultOptions = client.defaultOptions
    CabiOk
  except Exception:
    CabiInternal

proc joubako_request_json*(
    handle: pointer;
    methodText, path, jsonBody: cstring;
    outResponse: ptr pointer
): cint {.cdecl, exportc, dynlib, raises: [].} =
  if outResponse == nil:
    return CabiInvalidArgument
  outResponse[] = nil
  if handle == nil or methodText == nil or path == nil:
    return CabiInvalidArgument

  try:
    let cClient = cast[CClient](handle)
    var httpMethod: RequestMethod
    if not parseMethod($methodText, httpMethod):
      outResponse[] = makeResponse(
        CabiInvalidArgument,
        message = "unsupported HTTP method"
      )
      return CabiInvalidArgument

    let body = if jsonBody == nil: "" else: $jsonBody
    if body.len > 0:
      try:
        discard body.parseJson()
      except CatchableError as error:
        outResponse[] = makeResponse(
          errorCode(jeCodec),
          message = "invalid JSON request body: " & error.msg
        )
        return errorCode(jeCodec)

    var outcome = waitFor cClient.client.request(
      httpMethod,
      $path,
      body,
      cClient.defaultHeaders
    )
    if outcome.isErr:
      let failure = responseFromJsonError(outcome.error)
      outResponse[] = failure.response
      return failure.code

    let response = outcome.takeValue()
    if response.body.len > 0:
      try:
        discard response.body.parseJson()
      except CatchableError as error:
        outResponse[] = makeResponse(
          errorCode(jeCodec),
          response.status,
          response.body,
          "invalid JSON response body: " & error.msg
        )
        return errorCode(jeCodec)

    outResponse[] = makeResponse(
      CabiOk,
      response.status,
      response.body
    )
    CabiOk
  except CatchableError as error:
    outResponse[] = makeResponse(CabiInternal, message = error.msg)
    CabiInternal
  except Exception:
    outResponse[] = makeResponse(
      CabiInternal,
      message = "unexpected internal error"
    )
    CabiInternal

proc joubako_response_free*(handle: pointer) {.
    cdecl, exportc, dynlib, raises: [].} =
  releaseResponse(handle)

proc joubako_response_error_code*(handle: pointer): cint {.
    cdecl, exportc, dynlib, raises: [].} =
  if handle == nil: CabiInvalidArgument
  else: cast[CResponse](handle).errorCode

proc joubako_response_status*(handle: pointer): int32 {.
    cdecl, exportc, dynlib, raises: [].} =
  if handle == nil: 0'i32
  else: cast[CResponse](handle).status.int32

proc joubako_response_body*(handle: pointer): cstring {.
    cdecl, exportc, dynlib, raises: [].} =
  if handle == nil: nil
  else: cast[CResponse](handle).body.cstring

proc joubako_response_body_size*(handle: pointer): csize_t {.
    cdecl, exportc, dynlib, raises: [].} =
  if handle == nil: 0.csize_t
  else: cast[CResponse](handle).body.len.csize_t

proc joubako_response_error_message*(handle: pointer): cstring {.
    cdecl, exportc, dynlib, raises: [].} =
  if handle == nil: nil
  else: cast[CResponse](handle).errorMessage.cstring

proc joubako_response_error_message_size*(handle: pointer): csize_t {.
    cdecl, exportc, dynlib, raises: [].} =
  if handle == nil: 0.csize_t
  else: cast[CResponse](handle).errorMessage.len.csize_t
