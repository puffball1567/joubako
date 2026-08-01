import std/os

version       = "0.1.0"
author        = "Joubako contributors"
description   = "A typed, Promise-friendly transport client for native Nim applications"
license       = "MIT"
srcDir        = "src"

requires "nim >= 2.2.0"
requires "flowbrigade >= 0.5.0"
requires "zlib >= 0.2.0"

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
  exec "nim c -r --path:src --nimcache:" & temporary("joubako-compression-nimcache") & " --out:" & temporary("joubako-test-compression") & " tests/test_compression.nim"
  exec "nim c -r --path:src --nimcache:" & temporary("joubako-flowbrigade-nimcache") & " --out:" & temporary("joubako-test-flowbrigade") & " tests/test_flowbrigade_dependency.nim"
  exec "nim c -r --path:src --nimcache:" & temporary("joubako-result-future-nimcache") & " --out:" & temporary("joubako-test-result-future") & " tests/test_result_future.nim"
  exec "nim c -r --path:src --nimcache:" & temporary("joubako-result-client-nimcache") & " --out:" & temporary("joubako-test-result-client") & " tests/test_result_client.nim"

task benchmark, "Build and run local core benchmarks":
  exec "nim c -d:release -r --path:src --nimcache:" & temporary("joubako-benchmark-nimcache") & " --out:" & temporary("joubako-core-benchmark") & " benchmarks/core_bench.nim"

task leak, "Run ARC success and Result-error lifecycle probes under Valgrind":
  exec "nim c -d:release -d:useMalloc --mm:arc --path:src --nimcache:" & temporary("joubako-leak-nimcache") & " --out:" & temporary("joubako-leak-probe") & " tests/leak_probe.nim"
  exec "valgrind --leak-check=full --show-leak-kinds=definite,indirect --errors-for-leak-kinds=definite,indirect --error-exitcode=99 " & temporary("joubako-leak-probe")
  exec "nim c -d:release -d:useMalloc --mm:arc --path:src --nimcache:" & temporary("joubako-result-leak-nimcache") & " --out:" & temporary("joubako-result-leak-probe") & " tests/result_leak_probe.nim"
  exec "valgrind --leak-check=full --show-leak-kinds=all --errors-for-leak-kinds=definite,indirect,possible --error-exitcode=99 " & temporary("joubako-result-leak-probe")
  exec "nim c -d:release -d:useMalloc --mm:arc --path:src --nimcache:" & temporary("joubako-compression-leak-nimcache") & " --out:" & temporary("joubako-compression-leak-probe") & " tests/compression_leak_probe.nim"
  exec "valgrind --leak-check=full --show-leak-kinds=all --errors-for-leak-kinds=definite,indirect,possible --error-exitcode=99 " & temporary("joubako-compression-leak-probe")
