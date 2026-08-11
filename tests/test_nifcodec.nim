import std/[asyncdispatch, sequtils, strutils, unittest]
import nifkit
import joubako
import ./result_test_helpers

type
  CreateRecord = object
    title: string
    count: int
    enabled: bool

  RecordReply = object
    id: int
    record: CreateRecord

  SmallCount = object
    count: int8

  TwoFields = object
    first: int
    second: int

  RefNode = ref object
    value: int
    next: RefNode

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
  test "network defaults are finite and independent from NIFKit policy":
    let options = defaultNifCodecOptions()
    check defaultCodecLimits() == unlimitedCodecLimits()
    check options.encodeLimits != defaultCodecLimits()
    check options.encodeLimits.maxInputBytes == DefaultNifInputBytes
    check options.encodeLimits.maxOutputBytes == DefaultNifEncodedBytes
    check options.encodeLimits.maxNestingDepth == DefaultNifNestingDepth
    check options.encodeLimits.maxTokens == DefaultNifTokens
    check options.encodeLimits.maxPoolEntries == DefaultNifPoolEntries
    check options.encodeLimits.maxPoolBytes == DefaultNifPoolBytes
    check options.encodeLimits.maxStringBytes == DefaultNifStringBytes
    check options.encodeLimits.maxIndexEntries == DefaultNifIndexEntries
    check options.encodeLimits.maxContainerItems == DefaultNifContainerItems
    check options.encodeLimits.maxObjectFields == DefaultNifObjectFields
    check options.encodeLimits.maxTrackedReferences ==
      DefaultNifTrackedReferences
    check options.decodeLimits.maxInputBytes == DefaultNifInputBytes
    check options.decodeLimits.maxOutputBytes == DefaultNifDecodedBytes
    check options.decodeLimits.maxNestingDepth == DefaultNifNestingDepth
    check options.decodeLimits.maxTokens == DefaultNifTokens
    check options.decodeLimits.maxPoolEntries == DefaultNifPoolEntries
    check options.decodeLimits.maxPoolBytes == DefaultNifPoolBytes
    check options.decodeLimits.maxStringBytes == DefaultNifStringBytes
    check options.decodeLimits.maxIndexEntries == DefaultNifIndexEntries
    check options.decodeLimits.maxContainerItems == DefaultNifContainerItems
    check options.decodeLimits.maxObjectFields == DefaultNifObjectFields
    check options.decodeLimits.maxTrackedReferences ==
      DefaultNifTrackedReferences
    check options.typedOptions.requireTypeNames
    check not options.typedOptions.allowUnknownFields

  test "named policies apply route-specific wire and codec limits":
    var observedRequestLimit = 0
    var observedResponseLimit = 0
    let handler = proc(request: Request): Future[Response] {.async.} =
      observedRequestLimit = request.options.maxRequestBytes
      observedResponseLimit = request.options.maxResponseBytes
      return Response(status: 200, body: request.body, request: request)
    var policies = initNifPolicySet()
    policies.definePolicy("default", newNifPolicy(
      maxRequestBytes = 1024 * 1024,
      maxResponseBytes = 1024 * 1024,
      maxNestingDepth = 64,
      maxTokens = 100_000,
      maxPoolBytes = 512 * 1024
    ))
    policies.definePolicy("upload", newNifPolicy(
      maxRequestBytes = 128 * 1024 * 1024,
      maxResponseBytes = 2 * 1024 * 1024,
      maxNestingDepth = 32,
      maxTokens = 200_000,
      maxPoolBytes = 1024 * 1024
    ))
    policies.addRoute NifPolicyRoute(
      httpMethods: {rmPost}, path: "/uploads", policy: "upload"
    )
    policies.addRoute NifPolicyRoute(
      pathPrefix: "/", policy: "default"
    )
    let client = newClient(newInProcessTransport(handler)).withNifPolicies(
      policies
    )
    check waitFor(client.postNif("/uploads", "(file true)")) ==
      "(file true)"
    check observedRequestLimit == 128 * 1024 * 1024
    check observedResponseLimit == 2 * 1024 * 1024
    let selected = policies.resolveNifPolicy(rmPost, "/uploads")
    check selected.codecOptions.encodeLimits.maxInputBytes ==
      128 * 1024 * 1024
    check selected.codecOptions.encodeLimits.maxOutputBytes ==
      128 * 1024 * 1024
    check selected.codecOptions.encodeLimits.maxNestingDepth == 32
    check selected.codecOptions.decodeLimits.maxTokens == 200_000
    check selected.codecOptions.decodeLimits.maxPoolBytes == 1024 * 1024

  test "policy routes honor methods exact paths and query-free prefixes":
    var policies = initNifPolicySet()
    policies.definePolicy("default", newNifPolicy(maxRequestBytes = 100))
    policies.definePolicy("api", newNifPolicy(maxRequestBytes = 200))
    policies.definePolicy("deep", newNifPolicy(maxRequestBytes = 300))
    policies.definePolicy("exact", newNifPolicy(maxRequestBytes = 400))
    policies.definePolicy("postOnly", newNifPolicy(maxRequestBytes = 500))
    policies.addRoute NifPolicyRoute(pathPrefix: "/api", policy: "api")
    policies.addRoute NifPolicyRoute(
      pathPrefix: "/api/private", policy: "deep"
    )
    policies.addRoute NifPolicyRoute(
      path: "/api/private/item", policy: "exact"
    )
    policies.addRoute NifPolicyRoute(
      httpMethods: {rmPost}, path: "/method", policy: "postOnly"
    )
    check policies.resolveNifPolicy(
      rmGet, "https://example.test/api/private/a?x=1"
    ).maxRequestBytes == 300
    check policies.resolveNifPolicy(
      rmGet, "/api/private/item?x=1"
    ).maxRequestBytes == 400
    check policies.resolveNifPolicy(rmPost, "/method").maxRequestBytes == 500
    check policies.resolveNifPolicy(rmGet, "/method").maxRequestBytes == 100
    check policies.resolveNifPolicy(rmGet, "/api-evil").maxRequestBytes == 100

  test "an explicit policy overrides route selection":
    var policies = initNifPolicySet()
    policies.definePolicy("small", newNifPolicy(maxRequestBytes = 64))
    policies.definePolicy("large", newNifPolicy(maxRequestBytes = 4096))
    policies.addRoute NifPolicyRoute(pathPrefix: "/", policy: "small")
    check policies.resolveNifPolicy(
      rmPost, "/upload", "large"
    ).maxRequestBytes == 4096

  test "per-request wire limits override the selected policy":
    var observedRequestLimit = 0
    let handler = proc(request: Request): Future[Response] {.async.} =
      observedRequestLimit = request.options.maxRequestBytes
      return Response(status: 200, body: request.body, request: request)
    var policies = initNifPolicySet()
    policies.definePolicy("default", newNifPolicy(maxRequestBytes = 1024))
    let client = newClient(newInProcessTransport(handler)).withNifPolicies(
      policies
    )
    var requestOptions = RequestOptions(maxRequestBytes: 2048)
    discard waitFor client.postNif(
      "/", "true", options = requestOptions
    )
    check observedRequestLimit == 2048

  test "selected policies reject oversized BIF before dispatch":
    var calls = 0
    let handler = proc(request: Request): Future[Response] {.async.} =
      inc calls
      return Response(status: 200, body: request.body, request: request)
    var policies = initNifPolicySet()
    policies.definePolicy("tiny", newNifPolicy(maxRequestBytes = 16))
    policies.addRoute NifPolicyRoute(path: "/tiny", policy: "tiny")
    let outcome = waitOutcome newClient(
      newInProcessTransport(handler)
    ).withNifPolicies(policies).postNif(
      "/tiny", "(payload \"too large for sixteen bytes\")"
    )
    check outcome.isErr
    check outcome.error.kind == jeCodec
    check calls == 0

  test "policy-aware typed calls apply response and nesting bounds":
    let handler = proc(request: Request): Future[Response] {.async.} =
      let decoded = fromBif(
        request.body, CreateRecord, defaultNifDecodeLimits()
      )
      return Response(
        status: 200,
        body: toBif(
          RecordReply(id: 9, record: decoded), defaultNifEncodeLimits()
        ),
        request: request
      )
    var policies = initNifPolicySet()
    policies.definePolicy("typed", newNifPolicy(
      maxResponseBytes = 4096,
      maxNestingDepth = 16
    ))
    policies.addRoute NifPolicyRoute(
      httpMethods: {rmPost}, pathPrefix: "/typed", policy: "typed"
    )
    let value = CreateRecord(title: "routed", count: 2, enabled: true)
    let outcome = waitOutcome newClient(
      newInProcessTransport(handler)
    ).withNifPolicies(policies).postNif(
      "typed/records?version=1", value, RecordReply
    )
    check outcome.isOk
    check outcome.value == RecordReply(id: 9, record: value)

  test "policy response limits run before typed decoding":
    let handler = proc(request: Request): Future[Response] {.async.} =
      return Response(
        status: 200,
        body: toBif(
          RecordReply(
            id: 10,
            record: CreateRecord(
              title: repeat('x', 128), count: 1, enabled: true
            )
          ),
          defaultNifEncodeLimits()
        ),
        request: request
      )
    var policies = initNifPolicySet()
    policies.definePolicy("tinyResponse", newNifPolicy(
      maxResponseBytes = 32
    ))
    policies.addRoute NifPolicyRoute(
      path: "/tiny-response", policy: "tinyResponse"
    )
    let outcome = waitOutcome newClient(
      newInProcessTransport(handler)
    ).withNifPolicies(policies).getNif(
      "/tiny-response", RecordReply
    )
    check outcome.isErr
    check outcome.error.kind == jeBodyTooLarge

  test "invalid policy configurations fail during construction":
    var policies = initNifPolicySet()
    expect ValueError:
      policies.definePolicy("", defaultNifPolicy())
    expect ValueError:
      policies.addRoute NifPolicyRoute(path: "/", policy: "missing")
    expect ValueError:
      policies.addRoute NifPolicyRoute(policy: "default")
    expect ValueError:
      policies.addRoute NifPolicyRoute(
        path: "/one", pathPrefix: "/", policy: "default"
      )
    policies.defaultPolicy = "missing"
    expect ValueError:
      discard newClient(newInProcessTransport(echoBif)).withNifPolicies(
        policies
      )
    policies = initNifPolicySet()
    policies.definePolicy("zero", newNifPolicy(maxRequestBytes = 0))
    policies.defaultPolicy = "zero"
    expect ValueError:
      discard newClient(newInProcessTransport(echoBif)).withNifPolicies(
        policies
      )

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

  test "typed post converts Nim values directly through BIF":
    var captured = CreateRecord()
    var contentType = ""
    var accept = ""
    let handler = proc(request: Request): Future[Response] {.async.} =
      contentType = request.headers.get("content-type")
      accept = request.headers.get("accept")
      captured = fromBif(
        request.body, CreateRecord, defaultNifDecodeLimits()
      )
      let reply = RecordReply(id: 7, record: captured)
      return Response(
        status: 200,
        body: toBif(reply, defaultNifEncodeLimits()),
        request: request
      )
    let value = CreateRecord(title: "NIF", count: 12, enabled: true)
    let outcome = waitOutcome newClient(
      newInProcessTransport(handler)
    ).postNif("/typed", value, RecordReply)
    check outcome.isOk
    check outcome.value == RecordReply(id: 7, record: value)
    check captured == value
    check contentType == BifMediaType
    check accept == BifMediaType

  test "typed direct helpers round-trip without NIF text allocation":
    let value = RecordReply(
      id: 9,
      record: CreateRecord(title: "direct", count: -4, enabled: false)
    )
    let payload = encodeNifValue(value)
    check payload.startsWith("NIFBIN\0\5")
    check decodeNifValue(payload, RecordReply) == value

  test "typed decode retains logical error paths":
    let payload = nifToBif(
      "(nifkit\\2Ddata 1 (object \"SmallCount\" (field \"count\" 999)))"
    )
    let outcome = tryDecodeNifValue(payload, SmallCount)
    check outcome.isErr
    check outcome.error.codecCode == "nkeTypeMismatch"
    check outcome.error.codecPath == "$.count"
    check outcome.error.codecOffset >= 0

  test "typed strictness can be relaxed only by caller policy":
    let payload = nifToBif(
      "(nifkit\\2Ddata 1 (object \"SmallCount\"" &
      " (field \"count\" 7) (field \"future\" true)))"
    )
    let strict = tryDecodeNifValue(payload, SmallCount)
    check strict.isErr
    check strict.error.codecCode == "nkeUnknownField"
    check strict.error.codecPath == "$.future"

    var options = defaultNifCodecOptions()
    options.typedOptions.allowUnknownFields = true
    let compatible = tryDecodeNifValue(payload, SmallCount, options)
    check compatible.isOk
    check compatible.value.count == 7

  test "typed container object and reference limits are finite":
    var options = defaultNifCodecOptions()
    options.encodeLimits.maxContainerItems = 1
    let container = tryEncodeNifValue(@[1, 2], options)
    check container.isErr
    check container.error.codecCode == "nkeTokenLimit"
    check container.error.codecPath == "$"

    options = defaultNifCodecOptions()
    options.encodeLimits.maxObjectFields = 1
    let objectFields = tryEncodeNifValue(
      TwoFields(first: 1, second: 2), options
    )
    check objectFields.isErr
    check objectFields.error.codecCode == "nkeTokenLimit"

    options = defaultNifCodecOptions()
    options.encodeLimits.maxTrackedReferences = 1
    let references = tryEncodeNifValue(
      RefNode(value: 1, next: RefNode(value: 2)), options
    )
    check references.isErr
    check references.error.codecCode == "nkeTokenLimit"
    check references.error.codecPath == "$.next"

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
