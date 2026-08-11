import std/[asyncdispatch, json]
import joubako

type
  Event = object
    id: int

  Counter = ref object
    value: int

proc streamResponse(request: Request): Response =
  let format =
    if request.headers.get("accept") == JsonSequenceMediaType:
      jsfJsonSequence
    else:
      jsfNdjson
  let body =
    if format == jsfJsonSequence:
      "\x1e{\"id\":1}\n\x1e{\"id\":2}\n"
    else:
      "{\"id\":1}\n{\"id\":2}\n"
  var headers = initHeaders()
  headers.set("content-type", format.mediaType)
  Response(status: 200, headers: headers, body: body, request: request)

proc asyncConsumer(counter: Counter): AsyncJsonRecordProc[Event] =
  result = proc(event: Event): Future[void] {.async.} =
    counter.value += event.id

proc syncConsumer(counter: Counter): JsonRecordProc[Event] =
  result = proc(event: Event) = counter.value += event.id

proc main(): Future[void] {.async.} =
  let client = newClient(newInProcessTransport(
    proc(request: Request): Future[Response] {.async.} =
      return request.streamResponse()
  ))
  let counter = Counter()
  let consumeAsync = counter.asyncConsumer()
  let consume = counter.syncConsumer()
  for _ in 0 ..< 300:
    let ndjson = await client.getNdjson("/ndjson", Event, consume)
    doAssert ndjson.isOk
    let sequence = await client.getJsonSequenceAsync(
      "/sequence", Event, consumeAsync
    )
    doAssert sequence.isOk
    let encodedNdjson = encodeNdjson([Event(id: 1), Event(id: 2)])
    let encodedSequence = encodeJsonSequence([%*true, %*42])
    doAssert encodedNdjson.isOk
    doAssert encodedSequence.isOk

  doAssert counter.value == 1_800

waitFor main()
