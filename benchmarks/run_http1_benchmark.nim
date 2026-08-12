import std/[monotimes, net, os, osproc, times]

const ServerStartupTimeout = initDuration(seconds = 30)

proc main(): int =
  if paramCount() != 1:
    quit "usage: run_http1_benchmark <benchmark-binary>"

  let server = startProcess(
    "node",
    workingDir = getCurrentDir(),
    args = ["benchmarks/http1_bench_server.mjs"],
    options = {poUsePath, poParentStreams}
  )
  defer:
    if server.running:
      server.terminate()
    discard server.waitForExit(3_000)
    server.close()

  var ready = false
  let startupDeadline = getMonoTime() + ServerStartupTimeout
  while getMonoTime() < startupDeadline:
    if not server.running:
      quit "HTTP/1.1 benchmark server exited during startup with code " &
        $server.peekExitCode()
    var socket = newSocket()
    try:
      socket.connect("127.0.0.1", Port(18_944))
      ready = true
      socket.close()
      break
    except OSError:
      socket.close()
      sleep(25)

  if not ready:
    quit "HTTP/1.1 benchmark server did not become ready within " &
      $ServerStartupTimeout.inSeconds & " seconds"
  execCmd(paramStr(1))

quit main()
