import std/[asyncdispatch, monotimes]
import joubako
import ./http1_bench_common

proc checked(outcome: JResult[Response]) =
  if outcome.isErr:
    raise newException(IOError, outcome.error.msg)
  if outcome.value.status != 200 or
      outcome.value.body.len != ExpectedBodyBytes:
    raise newException(IOError, "unexpected benchmark response")

proc runMode(label: string; maxIdleConnections: Natural;
             config: BenchConfig): Future[void] {.async.} =
  let transport = newHttpTransport(maxIdleConnections = maxIdleConnections)
  let client = newClient(transport, config.baseUrl)
  defer:
    transport.closeIdleConnections()

  for _ in 0 ..< config.warmup:
    checked(await client.get(""))

  var sequentialSamples: seq[int64]
  for _ in 0 ..< config.samples:
    let started = getMonoTime()
    for _ in 0 ..< config.iterations:
      checked(await client.get(""))
    sequentialSamples.add elapsedSince(started)
  report("Joubako v0.2.0", label, "HTTP/1.1 sequential GET",
         sequentialSamples, config.iterations)

  var concurrentSamples: seq[int64]
  for _ in 0 ..< config.samples:
    let started = getMonoTime()
    var completed = 0
    while completed < config.iterations:
      let batchSize = min(config.concurrency, config.iterations - completed)
      var pending = newSeq[Future[JResult[Response]]](batchSize)
      for index in 0 ..< batchSize:
        pending[index] = client.get("")
      for request in pending:
        checked(await request)
      completed += batchSize
    concurrentSamples.add elapsedSince(started)
  report("Joubako v0.2.0", label,
         "HTTP/1.1 concurrent GET (" & $config.concurrency & ")",
         concurrentSamples, config.iterations)

proc run() {.async.} =
  let config = benchConfig()
  await runMode("default pool (8 idle)", 8, config)
  await runMode("pool matched to concurrency", config.concurrency.Natural,
                config)

when isMainModule:
  waitFor run()

