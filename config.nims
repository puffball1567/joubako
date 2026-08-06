# begin Nimble config (version 2)
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config

# ARC is the local default; CI and dedicated Nimble tasks also test ORC.
switch("mm", "arc")
