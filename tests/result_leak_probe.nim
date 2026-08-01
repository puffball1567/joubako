import std/[asyncdispatch, os, strutils]
import joubako

const Iterations = 800

proc rawFailure(index: int): Future[int] =
  result = newFuture[int]("resultLeak.rawFailure")
  result.fail(newException(IOError, "failure " & $index))

proc safeValue(value: int): Future[JResult[int]] =
  completedResult(ok(value))

proc safeError(index: int): Future[JResult[int]] =
  completedResult(err[int](
    newJoubakoError(jeTransport, "safe failure " & $index)
  ))

proc consumeChunk(_: string): Future[void] =
  result = newFuture[void]("resultLeak.consumeChunk")
  result.complete()

proc rejectChunk(_: string): Future[void] =
  result = newFuture[void]("resultLeak.rejectChunk")
  result.fail(newException(IOError, "consumer failure"))

proc missingHandler(request: Request): Future[Response] {.async.} =
  if request.url == "offline":
    raise newException(IOError, "offline")
  if request.url == "stream":
    return Response(status: 200, body: "stream payload", request: request)
  if request.url == "codec":
    return Response(status: 200, body: request.body, request: request)
  var headers = initHeaders()
  headers.add("x-probe", "retained")
  return Response(
    status: 404,
    statusText: "Not Found",
    headers: headers,
    body: "bounded error response",
    request: request
  )

proc main(): Future[void] {.async.} =
  var callbackTotal = 0
  let client = newClient(newInProcessTransport(missingHandler))
  let codec = Codec[int, int](
    encodeAsync: proc(value: int): Future[string] {.async.} = $value,
    decodeResponseAsync: proc(response: Response): Future[int] {.async.} =
      return response.body.parseInt
  )
  let failingCodec = Codec[int, int](
    encode: proc(value: int): string = $value,
    decodeResponseAsync: proc(response: Response): Future[int] {.async.} =
      discard response
      raise newException(ValueError, "decoder failure")
  )
  for index in 0 ..< Iterations:
    let raw = rawFailure(index)
    let normalized = settle(fallible(raw))
    let settled = await normalized
    doAssert settled.isErr

    let recovery = safeError(index)
      .then(proc(value: int): int = value + 1)
      .catch(proc(error: ref JoubakoError): int =
        doAssert error.kind == jeTransport
        index
      )
    let recovered = await recovery
    doAssert recovered.isOk
    doAssert recovered.value == index

    let response = await client.get("missing")
    doAssert response.isErr
    doAssert response.error.kind == jeHttpStatus
    doAssert response.error.hasResponse
    doAssert response.error.response.statusText == "Not Found"
    doAssert response.error.response.headers.get("x-probe") == "retained"
    doAssert response.error.response.body == "bounded error response"
    doAssert response.error.attempts == 1

    let offline = await client.get("offline")
    doAssert offline.isErr
    doAssert offline.error.kind == jeTransport

    var streamOptions = defaultRequestOptions()
    streamOptions.streamResponse = true
    streamOptions.onDownloadChunkAsync = consumeChunk
    let streamed = await client.get("stream", options = streamOptions)
    doAssert streamed.isOk
    doAssert streamed.value.body.len == 0

    streamOptions.onDownloadChunkAsync = rejectChunk
    let rejected = await client.get("stream", options = streamOptions)
    doAssert rejected.isErr
    doAssert rejected.error.kind == jeStream

    let decoded = await client.sendWithCodec(
      rmPost, "codec", index, codec
    )
    doAssert decoded.isOk
    doAssert decoded.value == index

    let decodeFailure = await client.sendWithCodec(
      rmPost, "codec", index, failingCodec
    )
    doAssert decodeFailure.isErr
    doAssert decodeFailure.error.kind == jeCodec
    doAssert decodeFailure.error.hasResponse

    let parallel = await all(safeValue(index), safeError(index))
    doAssert parallel.isErr

    discard safeValue(index).then(
      proc(value: int) = callbackTotal += value
    )

  doAssert callbackTotal == (Iterations - 1) * Iterations div 2

  let outputPath = getTempDir() /
    ("joubako-result-leak-" & $getCurrentProcessId() & ".bin")
  defer:
    if fileExists(outputPath):
      removeFile(outputPath)
  let downloaded = await client.downloadToFile("stream", outputPath)
  doAssert downloaded.isOk
  doAssert downloaded.value.body.len == 0
  doAssert readFile(outputPath) == "stream payload"

let probe = main()
waitFor probe
probe.clearCallbacks()
