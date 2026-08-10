import std/os

version       = "0.1.1"
author        = "Joubako contributors"
description   = "A typed, Promise-friendly transport client for native Nim applications"
license       = "Apache-2.0"
srcDir        = "src"

requires "nim >= 2.2.0"
requires "flowbrigade >= 0.5.0"
requires "nifkit >= 0.2.0"
requires "zlib >= 0.2.0"
requires "libcurl >= 1.0.0"
requires "faststreams >= 0.5.1"
requires "cbor_serialization >= 0.4.2"
requires "protobuf_serialization >= 0.6.1"

proc temporary(name: string): string =
  quoteShell(getTempDir() / name)

const testPrograms = [
  ("all", "tests/test_all.nim"),
  ("types-query", "tests/test_types_query.nim"),
  ("promise", "tests/test_promise.nim"),
  ("client-json", "tests/test_client_json.nim"),
  ("http", "tests/test_http.nim"),
  ("retry", "tests/test_retry.nim"),
  ("resilience-security", "tests/test_resilience_security.nim"),
  ("ipc", "tests/test_ipc.nim"),
  ("websocket", "tests/test_websocket.nim"),
  ("codecs-forms", "tests/test_codecs_forms.nim"),
  ("nif-codec", "tests/test_nifcodec.nim"),
  ("compression", "tests/test_compression.nim"),
  ("cookiejar", "tests/test_cookiejar.nim"),
  ("tls-options", "tests/test_tls_options.nim"),
  ("proxyconfig", "tests/test_proxyconfig.nim"),
  ("fault-injection", "tests/test_fault_injection.nim"),
  ("flowbrigade", "tests/test_flowbrigade_dependency.nim"),
  ("result-future", "tests/test_result_future.nim"),
  ("result-client", "tests/test_result_client.nim"),
  ("sse", "tests/test_sse.nim"),
  ("opentelemetry", "tests/test_opentelemetry.nim"),
  ("httpcache", "tests/test_httpcache.nim"),
  ("graphql", "tests/test_graphql.nim"),
  ("graphql-subscription", "tests/test_graphql_subscription.nim"),
  ("json-rpc", "tests/test_jsonrpc.nim"),
  ("json-stream", "tests/test_jsonstream.nim"),
  ("cbor-codec", "tests/test_cborcodec.nim"),
  ("protobuf-codec", "tests/test_protobufcodec.nim"),
  ("upload-stream", "tests/test_uploadstream.nim"),
  ("streaming", "tests/test_streaming.nim"),
]

proc runTestSuite(memoryManager: string) =
  for (name, source) in testPrograms:
    let stem = "joubako-" & memoryManager & "-" & name
    exec "nim c -r --mm:" & memoryManager & " --path:src --nimcache:" &
      temporary(stem & "-nimcache") & " --out:" & temporary(stem) & " " & source
  when not defined(windows):
    let runner = temporary("joubako-" & memoryManager & "-http2-runner")
    exec "nim c --mm:" & memoryManager & " --nimcache:" &
      temporary("joubako-" & memoryManager & "-http2-runner-nimcache") &
      " --out:" & runner & " tests/run_http2_test.nim"
    for (name, source) in [
      ("http2", "tests/test_http2.nim"),
      ("grpc", "tests/test_grpc.nim")
    ]:
      let testBinary = temporary(
        "joubako-" & memoryManager & "-" & name
      )
      exec "nim c --mm:" & memoryManager & " --path:src --nimcache:" &
        temporary("joubako-" & memoryManager & "-" & name & "-nimcache") &
        " --out:" & testBinary & " " & source
      exec runner & " " & testBinary

task test, "Run the Joubako test suite with ARC":
  runTestSuite("arc")

task testOrc, "Run the Joubako test suite with ORC":
  runTestSuite("orc")

task testSsl, "Run TLS, mTLS, and SOCKS5h integration tests":
  exec "nim c -r -d:ssl --mm:arc --path:src --nimcache:" & temporary("joubako-secure-transport-nimcache") & " --out:" & temporary("joubako-test-secure-transport") & " tests/test_secure_transport.nim"

task testSslOrc, "Run TLS, mTLS, and SOCKS5h integration tests with ORC":
  exec "nim c -r -d:ssl --mm:orc --path:src --nimcache:" & temporary("joubako-orc-secure-transport-nimcache") & " --out:" & temporary("joubako-orc-test-secure-transport") & " tests/test_secure_transport.nim"

task benchmark, "Build and run local core benchmarks":
  exec "nim c -d:release -r --path:src --nimcache:" & temporary("joubako-benchmark-nimcache") & " --out:" & temporary("joubako-core-benchmark") & " benchmarks/core_bench.nim"

