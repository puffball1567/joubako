import std/[asyncdispatch, monotimes, os, strutils]
import joubako
import ./http1_bench_common

proc checked(outcome: JResult[Response]) =
  if outcome.isErr:
    raise newException(IOError, outcome.error.msg)
  if outcome.value.status != 200 or
      outcome.value.body.len != ExpectedBodyBytes:
    raise newException(IOError, "unexpected benchmark response")

proc checkedPost(outcome: JResult[Response]; expectedBody: string) =
  if outcome.isErr:
    raise newException(IOError, outcome.error.msg)
  if outcome.value.status != 200 or outcome.value.body != expectedBody:
    raise newException(IOError, "unexpected benchmark POST response")

proc runMode(label: string; maxIdleConnections: Natural;
             config: BenchConfig): Future[void] {.async.} =
  let transport = newHttpTransport(maxIdleConnections = maxIdleConnections)
  let client = newClient(transport, config.baseUrl)
  defer:
    transport.closeIdleConnections()

  let workload = getEnv("JOUBAKO_HTTP1_BENCH_WORKLOAD", "all").toLowerAscii
  if workload notin ["all", "get", "post"]:
    raise newException(ValueError,
      "JOUBAKO_HTTP1_BENCH_WORKLOAD must be all, get, or post")

  if workload in ["all", "get"]:
    for _ in 0 ..< config.warmup:
      checked(await client.get(""))

    var sequentialSamples: seq[int64]
    for _ in 0 ..< config.samples:
      let started = getMonoTime()
      for _ in 0 ..< config.iterations:
        checked(await client.get(""))
      sequentialSamples.add elapsedSince(started)
    report("Joubako current", label, "HTTP/1.1 sequential GET",
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
    report("Joubako current", label,
           "HTTP/1.1 concurrent GET (" & $config.concurrency & ")",
           concurrentSamples, config.iterations)

  if workload in ["all", "post"]:
    let payload = postBody()
    for _ in 0 ..< config.warmup:
      checkedPost(await client.post("echo", payload), payload)

    var sequentialPostSamples: seq[int64]
    for _ in 0 ..< config.samples:
      let started = getMonoTime()
      for _ in 0 ..< config.iterations:
        checkedPost(await client.post("echo", payload), payload)
      sequentialPostSamples.add elapsedSince(started)
    report("Joubako current", label, "HTTP/1.1 sequential POST (1 KiB echo)",
           sequentialPostSamples, config.iterations)

    var concurrentPostSamples: seq[int64]
    for _ in 0 ..< config.samples:
      let started = getMonoTime()
      var completed = 0
      while completed < config.iterations:
        let batchSize = min(config.concurrency, config.iterations - completed)
        var pending = newSeq[Future[JResult[Response]]](batchSize)
        for index in 0 ..< batchSize:
          pending[index] = client.post("echo", payload)
        for request in pending:
          checkedPost(await request, payload)
        completed += batchSize
      concurrentPostSamples.add elapsedSince(started)
    report("Joubako current", label,
           "HTTP/1.1 concurrent POST (1 KiB echo, " & $config.concurrency & ")",
           concurrentPostSamples, config.iterations)

proc run() {.async.} =
  let config = benchConfig()
  case getEnv("JOUBAKO_HTTP1_BENCH_POOL", "all").toLowerAscii
  of "legacy":
    await runMode("legacy pool (8 idle)", 8, config)
  of "default":
    await runMode("default pool (32 idle)", 32, config)
  of "matched":
    await runMode("pool matched to concurrency", config.concurrency.Natural,
                  config)
  of "all":
    await runMode("legacy pool (8 idle)", 8, config)
    await runMode("default pool (32 idle)", 32, config)
    await runMode("pool matched to concurrency", config.concurrency.Natural,
                  config)
  else:
    raise newException(ValueError,
      "JOUBAKO_HTTP1_BENCH_POOL must be all, legacy, default, or matched")

when isMainModule:
  waitFor run()
