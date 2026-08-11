import std/asyncdispatch
import joubako

const Iterations = 2_000

type LeakRecord = object
  id: int
  label: string

proc handler(request: Request): Future[Response] {.async.} =
  if request.url == "/malformed-response":
    return Response(status: 200, body: "not-bif", request: request)
  return Response(status: 200, body: request.body, request: request)

proc exercise(
    client: Client;
    policyClient: NifClient;
    index: int
): Future[void] {.async.} =
  let source = "(record id " & $index & ")"
  let success = await client.postNif("/roundtrip", source)
  doAssert success.isOk
  doAssert success.value == source

  let encodeFailure = await client.postNif(
    "/malformed-request",
    "("
  )
  doAssert encodeFailure.isErr
  doAssert encodeFailure.error.codecCode == "nkeMalformedInput"

  let decodeFailure = await client.getNif(
    "/malformed-response"
  )
  doAssert decodeFailure.isErr
  doAssert decodeFailure.error.codecCode == "nkeMalformedInput"

  var options = defaultNifCodecOptions()
  options.encodeLimits.maxTokens = 0
  let limitFailure = await client.postNif(
    "/limit",
    "x",
    codecOptions = options
  )
  doAssert limitFailure.isErr
  doAssert limitFailure.error.codecCode == "nkeTokenLimit"

  let typedValue = LeakRecord(id: index, label: "record-" & $index)
  let typedSuccess = await policyClient.postNif(
    "/roundtrip", typedValue, LeakRecord
  )
  doAssert typedSuccess.isOk
  doAssert typedSuccess.value == typedValue

  let typedFailure = tryDecodeNifValue("not-bif", LeakRecord)
  doAssert typedFailure.isErr
  doAssert typedFailure.error.codecCode == "nkeMalformedInput"

proc main(): Future[void] {.async.} =
  let client = newClient(newInProcessTransport(handler))
  var policies = initNifPolicySet()
  policies.definePolicy("records", newNifPolicy(
    maxRequestBytes = 4096,
    maxResponseBytes = 4096,
    maxNestingDepth = 16
  ))
  policies.addRoute NifPolicyRoute(
    httpMethods: {rmPost}, pathPrefix: "/roundtrip", policy: "records"
  )
  let policyClient = client.withNifPolicies(policies)
  for index in 0 ..< Iterations:
    await exercise(client, policyClient, index)

let probe = main()
waitFor probe
probe.clearCallbacks()
