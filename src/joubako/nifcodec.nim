## Bounded NIF text / BIF v5 HTTP codec backed by NIFKit.
##
## Callers work with NIF text. Requests are encoded as BIF bytes and successful
## responses are decoded to canonical NIF text. NIFKit v0.2 does not yet expose
## its planned typed Nim-value serializer, so this boundary intentionally uses
## strings and can adopt that API later without changing the wire format.

import std/asyncdispatch
import nifkit
import ./[client, codec, result, types]

const BifMediaType* = "application/x-nif-bif"

type NifCodecOptions* = object
  encodeLimits*: CodecLimits
  decodeLimits*: CodecLimits

proc defaultNifCodecOptions*(): NifCodecOptions =
  NifCodecOptions(
    encodeLimits: defaultCodecLimits(),
    decodeLimits: defaultCodecLimits()
  )

proc asNifCodecError(
    error: ref NifKitError;
    operation: string;
    url = "";
    status = 0
): ref JoubakoError =
  result = newJoubakoError(
    jeCodec,
    operation & ": " & error.msg,
    url,
    status
  )
  result.codecCode = $error.kind
  result.codecOffset = error.offset

proc asMalformedNifCodecError(
    error: ref BifError;
    operation: string;
    url = ""
): ref JoubakoError =
  result = newJoubakoError(jeCodec, operation & ": " & error.msg, url)
  result.codecCode = $nkeMalformedInput
  result.codecOffset = -1

proc tryEncodeNifPayload(
    source: string;
    limits: CodecLimits;
    url = ""
): JResult[string] =
  try:
    result = ok(nifToBif(source, limits))
  except NifKitError as error:
    result = err[string](error.asNifCodecError(
      "could not encode NIF request", url
    ))
  except BifError as error:
    # NIFKit v0.2 retains BifError as its compatibility base and some NIF
    # syntax failures do not yet carry a structured kind or byte offset.
    result = err[string](error.asMalformedNifCodecError(
      "could not encode NIF request", url
    ))
  except CatchableError as error:
    result = err[string](newJoubakoError(
      jeCodec,
      "could not encode NIF request: " & error.msg,
      url
    ))

proc tryDecodeBifResponse(
    response: Response;
    limits: CodecLimits
): JResult[string] =
  try:
    result = ok(bifToNif(response.body, limits))
  except NifKitError as error:
    result = err[string](error.asNifCodecError(
      "could not decode BIF response",
      response.request.url,
      response.status
    ))
  except CatchableError as error:
    result = err[string](newJoubakoError(
      jeCodec,
      "could not decode BIF response: " & error.msg,
      response.request.url,
      response.status
    ))

proc encodeNifPayload*(
    source: string;
    limits = defaultCodecLimits();
    url = ""
): string =
  let encoded = tryEncodeNifPayload(source, limits, url)
  if encoded.isErr:
    raise encoded.error
  result = encoded.value

proc decodeBifResponse*(
    response: Response;
    limits = defaultCodecLimits()
): string =
  let decoded = tryDecodeBifResponse(response, limits)
  if decoded.isErr:
    raise decoded.error
  result = decoded.value

proc nifCodec*(
    options = defaultNifCodecOptions()
): Codec[string, string] =
  Codec[string, string](
    mediaType: BifMediaType,
    encodeResult: proc(source: string): JResult[string] =
      tryEncodeNifPayload(source, options.encodeLimits),
    decodeResponseResult: proc(response: Response): JResult[string] =
      tryDecodeBifResponse(response, options.decodeLimits)
  )

proc getNif*(
    client: Client;
    path: string;
    headers = initHeaders();
    options = RequestOptions();
    codecOptions = defaultNifCodecOptions()
): Future[JResult[string]] =
  client.getWithCodec(
    path,
    proc(response: Response): JResult[string] =
      tryDecodeBifResponse(response, codecOptions.decodeLimits),
    headers,
    options
  )

proc sendNif*(
    client: Client;
    httpMethod: RequestMethod;
    path: string;
    source: string;
    headers = initHeaders();
    options = RequestOptions();
    codecOptions = defaultNifCodecOptions()
): Future[JResult[string]] =
  client.sendWithCodec(
    httpMethod,
    path,
    source,
    nifCodec(codecOptions),
    headers,
    options
  )

proc postNif*(
    client: Client;
    path: string;
    source: string;
    headers = initHeaders();
    options = RequestOptions();
    codecOptions = defaultNifCodecOptions()
): Future[JResult[string]] =
  client.sendNif(rmPost, path, source, headers, options, codecOptions)

proc putNif*(
    client: Client;
    path: string;
    source: string;
    headers = initHeaders();
    options = RequestOptions();
    codecOptions = defaultNifCodecOptions()
): Future[JResult[string]] =
  client.sendNif(rmPut, path, source, headers, options, codecOptions)

proc patchNif*(
    client: Client;
    path: string;
    source: string;
    headers = initHeaders();
    options = RequestOptions();
    codecOptions = defaultNifCodecOptions()
): Future[JResult[string]] =
  client.sendNif(rmPatch, path, source, headers, options, codecOptions)
