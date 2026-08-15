import std/[monotimes, os, strutils]
import chronos/apps/http/httpclient
import ./http1_bench_common

proc checked(response: HttpResponseTuple) =
  if response.status != 200 or response.data.len != ExpectedBodyBytes:
    raise newException(IOError, "unexpected benchmark response")

proc checkedPost(response: HttpResponseTuple; expectedBody: string) =
  if response.status != 200 or response.data.len != expectedBody.len:
    raise newException(IOError, "unexpected benchmark POST response")
  for index, value in response.data:
    if value != expectedBody[index].byte:
      raise newException(IOError, "unexpected benchmark POST response")

proc post(session: HttpSessionRef; url, body: string): Future[HttpResponseTuple] =
  let request = HttpClientRequestRef.post(session, url, body = body).valueOr:
    raise newException(IOError, $error)
  request.fetch()

proc runMode(label: string; flags: HttpClientFlags;
             config: BenchConfig): Future[void] {.async.} =
  let session = HttpSessionRef.new(
    flags = flags,
    maxConnections = config.concurrency
  )
  let url = parseUri(config.baseUrl)
  try:
    let workload = getEnv("JOUBAKO_HTTP1_BENCH_WORKLOAD", "all").toLowerAscii
    if workload notin ["all", "get", "post"]:
      raise newException(ValueError,
        "JOUBAKO_HTTP1_BENCH_WORKLOAD must be all, get, or post")

    if workload in ["all", "get"]:
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

    if workload in ["all", "post"]:
      let payload = postBody()
      let postUrl = config.baseUrl & "echo"
      for _ in 0 ..< config.warmup:
        checkedPost(await session.post(postUrl, payload), payload)

      var sequentialPostSamples: seq[int64]
      for _ in 0 ..< config.samples:
        let started = getMonoTime()
        for _ in 0 ..< config.iterations:
          checkedPost(await session.post(postUrl, payload), payload)
        sequentialPostSamples.add elapsedSince(started)
      report("Chronos v4.4.0", label,
             "HTTP/1.1 sequential POST (1 KiB echo)",
             sequentialPostSamples, config.iterations)

      var concurrentPostSamples: seq[int64]
      for _ in 0 ..< config.samples:
        let started = getMonoTime()
        var completed = 0
        while completed < config.iterations:
          let batchSize = min(config.concurrency, config.iterations - completed)
          var pending = newSeq[Future[HttpResponseTuple]](batchSize)
          for index in 0 ..< batchSize:
            pending[index] = session.post(postUrl, payload)
          for request in pending:
            checkedPost(await request, payload)
          completed += batchSize
        concurrentPostSamples.add elapsedSince(started)
      report("Chronos v4.4.0", label,
             "HTTP/1.1 concurrent POST (1 KiB echo, " &
               $config.concurrency & ")",
             concurrentPostSamples, config.iterations)
  finally:
    await noCancel(session.closeWait())

proc run() {.async.} =
  let config = benchConfig()
  case getEnv("JOUBAKO_HTTP1_BENCH_CHRONOS_MODE", "all").toLowerAscii
  of "default":
    await runMode("default (new connection)", {}, config)
  of "persistent":
    {.push warning[Deprecated]: off.}
    # Chronos v4.4.0 uses this deprecated flag only as the gate for persistent
    # connection reuse; its source explicitly says pipelining is not
    # implemented. Acquired connections still carry one active request.
    await runMode("persistent connection pool",
                  {HttpClientFlag.Http11Pipeline}, config)
    {.pop.}
  of "all":
    await runMode("default (new connection)", {}, config)
    {.push warning[Deprecated]: off.}
    # See the persistent-mode note above: this is keep-alive reuse, not an
    # HTTP/1.1 pipelining comparison.
    await runMode("persistent connection pool",
                  {HttpClientFlag.Http11Pipeline}, config)
    {.pop.}
  else:
    raise newException(ValueError,
      "JOUBAKO_HTTP1_BENCH_CHRONOS_MODE must be default, persistent, or all")

when isMainModule:
  waitFor run()
