import std/[asyncdispatch, strutils, unittest]
import joubako/[compression, types]
import ./compression_test_helpers

proc decodeAll(
    encoded: string;
    contentEncoding: string;
    limit = -1;
    splitEveryByte = false
): Future[string] {.async.} =
  let decoder = newContentDecoder(
    contentEncoding,
    limit,
    "https://example.test/data",
    200
  )
  defer:
    decoder.close()
  var output: string
  proc emit(chunk: string): Future[void] {.async.} =
    output.add chunk
  if splitEveryByte:
    for value in encoded:
      await decoder.decode($value, emit)
  else:
    await decoder.decode(encoded, emit)
  decoder.finish()
  return output

suite "Bounded HTTP content decoding":
  test "gzip responses are decoded":
    let body = "hello gzip\0payload"
    check waitFor(decodeAll(body.gzipForTest, "gzip")) == body

  test "an empty gzip response is decoded at a zero-byte limit":
    check waitFor(decodeAll(gzipForTest(""), "gzip", 0)) == ""

  test "gzip input can arrive one byte at a time":
    let body = "one-byte transport chunks"
    check waitFor(decodeAll(
      body.gzipForTest,
      "GZip",
      splitEveryByte = true
    )) == body

  test "zlib-wrapped deflate responses are decoded":
    let body = "standard HTTP deflate"
    check waitFor(decodeAll(body.zlibForTest, "deflate")) == body

  test "raw deflate is accepted for compatibility":
    let body = "legacy raw HTTP deflate"
    check waitFor(decodeAll(
      body.rawDeflateForTest,
      "deflate",
      splitEveryByte = true
    )) == body

  test "a body exactly at the decoded limit is accepted":
    let body = "12345678"
    check waitFor(decodeAll(body.gzipForTest, "gzip", body.len)) == body

  test "one decoded byte over the limit is rejected":
    let body = "123456789"
    try:
      discard waitFor(decodeAll(body.gzipForTest, "gzip", body.len - 1))
      fail()
    except JoubakoError as error:
      check error.kind == jeBodyTooLarge
      check error.status == 200
      check error.url == "https://example.test/data"

  test "a zero-byte limit rejects non-empty decoded content":
    try:
      discard waitFor(decodeAll(gzipForTest("x"), "gzip", 0))
      fail()
    except JoubakoError as error:
      check error.kind == jeBodyTooLarge

  test "high-ratio expansion is stopped at the decoded limit":
    let body = repeat('A', 1024 * 1024)
    try:
      discard waitFor(decodeAll(body.gzipForTest, "gzip", 64))
      fail()
    except JoubakoError as error:
      check error.kind == jeBodyTooLarge

  test "a truncated gzip stream is rejected":
    let encoded = gzipForTest("truncated")
    try:
      discard waitFor(decodeAll(encoded[0 ..< encoded.len - 3], "gzip"))
      fail()
    except JoubakoError as error:
      check error.kind == jeCompression
      check "ended before" in error.msg or "invalid" in error.msg

  test "a corrupt gzip checksum is rejected":
    var encoded = gzipForTest("checksum")
    encoded[^5] = char(uint8(encoded[^5]) xor 0xff'u8)
    try:
      discard waitFor(decodeAll(encoded, "gzip"))
      fail()
    except JoubakoError as error:
      check error.kind == jeCompression

  test "trailing bytes are rejected":
    let encoded = gzipForTest("complete") & "unexpected"
    try:
      discard waitFor(decodeAll(encoded, "gzip"))
      fail()
    except JoubakoError as error:
      check error.kind == jeCompression
      check "trailing" in error.msg

  test "unsupported encodings do not create a decoder":
    check newContentDecoder("br", 100, "", 200) == nil
    check newContentDecoder("identity", 100, "", 200) == nil
