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

proc temporary(name: string): string =
  quoteShell(getTempDir() / name)

task test, "Run the Joubako test suite":
  exec "nim c -r --path:src --nimcache:" & temporary("joubako-nimcache") & " --out:" & temporary("joubako-test-all") & " tests/test_all.nim"
  exec "nim c -r --path:src --nimcache:" & temporary("joubako-types-query-nimcache") & " --out:" & temporary("joubako-test-types-query") & " tests/test_types_query.nim"
  exec "nim c -r --path:src --nimcache:" & temporary("joubako-promise-nimcache") & " --out:" & temporary("joubako-test-promise") & " tests/test_promise.nim"
  exec "nim c -r --path:src --nimcache:" & temporary("joubako-client-json-nimcache") & " --out:" & temporary("joubako-test-client-json") & " tests/test_client_json.nim"
  exec "nim c -r --path:src --nimcache:" & temporary("joubako-http-nimcache") & " --out:" & temporary("joubako-test-http") & " tests/test_http.nim"
  exec "nim c -r --path:src --nimcache:" & temporary("joubako-retry-nimcache") & " --out:" & temporary("joubako-test-retry") & " tests/test_retry.nim"
  exec "nim c -r --path:src --nimcache:" & temporary("joubako-resilience-security-nimcache") & " --out:" & temporary("joubako-test-resilience-security") & " tests/test_resilience_security.nim"
  exec "nim c -r --path:src --nimcache:" & temporary("joubako-ipc-nimcache") & " --out:" & temporary("joubako-test-ipc") & " tests/test_ipc.nim"
  exec "nim c -r --path:src --nimcache:" & temporary("joubako-websocket-nimcache") & " --out:" & temporary("joubako-test-websocket") & " tests/test_websocket.nim"
  exec "nim c -r --path:src --nimcache:" & temporary("joubako-codecs-forms-nimcache") & " --out:" & temporary("joubako-test-codecs-forms") & " tests/test_codecs_forms.nim"
  exec "nim c -r --path:src --nimcache:" & temporary("joubako-nif-codec-nimcache") & " --out:" & temporary("joubako-test-nif-codec") & " tests/test_nifcodec.nim"
  exec "nim c -r --path:src --nimcache:" & temporary("joubako-compression-nimcache") & " --out:" & temporary("joubako-test-compression") & " tests/test_compression.nim"
  exec "nim c -r --path:src --nimcache:" & temporary("joubako-cookiejar-nimcache") & " --out:" & temporary("joubako-test-cookiejar") & " tests/test_cookiejar.nim"
  exec "nim c -r --path:src --nimcache:" & temporary("joubako-tls-options-nimcache") & " --out:" & temporary("joubako-test-tls-options") & " tests/test_tls_options.nim"
  exec "nim c -r --path:src --nimcache:" & temporary("joubako-proxyconfig-nimcache") & " --out:" & temporary("joubako-test-proxyconfig") & " tests/test_proxyconfig.nim"
  exec "nim c -r --path:src --nimcache:" & temporary("joubako-fault-injection-nimcache") & " --out:" & temporary("joubako-test-fault-injection") & " tests/test_fault_injection.nim"
  exec "nim c -r --path:src --nimcache:" & temporary("joubako-flowbrigade-nimcache") & " --out:" & temporary("joubako-test-flowbrigade") & " tests/test_flowbrigade_dependency.nim"
  exec "nim c -r --path:src --nimcache:" & temporary("joubako-result-future-nimcache") & " --out:" & temporary("joubako-test-result-future") & " tests/test_result_future.nim"
  exec "nim c -r --path:src --nimcache:" & temporary("joubako-result-client-nimcache") & " --out:" & temporary("joubako-test-result-client") & " tests/test_result_client.nim"
  exec "nim c -r --path:src --nimcache:" & temporary("joubako-sse-nimcache") & " --out:" & temporary("joubako-test-sse") & " tests/test_sse.nim"
  exec "nim c -r --path:src --nimcache:" & temporary("joubako-opentelemetry-nimcache") & " --out:" & temporary("joubako-test-opentelemetry") & " tests/test_opentelemetry.nim"
  exec "nim c -r --path:src --nimcache:" & temporary("joubako-httpcache-nimcache") & " --out:" & temporary("joubako-test-httpcache") & " tests/test_httpcache.nim"
  exec "nim c -r --mm:arc --path:src --nimcache:" & temporary("joubako-graphql-nimcache") & " --out:" & temporary("joubako-test-graphql") & " tests/test_graphql.nim"
  when not defined(windows):
    exec "nim c --mm:arc --path:src --nimcache:" & temporary("joubako-http2-nimcache") & " --out:" & temporary("joubako-test-http2") & " tests/test_http2.nim"
    exec "nim c --mm:arc --nimcache:" & temporary("joubako-http2-runner-nimcache") & " --out:" & temporary("joubako-http2-runner") & " tests/run_http2_test.nim"
    exec temporary("joubako-http2-runner") & " " & temporary("joubako-test-http2")

task testSsl, "Run TLS, mTLS, and SOCKS5h integration tests":
  exec "nim c -r -d:ssl --mm:arc --path:src --nimcache:" & temporary("joubako-secure-transport-nimcache") & " --out:" & temporary("joubako-test-secure-transport") & " tests/test_secure_transport.nim"

task benchmark, "Build and run local core benchmarks":
  exec "nim c -d:release -r --path:src --nimcache:" & temporary("joubako-benchmark-nimcache") & " --out:" & temporary("joubako-core-benchmark") & " benchmarks/core_bench.nim"

