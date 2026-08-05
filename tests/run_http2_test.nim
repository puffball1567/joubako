import std/[net, os, osproc]

proc main(): int =
  if paramCount() != 1:
    quit "usage: run_http2_test <test-binary>"

  let server = startProcess(
    "node",
    workingDir = getCurrentDir(),
    args = ["tests/http2_server.mjs"],
    options = {poUsePath, poParentStreams}
  )
  defer:
    if server.running:
      server.terminate()
    discard server.waitForExit(3_000)
    server.close()

  var ready = false
  for _ in 0 ..< 100:
    var socket = newSocket()
    try:
      socket.connect("127.0.0.1", Port(18_942))
      ready = true
      socket.close()
      break
    except OSError:
      socket.close()
      sleep(20)

  if not ready:
    quit "HTTP/2 test server did not become ready"
  execCmd(paramStr(1))

quit main()
