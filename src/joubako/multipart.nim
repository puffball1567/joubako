import std/[asyncdispatch, base64, strutils, sysrand]
import ./[client, result, types]

type
  MultipartPart* = object
    name*: string
    filename*: string
    contentType*: string
    body*: string

func formField*(name, value: string): MultipartPart =
  MultipartPart(name: name, body: value)

func formFile*(
    name, filename, body: string;
    contentType = "application/octet-stream"
): MultipartPart =
  MultipartPart(
    name: name,
    filename: filename,
    contentType: contentType,
    body: body
  )

proc multipartBoundary*(): string =
  var random = newString(18)
  let bytes = urandom(18)
  for index, value in bytes:
    random[index] = char(value)
  "joubako-" & encode(random).replace("+", "-").replace("/", "_").replace("=", "")

proc validateDispositionValue(value, label: string) =
  if value.len == 0 or value.contains({'\r', '\n', '"'}):
    raise newJoubakoError(
      jeInvalidRequest, "invalid multipart " & label
    )

proc encodeMultipart*(
    parts: openArray[MultipartPart];
    boundary: string
): string =
  validateDispositionValue(boundary, "boundary")
  for part in parts:
    validateDispositionValue(part.name, "field name")
    result.add "--" & boundary & "\r\n"
    result.add "Content-Disposition: form-data; name=\"" & part.name & "\""
    if part.filename.len > 0:
      validateDispositionValue(part.filename, "filename")
      result.add "; filename=\"" & part.filename & "\""
    result.add "\r\n"
    if part.contentType.len > 0:
      if part.contentType.contains({'\r', '\n'}):
        raise newJoubakoError(
          jeInvalidRequest, "invalid multipart content type"
        )
      result.add "Content-Type: " & part.contentType & "\r\n"
    result.add "\r\n" & part.body & "\r\n"
  result.add "--" & boundary & "--\r\n"

proc postMultipart*(
    client: Client;
    path: string;
    parts: openArray[MultipartPart];
    headers = initHeaders();
    options = RequestOptions()
): Future[JResult[Response]] =
  let boundary = multipartBoundary()
  var multipartHeaders = headers
  if not multipartHeaders.contains("content-type"):
    multipartHeaders.set(
      "content-type", "multipart/form-data; boundary=" & boundary
    )
  client.post(
    path,
    encodeMultipart(parts, boundary),
    multipartHeaders,
    options
  )