task fuzz, "Run deterministic structured-input fuzzing":
  exec "nim c -d:release -r --path:src --nimcache:" & temporary("joubako-fuzz-nimcache") & " --out:" & temporary("joubako-fuzz-inputs") & " tests/fuzz_inputs.nim"

task soak, "Run the long mixed success/failure lifecycle probe":
  exec "nim c -d:release -r --path:src --nimcache:" & temporary("joubako-soak-nimcache") & " --out:" & temporary("joubako-soak-probe") & " tests/soak_probe.nim"

task e2e, "Run the cross-container HTTP integration suite":
  let compose = "docker compose -f tests/e2e/compose.yml"
  try:
    exec compose &
      " up --build --abort-on-container-exit --exit-code-from client"
  except OSError:
    try:
      exec compose & " down --volumes --remove-orphans"
    except OSError:
      discard
    raise
  exec compose & " down --volumes --remove-orphans"

task e2eHost, "Run the cross-process HTTP integration suite without Docker":
  exec "python3 tests/e2e/run_host.py"

task leak, "Run ARC success and Result-error lifecycle probes under Valgrind":
  exec "nim c -d:release -d:useMalloc --mm:arc --path:src --nimcache:" & temporary("joubako-leak-nimcache") & " --out:" & temporary("joubako-leak-probe") & " tests/leak_probe.nim"
  exec "valgrind --leak-check=full --show-leak-kinds=definite,indirect --errors-for-leak-kinds=definite,indirect --error-exitcode=99 " & temporary("joubako-leak-probe")
  exec "nim c -d:release -d:useMalloc --mm:arc --path:src --nimcache:" & temporary("joubako-result-leak-nimcache") & " --out:" & temporary("joubako-result-leak-probe") & " tests/result_leak_probe.nim"
  exec "valgrind --leak-check=full --show-leak-kinds=all --errors-for-leak-kinds=definite,indirect,possible --error-exitcode=99 " & temporary("joubako-result-leak-probe")
  exec "nim c -d:release -d:useMalloc --mm:arc --path:src --nimcache:" & temporary("joubako-compression-leak-nimcache") & " --out:" & temporary("joubako-compression-leak-probe") & " tests/compression_leak_probe.nim"
  exec "valgrind --leak-check=full --show-leak-kinds=all --errors-for-leak-kinds=definite,indirect,possible --error-exitcode=99 " & temporary("joubako-compression-leak-probe")
  exec "nim c -d:release -d:useMalloc --mm:arc --path:src --nimcache:" & temporary("joubako-cookiejar-leak-nimcache") & " --out:" & temporary("joubako-cookiejar-leak-probe") & " tests/cookiejar_leak_probe.nim"
  exec "valgrind --leak-check=full --show-leak-kinds=all --errors-for-leak-kinds=definite,indirect,possible --error-exitcode=99 " & temporary("joubako-cookiejar-leak-probe")
  exec "nim c -d:release -d:useMalloc --mm:arc --path:src --nimcache:" & temporary("joubako-fault-leak-nimcache") & " --out:" & temporary("joubako-fault-leak-probe") & " tests/fault_leak_probe.nim"
  exec "valgrind --leak-check=full --show-leak-kinds=all --errors-for-leak-kinds=definite,indirect,possible --error-exitcode=99 " & temporary("joubako-fault-leak-probe")
  exec "nim c -d:release -d:useMalloc --mm:arc --path:src --nimcache:" & temporary("joubako-nifcodec-leak-nimcache") & " --out:" & temporary("joubako-nifcodec-leak-probe") & " tests/nifcodec_leak_probe.nim"
  exec "valgrind --leak-check=full --show-leak-kinds=all --errors-for-leak-kinds=definite,indirect,possible --error-exitcode=99 " & temporary("joubako-nifcodec-leak-probe")
  exec "nim c -d:release -d:useMalloc --mm:arc --path:src --nimcache:" & temporary("joubako-sse-leak-nimcache") & " --out:" & temporary("joubako-sse-leak-probe") & " tests/sse_leak_probe.nim"
  exec "valgrind --leak-check=full --show-leak-kinds=all --errors-for-leak-kinds=definite,indirect,possible --error-exitcode=99 " & temporary("joubako-sse-leak-probe")
  exec "nim c -d:release -d:useMalloc --mm:arc --path:src --nimcache:" & temporary("joubako-opentelemetry-leak-nimcache") & " --out:" & temporary("joubako-opentelemetry-leak-probe") & " tests/opentelemetry_leak_probe.nim"
  exec "valgrind --leak-check=full --show-leak-kinds=all --errors-for-leak-kinds=definite,indirect,possible --error-exitcode=99 " & temporary("joubako-opentelemetry-leak-probe")
  exec "nim c -d:release -d:useMalloc --mm:arc --path:src --nimcache:" & temporary("joubako-httpcache-leak-nimcache") & " --out:" & temporary("joubako-httpcache-leak-probe") & " tests/httpcache_leak_probe.nim"
  exec "valgrind --leak-check=full --show-leak-kinds=all --errors-for-leak-kinds=definite,indirect,possible --error-exitcode=99 " & temporary("joubako-httpcache-leak-probe")
  exec "bash tests/http2_leak.sh"
  exec "nim c -d:release -d:useMalloc --mm:arc --path:src --nimcache:" & temporary("joubako-graphql-leak-nimcache") & " --out:" & temporary("joubako-graphql-leak-probe") & " tests/graphql_leak_probe.nim"
  exec "valgrind --leak-check=full --show-leak-kinds=all --errors-for-leak-kinds=definite,indirect,possible --error-exitcode=99 " & temporary("joubako-graphql-leak-probe")
