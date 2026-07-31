# begin Nimble config (version 2)
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config

# Joubako is developed and tested with deterministic ARC memory management.
switch("mm", "arc")