proc runNetworkBenchmark(memoryManager: string) =
  when defined(windows):
    echo "benchmarkNetwork currently requires a POSIX host and Node.js"
  else:
    let stem = "joubako-" & memoryManager & "-network-benchmark"
    let runner = temporary(stem & "-runner")
    let benchmark = temporary(stem)
    exec "nim c --mm:" & memoryManager & " --nimcache:" &
      temporary(stem & "-runner-nimcache") &
      " --out:" & runner & " tests/run_http2_test.nim"
    exec "nim c -d:release --mm:" & memoryManager &
      " --path:src --nimcache:" & temporary(stem & "-nimcache") &
      " --out:" & benchmark & " benchmarks/network_bench.nim"
    exec runner & " " & benchmark

task benchmarkNetwork, "Run reproducible HTTP/2 and gRPC loopback benchmarks":
  runNetworkBenchmark("arc")

task benchmarkNetworkOrc, "Run reproducible HTTP/2 and gRPC loopback benchmarks with ORC":
  runNetworkBenchmark("orc")

task fuzz, "Run deterministic structured-input fuzzing":
  exec "nim c -d:release -r --mm:arc --path:src --nimcache:" & temporary("joubako-fuzz-nimcache") & " --out:" & temporary("joubako-fuzz-inputs") & " tests/fuzz_inputs.nim"

task fuzzOrc, "Run deterministic structured-input fuzzing with ORC":
  exec "nim c -d:release -r --mm:orc --path:src --nimcache:" & temporary("joubako-orc-fuzz-nimcache") & " --out:" & temporary("joubako-orc-fuzz-inputs") & " tests/fuzz_inputs.nim"

const asanPrograms = [
  ("structured-inputs", "tests/fuzz_inputs.nim"),
  ("async-file-lifecycle", "tests/result_leak_probe.nim"),
]

proc runAsanSuite(memoryManager: string) =
  # Windows uses LLVM Clang's ASan rather than MSVC's implementation.
  let compilerFlag =
    if hostOS == "windows": " --cc:clang"
    else: ""
  let sanitizerFlags =
    compilerFlag & " --passC:-fsanitize=address" &
    " --passL:-fsanitize=address --passC:-fno-omit-frame-pointer"
  for (name, source) in asanPrograms:
    let stem = "joubako-" & memoryManager & "-asan-" & name
    exec "nim c -d:release -r --mm:" & memoryManager &
      sanitizerFlags & " --path:src --nimcache:" &
      temporary(stem & "-nimcache") & " --out:" & temporary(stem) &
      " " & source

task asan, "Run ARC memory-safety probes under AddressSanitizer":
  runAsanSuite("arc")

task asanOrc, "Run ORC memory-safety probes under AddressSanitizer":
  runAsanSuite("orc")

proc runUbsanSuite(memoryManager: string) =
  if hostOS == "windows":
    quit "UBSan is disabled on Windows because the LLVM runtime does not link reliably with this Nim toolchain"
  let flags =
    " --cc:clang --passC:-fsanitize=undefined --passL:-fsanitize=undefined" &
    " --passC:-fno-sanitize-recover=undefined" &
    " --passC:-fno-omit-frame-pointer"
  for (name, source) in asanPrograms:
    let stem = "joubako-" & memoryManager & "-ubsan-" & name
    exec "nim c -d:release -r --mm:" & memoryManager & flags &
      " --path:src --nimcache:" & temporary(stem & "-nimcache") &
      " --out:" & temporary(stem) & " " & source

task ubsan, "Run ARC probes under UndefinedBehaviorSanitizer":
  runUbsanSuite("arc")

task ubsanOrc, "Run ORC probes under UndefinedBehaviorSanitizer":
  runUbsanSuite("orc")

proc runLsanSuite(memoryManager: string) =
  if hostOS notin ["linux", "macosx"]:
    quit "standalone LeakSanitizer is supported only on Linux and macOS"
  let stem = "joubako-" & memoryManager & "-lsan-lifecycle"
  exec "nim c -d:release -r --mm:" & memoryManager &
    " --cc:clang --passC:-fsanitize=leak --passL:-fsanitize=leak" &
    " --passC:-fno-omit-frame-pointer --path:src --nimcache:" &
    temporary(stem & "-nimcache") & " --out:" & temporary(stem) &
    " tests/result_leak_probe.nim"

task lsan, "Run ARC lifecycle probes under standalone LeakSanitizer":
  runLsanSuite("arc")

task lsanOrc, "Run ORC lifecycle probes under standalone LeakSanitizer":
  runLsanSuite("orc")

proc runTsanSuite(memoryManager: string) =
  if hostOS == "windows":
    quit "ThreadSanitizer is not supported on Windows"
  let stem = "joubako-" & memoryManager & "-tsan"
  exec "nim c -d:release -r --threads:on --mm:" & memoryManager &
    " --cc:clang --passC:-fsanitize=thread --passL:-fsanitize=thread" &
    " --passC:-fno-omit-frame-pointer --path:src --nimcache:" &
    temporary(stem & "-nimcache") & " --out:" & temporary(stem) &
    " tests/tsan_probe.nim"

