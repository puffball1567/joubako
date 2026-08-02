import std/asyncdispatch
import joubako

proc main() {.async.} =
  let api = newClient(newHttpTransport(), "https://api.example.com/")
  let response = await api.get("health")
  if response.isErr:
    echo response.error.msg
  else:
    echo response.value.status

when isMainModule:
  waitFor main()
