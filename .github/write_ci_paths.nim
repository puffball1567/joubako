import std/[os, strutils]

const dependencyPaths = [
  ("flowbrigade", "src"),
  ("nifkit", "src"),
  ("results", ""),
  ("unittest2", ""),
  ("stew", ""),
  ("zlib", ""),
  ("libcurl", ""),
  ("faststreams", ""),
  ("serialization", ""),
  ("cbor_serialization", ""),
  ("protobuf_serialization", ""),
  ("npeg", "src"),
]

let root = getCurrentDir()
let dependencyRoot = getEnv("JOUBAKO_DEPENDENCY_ROOT", root / "_deps")
var config = "--noNimblePath\n--path:\"" &
  (root / "src").replace('\\', '/') & "\"\n"

for (packageName, sourcePath) in dependencyPaths:
  let absolutePath = (dependencyRoot / packageName / sourcePath)
    .replace('\\', '/')
  if not dirExists(absolutePath):
    quit "missing CI dependency path: " & absolutePath
  config.add "--path:\"" & absolutePath & "\"\n"

writeFile(root / "nimble.paths", config)
