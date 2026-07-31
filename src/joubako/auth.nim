import std/base64
import ./types

proc setBasicAuth*(headers: var Headers; username, password: string) =
  headers.set("authorization", "Basic " & encode(username & ":" & password))

proc setBearerToken*(headers: var Headers; token: string) =
  headers.set("authorization", "Bearer " & token)
