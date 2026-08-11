import std/asyncdispatch
import joubako

proc sseHeaders(): Headers =
  result = initHeaders()
  result.set("content-type", "text/event-stream")

proc successfulStream(request: Request): Future[Response] {.async.} =
  return Response(
    status: 200,
    headers: sseHeaders(),
    body: "id: 1\ndata: payload\n\n",
    request: request
  )

proc wrongContentType(request: Request): Future[Response] {.async.} =
  var headers = initHeaders()
  headers.set("content-type", "application/json")
  return Response(
    status: 200,
    headers: headers,
    body: "data: rejected\n\n",
    request: request
  )

proc consume(event: ServerSentEvent) =
  doAssert event.data == "payload"

proc exercise(): Future[void] {.async.} =
  var options = defaultSseOptions()
  options.maxReconnects = 0

  for iteration in 0 ..< 100:
    discard iteration
    block:
      let client = newClient(newInProcessTransport(successfulStream))
      let subscribed = await client.subscribeSse(
        "/events", consume, sseOptions = options
      )
      doAssert subscribed.isOk

    block:
      let client = newClient(newInProcessTransport(wrongContentType))
      let subscribed = await client.subscribeSse(
        "/events", consume, sseOptions = options
      )
      doAssert subscribed.isErr
      doAssert subscribed.error.kind == jeStream

    block:
      let parser = newSseParser(maxEventBytes = 8)
      let parsed = parser.feed("data: oversized\n\n")
      doAssert parsed.isErr
      doAssert parsed.error.kind == jeStream

waitFor exercise()
