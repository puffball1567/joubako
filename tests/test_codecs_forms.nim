import std/[asyncdispatch, jsonutils, strutils, unittest]
import joubako
import ./result_test_helpers

suite "Pluggable codecs":
  test "custom codecs encode requests and decode responses":
    var seenBody = ""
    var seenType = ""
    let handler = proc(request: Request): Future[Response] {.async.} =
      seenBody = request.body
      seenType = request.headers.get("content-type")
      return Response(status: 200, body: "42", request: request)
    let client = newClient(newInProcessTransport(handler))
    let codec = Codec[int, int](
      mediaType: "application/x-number",
      encode: proc(value: int): string = $value,
      decode: proc(payload: string): int = payload.parseInt
    )
    check waitFor(client.sendWithCodec(rmPost, "/", 7, codec)) == 42
    check seenBody == "7"
    check seenType == "application/x-number"

  test "explicit content types override codec defaults":
    var seenType = ""
    let handler = proc(request: Request): Future[Response] {.async.} =
      seenType = request.headers.get("content-type")
      return Response(status: 200, body: "ok", request: request)
    let client = newClient(newInProcessTransport(handler))
    let codec = Codec[string, string](
      mediaType: "application/default",
      encode: proc(value: string): string = value,
      decode: proc(payload: string): string = payload
    )
    var headers = initHeaders()
    headers.set("content-type", "application/custom")
    discard waitFor client.sendWithCodec(rmPost, "/", "body", codec, headers)
    check seenType == "application/custom"

  test "decoder failures become codec errors":
    let handler = proc(request: Request): Future[Response] {.async.} =
      return Response(status: 200, body: "bad", request: request)
    let client = newClient(newInProcessTransport(handler))
    try:
      discard waitFor client.getWithCodec(
        "/",
        proc(payload: string): int = payload.parseInt
      )
      fail()
    except JoubakoError as error:
      check error.kind == jeCodec

  test "nil codec callbacks are rejected":
    let client = newClient(newInProcessTransport(
      proc(request: Request): Future[Response] {.async.} =
        return Response(status: 200, request: request)
    ))
    let codec = Codec[string, string]()
    try:
      discard waitFor client.sendWithCodec(rmPost, "/", "x", codec)
      fail()
    except JoubakoError as error:
      check error.kind == jeInvalidRequest

  test "encoder failures become codec errors before dispatch":
    var dispatched = false
    let handler = proc(request: Request): Future[Response] {.async.} =
      dispatched = true
      return Response(status: 200, request: request)
    let client = newClient(newInProcessTransport(handler))
    let codec = Codec[string, string](
      encode: proc(value: string): string =
        discard value
        raise newException(ValueError, "cannot encode"),
      decode: proc(payload: string): string = payload
    )
    try:
      discard waitFor client.sendWithCodec(rmPost, "/", "x", codec)
      fail()
    except JoubakoError as error:
      check error.kind == jeCodec
      check "cannot encode" in error.msg
    check not dispatched

  test "structured decoder errors are preserved":
    let handler = proc(request: Request): Future[Response] {.async.} =
      return Response(status: 200, body: "x", request: request)
    let client = newClient(newInProcessTransport(handler))
    try:
      discard waitFor client.getWithCodec(
        "/",
        proc(payload: string): string =
          discard payload
          raise newJoubakoError(jeCodec, "specific")
      )
      fail()
    except JoubakoError as error:
      check error.kind == jeCodec
      check error.msg.startsWith("specific")

  test "nil standalone decoders are rejected before dispatch":
    var dispatched = false
    let handler = proc(request: Request): Future[Response] {.async.} =
      dispatched = true
      return Response(status: 200, request: request)
    let client = newClient(newInProcessTransport(handler))
    let decoder: Decoder[string] = nil
    expect JoubakoError:
      discard waitFor client.getWithCodec("/", decoder)
    check not dispatched

  test "response decoders can inspect status and repeated headers":
    let handler = proc(request: Request): Future[Response] {.async.} =
      var headers = initHeaders()
      headers.add("x-value", "one")
      headers.add("x-value", "two")
      return Response(
        status: 201, headers: headers, body: "created", request: request
      )
    let client = newClient(
      newInProcessTransport(handler),
      validateStatus = proc(status: int): bool = status == 201
    )
    let decoded = waitFor client.getWithCodec(
      "/",
      proc(response: Response): string =
        $response.status & ":" & response.headers.getAll("x-value").join(",")
    )
    check decoded == "201:one,two"

  test "asynchronous encoders and response decoders are flattened":
    var seenBody = ""
    let handler = proc(request: Request): Future[Response] {.async.} =
      seenBody = request.body
      return Response(status: 200, body: "21", request: request)
    let codec = Codec[int, int](
      encodeAsync: proc(value: int): Future[string] {.async.} =
        await sleepAsync(1)
        return $value,
      decodeResponseAsync: proc(response: Response): Future[int] {.async.} =
        await sleepAsync(1)
        return response.body.parseInt * 2
    )
    let client = newClient(newInProcessTransport(handler))
    check waitFor(client.sendWithCodec(rmPost, "/", 21, codec)) == 42
    check seenBody == "21"

  test "Result codecs preserve operational encoder errors without dispatch":
    var dispatched = false
    let client = newClient(newInProcessTransport(
      proc(request: Request): Future[Response] {.async.} =
        dispatched = true
        return Response(status: 200, request: request)
    ))
    let codec = Codec[string, string](
      encodeResult: proc(_: string): JResult[string] =
        err[string](newJoubakoError(jeCodec, "rejected")),
      decode: proc(value: string): string = value
    )
    let outcome = asyncdispatch.waitFor client.sendWithCodec(
      rmPost, "/result-encode", "x", codec
    )
    check outcome.isErr
    check outcome.error.kind == jeCodec
    check outcome.error.url == "/result-encode"
    check not dispatched

  test "Result response decoders retain bounded response context":
    let handler = proc(request: Request): Future[Response] {.async.} =
      return Response(status: 200, body: "bad", request: request)
    let client = newClient(newInProcessTransport(handler))
    let outcome = asyncdispatch.waitFor client.getWithCodec(
      "/result-decode",
      proc(_: Response): JResult[int] =
        err[int](newJoubakoError(jeCodec, "rejected"))
    )
    check outcome.isErr
    check outcome.error.url == "/result-decode"
    check outcome.error.hasResponse
    check outcome.error.response.body == "bad"

  test "unexpected exceptions from Result codecs are normalized":
    let handler = proc(request: Request): Future[Response] {.async.} =
      return Response(status: 200, body: "ok", request: request)
    let codec = Codec[string, string](
      encodeResult: proc(_: string): JResult[string] =
        raise newException(ValueError, "unexpected"),
      decode: proc(value: string): string = value
    )
    let outcome = asyncdispatch.waitFor newClient(
      newInProcessTransport(handler)
    ).sendWithCodec(rmPost, "/unexpected", "x", codec)
    check outcome.isErr
    check outcome.error.kind == jeCodec
    check outcome.error.url == "/unexpected"

  test "ambiguous encoder and decoder configurations are rejected":
    var dispatched = false
    let client = newClient(newInProcessTransport(
      proc(request: Request): Future[Response] {.async.} =
        dispatched = true
        return Response(status: 200, request: request)
    ))
    let codec = Codec[string, string](
      encode: proc(value: string): string = value,
      encodeAsync: proc(value: string): Future[string] {.async.} = value,
      decode: proc(value: string): string = value,
      decodeResponse: proc(response: Response): string = response.body
    )
    try:
      discard waitFor client.sendWithCodec(rmPost, "/", "x", codec)
      fail()
    except JoubakoError as error:
      check error.kind == jeInvalidRequest
    check not dispatched

  test "asynchronous decoder failures retain response context":
    let handler = proc(request: Request): Future[Response] {.async.} =
      var headers = initHeaders()
      headers.set("content-type", "application/x-broken")
      return Response(status: 200, headers: headers, body: "bad", request: request)
    let client = newClient(newInProcessTransport(handler))
    try:
      discard waitFor client.getWithCodecAsync(
        "/decode",
        proc(response: Response): Future[int] {.async.} =
          discard response
          raise newException(ValueError, "async decode failed")
      )
      fail()
    except JoubakoError as error:
      check error.kind == jeCodec
      check error.url == "/decode"
      check error.hasResponse
      check error.response.status == 200
      check error.response.body == "bad"
      check error.response.headers.get("content-type") ==
        "application/x-broken"

  test "asynchronous encoder failures stop before dispatch":
    var dispatched = false
    let client = newClient(newInProcessTransport(
      proc(request: Request): Future[Response] {.async.} =
        dispatched = true
        return Response(status: 200, request: request)
    ))
    let codec = Codec[string, string](
      encodeAsync: proc(value: string): Future[string] {.async.} =
        discard value
        raise newException(ValueError, "async encode failed"),
      decode: proc(value: string): string = value
    )
    try:
      discard waitFor client.sendWithCodec(rmPost, "/encode", "x", codec)
      fail()
    except JoubakoError as error:
      check error.kind == jeCodec
      check error.url == "/encode"
    check not dispatched

  test "nil asynchronous Futures become structured codec errors":
    let client = newClient(newInProcessTransport(
      proc(request: Request): Future[Response] {.async.} =
        return Response(status: 200, body: "ok", request: request)
    ))
    let nilEncoder = Codec[string, string](
      encodeAsync: proc(_: string): Future[string] = nil,
      decode: proc(value: string): string = value
    )
    let nilDecoder = Codec[string, string](
      encode: proc(value: string): string = value,
      decodeResponseAsync: proc(_: Response): Future[string] = nil
    )
    for codec in [nilEncoder, nilDecoder]:
      try:
        discard waitFor client.sendWithCodec(rmPost, "/", "x", codec)
        fail()
      except JoubakoError as error:
        check error.kind == jeCodec

  test "codec media type injection is rejected before encoding":
    var encoded = false
    let codec = Codec[string, string](
      mediaType: "text/plain\r\nx-injected: yes",
      encode: proc(value: string): string =
        encoded = true
        value,
      decode: proc(value: string): string = value
    )
    let client = newClient(newInProcessTransport(
      proc(request: Request): Future[Response] {.async.} =
        return Response(status: 200, request: request)
    ))
    try:
      discard waitFor client.sendWithCodec(rmPost, "/", "x", codec)
      fail()
    except JoubakoError as error:
      check error.kind == jeInvalidRequest
    check not encoded

  test "JSON codec options allow additional response fields":
    type SmallPayload = object
      id: int
    let handler = proc(request: Request): Future[Response] {.async.} =
      return Response(
        status: 200, body: "{\"id\":7,\"futureField\":true}", request: request
      )
    var options = defaultJsonCodecOptions()
    options.decodeOptions.allowExtraKeys = true
    let client = newClient(newInProcessTransport(handler))
    let payload = waitFor client.getJson(
      "/", SmallPayload, codecOptions = options
    )
    check payload.id == 7

  test "JSON codec factories honor enum encoding options":
    type Mode = enum
      modeOne,
      modeTwo
    var seenBody = ""
    let handler = proc(request: Request): Future[Response] {.async.} =
      seenBody = request.body
      return Response(status: 200, body: "\"accepted\"", request: request)
    var options = defaultJsonCodecOptions()
    options.encodeOptions.enumMode = joptEnumString
    let codec = jsonCodec[Mode, string](options)
    let client = newClient(newInProcessTransport(handler))
    check waitFor(client.sendWithCodec(rmPost, "/", modeTwo, codec)) ==
      "accepted"
    check seenBody == "\"modeTwo\""

