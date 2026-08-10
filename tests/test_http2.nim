import std/[asyncdispatch, monotimes, os, strutils, times, unittest]
import joubako/[client, cookiejar, multipart, result, types, uploadstream]
import joubako/transports/http2

const
  h2Host = "127.0.0.1"
  h2Port = 18_942
  h2Base = "http://" & h2Host & ":" & $h2Port

proc options(): RequestOptions =
  result = defaultRequestOptions()
  result.retry.maxAttempts = 1

proc request(
    path: string;
    httpMethod = rmGet;
    body = "";
    requestOptions = options();
    headers = initHeaders()
): Request =
  Request(
    httpMethod: httpMethod,
    url: h2Base & path,
    headers: headers,
    body: body,
    options: requestOptions
  )

proc errorKind(pending: Future[Response]): ErrorKind =
  try:
    discard waitFor pending
    doAssert false, "request unexpectedly succeeded"
  except JoubakoError as error:
    result = error.kind

suite "HTTP/2 transport":
  test "streams a request body in order through a bounded producer queue":
    let transport = newHttp2Transport(allowH2c = true)
    let api = newClient(transport, h2Base)
    let upload = api.openUpload(
      rmPost, "/upload-stream", maxBufferedBytes = 7
    )
    check (waitFor upload.send("alpha-")).isOk
    check (waitFor upload.send(repeat("0123456789", 4096))).isOk
    check (waitFor upload.send("-omega")).isOk
    let outcome = waitFor upload.finish()
    check outcome.isOk
    if outcome.isOk:
      check outcome.value.httpVersion == "HTTP/2"
      check outcome.value.body ==
        "POST:alpha-" & repeat("0123456789", 4096) & "-omega"
      check outcome.value.request.uploadSource == nil
    check upload.acceptedBytes == (40 * 1024 + 12).int64
    check upload.queuedBytes == 0
    waitFor transport.close()

  test "applies asynchronous backpressure when the upload queue is full":
    let transport = newHttp2Transport(allowH2c = true)
    let upload = newClient(transport, h2Base).openUpload(
      rmPost, "/slow-upload", maxBufferedBytes = 8
    )
    let sending = upload.send(repeat('b', 4 * 1024))
    check not sending.finished
    let sent = waitFor sending
    check sent.isOk
    let outcome = waitFor upload.finish()
    check outcome.isOk
    check upload.queuedBytes == 0
    waitFor transport.close()

  test "rejects oversized streaming input and wakes the transport":
    let transport = newHttp2Transport(allowH2c = true)
    var opts = options()
    opts.maxRequestBytes = 5
    let upload = newClient(transport, h2Base).openUpload(
      rmPut, "/upload-stream", options = opts, maxBufferedBytes = 2
    )
    let sent = waitFor upload.send("123456")
    check sent.isErr
    check sent.error.kind == jeBodyTooLarge
    let outcome = waitFor upload.finish()
    check outcome.isErr
    check outcome.error.kind in {jeBodyTooLarge, jeStream}
    waitFor transport.close()

  test "cancels a blocked streaming producer without hanging":
    let transport = newHttp2Transport(allowH2c = true)
    let upload = newClient(transport, h2Base).openUpload(
      rmPost, "/slow-upload", maxBufferedBytes = 8
    )
    let sending = upload.send(repeat('c', 512 * 1024))
    upload.cancel("stop streaming upload")
    let sent = waitFor sending
    check sent.isErr
    check sent.error.kind == jeCancelled
    let outcome = waitFor upload.finish()
    check outcome.isErr
    check outcome.error.kind in {jeCancelled, jeStream}
    waitFor transport.close()

  test "does not replay a consumed upload across redirects":
    let transport = newHttp2Transport(allowH2c = true)
    let upload = newClient(transport, h2Base).openUpload(
      rmPost, "/upload-redirect", maxBufferedBytes = 16
    )
    check (waitFor upload.send("single-use")).isOk
    let outcome = waitFor upload.finish()
    check outcome.isErr
    check outcome.error.kind == jeTransport
    waitFor transport.close()

  test "rejects retry policy for a non-replayable upload source":
    let transport = newHttp2Transport(allowH2c = true)
    var opts = options()
    opts.retry.maxAttempts = 2
    let upload = newClient(transport, h2Base).openUpload(
      rmPost, "/upload-stream", options = opts
    )
    let outcome = waitFor upload.finish()
    check outcome.isErr
    check outcome.error.kind == jeInvalidRequest
    waitFor transport.close()

  test "rejects h2c unless explicitly enabled":
    let transport = newHttp2Transport()
    check errorKind(transport.send(request("/"))) == jeInvalidRequest
    waitFor transport.close()

  test "reports HTTP/2 and receives a bounded response":
    let transport = newHttp2Transport(allowH2c = true)
    let response = waitFor transport.send(request("/"))
    check response.status == 200
    check response.statusText == ""
    check response.httpVersion == "HTTP/2"
    check response.body == "ok"
    check response.headers.get("content-type") == "text/plain"
    waitFor transport.close()

  test "sends methods, request bodies, and upload progress":
    let transport = newHttp2Transport(allowH2c = true)
    var progress: seq[(int64, int64)]
    var opts = options()
    opts.onUploadProgress = proc(done, total: int64) =
      progress.add (done, total)
    let payload = repeat('p', 40 * 1024)
    let response = waitFor transport.send(
      request("/echo", rmPost, payload, opts)
    )
    check response.body == "POST:" & payload
    check progress.len >= 1
    check progress[^1] == (payload.len.int64, payload.len.int64)
    waitFor transport.close()

  test "streams mixed file-backed multipart parts with progress":
    let uploadPath = getTempDir() / "joubako-http2-multipart-upload.txt"
    writeFile(uploadPath, repeat("file-payload-", 8 * 1024))
    defer:
      if fileExists(uploadPath):
        removeFile(uploadPath)
    let transport = newHttp2Transport(allowH2c = true)
    var progress: seq[(int64, int64)]
    var opts = options()
    opts.onUploadProgress = proc(done, total: int64) =
      progress.add (done, total)
    var multipartRequest = request(
      "/multipart", rmPost, requestOptions = opts
    )
    multipartRequest.multipartParts = @[
      MultipartPart(name: "description", body: "from-nim"),
      MultipartPart(
        name: "memory-file",
        filename: "memory.txt",
        contentType: "text/plain",
        body: "buffered-data"
      ),
      MultipartPart(
        name: "disk-file",
        filename: "payload.txt",
        contentType: "text/plain",
        filePath: uploadPath
      )
    ]
    multipartRequest.headers.set("content-length", "1")
    let response = waitFor transport.send(multipartRequest)
    check response.body.startsWith("multipart/form-data; boundary=")
    check "name=\"description\"" in response.body
    check "from-nim" in response.body
    check "filename=\"memory.txt\"" in response.body
    check "buffered-data" in response.body
    check "filename=\"payload.txt\"" in response.body
    check "joubako-http2-multipart-upload.txt" notin response.body
    check repeat("file-payload-", 8 * 1024) in response.body
    check progress.len > 0
    check progress[^1][0] == progress[^1][1]
    check progress[^1][0] > getFileSize(uploadPath)
    waitFor transport.close()

  test "reopens file-backed multipart parts across 307 redirects":
    let uploadPath = getTempDir() / "joubako-http2-multipart-redirect.txt"
    writeFile(uploadPath, "redirected-file")
    defer:
      if fileExists(uploadPath):
        removeFile(uploadPath)
    let transport = newHttp2Transport(allowH2c = true)
    var multipartRequest = request("/multipart-redirect", rmPost)
    multipartRequest.multipartParts = @[
      MultipartPart(
        name: "disk-file",
        filename: "redirect.txt",
        contentType: "text/plain",
        filePath: uploadPath
      )
    ]
    let response = waitFor transport.send(multipartRequest)
    check "filename=\"redirect.txt\"" in response.body
    check "redirected-file" in response.body
    waitFor transport.close()

  test "public PUT and PATCH helpers stream file-backed parts over HTTP/2":
    let uploadPath = getTempDir() / "joubako-http2-multipart-method.txt"
    writeFile(uploadPath, "method-file")
    defer:
      if fileExists(uploadPath):
        removeFile(uploadPath)
    let transport = newHttp2Transport(allowH2c = true)
    let api = newClient(transport, h2Base & "/")
    let parts = @[
      formField("field", "value"),
      formFilePath(
        "file", uploadPath,
        filename = "method.txt",
        contentType = "text/plain"
      )
    ]
    let putOutcome = waitFor api.putMultipart("multipart-method", parts)
    check putOutcome.isOk
    if putOutcome.isOk:
      check putOutcome.value.body.startsWith(
        "PUT\nmultipart/form-data; boundary="
      )
      check "filename=\"method.txt\"" in putOutcome.value.body
      check "method-file" in putOutcome.value.body
    let patchOutcome = waitFor api.patchMultipart("multipart-method", parts)
    check patchOutcome.isOk
    if patchOutcome.isOk:
      check patchOutcome.value.body.startsWith(
        "PATCH\nmultipart/form-data; boundary="
      )
      check "filename=\"method.txt\"" in patchOutcome.value.body
      check "method-file" in patchOutcome.value.body
    waitFor transport.close()

  test "drops multipart bodies when a 303 redirect changes to GET":
    let uploadPath = getTempDir() / "joubako-http2-multipart-303.txt"
    writeFile(uploadPath, "must-not-be-replayed")
    defer:
      if fileExists(uploadPath):
        removeFile(uploadPath)
    let transport = newHttp2Transport(allowH2c = true)
    var multipartRequest = request("/multipart-redirect-get", rmPost)
    multipartRequest.multipartParts = @[
      MultipartPart(
        name: "disk-file",
        filename: "redirect.txt",
        contentType: "text/plain",
        filePath: uploadPath
      )
    ]
    let response = waitFor transport.send(multipartRequest)
    check response.body == "GET:"
    waitFor transport.close()

  test "rejects missing multipart files and wire sizes before dispatch":
    let transport = newHttp2Transport(allowH2c = true)
    var missingRequest = request("/multipart", rmPost)
    missingRequest.multipartParts = @[
      MultipartPart(
        name: "disk-file",
        filename: "missing.txt",
        contentType: "text/plain",
        filePath: getTempDir() / "joubako-http2-does-not-exist"
      )
    ]
    check errorKind(transport.send(missingRequest)) == jeStream

    let uploadPath = getTempDir() / "joubako-http2-multipart-limit.txt"
    writeFile(uploadPath, "12345678")
    defer:
      if fileExists(uploadPath):
        removeFile(uploadPath)
    var opts = options()
    opts.maxRequestBytes = 8
    var oversizedRequest = request(
      "/multipart", rmPost, requestOptions = opts
    )
    oversizedRequest.multipartParts = @[
      MultipartPart(
        name: "disk-file",
        filename: "limit.txt",
        contentType: "text/plain",
        filePath: uploadPath
      )
    ]
    check errorKind(transport.send(oversizedRequest)) == jeBodyTooLarge

    var conflictingRequest = request("/multipart", rmPost, "body")
    conflictingRequest.multipartParts = @[
      MultipartPart(name: "field", body: "value")
    ]
    check errorKind(transport.send(conflictingRequest)) == jeInvalidRequest

    conflictingRequest.body = ""
    conflictingRequest.headers.set(
      "content-type", "multipart/form-data; boundary=caller"
    )
    check errorKind(transport.send(conflictingRequest)) == jeInvalidRequest
    waitFor transport.close()

  test "cancels a file-backed multipart upload in progress":
    let uploadPath = getTempDir() / "joubako-http2-multipart-cancel.txt"
    writeFile(uploadPath, repeat('x', 512 * 1024))
    defer:
      if fileExists(uploadPath):
        removeFile(uploadPath)
    let transport = newHttp2Transport(allowH2c = true)
    let token = newCancellationToken()
    var opts = options()
    opts.cancellation = token
    opts.onUploadProgress = proc(done, total: int64) =
      if done > 0:
        token.cancel("stop multipart upload")
    var multipartRequest = request(
      "/slow-upload", rmPost, requestOptions = opts
    )
    multipartRequest.multipartParts = @[
      MultipartPart(
        name: "disk-file",
        filename: "cancel.txt",
        contentType: "text/plain",
        filePath: uploadPath
      )
    ]
    check errorKind(transport.send(multipartRequest)) == jeCancelled
    waitFor transport.close()

  test "preserves repeated response headers and status errors as responses":
    let transport = newHttp2Transport(allowH2c = true)
    let response = waitFor transport.send(request("/status"))
    check response.status == 418
    check response.headers.getAll("x-test") == @["first", "second"]
    check response.body == ""
    waitFor transport.close()

  test "keeps HTTP/2 trailers separate from initial headers":
    let transport = newHttp2Transport(allowH2c = true)
    let response = waitFor transport.send(request("/trailers"))
    check response.headers.get("x-initial") == "header"
    check not response.headers.contains("x-final")
    check response.trailers.get("x-final") == "trailer"
    waitFor transport.close()

  test "follows bounded relative redirects":
    let transport = newHttp2Transport(allowH2c = true)
    let response = waitFor transport.send(request("/redirect"))
    check response.status == 200
    check response.body == "ok"
    check response.request.url == h2Base & "/redirect"
    waitFor transport.close()

  test "rejects redirect loops at the configured limit":
    let transport = newHttp2Transport(maxRedirects = 2, allowH2c = true)
    check errorKind(transport.send(request("/redirect-loop"))) == jeTransport
    waitFor transport.close()

  test "cookie jar stores and replays cookies across redirects":
    let jar = newCookieJar()
    let transport = newHttp2Transport(allowH2c = true, cookieJar = jar)
    check transport.usesImplicitCredentials
    let response = waitFor transport.send(request("/set-cookie"))
    check "cookie: session=h2" in response.body
    waitFor transport.close()

  test "invokes headers before download consumers":
    let transport = newHttp2Transport(allowH2c = true)
    var events: seq[string]
    var opts = options()
    opts.onResponseHeaders = proc(status: int; headers: Headers) =
      check status == 200
      check headers.get("content-type") == "text/plain"
      events.add "headers"
    opts.onDownloadChunk = proc(chunk: string) =
      events.add "sync:" & chunk
    opts.onDownloadChunkAsync = proc(chunk: string): Future[void] {.async.} =
      await sleepAsync(1)
      events.add "async:" & chunk
    let response = waitFor transport.send(request("/chunks", requestOptions = opts))
    check response.body == "onetwothree"
    check events.len >= 3
    check events[0] == "headers"
    check events[1].startsWith("sync:")
    check events[2].startsWith("async:")
    waitFor transport.close()

  test "streamResponse delivers without retaining the body":
    let transport = newHttp2Transport(allowH2c = true)
    var delivered = ""
    var opts = options()
    opts.streamResponse = true
    opts.onDownloadChunk = proc(chunk: string) = delivered.add chunk
    let response = waitFor transport.send(request("/chunks", requestOptions = opts))
    check delivered == "onetwothree"
    check response.body == ""
    waitFor transport.close()

  test "enforces the response limit while streaming":
    let transport = newHttp2Transport(allowH2c = true)
    var opts = options()
    opts.maxResponseBytes = 1024
    check errorKind(transport.send(request("/large", requestOptions = opts))) ==
      jeBodyTooLarge
    waitFor transport.close()

  test "enforces the request limit before connecting":
    let transport = newHttp2Transport(allowH2c = true)
    var opts = options()
    opts.maxRequestBytes = 2
    check errorKind(transport.send(request("/echo", rmPost, "abc", opts))) ==
      jeBodyTooLarge
    waitFor transport.close()

  test "enforces allowed hosts":
    let transport = newHttp2Transport(allowH2c = true)
    var opts = options()
    opts.allowedHosts = @["example.com"]
    check errorKind(transport.send(request("/", requestOptions = opts))) ==
      jeInvalidRequest
    waitFor transport.close()

  test "filters HTTP/1 connection headers":
    let transport = newHttp2Transport(allowH2c = true)
    var headers = initHeaders()
    headers.set("connection", "keep-alive")
    headers.set("upgrade", "h2c")
    headers.set("te", "gzip")
    headers.set("x-safe", "yes")
    let response = waitFor transport.send(request("/headers", headers = headers))
    check "connection:" notin response.body
    check "upgrade:" notin response.body
    check "te:" notin response.body
    check "x-safe: yes" in response.body
    waitFor transport.close()

  test "maps total timeout and remains reusable with a fresh connection":
    let transport = newHttp2Transport(allowH2c = true)
    var opts = options()
    opts.timeoutMs = 20
    check errorKind(transport.send(request("/slow", requestOptions = opts))) ==
      jeTimeout
    let response = waitFor transport.send(request("/"))
    check response.body == "ok"
    waitFor transport.close()

  test "maps pre-cancellation without opening a connection":
    let transport = newHttp2Transport(allowH2c = true)
    var opts = options()
    opts.cancellation = newCancellationToken()
    opts.cancellation.cancel("stop")
    check errorKind(transport.send(request("/", requestOptions = opts))) ==
      jeCancelled
    waitFor transport.close()

  test "multiplexes concurrent requests over one transport":
    let transport = newHttp2Transport(allowH2c = true)
    let started = getMonoTime()
    let first = transport.send(request("/slow"))
    let second = transport.send(request("/slow"))
    let responses = waitFor all(first, second)
    let elapsed = (getMonoTime() - started).inMilliseconds
    check responses[0].body == "slow"
    check responses[1].body == "slow"
    check elapsed < 220
    waitFor transport.close()
