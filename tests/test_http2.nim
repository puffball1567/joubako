import std/[asyncdispatch, monotimes, strutils, times, unittest]
import joubako/[cookiejar, types]
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

  test "preserves repeated response headers and status errors as responses":
    let transport = newHttp2Transport(allowH2c = true)
    let response = waitFor transport.send(request("/status"))
    check response.status == 418
    check response.headers.getAll("x-test") == @["first", "second"]
    check response.body == ""
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
