#!/usr/bin/env bash
set -euo pipefail

probe=/tmp/joubako-http2-leak-probe

nim c -d:release -d:useMalloc --mm:arc \
  --nimcache:/tmp/joubako-http2-leak-probe-cache \
  --out:"$probe" tests/http2_leak_probe.nim

JOUBAKO_HTTP2_PORT=18943 node tests/http2_server.mjs &
server_pid=$!
cleanup() {
  kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
}
trap cleanup EXIT

for _ in $(seq 1 100); do
  if (echo >/dev/tcp/127.0.0.1/18943) 2>/dev/null; then
    break
  fi
done

valgrind --leak-check=full --show-leak-kinds=all \
  --errors-for-leak-kinds=definite,indirect,possible \
  --error-exitcode=99 "$probe"
