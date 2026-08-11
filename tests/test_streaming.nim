import std/[asyncdispatch, os, strutils, unittest]
import joubako

var pathCounter = 0

proc temporaryFile(label: string): string =
  inc pathCounter
  getTempDir() / ("joubako-" & label & "-" & $getCurrentProcessId() &
    "-" & $pathCounter & ".bin")

proc partialHeaders(contentRange: string; encoding = ""): Headers =
  result = initHeaders()
  result.set("content-range", contentRange)
  if encoding.len > 0:
    result.set("content-encoding", encoding)

suite "file download streaming":
  test "resumes a partial file only after validating response metadata":
    let outputPath = temporaryFile("resume")
    writeFile(outputPath, "hello ")
    defer: removeFile(outputPath)
    var progress: seq[(int64, int64)]
    let client = newClient(newInProcessTransport(
      proc(request: Request): Future[Response] {.async.} =
        doAssert request.headers.get("range") == "bytes=6-"
        doAssert request.headers.get("if-range") == "\"revision-7\""
        doAssert request.headers.get("accept-encoding") == "identity"
        doAssert request.options.retry.maxAttempts == 1
        return Response(
          status: 206,
          headers: partialHeaders("bytes 6-10/11"),
          body: "world",
          request: request
        )
    ))
    var options = defaultRequestOptions()
    options.onDownloadProgress = proc(current, total: int64) =
      progress.add (current, total)
    let outcome = waitFor client.resumeDownloadToFile(
      "inprocess://download", outputPath, "\"revision-7\"",
      options = options
    )
    check outcome.isOk
    check outcome.value.body == ""
    check outcome.value.request.options.onDownloadChunkAsync.isNil
    check outcome.value.request.options.onResponseHeaders.isNil
    check readFile(outputPath) == "hello world"
    check progress == @[(11'i64, 11'i64)]

  test "a missing or empty partial file becomes a fresh download":
    for createEmpty in [false, true]:
      let outputPath = temporaryFile("fresh")
      if createEmpty:
        writeFile(outputPath, "")
      defer:
        if fileExists(outputPath): removeFile(outputPath)
      let client = newClient(newInProcessTransport(
        proc(request: Request): Future[Response] {.async.} =
          doAssert not request.headers.contains("range")
          doAssert request.options.retry.maxAttempts == 1
          return Response(status: 200, body: "complete", request: request)
      ))
      let outcome = waitFor client.resumeDownloadToFile(
        "inprocess://fresh", outputPath
      )
      check outcome.isOk
      check readFile(outputPath) == "complete"

  test "downloadToFile disables unsafe transport retries":
    let outputPath = temporaryFile("single-attempt")
    defer:
      if fileExists(outputPath): removeFile(outputPath)
    let client = newClient(newInProcessTransport(
      proc(request: Request): Future[Response] {.async.} =
        doAssert request.options.retry.maxAttempts == 1
        return Response(status: 200, body: "safe", request: request)
    ))
    check (waitFor client.downloadToFile(
      "inprocess://single-attempt", outputPath
    )).isOk
    check readFile(outputPath) == "safe"

  test "an ignored Range request never overwrites or appends the partial file":
    let outputPath = temporaryFile("ignored-range")
    writeFile(outputPath, "partial")
    defer: removeFile(outputPath)
    var headersObserved = 0
    let client = newClient(newInProcessTransport(
      proc(request: Request): Future[Response] {.async.} =
        return Response(status: 200, body: "whole-new-body", request: request)
    ))
    var options = defaultRequestOptions()
    options.onResponseHeaders = proc(status: int; headers: Headers) =
      discard status
      discard headers
      inc headersObserved
    let outcome = waitFor client.resumeDownloadToFile(
      "inprocess://ignored", outputPath, options = options
    )
    check outcome.isErr
    check outcome.error.kind == jeStream
    check "expected HTTP 206" in outcome.error.msg
    check headersObserved == 1
    check readFile(outputPath) == "partial"

  test "inconsistent range metadata is rejected before writing":
    for contentRange in [
      "", "items 7-9/10", "bytes", "bytes x-9/10", "bytes 7-x/10",
      "bytes 7-6/10", "bytes 6-9/10", "bytes 7-9/9",
      "bytes 7-9/invalid"
    ]:
      let outputPath = temporaryFile("invalid-range")
      writeFile(outputPath, "1234567")
      defer: removeFile(outputPath)
      let capturedRange = contentRange
      let client = newClient(newInProcessTransport(
        proc(request: Request): Future[Response] {.async.} =
          return Response(
            status: 206,
            headers: partialHeaders(capturedRange),
            body: "tail",
            request: request
          )
      ))
      let outcome = waitFor client.resumeDownloadToFile(
        "inprocess://invalid", outputPath
      )
      check outcome.isErr
      check outcome.error.kind == jeStream
      check readFile(outputPath) == "1234567"

  test "unknown totals are accepted but transformed ranges are rejected":
    block accepted:
      let outputPath = temporaryFile("unknown-total")
      writeFile(outputPath, "1234567")
      defer: removeFile(outputPath)
      let client = newClient(newInProcessTransport(
        proc(request: Request): Future[Response] {.async.} =
          return Response(
            status: 206,
            headers: partialHeaders("bytes 7-10/*"),
            body: "tail",
            request: request
          )
      ))
      check (waitFor client.resumeDownloadToFile(
        "inprocess://unknown", outputPath
      )).isOk
      check readFile(outputPath) == "1234567tail"

    block encoded:
      let outputPath = temporaryFile("encoded")
      writeFile(outputPath, "partial")
      defer: removeFile(outputPath)
      let client = newClient(newInProcessTransport(
        proc(request: Request): Future[Response] {.async.} =
          return Response(
            status: 206,
            headers: partialHeaders("bytes 7-10/11", "gzip"),
            body: "tail",
            request: request
          )
      ))
      let outcome = waitFor client.resumeDownloadToFile(
        "inprocess://encoded", outputPath
      )
      check outcome.isErr
      check "identity content encoding" in outcome.error.msg
      check readFile(outputPath) == "partial"
