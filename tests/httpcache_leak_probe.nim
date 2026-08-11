import std/asyncdispatch
import joubako

proc maxAgeHeaders(): Headers =
  result = initHeaders()
  result.set("cache-control", "max-age=3600")

proc cachedResponse(request: Request): Future[Response] {.async.} =
  return Response(
    status: 200,
    headers: maxAgeHeaders(),
    body: "cached payload",
    request: request
  )

proc exercise(): Future[void] {.async.} =
  block:
    let store = newMemoryHttpCache(maxEntries = 8, maxBytes = 4096)
    let client = newClient(newCachingTransport(
      newInProcessTransport(cachedResponse), store
    ))
    for iteration in 0 ..< 100:
      let outcome = await client.get("https://example.com/data")
      doAssert outcome.isOk
      doAssert outcome.value.body == "cached payload"
      if iteration > 0:
        doAssert outcome.value.fromCache

  block:
    let store = newMemoryHttpCache(maxEntries = 8, maxBytes = 4096)
    let client = newClient(newCachingTransport(
      newInProcessTransport(cachedResponse), store
    ))
    discard await client.get("https://example.com/limited")
    var options = defaultRequestOptions()
    options.maxResponseBytes = 4
    for iteration in 0 ..< 100:
      discard iteration
      let outcome = await client.get(
        "https://example.com/limited", options = options
      )
      doAssert outcome.isErr
      doAssert outcome.error.kind == jeBodyTooLarge

waitFor exercise()
