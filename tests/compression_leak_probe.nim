import std/[asyncdispatch, strutils]
import joubako/[compression, result, types]
import ./compression_test_helpers

proc consume(
    encoded: string;
    limit: int
): Future[JResult[int]] {.async.} =
  let decoder = newContentDecoder("gzip", limit, "leak://probe", 200)
  defer:
    decoder.close()
  var received = 0
  proc emit(chunk: string): Future[void] {.async.} =
    received += chunk.len
  let decoded = await settle(
    fallible(decoder.decode(encoded, emit)),
    jeCompression,
    "leak://probe"
  )
  if decoded.isErr:
    return err[int](decoded.error)
  try:
    decoder.finish()
  except JoubakoError as error:
    return err[int](error)
  return ok(received)

proc exercise(): Future[void] {.async.} =
  let body = repeat('A', 64 * 1024)
  let valid = body.gzipForTest
  var corrupt = valid
  corrupt[^5] = char(uint8(corrupt[^5]) xor 0xff'u8)

  for _ in 0 ..< 400:
    let success = await consume(valid, body.len)
    doAssert success.isOk
    doAssert success.value == body.len
    let oversized = await consume(valid, 32)
    doAssert oversized.isErr
    doAssert oversized.error.kind == jeBodyTooLarge
    let invalid = await consume(corrupt, body.len)
    doAssert invalid.isErr
    doAssert invalid.error.kind == jeCompression

waitFor exercise()
