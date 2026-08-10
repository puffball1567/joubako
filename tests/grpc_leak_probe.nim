import std/[asyncdispatch, strutils]
import joubako

type ProbeMessage {.proto3.} = object
  iteration {.fieldNumber: 1, pint.}: int32
  payload {.fieldNumber: 2.}: seq[byte]

const Iterations = 2_000

proc handler(request: Request): Future[Response] {.async.} =
  var headers = initHeaders()
  headers.set("content-type", GrpcMediaType)
  if request.headers.get("grpc-encoding") == "gzip":
    headers.set("grpc-encoding", "gzip")
  var trailers = initHeaders()
  if request.url.endsWith("/Failure"):
    trailers.set("grpc-status", "14")
    trailers.set("grpc-message", "unavailable")
    return Response(
      status: 200,
      httpVersion: "HTTP/2",
      headers: headers,
      trailers: trailers,
      request: request
    )
  trailers.set("grpc-status", "0")
  Response(
    status: 200,
    httpVersion: "HTTP/2",
    headers: headers,
    trailers: trailers,
    body: request.body,
    request: request
  )

proc exercise(client: Client; iteration: int): Future[void] {.async.} =
  let value = ProbeMessage(
    iteration: iteration.int32,
    payload: @[0'u8, 1, 255]
  )
  let unary = await client.grpcUnary(
    "joubako.leak.Probe", "Unary", value, ProbeMessage
  )
  doAssert unary.isOk
  doAssert unary.value == value

  var gzipOptions = defaultGrpcOptions()
  gzipOptions.requestEncoding = geGzip
  let compressed = await client.grpcUnary(
    "joubako.leak.Probe", "Unary", value, ProbeMessage,
    grpcOptions = gzipOptions
  )
  doAssert compressed.isOk
  doAssert compressed.value == value

  let failure = await client.grpcUnary(
    "joubako.leak.Probe", "Failure", value, ProbeMessage
  )
  doAssert failure.isErr
  doAssert failure.error.kind == jeRpcStatus
  doAssert failure.error.grpcStatus == ord(gsUnavailable)

  var streamed = 0
  let stream = await client.grpcServerStream(
    "joubako.leak.Probe",
    "Stream",
    value,
    ProbeMessage,
    proc(message: ProbeMessage) =
      doAssert message == value
      inc streamed
  )
  doAssert stream.isOk
  doAssert streamed == 1

proc main(): Future[void] {.async.} =
  let client = newClient(newInProcessTransport(handler))
  for iteration in 0 ..< Iterations:
    await exercise(client, iteration)

let probe = main()
waitFor probe
probe.clearCallbacks()
