import std/[os, strutils]

const dependencyPaths = [
  "src",
  "_deps/flowbrigade/src",
  "_deps/nifkit/src",
  "_deps/results",
  "_deps/unittest2",
  "_deps/stew",
  "_deps/zlib",
  "_deps/libcurl",
  "_deps/faststreams",
  "_deps/serialization",
  "_deps/cbor_serialization",
  "_deps/npeg/src",
]

let root = getCurrentDir()
var config = "--noNimblePath\n"

for relativePath in dependencyPaths:
  let absolutePath = (root / relativePath).replace('\\', '/')
  if not dirExists(absolutePath):
    quit "missing CI dependency path: " & absolutePath
  config.add "--path:\"" & absolutePath & "\"\n"

writeFile(root / "nimble.paths", config)