task tsan, "Run ARC concurrent codec probes under ThreadSanitizer":
  runTsanSuite("arc")

task tsanOrc, "Run ORC concurrent codec probes under ThreadSanitizer":
  runTsanSuite("orc")

task soak, "Run the long mixed success/failure lifecycle probe":
  exec "nim c -d:release -r --mm:arc --path:src --nimcache:" & temporary("joubako-soak-nimcache") & " --out:" & temporary("joubako-soak-probe") & " tests/soak_probe.nim"

task soakOrc, "Run the long mixed success/failure lifecycle probe with ORC":
  exec "nim c -d:release -r --mm:orc --path:src --nimcache:" & temporary("joubako-orc-soak-nimcache") & " --out:" & temporary("joubako-orc-soak-probe") & " tests/soak_probe.nim"

proc runDockerE2e(memoryManager: string) =
  let compose = "docker compose -f tests/e2e/compose.yml"
  let previous = getEnv("JOUBAKO_MEMORY_MANAGER")
  putEnv("JOUBAKO_MEMORY_MANAGER", memoryManager)
  try:
    exec compose &
      " up --build --abort-on-container-exit --exit-code-from client"
  finally:
    try:
      exec compose & " down --volumes --remove-orphans"
    except OSError:
      discard
    if previous.len > 0:
      putEnv("JOUBAKO_MEMORY_MANAGER", previous)
    else:
      delEnv("JOUBAKO_MEMORY_MANAGER")

task e2e, "Run the cross-container HTTP integration suite with ARC":
  runDockerE2e("arc")

task e2eOrc, "Run the cross-container HTTP integration suite with ORC":
  runDockerE2e("orc")

proc runHostE2e(memoryManager: string) =
  let previous = getEnv("JOUBAKO_MEMORY_MANAGER")
  putEnv("JOUBAKO_MEMORY_MANAGER", memoryManager)
  try:
    exec "python3 tests/e2e/run_host.py"
  finally:
    if previous.len > 0:
      putEnv("JOUBAKO_MEMORY_MANAGER", previous)
    else:
      delEnv("JOUBAKO_MEMORY_MANAGER")

task e2eHost, "Run the cross-process HTTP integration suite with ARC without Docker":
  runHostE2e("arc")

task e2eHostOrc, "Run the cross-process HTTP integration suite with ORC without Docker":
  runHostE2e("orc")

const leakPrograms = [
  ("core", "tests/leak_probe.nim", false),
  ("result", "tests/result_leak_probe.nim", true),
  ("compression", "tests/compression_leak_probe.nim", true),
  ("cookiejar", "tests/cookiejar_leak_probe.nim", true),
  ("fault", "tests/fault_leak_probe.nim", true),
  ("nifcodec", "tests/nifcodec_leak_probe.nim", true),
  ("sse", "tests/sse_leak_probe.nim", true),
  ("opentelemetry", "tests/opentelemetry_leak_probe.nim", true),
  ("httpcache", "tests/httpcache_leak_probe.nim", true),
  ("graphql", "tests/graphql_leak_probe.nim", true),
  ("graphql-ws", "tests/graphql_ws_leak_probe.nim", true),
  ("json-rpc", "tests/jsonrpc_leak_probe.nim", true),
  ("json-stream", "tests/jsonstream_leak_probe.nim", true),
  ("cbor-codec", "tests/cborcodec_leak_probe.nim", true),
  ("protobuf-codec", "tests/protobufcodec_leak_probe.nim", true),
  ("grpc", "tests/grpc_leak_probe.nim", true),
]

proc runLeakSuite(memoryManager: string) =
  for (name, source, strictPossible) in leakPrograms:
    let stem = "joubako-" & memoryManager & "-" & name & "-leak-probe"
    let binary = temporary(stem)
    exec "nim c -d:release -d:useMalloc --mm:" & memoryManager &
      " --path:src --nimcache:" & temporary(stem & "-nimcache") &
      " --out:" & binary & " " & source
    let errorKinds =
      if strictPossible: "definite,indirect,possible"
      else: "definite,indirect"
    let valgrind = "valgrind --leak-check=full --show-leak-kinds=all " &
      "--errors-for-leak-kinds=" & errorKinds & " --error-exitcode=99 "
    exec valgrind & binary
  exec "bash tests/http2_leak.sh " & memoryManager

task leak, "Run ARC lifecycle probes under Valgrind":
  runLeakSuite("arc")

task leakOrc, "Run ORC lifecycle probes under Valgrind":
  runLeakSuite("orc")
