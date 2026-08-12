import std/monotimes
import chronos/apps/http/httpclient
import ./http1_bench_common

proc checked(response: HttpResponseTuple) =
  if response.status != 200 or response.data.len != ExpectedBodyBytes:
    raise newException(IOError, "unexpected benchmark response")

proc runMode(label: string; flags: HttpClientFlags;
             config: BenchConfig): Future[void] {.async.} =
  let session = HttpSessionRef.new(
    flags = flags,
    maxConnections = config.concurrency
  )
  let url = parseUri(config.baseUrl)
  try:
    for _ in 0 ..< config.warmup:
      checked(await session.fetch(url))

    var sequentialSamples: seq[int64]
    for _ in 0 ..< config.samples:
      let started = getMonoTime()
      for _ in 0 ..< config.iterations:
        checked(await session.fetch(url))
      sequentialSamples.add elapsedSince(started)
    report("Chronos v4.4.0", label, "HTTP/1.1 sequential GET",
           sequentialSamples, config.iterations)

    var concurrentSamples: seq[int64]
    for _ in 0 ..< config.samples:
      let started = getMonoTime()
      var completed = 0
      while completed < config.iterations:
        let batchSize = min(config.concurrency, config.iterations - completed)
        var pending = newSeq[Future[HttpResponseTuple]](batchSize)
        for index in 0 ..< batchSize:
          pending[index] = session.fetch(url)
        for request in pending:
          checked(await request)
        completed += batchSize
      concurrentSamples.add elapsedSince(started)
    report("Chronos v4.4.0", label,
           "HTTP/1.1 concurrent GET (" & $config.concurrency & ")",
           concurrentSamples, config.iterations)
  finally:
    await noCancel(session.closeWait())

proc run() {.async.} =
  let config = benchConfig()
  await runMode("default (new connection)", {}, config)
  {.push warning[Deprecated]: off.}
  await runMode("persistent connection pool",
                {HttpClientFlag.Http11Pipeline}, config)
  {.pop.}

when isMainModule:
  waitFor run()

