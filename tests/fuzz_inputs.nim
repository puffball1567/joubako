import std/[asyncdispatch, os, random, strutils, times]
import joubako
import joubako/compression

type FuzzProtobuf {.proto3.} = object
  id {.fieldNumber: 1, pint.}: uint64
  payload {.fieldNumber: 2.}: seq[byte]

proc randomBytes(maxLength: int): string =
  result = newString(rand(maxLength))
  for index in 0 ..< result.len:
    result[index] = char(rand(255))

proc fuzzCompression(payload: string): Future[void] {.async.} =
  let emit: DecodedChunkProc = proc(_: string): Future[void] {.async.} =
    discard
  for encoding in ["gzip", "deflate"]:
    let decoder = newContentDecoder(
      encoding, 1_024, "fuzz://input", 200
    )
    defer:
      decoder.close()
    let decoded = await settle(
      fallible(decoder.decode(payload, emit)),
      jeCompression,
      "fuzz://input"
    )
    if decoded.isOk:
      try:
        decoder.finish()
      except JoubakoError as error:
        doAssert error.kind in {jeCompression, jeBodyTooLarge}
    else:
      doAssert decoded.error.kind in {jeCompression, jeBodyTooLarge}

proc fuzzJsonStreams(payload: string) =
  for format in [jsfNdjson, jsfJsonSequence]:
    var options = defaultJsonStreamParserOptions()
    options.maxRecordBytes = 128
    options.skipInvalidRecords = (payload.len mod 2) == 0
    options.allowUnterminatedNdjsonRecord = (payload.len mod 3) == 0
    let parser = newJsonStreamParser(format, options)
    var offset = 0
    var failed = false
    while offset < payload.len and not failed:
      let size = min(payload.len - offset, max(1, rand(16)))
      let parsed = parser.feed(payload[offset ..< offset + size])
      if parsed.isErr:
        doAssert parsed.error.kind in {jeCodec, jeBodyTooLarge}
        failed = true
      offset += size
    if not failed:
      let finished = parser.finish()
      if finished.isErr:
        doAssert finished.error.kind in {jeCodec, jeBodyTooLarge}

proc fuzzCbor(payload: string) =
  var options = defaultCborCodecOptions()
  options.maxPayloadBytes = 512
  options.readerConf.nestedDepthLimit = 16
  options.readerConf.arrayElementsLimit = 64
  options.readerConf.objectFieldsLimit = 64
  options.readerConf.stringLengthLimit = 256
  options.readerConf.byteStringLengthLimit = 256
  for decoded in [
      tryDecodeCborPayload(payload, uint64, options).isOk,
      tryDecodeCborPayload(payload, string, options).isOk,
      tryDecodeCborPayload(payload, seq[byte], options).isOk,
      tryDecodeCborPayload(payload, CborValueRef, options).isOk
  ]:
    discard decoded

proc fuzzProtobuf(payload: string) =
  var options = defaultProtobufCodecOptions()
  options.maxPayloadBytes = 512
  let decoded = tryDecodeProtobufPayload(payload, FuzzProtobuf, options)
  if decoded.isErr:
    doAssert decoded.error.kind == jeCodec

proc main(): Future[void] {.async.} =
  randomize(0x4a4f5542)
  let iterations = getEnv("JOUBAKO_FUZZ_ITERATIONS", "10000").parseInt
  let jar = newCookieJar(maxCookies = 128, maxCookiesPerDomain = 32)
  for index in 0 ..< iterations:
    let payload = randomBytes(512)
    discard jar.store(
      "https://api.example.test/a/" & $index,
      payload,
      fromUnix(int64(index))
    )
    discard jar.cookieHeader(
      "https://api.example.test/a/resource", fromUnix(int64(index))
    )
    discard isProxyBypassed(
      "https://api.example.test:443/path",
      [payload, ".example.test", "[::1]:443"]
    )
    discard parseRetryAfterMs(payload, fromUnix(0))
    discard withQuery("/fuzz#fragment", [
      (name: payload, value: randomBytes(64))
    ])
    fuzzJsonStreams(payload)
    fuzzCbor(payload)
    fuzzProtobuf(payload)
    if index mod 10 == 0:
      await fuzzCompression(payload)

waitFor main()
