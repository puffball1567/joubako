import std/[asyncdispatch, json, os, sequtils, strutils]
import joubako

type
  Health = object
    ok: bool
    role: string

  EchoPayload = object
    id: int
    text: string

  StreamState = ref object
    body: string

proc requireOk[T](outcome: JResult[T]; label: string): T =
  if outcome.isErr:
    raise newException(
      IOError,
      label & " failed: " & $outcome.error.kind & ": " & outcome.error.msg
    )
  outcome.value

proc appendChunks(state: StreamState): DownloadChunkProc =
  result = proc(chunk: string) =
    state.body.add chunk

proc main() {.async.} =
  let baseUrl = getEnv("JOUBAKO_E2E_BASE_URL", "http://backend:8080/")
  let topology = getEnv("JOUBAKO_E2E_TOPOLOGY", "Docker")
  let redirectHost = getEnv(
    "JOUBAKO_E2E_REDIRECT_HOST",
    "redirect:8080"
  )
  let jar = newCookieJar()
  let transport = newHttpTransport(cookieJar = jar)
  let api = newClient(transport, baseUrl)

  let health = requireOk(
    await api.getJson("health", Health),
    "health request"
  )
  doAssert health.ok
  doAssert health.role == "backend"

  let payload = EchoPayload(id: 42, text: "状箱 across Docker")
  let echoed = requireOk(
    await api.postJson("echo-json", payload, EchoPayload),
    "typed JSON round trip"
  )
  doAssert echoed == payload

  let queryResponse = requireOk(
    await api.get("query", [
      (name: "tag", value: "one"),
      (name: "tag", value: "two"),
      (name: "name", value: "状箱")
    ]),
    "query request"
  )
  let queryJson = queryResponse.body.parseJson
  doAssert queryJson["query"]["tag"].getElems.mapIt(it.getStr) ==
    @["one", "two"]
  doAssert queryJson["query"]["name"][0].getStr == "状箱"

  let headerResponse = requireOk(await api.get("headers"), "header request")
  doAssert headerResponse.headers.getAll("x-repeat") == @["one", "two"]

  let binary = "binary\0payload\xFF"
  let binaryResponse = requireOk(
    await api.post("echo-binary", binary),
    "binary round trip"
  )
  doAssert binaryResponse.body == binary

  let compressed = requireOk(await api.get("gzip"), "gzip request")
  doAssert compressed.body == "compressed across containers"

  let streamState = StreamState()
  var streamOptions = defaultRequestOptions()
  streamOptions.streamResponse = true
  streamOptions.onDownloadChunk = appendChunks(streamState)
  let streamed = requireOk(
    await api.get("chunked", options = streamOptions),
    "chunked stream"
  )
  doAssert streamed.body.len == 0
  doAssert streamState.body == "container-stream-complete"

  var retryOptions = defaultRequestOptions()
  retryOptions.retry = defaultHttpRetryOptions()
  let retried = requireOk(
    await api.get("retry", options = retryOptions),
    "retry request"
  )
  doAssert retried.body.parseJson["attempt"].getInt == 2

  var sensitive = initHeaders()
  sensitive.set("authorization", "Bearer docker-secret")
  sensitive.set("cookie", "manual=secret")
  sensitive.set("proxy-authorization", "Basic c2VjcmV0")
  sensitive.set("host", "backend:8080")
  let redirected = requireOk(
    await api.get("redirect-cross", sensitive),
    "cross-origin redirect"
  )
  let redirectJson = redirected.body.parseJson
  doAssert redirectJson["role"].getStr == "redirect"
  doAssert redirectJson["authorization"].getStr.len == 0
  doAssert redirectJson["cookie"].getStr.len == 0
  doAssert redirectJson["proxyAuthorization"].getStr.len == 0
  doAssert redirectJson["host"].getStr == redirectHost

  discard requireOk(await api.get("set-cookie"), "cookie storage")
  let cookieResponse = requireOk(await api.get("cookie"), "cookie replay")
  doAssert cookieResponse.body.parseJson["cookie"].getStr == "session=e2e"

  let uploadPath = "/tmp/joubako-e2e-upload.bin"
  writeFile(uploadPath, "binary\0payload")
  defer:
    if fileExists(uploadPath):
      removeFile(uploadPath)
  let multipartResponse = requireOk(
    await api.postMultipart("multipart", [
      formField("title", "Joubako E2E"),
      formFilePath(
        "document",
        uploadPath,
        filename = "payload.bin",
        contentType = "application/octet-stream"
      )
    ]),
    "multipart upload"
  )
  doAssert multipartResponse.body.parseJson["valid"].getBool

  let downloadPath = "/tmp/joubako-e2e-download.bin"
  defer:
    if fileExists(downloadPath):
      removeFile(downloadPath)
  let downloaded = requireOk(
    await api.downloadToFile("download", downloadPath),
    "file download"
  )
  doAssert downloaded.body.len == 0
  doAssert readFile(downloadPath) == "downloaded-across-container-network"

  var sizeOptions = defaultRequestOptions()
  sizeOptions.maxResponseBytes = 15
  let oversized = await api.get("sized?bytes=16", options = sizeOptions)
  doAssert oversized.isErr
  doAssert oversized.error.kind == jeBodyTooLarge

  let nifResponse = requireOk(
    await api.postNif("echo-bif", "(record title \"NIF\" -5 12u)"),
    "NIF/BIF round trip"
  )
  doAssert nifResponse == "(record title \"NIF\" -5 12u)"

  let typedNifResponse = requireOk(
    await api.postNif("echo-bif", payload, EchoPayload),
    "typed NIF/BIF round trip"
  )
  doAssert typedNifResponse == payload

  let concurrent = requireOk(
    await all(api.get("health"), api.get("headers")),
    "concurrent requests"
  )
  doAssert concurrent.first.status == 200
  doAssert concurrent.second.headers.getAll("x-repeat") == @["one", "two"]

  var timeoutOptions = defaultRequestOptions()
  timeoutOptions.timeoutMs = 100
  let timedOut = await api.get("slow", options = timeoutOptions)
  doAssert timedOut.isErr
  doAssert timedOut.error.kind == jeTimeout

  transport.closeIdleConnections()
  echo "Joubako " & topology & " E2E passed"

when isMainModule:
  waitFor main()
