import std/[asyncdispatch, os, strutils]
import joubako/[client, result, types, uploadstream]
import joubako/transports/http2

proc main() {.async.} =
  let uploadPath = getTempDir() / "joubako-http2-leak-upload.txt"
  writeFile(uploadPath, repeat("multipart-probe-", 256))
  defer:
    if fileExists(uploadPath):
      removeFile(uploadPath)
  let transport = newHttp2Transport(allowH2c = true)
  var options = defaultRequestOptions()
  options.timeoutMs = -1
  options.connectTimeoutMs = -1
  options.readTimeoutMs = -1
  for _ in 0 ..< 100:
    let response = await transport.send(Request(
      httpMethod: rmGet,
      url: "http://127.0.0.1:18943/",
      headers: initHeaders(),
      options: options
    ))
    doAssert response.status == 200
    doAssert response.httpVersion == "HTTP/2"
    doAssert response.body == "ok"

  for _ in 0 ..< 25:
    let upload = newClient(transport, "http://127.0.0.1:18943").openUpload(
      rmPost, "/upload-stream", options = options, maxBufferedBytes = 17
    )
    let sent = await upload.send(repeat("stream-probe-", 64))
    doAssert sent.isOk
    let streamed = await upload.finish()
    doAssert streamed.isOk
    doAssert streamed.value.body ==
      "POST:" & repeat("stream-probe-", 64)

    let multipart = await transport.send(Request(
      httpMethod: rmPost,
      url: "http://127.0.0.1:18943/multipart-redirect",
      headers: initHeaders(),
      multipartParts: @[
        MultipartPart(name: "field", body: "value"),
        MultipartPart(
          name: "file",
          filename: "probe.txt",
          contentType: "text/plain",
          filePath: uploadPath,
          maxBytes: getFileSize(uploadPath)
        )
      ],
      options: options
    ))
    doAssert "filename=\"probe.txt\"" in multipart.body
    doAssert "multipart-probe-" in multipart.body

    var bounded = options
    bounded.maxResponseBytes = 1024
    let boundedOutcome = await settle(fallible(transport.send(Request(
      httpMethod: rmGet,
      url: "http://127.0.0.1:18943/large",
      headers: initHeaders(),
      options: bounded
    ))))
    doAssert boundedOutcome.isErr
    doAssert boundedOutcome.error.kind == jeBodyTooLarge

    var timed = options
    timed.timeoutMs = 5
    let timedOutcome = await settle(fallible(transport.send(Request(
      httpMethod: rmGet,
      url: "http://127.0.0.1:18943/slow",
      headers: initHeaders(),
      options: timed
    ))))
    doAssert timedOutcome.isErr
    doAssert timedOutcome.error.kind == jeTimeout

    var cancelled = options
    cancelled.cancellation = newCancellationToken()
    cancelled.cancellation.cancel("probe")
    let cancelledOutcome = await settle(fallible(transport.send(Request(
      httpMethod: rmGet,
      url: "http://127.0.0.1:18943/",
      headers: initHeaders(),
      options: cancelled
    ))))
    doAssert cancelledOutcome.isErr
    doAssert cancelledOutcome.error.kind == jeCancelled
  await transport.close()

let probe = main()
waitFor probe
probe.clearCallbacks()
doAssert not hasPendingOperations()
setGlobalDispatcher(nil)