suite "Form bodies":
  test "URL encoded forms preserve repetition and empty values":
    check encodeForm([
      (name: "tag", value: "nim"),
      (name: "tag", value: "native"),
      (name: "empty", value: "")
    ]) == "tag=nim&tag=native&empty="

  test "postForm sets its content type":
    var seen = Request()
    let handler = proc(request: Request): Future[Response] {.async.} =
      seen = request
      return Response(status: 200, request: request)
    let client = newClient(newInProcessTransport(handler))
    discard waitFor client.postForm(
      "/form",
      [(name: "hello", value: "world space")]
    )
    check seen.httpMethod == rmPost
    check seen.body == "hello=world+space"
    check seen.headers.get("content-type") ==
      "application/x-www-form-urlencoded"

  test "empty forms encode to an empty body":
    let fields: seq[QueryParam] = @[]
    check encodeForm(fields) == ""

  test "form names and values encode reserved and Unicode characters":
    check encodeForm([
      (name: "a&b", value: "日本 語")
    ]) == "a%26b=%E6%97%A5%E6%9C%AC+%E8%AA%9E"

  test "caller form content types are retained":
    var seenType = ""
    let handler = proc(request: Request): Future[Response] {.async.} =
      seenType = request.headers.get("content-type")
      return Response(status: 200, request: request)
    let client = newClient(newInProcessTransport(handler))
    var headers = initHeaders()
    headers.set("content-type", "application/custom-form")
    discard waitFor client.postForm(
      "/", [(name: "a", value: "b")], headers
    )
    check seenType == "application/custom-form"

  test "PUT and PATCH form helpers dispatch the right methods":
    var methods: seq[RequestMethod]
    let handler = proc(request: Request): Future[Response] {.async.} =
      methods.add request.httpMethod
      return Response(status: 200, request: request)
    let client = newClient(newInProcessTransport(handler))
    discard waitFor client.putForm("/", [(name: "a", value: "b")])
    discard waitFor client.patchForm("/", [(name: "a", value: "b")])
    check methods == @[rmPut, rmPatch]

