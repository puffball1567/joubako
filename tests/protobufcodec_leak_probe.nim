import std/asyncdispatch
import joubako

type ProbeValue {.proto3.} = object
  iteration {.fieldNumber: 1, pint.}: int32
  payload {.fieldNumber: 2.}: seq[byte]

const Iterations = 2_000

proc handler(request: Request): Future[Response] {.async.} =
  if request.url == "/malformed":
    return Response(status: 200, body: "\x80", request: request)
  return Response(status: 200, body: request.body, request: request)

proc exercise(client: Client; iteration: int): Future[void] {.async.} =
  let value = ProbeValue(
    iteration: iteration.int32, payload: @[0'u8, 1, 255]
  )
  let success = await client.postProtobuf("/roundtrip", value, ProbeValue)
  doAssert success.isOk
  doAssert success.value == value

  let malformed = await client.getProtobuf("/malformed", ProbeValue)
  doAssert malformed.isErr
  doAssert malformed.error.codecCode == "protobuf_decode"

  var codecOptions = defaultProtobufCodecOptions()
  codecOptions.maxPayloadBytes = 1
  let bounded = await client.postProtobuf(
    "/bounded", value, ProbeValue, codecOptions = codecOptions
  )
  doAssert bounded.isErr
  doAssert bounded.error.codecCode == "protobuf_payload_too_large"

proc main(): Future[void] {.async.} =
  let client = newClient(newInProcessTransport(handler))
  for iteration in 0 ..< Iterations:
    await exercise(client, iteration)

let probe = main()
waitFor probe
probe.clearCallbacks()
