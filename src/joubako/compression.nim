import std/[asyncdispatch, strutils]
import zlib/zlib_api
import ./types

const DecodeChunkBytes = 16 * 1024

type
  DecodedChunkProc* = proc(chunk: string): Future[void] {.closure.}

  ContentDecoder* = ref object
    stream: ZStream
    encoding: string
    url: string
    status: int
    limit: int
    produced: int
    initialized: bool
    finished: bool
    pending: string
    inputOwner: string

func normalizedEncoding(value: string): string =
  value.strip.toLowerAscii

func isCompressedEncoding*(value: string): bool =
  normalizedEncoding(value) in ["gzip", "deflate"]

proc compressionError(
    decoder: ContentDecoder;
    message: string
): ref JoubakoError =
  newJoubakoError(jeCompression, message, decoder.url, decoder.status)

proc initialize(decoder: ContentDecoder; windowBits: int) =
  let status = decoder.stream.inflateInit2(cast[ZWindowBits](windowBits))
  if status != Z_OK:
    raise decoder.compressionError(
      "failed to initialize " & decoder.encoding & " response decoder: " &
      $status
    )
  decoder.initialized = true

func hasZlibWrapper(data: string): bool =
  if data.len < 2:
    return false
  let
    cmf = uint8(data[0])
    flg = uint8(data[1])
  (cmf and 0x0f'u8) == 8'u8 and
    (cmf shr 4) <= 7'u8 and
    (uint16(cmf) * 256'u16 + uint16(flg)) mod 31'u16 == 0'u16

proc newContentDecoder*(
    contentEncoding: string;
    limit: int;
    url: string;
    status: int
): ContentDecoder =
  let encoding = contentEncoding.normalizedEncoding
  if encoding notin ["gzip", "deflate"]:
    return nil
  result = ContentDecoder(
    encoding: encoding,
    url: url,
    status: status,
    limit: limit
  )
  if encoding == "gzip":
    # MAX_WBITS + 16 asks zlib to validate the gzip wrapper and checksum.
    result.initialize(31)

proc close*(decoder: ContentDecoder) =
  if decoder != nil and decoder.initialized:
    discard decoder.stream.inflateEnd()
    decoder.initialized = false
  if decoder != nil:
    decoder.inputOwner.setLen(0)
    decoder.pending.setLen(0)

proc decode*(
    decoder: ContentDecoder;
    input: string;
    emit: DecodedChunkProc
): Future[void] {.async.} =
  if decoder == nil or input.len == 0:
    return
  if decoder.finished:
    raise decoder.compressionError(
      "compressed response contains trailing data"
    )

  if not decoder.initialized:
    decoder.pending.add input
    if decoder.pending.len < 2:
      return
    # HTTP `deflate` formally means the zlib wrapper. Raw DEFLATE is also
    # accepted for compatibility with older servers.
    decoder.initialize(if decoder.pending.hasZlibWrapper: 15 else: -15)
    decoder.inputOwner = move(decoder.pending)
  else:
    decoder.inputOwner = input

  defer:
    decoder.inputOwner.setLen(0)

  decoder.stream.next_in =
    cast[ptr uint8](decoder.inputOwner[0].unsafeAddr)
  decoder.stream.avail_in = decoder.inputOwner.len.cuint

  var output: array[DecodeChunkBytes, char]
  while not decoder.finished:
    let remaining =
      if decoder.limit < 0:
        DecodeChunkBytes
      else:
        max(0, decoder.limit - decoder.produced)
    # The extra byte detects an over-limit stream without materializing an
    # arbitrarily large expansion.
    let capacity =
      if decoder.limit < 0:
        DecodeChunkBytes
      elif remaining >= DecodeChunkBytes:
        DecodeChunkBytes
      else:
        remaining + 1
    decoder.stream.next_out = cast[ptr uint8](output[0].addr)
    decoder.stream.avail_out = capacity.cuint
    let inputBefore = decoder.stream.avail_in
    let status = decoder.stream.inflate(Z_NO_FLUSH)
    let outputSize = capacity - decoder.stream.avail_out.int

    if decoder.limit >= 0 and outputSize > remaining:
      raise newJoubakoError(
        jeBodyTooLarge,
        "decompressed response body exceeded the configured limit",
        decoder.url,
        decoder.status
      )

    if outputSize > 0:
      decoder.produced += outputSize
      var chunk = newString(outputSize)
      copyMem(chunk[0].addr, output[0].addr, outputSize)
      await emit(move(chunk))

    case status
    of Z_STREAM_END:
      decoder.finished = true
      if decoder.stream.avail_in > 0:
        raise decoder.compressionError(
          "compressed response contains trailing data"
        )
    of Z_OK:
      if decoder.stream.avail_in == inputBefore and outputSize == 0:
        raise decoder.compressionError(
          "compressed response decoder made no progress"
        )
      if decoder.stream.avail_in == 0 and
          decoder.stream.avail_out > 0:
        break
    of Z_BUF_ERROR:
      if decoder.stream.avail_in > 0:
        raise decoder.compressionError(
          "compressed response decoder exhausted its output buffer"
        )
      break
    else:
      raise decoder.compressionError(
        "invalid " & decoder.encoding & " response body: " & $status
      )

proc finish*(decoder: ContentDecoder) =
  if decoder == nil:
    return
  if not decoder.initialized or not decoder.finished:
    raise decoder.compressionError(
      "compressed response body ended before the stream was complete"
    )
