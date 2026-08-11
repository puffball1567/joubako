import std/[asyncdispatch, base64, os, strutils, sysrand]
import ./[client, result, types]

func formField*(name, value: string): MultipartPart =
  MultipartPart(name: name, body: value)

func formFile*(
    name, filename, body: string;
    contentType = "application/octet-stream";
    maxBytes = 0'i64
): MultipartPart =
  MultipartPart(
    name: name,
    filename: filename,
    contentType: contentType,
    body: body,
    maxBytes: maxBytes
  )

func formFilePath*(
    name, filePath: string;
    filename = "";
    contentType = "application/octet-stream";
    maxBytes = 0'i64
): MultipartPart =
  ## Describes a file that will be opened and streamed during HTTP dispatch.
  ## The path itself is never placed in the multipart headers.
  let transmittedName =
    if filename.len > 0:
      filename
    else:
      let (_, base, extension) = splitFile(filePath)
      base & extension
  MultipartPart(
    name: name,
    filename: transmittedName,
    contentType: contentType,
    filePath: filePath,
    maxBytes: maxBytes
  )

proc multipartBoundary*(): string =
  var random = newString(18)
  let bytes = urandom(18)
  for index, value in bytes:
    random[index] = char(value)
  "joubako-" & encode(random).replace("+", "-").replace("/", "_").replace("=", "")

proc validateDispositionValue(value, label: string) =
  if value.len == 0 or value.contains({'\0', '\r', '\n', '"'}):
    raise newJoubakoError(
      jeInvalidRequest, "invalid multipart " & label
    )

proc encodeMultipart*(
    parts: openArray[MultipartPart];
    boundary: string
): string =
  validateDispositionValue(boundary, "boundary")
  for part in parts:
    if part.filePath.len > 0:
      raise newJoubakoError(
        jeInvalidRequest,
        "file-backed multipart parts cannot be buffered"
      )
    validateDispositionValue(part.name, "field name")
    result.add "--" & boundary & "\r\n"
    result.add "Content-Disposition: form-data; name=\"" & part.name & "\""
    if part.filename.len > 0:
      validateDispositionValue(part.filename, "filename")
      result.add "; filename=\"" & part.filename & "\""
    result.add "\r\n"
    if part.contentType.len > 0:
      if part.contentType.contains({'\0', '\r', '\n'}):
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
  for part in parts:
    if part.filePath.len > 0:
      return client.requestMultipart(
        rmPost, path, @parts, headers, options
      )
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

proc putMultipart*(
    client: Client;
    path: string;
    parts: openArray[MultipartPart];
    headers = initHeaders();
    options = RequestOptions()
): Future[JResult[Response]] =
  for part in parts:
    if part.filePath.len > 0:
      return client.requestMultipart(rmPut, path, @parts, headers, options)
  let boundary = multipartBoundary()
  var multipartHeaders = headers
  if not multipartHeaders.contains("content-type"):
    multipartHeaders.set(
      "content-type", "multipart/form-data; boundary=" & boundary
    )
  client.put(path, encodeMultipart(parts, boundary), multipartHeaders, options)

proc patchMultipart*(
    client: Client;
    path: string;
    parts: openArray[MultipartPart];
    headers = initHeaders();
    options = RequestOptions()
): Future[JResult[Response]] =
  for part in parts:
    if part.filePath.len > 0:
      return client.requestMultipart(rmPatch, path, @parts, headers, options)
  let boundary = multipartBoundary()
  var multipartHeaders = headers
  if not multipartHeaders.contains("content-type"):
    multipartHeaders.set(
      "content-type", "multipart/form-data; boundary=" & boundary
    )
  client.patch(
    path, encodeMultipart(parts, boundary), multipartHeaders, options
  )
