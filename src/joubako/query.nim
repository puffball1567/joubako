import std/uri

type
  QueryParam* = tuple[name, value: string]

func withQuery*(path: string; params: openArray[QueryParam]): string =
  ## Adds percent-encoded query parameters while preserving an existing query
  ## and fragment. Repeated names remain repeated.
  if params.len == 0:
    return path

  var parsed = parseUri(path)
  let encoded = encodeQuery(params, omitEq = false)
  if parsed.query.len == 0:
    parsed.query = encoded
  else:
    parsed.query.add("&" & encoded)
  $parsed
