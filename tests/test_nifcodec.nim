import std/[asyncdispatch, sequtils, strutils, unittest]
import nifkit
import joubako
import ./result_test_helpers

proc echoBif(request: Request): Future[Response] {.async.} =
  return Response(status: 200, body: request.body, request: request)

proc waitOutcome[T](future: Future[JResult[T]]): JResult[T] =
  asyncdispatch.waitFor(future)

template expectCodecFailure(expectedCode: string; body: untyped) =
  block:
    try:
      body
      fail()
    except JoubakoError as error:
      check error.kind == jeCodec
      check error.codecCode == expectedCode

suite "NIFKit codec integration":
  test "default options retain every finite NIFKit limit":
    let options = defaultNifCodecOptions()
    let expected = defaultCodecLimits()
    check options.encodeLimits == expected
    check options.decodeLimits == expected
    check expected.maxInputBytes > 0
    check expected.maxOutputBytes > 0
    check expected.maxNestingDepth > 0
    check expected.maxTokens > 0
    check expected.maxPoolEntries > 0
    check expected.maxPoolBytes > 0
    check expected.maxStringBytes > 0
    check expected.maxIndexEntries > 0

  test "nifCodec sends BIF v5 and returns canonical NIF":
    var wireBody = ""
    var contentType = ""
    let handler = proc(request: Request): Future[Response] {.async.} =
      wireBody = request.body
      contentType = request.headers.get("content-type")
      validateBif(wireBody)
      return Response(
        status: 200,
        body: nifToBif("(reply \"ok\" 7)"),
        request: request
      )
    let client = newClient(newInProcessTransport(handler))
    let decoded = waitFor client.postNif(
      "/nif",
      "(command   \"run\"  3)"
    )
    check wireBody.startsWith("NIFBIN\0\5")
    check bifToNif(wireBody) == "(command \"run\" 3)"
    check contentType == BifMediaType
    check decoded == "(reply \"ok\" 7)"

  test "caller content types override the provisional BIF media type":
    var seenType = ""
    let handler = proc(request: Request): Future[Response] {.async.} =
      seenType = request.headers.get("content-type")
      return Response(status: 200, body: nifToBif("ok"), request: request)
    var headers = initHeaders()
    headers.set("content-type", "application/vnd.example.bif")
    let client = newClient(newInProcessTransport(handler))
    discard waitFor client.postNif("/", "request", headers)
    check seenType == "application/vnd.example.bif"

  test "getNif sends no BIF request body and decodes the response":
    var seenBody = "unexpected"
    var seenType = "unexpected"
    let handler = proc(request: Request): Future[Response] {.async.} =
      seenBody = request.body
      seenType = request.headers.get("content-type")
      return Response(
        status: 200,
        body: nifToBif("(result true)"),
        request: request
      )
    let client = newClient(newInProcessTransport(handler))
    check waitFor(client.getNif("/result")) == "(result true)"
    check seenBody.len == 0
    check seenType.len == 0

  test "send helpers dispatch POST PUT and PATCH":
    var methods: seq[RequestMethod]
    let handler = proc(request: Request): Future[Response] {.async.} =
      methods.add request.httpMethod
      return Response(status: 200, body: nifToBif("ok"), request: request)
    let client = newClient(newInProcessTransport(handler))
    discard waitFor client.postNif("/", "one")
    discard waitFor client.putNif("/", "two")
    discard waitFor client.patchNif("/", "three")
    discard waitFor client.sendNif(rmDelete, "/", "four")
    check methods == @[rmPost, rmPut, rmPatch, rmDelete]

  test "binary NUL bytes remain intact through the transport boundary":
    var captured = ""
    let handler = proc(request: Request): Future[Response] {.async.} =
      captured = request.body
      return Response(status: 200, body: request.body, request: request)
    let source = "(record title \"NIF\" -5 12u)"
    let decoded = waitFor newClient(newInProcessTransport(handler)).postNif(
      "/",
      source
    )
    check '\0' in captured
    check captured == nifToBif(source)
    check decoded == source

  test "malformed NIF fails before transport dispatch":
    var dispatched = false
    let handler = proc(request: Request): Future[Response] {.async.} =
      dispatched = true
      return Response(status: 200, request: request)
    let outcome = waitOutcome newClient(newInProcessTransport(handler)).postNif(
      "/malformed",
      "(unterminated"
    )
    check outcome.isErr
    check outcome.error.kind == jeCodec
    check outcome.error.codecCode == "nkeMalformedInput"
    check outcome.error.codecOffset == -1
    check outcome.error.url == "/malformed"
    check not dispatched

  test "malformed BIF retains structured code response context and offset":
    let handler = proc(request: Request): Future[Response] {.async.} =
      var headers = initHeaders()
      headers.set("content-type", BifMediaType)
      return Response(
        status: 200,
        headers: headers,
        body: "not-bif",
        request: request
      )
    let outcome = waitOutcome newClient(newInProcessTransport(handler)).getNif(
      "/malformed-response"
    )
    check outcome.isErr
    check outcome.error.kind == jeCodec
    check outcome.error.codecCode == "nkeMalformedInput"
    check outcome.error.codecOffset == -1
    check outcome.error.url == "/malformed-response"
    check outcome.error.status == 200
    check outcome.error.hasResponse
    check outcome.error.response.body == "not-bif"

  test "unsupported BIF versions remain distinguishable":
    var unsupported = nifToBif("ok")
    unsupported[7] = char(4)
    let handler = proc(request: Request): Future[Response] {.async.} =
      return Response(status: 200, body: unsupported, request: request)
    let outcome = waitOutcome newClient(newInProcessTransport(handler)).getNif(
      "/version"
    )
    check outcome.isErr
    check outcome.error.codecCode == "nkeUnsupportedVersion"

  test "HTTP status validation happens before BIF decoding":
    let handler = proc(request: Request): Future[Response] {.async.} =
      return Response(status: 503, body: "not-bif", request: request)
    let outcome = waitOutcome newClient(newInProcessTransport(handler)).getNif(
      "/unavailable"
    )
    check outcome.isErr
    check outcome.error.kind == jeHttpStatus
    check outcome.error.codecCode.len == 0

  test "NIF input limits accept the boundary and reject one byte more":
    let source = "abc"
    var options = defaultNifCodecOptions()
    options.encodeLimits.maxInputBytes = source.len
    check waitFor(newClient(newInProcessTransport(echoBif)).postNif(
      "/", source, codecOptions = options
    )) == source
    options.encodeLimits.maxInputBytes = source.len - 1
    let outcome = waitOutcome newClient(newInProcessTransport(echoBif)).postNif(
      "/input-limit", source, codecOptions = options
    )
    check outcome.isErr
    check outcome.error.codecCode == "nkeInputTooLarge"

  test "BIF input limits accept the boundary and reject one byte more":
    let bif = nifToBif("response")
    let handler = proc(request: Request): Future[Response] {.async.} =
      return Response(status: 200, body: bif, request: request)
    var options = defaultNifCodecOptions()
    options.decodeLimits.maxInputBytes = bif.len
    let client = newClient(newInProcessTransport(handler))
    check waitFor(client.getNif("/", codecOptions = options)) == "response"
    options.decodeLimits.maxInputBytes = bif.len - 1
    let outcome = waitOutcome client.getNif(
      "/decode-limit", codecOptions = options
    )
    check outcome.isErr
    check outcome.error.codecCode == "nkeInputTooLarge"

  test "codec output limits are enforced in both directions":
    let encoded = nifToBif("x")
    var encodeLimits = defaultCodecLimits()
    encodeLimits.maxOutputBytes = encoded.len
    check encodeNifPayload("x", encodeLimits) == encoded
    encodeLimits.maxOutputBytes = encoded.len - 1
    expectCodecFailure("nkeOutputTooLarge"):
      discard encodeNifPayload("x", encodeLimits)

    var decodeLimits = defaultCodecLimits()
    decodeLimits.maxOutputBytes = 1
    let response = Response(body: encoded)
    check response.decodeBifResponse(decodeLimits) == "x"
    decodeLimits.maxOutputBytes = 0
    expectCodecFailure("nkeOutputTooLarge"):
      discard response.decodeBifResponse(decodeLimits)

  test "nesting token pool string and index limits retain their codes":
    var limits = defaultCodecLimits()
    limits.maxNestingDepth = 1
    expectCodecFailure("nkeNestingTooDeep"):
      discard encodeNifPayload("(a (b x))", limits)

    limits = defaultCodecLimits()
    limits.maxTokens = 0
    expectCodecFailure("nkeTokenLimit"):
      discard encodeNifPayload("x", limits)

    limits = defaultCodecLimits()
    limits.maxPoolEntries = 0
    expectCodecFailure("nkePoolLimit"):
      discard encodeNifPayload("\"pooled\"", limits)

    limits = defaultCodecLimits()
    limits.maxStringBytes = 5
    expectCodecFailure("nkeStringLimit"):
      discard encodeNifPayload("\"abcdef\"", limits)

    let indexed = nifToBif("(defs :pkg.0.public)")
    limits = defaultCodecLimits()
    limits.maxIndexEntries = 0
    let indexedResponse = Response(body: indexed)
    expectCodecFailure("nkeIndexLimit"):
      discard indexedResponse.decodeBifResponse(limits)

  test "negative limit configurations become structured codec errors":
    var limits = defaultCodecLimits()
    limits.maxTokens = -1
    expectCodecFailure("nkeMalformedInput"):
      discard encodeNifPayload("x", limits, "/negative")

  test "Joubako request limits apply to encoded BIF bytes":
    let source = "x"
    let encodedSize = nifToBif(source).len
    var options = defaultRequestOptions()
    options.maxRequestBytes = encodedSize - 1
    var dispatched = false
    let handler = proc(request: Request): Future[Response] {.async.} =
      dispatched = true
      return Response(status: 200, body: request.body, request: request)
    let outcome = waitOutcome newClient(newInProcessTransport(handler)).postNif(
      "/request-size",
      source,
      options = options
    )
    check outcome.isErr
    check outcome.error.kind == jeBodyTooLarge
    check not dispatched

  test "Joubako response limits apply before BIF decoding":
    let bif = nifToBif("x")
    let handler = proc(request: Request): Future[Response] {.async.} =
      return Response(status: 200, body: bif, request: request)
    var options = defaultRequestOptions()
    options.maxResponseBytes = bif.len - 1
    let outcome = waitOutcome newClient(newInProcessTransport(handler)).getNif(
      "/response-size",
      options = options
    )
    check outcome.isErr
    check outcome.error.kind == jeBodyTooLarge

  test "an error does not poison a later conversion":
    let client = newClient(newInProcessTransport(echoBif))
    let failed = waitOutcome client.postNif("/", "(")
    check failed.isErr
    check waitFor(client.postNif("/", "(ok true)")) == "(ok true)"

  test "empty NIF documents round-trip without special cases":
    check waitFor(newClient(newInProcessTransport(echoBif)).postNif(
      "/empty", ""
    )) == ""

  test "Unicode strings survive a binary round trip":
    let source = "(message \"日本語\" true)"
    check waitFor(newClient(newInProcessTransport(echoBif)).postNif(
      "/unicode", source
    )) == source

  test "unsupported NIF escapes fail before transport dispatch":
    var dispatched = false
    let handler = proc(request: Request): Future[Response] {.async.} =
      dispatched = true
      return Response(status: 200, body: request.body, request: request)
    let outcome = waitOutcome newClient(
      newInProcessTransport(handler)
    ).postNif("/escape", "\"bad\\\"quote\"")
    check outcome.isErr
    if outcome.isErr:
      check outcome.error.codecCode == "nkeMalformedInput"
    check not dispatched

  test "request and response size limits accept exact BIF boundaries":
    let source = "(exact boundary)"
    let wireBytes = nifToBif(source).len
    var options = defaultRequestOptions()
    options.maxRequestBytes = wireBytes
    options.maxResponseBytes = wireBytes
    check waitFor(newClient(newInProcessTransport(echoBif)).postNif(
      "/exact", source, options = options
    )) == source

  test "encode and decode limits remain independent":
    let responseSource = "(response (nested value))"
    let handler = proc(request: Request): Future[Response] {.async.} =
      return Response(
        status: 200,
        body: nifToBif(responseSource),
        request: request
      )
    var options = defaultNifCodecOptions()
    options.encodeLimits.maxNestingDepth = 1
    options.decodeLimits.maxNestingDepth = 8
    let client = newClient(newInProcessTransport(handler))
    check waitFor(client.postNif(
      "/independent", "request", codecOptions = options
    )) == responseSource

    options.encodeLimits.maxNestingDepth = 8
    options.decodeLimits.maxNestingDepth = 1
    let outcome = waitOutcome client.postNif(
      "/independent", "request", codecOptions = options
    )
    check outcome.isErr
    check outcome.error.codecCode == "nkeNestingTooDeep"

  test "BIF nesting token pool and string limits retain their codes":
    let cases = @[
      (source: "(a (b x))", configure: proc(limits: var CodecLimits) =
        limits.maxNestingDepth = 1, expected: "nkeNestingTooDeep"),
      (source: "(a b c)", configure: proc(limits: var CodecLimits) =
        limits.maxTokens = 1, expected: "nkeTokenLimit"),
      (source: "\"pooled\"", configure: proc(limits: var CodecLimits) =
        limits.maxPoolEntries = 0, expected: "nkePoolLimit"),
      (source: "\"abcdef\"", configure: proc(limits: var CodecLimits) =
        limits.maxStringBytes = 5, expected: "nkeStringLimit")
    ]
    for item in cases:
      let wireBody = nifToBif(item.source)
      let handler = proc(request: Request): Future[Response] {.async.} =
        return Response(status: 200, body: wireBody, request: request)
      var options = defaultNifCodecOptions()
      item.configure(options.decodeLimits)
      let outcome = waitOutcome newClient(
        newInProcessTransport(handler)
      ).getNif("/decode-limit", codecOptions = options)
      check outcome.isErr
      check outcome.error.codecCode == item.expected
      check outcome.error.hasResponse

  test "pool byte limits are enforced in both conversion directions":
    let source = "\"pooled-value\""
    var options = defaultNifCodecOptions()
    options.encodeLimits.maxPoolBytes = 1
    let encodeFailure = waitOutcome newClient(
      newInProcessTransport(echoBif)
    ).postNif("/encode-pool", source, codecOptions = options)
    check encodeFailure.isErr
    check encodeFailure.error.codecCode == "nkePoolLimit"

    let wireBody = nifToBif(source)
    let handler = proc(request: Request): Future[Response] {.async.} =
      return Response(status: 200, body: wireBody, request: request)
    options = defaultNifCodecOptions()
    options.decodeLimits.maxPoolBytes = 1
    let decodeFailure = waitOutcome newClient(
      newInProcessTransport(handler)
    ).getNif("/decode-pool", codecOptions = options)
    check decodeFailure.isErr
    check decodeFailure.error.codecCode == "nkePoolLimit"

  test "truncated BIF payloads retain response metadata":
    let complete = nifToBif("(valid payload)")
    for cut in [0, 1, 7, complete.len - 1]:
      let truncated = complete[0 ..< cut]
      let handler = proc(request: Request): Future[Response] {.async.} =
        var headers = initHeaders()
        headers.set("x-corruption", $cut)
        return Response(
          status: 200,
          statusText: "OK",
          headers: headers,
          body: truncated,
          request: request
        )
      let outcome = waitOutcome newClient(
        newInProcessTransport(handler)
      ).getNif("/truncated/" & $cut)
      check outcome.isErr
      check outcome.error.kind == jeCodec
      check outcome.error.codecCode.len > 0
      check outcome.error.url == "/truncated/" & $cut
      check outcome.error.response.headers.get("x-corruption") == $cut

  test "a custom status validator can decode a BIF error document":
    let handler = proc(request: Request): Future[Response] {.async.} =
      return Response(
        status: 422,
        body: nifToBif("(error invalidRecord)"),
        request: request
      )
    let client = newClient(
      newInProcessTransport(handler),
      validateStatus = proc(status: int): bool = status == 422
    )
    check waitFor(client.getNif("/validation")) == "(error invalidRecord)"

  test "request interceptors observe encoded BIF without corrupting it":
    var observedNif = ""
    let client = newClient(newInProcessTransport(echoBif))
    discard client.useRequestInterceptor(proc(request: Request): Request =
      observedNif = bifToNif(request.body)
      result = request
      result.headers.set("x-observed", "yes")
    )
    check waitFor(client.postNif("/interceptor", "(request 7)")) ==
      "(request 7)"
    check observedNif == "(request 7)"

  test "pre-cancelled NIF requests never reach the transport":
    var dispatched = false
    let handler = proc(request: Request): Future[Response] {.async.} =
      dispatched = true
      return Response(status: 200, body: request.body, request: request)
    let token = newCancellationToken()
    token.cancel("no longer needed")
    var options = defaultRequestOptions()
    options.cancellation = token
    let outcome = waitOutcome newClient(
      newInProcessTransport(handler)
    ).postNif("/cancelled", "request", options = options)
    check outcome.isErr
    check outcome.error.kind == jeCancelled
    check not dispatched

  test "codec failures are not retried even when retry is enabled":
    var dispatches = 0
    let handler = proc(request: Request): Future[Response] {.async.} =
      inc dispatches
      return Response(status: 200, body: "not-bif", request: request)
    var options = defaultRequestOptions()
    options.retry = defaultHttpRetryOptions()
    options.retry.maxAttempts = 4
    let outcome = waitOutcome newClient(
      newInProcessTransport(handler)
    ).getNif("/no-retry", options = options)
    check outcome.isErr
    check outcome.error.kind == jeCodec
    check dispatches == 1

  test "concurrent NIF requests retain independent payloads":
    let handler = proc(request: Request): Future[Response] {.async.} =
      await sleepAsync(request.body.len mod 3)
      return Response(status: 200, body: request.body, request: request)
    let client = newClient(newInProcessTransport(handler))
    let sources = toSeq(0 ..< 64).mapIt("(record id " & $it & ")")
    var pending: seq[Future[JResult[string]]]
    for index, source in sources:
      pending.add client.postNif("/concurrent/" & $index, source)
    let outcomes = asyncdispatch.waitFor all(pending)
    check outcomes.len == sources.len
    for index, outcome in outcomes:
      check outcome.isOk
      check outcome.value == sources[index]
