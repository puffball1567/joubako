import std/[asyncdispatch, strutils]
import ./[client, query, result, types]

func encodeForm*(fields: openArray[QueryParam]): string =
  ## Uses the same RFC-compatible percent encoding as URL query parameters.
  withQuery("", fields).strip(chars = {'?'})

proc sendForm*(
    client: Client;
    httpMethod: RequestMethod;
    path: string;
    fields: openArray[QueryParam];
    headers = initHeaders();
    options = RequestOptions()
): Future[JResult[Response]] =
  var formHeaders = headers
  if not formHeaders.contains("content-type"):
    formHeaders.set("content-type", "application/x-www-form-urlencoded")
  client.request(
    httpMethod,
    path,
    encodeForm(fields),
    formHeaders,
    options
  )

proc postForm*(
    client: Client;
    path: string;
    fields: openArray[QueryParam];
    headers = initHeaders();
    options = RequestOptions()
): Future[JResult[Response]] =
  client.sendForm(rmPost, path, fields, headers, options)

proc putForm*(
    client: Client;
    path: string;
    fields: openArray[QueryParam];
    headers = initHeaders();
    options = RequestOptions()
): Future[JResult[Response]] =
  client.sendForm(rmPut, path, fields, headers, options)

proc patchForm*(
    client: Client;
    path: string;
    fields: openArray[QueryParam];
    headers = initHeaders();
    options = RequestOptions()
): Future[JResult[Response]] =
  client.sendForm(rmPatch, path, fields, headers, options)
