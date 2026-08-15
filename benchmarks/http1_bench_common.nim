import std/[algorithm, monotimes, os, parseutils, strformat, strutils, times]

const
  DefaultBaseUrl* = "http://127.0.0.1:18944/"
  ExpectedBodyBytes* = 128
  PostBodyBytes* = 1_024

proc postBody*(): string =
  repeat("p", PostBodyBytes)

type
  BenchConfig* = object
    baseUrl*: string
    iterations*: int
    concurrency*: int
    samples*: int
    warmup*: int

proc positiveEnv(name: string; fallback: int): int =
  let value = getEnv(name)
  if value.len == 0:
    return fallback
  if parseInt(value, result) != value.len or result <= 0:
    quit name & " must be a positive integer"

proc benchConfig*(): BenchConfig =
  BenchConfig(
    baseUrl: getEnv("JOUBAKO_HTTP1_BENCH_URL", DefaultBaseUrl),
    iterations: positiveEnv("JOUBAKO_HTTP1_BENCH_ITERATIONS", 1_000),
    concurrency: positiveEnv("JOUBAKO_HTTP1_BENCH_CONCURRENCY", 32),
    samples: positiveEnv("JOUBAKO_HTTP1_BENCH_SAMPLES", 5),
    warmup: positiveEnv("JOUBAKO_HTTP1_BENCH_WARMUP", 50)
  )

proc elapsedSince*(started: MonoTime): int64 =
  (getMonoTime() - started).inNanoseconds

proc report*(client, mode, workload: string; samples: var seq[int64];
             operations: int) =
  samples.sort()
  let elapsedNs = samples[samples.len div 2]
  let operationsPerSecond =
    operations.float * 1_000_000_000.0 / elapsedNs.float
  let nsPerOperation = elapsedNs div operations.int64
  echo &"{client} | {mode} | {workload}: {operationsPerSecond:.1f} op/s, " &
    &"{nsPerOperation} ns/op (median of {samples.len} samples)"
