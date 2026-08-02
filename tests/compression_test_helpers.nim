import zlib/zlib_api

proc compressForTest*(input: string; windowBits: int): string =
  var stream = ZStream(
    next_in:
      if input.len == 0: nil
      else: cast[ptr uint8](input[0].unsafeAddr),
    avail_in: input.len.cuint
  )
  doAssert stream.deflateInit2(
    Z_DEFAULT_LEVEL,
    Z_DEFLATED,
    cast[ZWindowBits](windowBits),
    Z_DEFAULT_MEM_LEVEL,
    Z_DEFAULT_STRATEGY
  ) == Z_OK
  defer:
    doAssert stream.deflateEnd() == Z_OK

  var buffer: array[4096, char]
  while true:
    stream.next_out = cast[ptr uint8](buffer[0].addr)
    stream.avail_out = buffer.len.cuint
    let status = stream.deflate(Z_FINISH)
    let produced = buffer.len - stream.avail_out.int
    if produced > 0:
      let previous = result.len
      result.setLen(previous + produced)
      copyMem(result[previous].addr, buffer[0].addr, produced)
    if status == Z_STREAM_END:
      break
    doAssert status == Z_OK

proc gzipForTest*(input: string): string =
  compressForTest(input, 31)

proc zlibForTest*(input: string): string =
  compressForTest(input, 15)

proc rawDeflateForTest*(input: string): string =
  compressForTest(input, -15)
