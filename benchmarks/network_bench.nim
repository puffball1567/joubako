import std/[asyncdispatch, json, monotimes, os, strformat, strutils, times]
import joubako

const
  BaseUrl = "http://127.0.0.1:18942"
  GrpcService = "joubako.test.Echo"

type
  BenchMessage {.proto3.} = object
    id {.fieldNumber: 1, pint.}: uint32
    text {.fieldNumber: 2.}: string
    payload {.fieldNumber: 3.}: seq[byte]

  Measurement = object
    name: string
    operations: int
    bytes: int64
    elapsedNs: int64

proc positiveEnv(name: string; fallback: int): int =
  let value = getEnv(name)
  if value.len == 0:
    return fallback
  try:
    result = parseInt(value)
  except ValueError:
    quit name & " must be a positive integer"
  if result <= 0:
    quit name & " must be a positive integer"

func perSecond(value: int64; elapsedNs: int64): float =
  if elapsedNs <= 0:
    return 0.0
  value.float * 1_000_000_000.0 / elapsedNs.float

proc report(measurement: Measurement; jsonLines: bool) =
  let nsPerOperation =
    measurement.elapsedNs div max(measurement.operations.int64, 1'i64)
  let operationsPerSecond = perSecond(
    measurement.operations.int64, measurement.elapsedNs
  )
  let bytesPerSecond = perSecond(measurement.bytes, measurement.elapsedNs)
  if jsonLines:
    echo $(%*{
      "name": measurement.name,
      "operations": measurement.operations,
      "bytes": measurement.bytes,
      "elapsedNs": measurement.elapsedNs,
      "nsPerOperation": nsPerOperation,
      "operationsPerSecond": operationsPerSecond,
      "bytesPerSecond": bytesPerSecond
    })
  elif measurement.bytes > 0:
    echo &"{measurement.name}: {nsPerOperation} ns/op, " &
      &"{operationsPerSecond:.1f} op/s, " &
      &"{bytesPerSecond / (1024.0 * 1024.0):.2f} MiB/s " &
      &"({measurement.operations} operations)"
  else:
    echo &"{measurement.name}: {nsPerOperation} ns/op, " &
      &"{operationsPerSecond:.1f} op/s " &
      &"({measurement.operations} operations)"

proc checked[T](outcome: JResult[T]; operation: string): T =
  if outcome.isErr:
    raise newException(IOError, operation & " failed: " & outcome.error.msg)
  outcome.value

proc checkedVoid(outcome: JResult[void]; operation: string) =
  if outcome.isErr:
    raise newException(IOError, operation & " failed: " & outcome.error.msg)

proc elapsedSince(started: MonoTime): int64 =
  (getMonoTime() - started).inNanoseconds

proc benchSequential(
    client: Client; iterations: int
): Future[Measurement] {.async.} =
  discard checked(await client.get("/"), "HTTP/2 warmup")
  let started = getMonoTime()
  for _ in 0 ..< iterations:
    discard checked(await client.get("/"), "HTTP/2 sequential request")
  Measurement(
    name: "HTTP/2 sequential GET",
    operations: iterations,
    elapsedNs: elapsedSince(started)
  )

proc benchMultiplexed(
    client: Client; iterations, concurrency: int
): Future[Measurement] {.async.} =
  let started = getMonoTime()
  var completed = 0
  while completed < iterations:
    let batchSize = min(concurrency, iterations - completed)
    var pending = newSeq[Future[JResult[Response]]](batchSize)
    for index in 0 ..< batchSize:
      pending[index] = client.get("/")
    for request in pending:
      discard checked(await request, "HTTP/2 multiplexed request")
    completed += batchSize
  Measurement(
    name: "HTTP/2 multiplexed GET (concurrency " & $concurrency & ")",
    operations: iterations,
    elapsedNs: elapsedSince(started)
  )

proc benchUpload(
    client: Client; iterations, uploadBytes: int
): Future[Measurement] {.async.} =
  let chunk = repeat('u', min(uploadBytes, 16 * 1024))
  let started = getMonoTime()
  for _ in 0 ..< iterations:
    let upload = client.openUpload(
      rmPost,
      "/upload-stream",
      maxBufferedBytes = 32 * 1024
    )
    var remaining = uploadBytes
    while remaining > 0:
      let count = min(remaining, chunk.len)
      checkedVoid(await upload.send(chunk[0 ..< count]), "upload send")
      remaining -= count
    let response = checked(await upload.finish(), "upload finish")
    if response.body.len != uploadBytes + "POST:".len:
      raise newException(IOError, "upload response length did not match input")
  Measurement(
    name: "HTTP/2 bounded streaming upload",
    operations: iterations,
    bytes: iterations.int64 * uploadBytes.int64,
    elapsedNs: elapsedSince(started)
  )

proc benchGrpc(
    client: Client;
    iterations: int;
    encoding: GrpcMessageEncoding
): Future[Measurement] {.async.} =
  var grpcOptions = defaultGrpcOptions()
  grpcOptions.requestEncoding = encoding
  let methodName =
    if encoding == geGzip: "CompressedUnary"
    else: "Unary"
  let value = BenchMessage(
    id: 42,
    text: repeat("native-network-benchmark-", 64),
    payload: @[0'u8, 1, 2, 127, 255]
  )
  discard checked(
    await client.grpcUnary(
      GrpcService, methodName, value, BenchMessage,
      grpcOptions = grpcOptions
    ),
    "gRPC warmup"
  )
  let started = getMonoTime()
  for _ in 0 ..< iterations:
    let echoed = checked(
      await client.grpcUnary(
        GrpcService, methodName, value, BenchMessage,
        grpcOptions = grpcOptions
      ),
      "gRPC unary request"
    )
    if echoed != value:
      raise newException(IOError, "gRPC response did not match request")
  Measurement(
    name: "gRPC unary " & (if encoding == geGzip: "gzip" else: "identity"),
    operations: iterations,
    elapsedNs: elapsedSince(started)
  )

proc run() {.async.} =
  let iterations = positiveEnv("JOUBAKO_NETWORK_BENCH_ITERATIONS", 200)
  let concurrency = positiveEnv("JOUBAKO_NETWORK_BENCH_CONCURRENCY", 32)
  let uploadIterations = positiveEnv(
    "JOUBAKO_NETWORK_BENCH_UPLOAD_ITERATIONS", 10
  )
  let uploadBytes = positiveEnv("JOUBAKO_NETWORK_BENCH_UPLOAD_BYTES", 1024 * 1024)
  let jsonLines = getEnv("JOUBAKO_NETWORK_BENCH_FORMAT").toLowerAscii == "jsonl"
  let transport = newHttp2Transport(allowH2c = true)
  defer:
    await transport.close()
  let client = newClient(transport, BaseUrl)

  report(await benchSequential(client, iterations), jsonLines)
  report(await benchMultiplexed(client, iterations, concurrency), jsonLines)
  report(await benchUpload(client, uploadIterations, uploadBytes), jsonLines)
  report(await benchGrpc(client, iterations, geIdentity), jsonLines)
  report(await benchGrpc(client, iterations, geGzip), jsonLines)

when isMainModule:
  waitFor run()
