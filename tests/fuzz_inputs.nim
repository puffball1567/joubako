import std/[asyncdispatch, os, random, strutils, times]
import joubako
import joubako/compression

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
    if index mod 10 == 0:
      await fuzzCompression(payload)

waitFor main()