suite "Multipart bodies":
  test "fields and binary files are encoded":
    let body = encodeMultipart([
      formField("title", "report"),
      formFile("data", "report.bin", "a\0b")
    ], "boundary")
    check "name=\"title\"\r\n\r\nreport\r\n" in body
    check "filename=\"report.bin\"" in body
    check "Content-Type: application/octet-stream" in body
    check "a\0b" in body
    check body.endsWith("--boundary--\r\n")

  test "multipart header injection is rejected":
    expect JoubakoError:
      discard encodeMultipart([formField("bad\r\nname", "x")], "boundary")

  test "filename injection is rejected":
    expect JoubakoError:
      discard encodeMultipart(
        [formFile("file", "bad\"\r\nname", "x")],
        "boundary"
      )

  test "content type injection is rejected":
    expect JoubakoError:
      discard encodeMultipart([
        formFile("file", "safe.bin", "x", "text/plain\r\nX-Bad: yes")
      ], "boundary")

  test "invalid boundaries are rejected":
    expect JoubakoError:
      discard encodeMultipart([formField("a", "b")], "bad\r\nboundary")

  test "an empty multipart body still has a closing boundary":
    let parts: seq[MultipartPart] = @[]
    check encodeMultipart(parts, "boundary") == "--boundary--\r\n"

  test "generated multipart boundaries differ":
    check multipartBoundary() != multipartBoundary()

  test "plain fields omit a content type":
    let body = encodeMultipart([formField("a", "b")], "boundary")
    check "Content-Type:" notin body

  test "file paths derive a transmitted basename without reading the file":
    let part = formFilePath("document", "/private/source/report.bin")
    check part.filename == "report.bin"
    check part.filePath == "/private/source/report.bin"
    check part.body == ""

  test "file-backed parts cannot enter the buffered encoder":
    expect JoubakoError:
      discard encodeMultipart([
        formFilePath("document", "/private/source/report.bin")
      ], "boundary")

  test "caller multipart content types are retained":
    var seenType = ""
    let handler = proc(request: Request): Future[Response] {.async.} =
      seenType = request.headers.get("content-type")
      return Response(status: 200, request: request)
    let client = newClient(newInProcessTransport(handler))
    var headers = initHeaders()
    headers.set("content-type", "multipart/custom")
    discard waitFor client.postMultipart(
      "/", [formField("a", "b")], headers
    )
    check seenType == "multipart/custom"

  test "multipart bodies still obey request size limits":
    let client = newClient(newInProcessTransport(
      proc(request: Request): Future[Response] {.async.} =
        return Response(status: 200, request: request)
    ))
    var options = defaultRequestOptions()
    options.maxRequestBytes = 1
    expect JoubakoError:
      discard waitFor client.postMultipart(
        "/", [formField("a", "b")], options = options
      )

  test "postMultipart uses the generated boundary":
    var seenHeaders = initHeaders()
    var seenBody = ""
    let handler = proc(request: Request): Future[Response] {.async.} =
      seenHeaders = request.headers
      seenBody = request.body
      return Response(status: 200, request: request)
    let client = newClient(newInProcessTransport(handler))
    discard waitFor client.postMultipart("/", [formField("x", "y")])
    let contentType = seenHeaders.get("content-type")
    check contentType.startsWith("multipart/form-data; boundary=")
    let boundary = contentType.split("boundary=", 1)[1]
    check seenBody.startsWith("--" & boundary & "\r\n")

  test "PUT and PATCH multipart helpers dispatch buffered bodies":
    var methods: seq[RequestMethod]
    let handler = proc(request: Request): Future[Response] {.async.} =
      methods.add request.httpMethod
      check "name=\"x\"" in request.body
      return Response(status: 200, request: request)
    let client = newClient(newInProcessTransport(handler))
    discard waitFor client.putMultipart("/", [formField("x", "put")])
    discard waitFor client.patchMultipart("/", [formField("x", "patch")])
    check methods == @[rmPut, rmPatch]

  test "file-backed multipart is rejected by non-HTTP transports":
    let client = newClient(newInProcessTransport(
      proc(request: Request): Future[Response] {.async.} =
        return Response(status: 200, request: request)
    ))
    try:
      discard waitFor client.postMultipart(
        "/", [formFilePath("file", "/tmp/not-opened-by-inprocess")]
      )
      fail()
    except JoubakoError as error:
      check error.kind == jeInvalidRequest

suite "HTTP method helpers":
  test "HEAD and OPTIONS dispatch their methods":
    var methods: seq[RequestMethod]
    let handler = proc(request: Request): Future[Response] {.async.} =
      methods.add request.httpMethod
      return Response(status: 200, request: request)
    let client = newClient(newInProcessTransport(handler))
    discard waitFor client.head("/")
    discard waitFor client.options("/")
    check methods == @[rmHead, rmOptions]

suite "Authentication helpers":
  test "basic authentication is Base64 encoded":
    var headers = initHeaders()
    headers.setBasicAuth("alice", "secret")
    check headers.get("authorization") == "Basic YWxpY2U6c2VjcmV0"

  test "bearer tokens replace existing authorization":
    var headers = initHeaders()
    headers.set("authorization", "old")
    headers.setBearerToken("token")
    check headers.get("authorization") == "Bearer token"

  test "basic authentication preserves separators in passwords":
    var headers = initHeaders()
    headers.setBasicAuth("alice", "a:b")
    check headers.get("authorization") == "Basic YWxpY2U6YTpi"

  test "empty bearer tokens have deterministic output":
    var headers = initHeaders()
    headers.setBearerToken("")
    check headers.get("authorization") == "Bearer "
