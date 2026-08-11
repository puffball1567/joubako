## Bounded NIF/BIF v5 HTTP codecs backed by NIFKit.
##
## Raw helpers convert NIF text to BIF bytes and successful responses to
## canonical NIF text. Typed helpers use NIFKit's data profile and convert Nim
## values directly to and from BIF without an intermediate NIF allocation.

import std/[asyncdispatch, strutils, tables, uri]
import nifkit
import ./[client, codec, result, transport, types]

const BifMediaType* = "application/x-nif-bif"

const
  DefaultNifInputBytes* = 16 * 1024 * 1024
  DefaultNifEncodedBytes* = 16 * 1024 * 1024
  DefaultNifDecodedBytes* = 64 * 1024 * 1024
  DefaultNifNestingDepth* = 64
  DefaultNifTokens* = 100_000
  DefaultNifPoolEntries* = 100_000
  DefaultNifPoolBytes* = 16 * 1024 * 1024
  DefaultNifStringBytes* = 4 * 1024 * 1024
  DefaultNifIndexEntries* = 100_000
  DefaultNifContainerItems* = 10_000
  DefaultNifObjectFields* = 10_000
  DefaultNifTrackedReferences* = 10_000
  DefaultNifMetadataBytes* = 64 * 1024
  DefaultNifUploadBytes* = 128 * 1024 * 1024
  DefaultNifMultipartBytes* = 129 * 1024 * 1024

type
  NifCodecOptions* = object
    encodeLimits*: CodecLimits
    decodeLimits*: CodecLimits
    typedOptions*: TypedCodecOptions

  NifMultipartLimits* = object
    ## Metadata, file payload, and complete multipart wire budgets are
    ## independent. Runtime accounting is required by default.
    maxMetadataBytes*: int
    maxUploadBytes*: int64
    maxMultipartBytes*: int
    requireRuntimeAccounting*: bool

  NifPolicy* = object
    ## Wire limits are kept beside codec limits so one selected policy bounds
    ## both transport buffering and NIFKit conversion.
    maxRequestBytes*: int
    maxResponseBytes*: int
    codecOptions*: NifCodecOptions
    multipartLimits*: NifMultipartLimits

  NifPolicyRoute* = object
    ## An empty method set matches every method. Exact paths take precedence
    ## over prefixes; otherwise the longest matching prefix wins.
    httpMethods*: set[RequestMethod]
    path*: string
    pathPrefix*: string
    policy*: string

  NifPolicySet* = object
    defaultPolicy*: string
    policies*: OrderedTable[string, NifPolicy]
    routes*: seq[NifPolicyRoute]

  NifClient* = object
    ## A policy-aware view over an ordinary Joubako client.
    client*: Client
    nifPolicies*: NifPolicySet

func networkNifCodecLimits(maxOutputBytes: int): CodecLimits =
  ## Joubako owns a finite policy for peer-facing conversion. NIFKit itself is
  ## intentionally policy-free because local tools have different workloads.
  CodecLimits(
    maxInputBytes: DefaultNifInputBytes,
    maxOutputBytes: maxOutputBytes,
    maxNestingDepth: DefaultNifNestingDepth,
    maxTokens: DefaultNifTokens,
    maxPoolEntries: DefaultNifPoolEntries,
    maxPoolBytes: DefaultNifPoolBytes,
    maxStringBytes: DefaultNifStringBytes,
    maxIndexEntries: DefaultNifIndexEntries,
    maxContainerItems: DefaultNifContainerItems,
    maxObjectFields: DefaultNifObjectFields,
    maxTrackedReferences: DefaultNifTrackedReferences
  )

func defaultNifEncodeLimits*(): CodecLimits =
  networkNifCodecLimits(DefaultNifEncodedBytes)

func defaultNifDecodeLimits*(): CodecLimits =
  networkNifCodecLimits(DefaultNifDecodedBytes)

proc defaultNifCodecOptions*(): NifCodecOptions =
  NifCodecOptions(
    encodeLimits: defaultNifEncodeLimits(),
    decodeLimits: defaultNifDecodeLimits(),
    typedOptions: defaultTypedCodecOptions()
  )

proc defaultNifMultipartLimits*(): NifMultipartLimits =
  NifMultipartLimits(
    maxMetadataBytes: DefaultNifMetadataBytes,
    maxUploadBytes: DefaultNifUploadBytes,
    maxMultipartBytes: DefaultNifMultipartBytes,
    requireRuntimeAccounting: true
  )

proc newNifMultipartLimits*(
    maxMetadataBytes = DefaultNifMetadataBytes;
    maxUploadBytes = DefaultNifUploadBytes.int64;
    maxMultipartBytes = DefaultNifMultipartBytes;
    requireRuntimeAccounting = true
): NifMultipartLimits =
  NifMultipartLimits(
    maxMetadataBytes: maxMetadataBytes,
    maxUploadBytes: maxUploadBytes,
    maxMultipartBytes: maxMultipartBytes,
    requireRuntimeAccounting: requireRuntimeAccounting
  )

proc defaultNifPolicy*(): NifPolicy =
  NifPolicy(
    maxRequestBytes: DefaultNifEncodedBytes,
    maxResponseBytes: DefaultNifInputBytes,
    codecOptions: defaultNifCodecOptions(),
    multipartLimits: defaultNifMultipartLimits()
  )

proc newNifPolicy*(
    maxRequestBytes = DefaultNifEncodedBytes;
    maxResponseBytes = DefaultNifInputBytes;
    maxNestingDepth = DefaultNifNestingDepth;
    maxTokens = DefaultNifTokens;
    maxPoolBytes = DefaultNifPoolBytes;
    maxMetadataBytes = DefaultNifMetadataBytes;
    maxUploadBytes = DefaultNifUploadBytes.int64;
    maxMultipartBytes = DefaultNifMultipartBytes;
    requireRuntimeAccounting = true
): NifPolicy =
  ## Creates the common, concise network policy shown in configuration files.
  ## Less common NIFKit limits remain independently adjustable through the
  ## exported `codecOptions` field.
  result = defaultNifPolicy()
  result.maxRequestBytes = maxRequestBytes
  result.maxResponseBytes = maxResponseBytes
  result.multipartLimits = newNifMultipartLimits(
    maxMetadataBytes,
    maxUploadBytes,
    maxMultipartBytes,
    requireRuntimeAccounting
  )
  result.codecOptions.encodeLimits.maxInputBytes = maxRequestBytes
  result.codecOptions.encodeLimits.maxOutputBytes = maxRequestBytes
  result.codecOptions.decodeLimits.maxInputBytes = maxResponseBytes
  result.codecOptions.encodeLimits.maxNestingDepth = maxNestingDepth
  result.codecOptions.decodeLimits.maxNestingDepth = maxNestingDepth
  result.codecOptions.encodeLimits.maxTokens = maxTokens
  result.codecOptions.decodeLimits.maxTokens = maxTokens
  result.codecOptions.encodeLimits.maxPoolBytes = maxPoolBytes
  result.codecOptions.decodeLimits.maxPoolBytes = maxPoolBytes

proc initNifPolicySet*(defaultPolicy = "default"): NifPolicySet =
  result.defaultPolicy = defaultPolicy
  result.policies = initOrderedTable[string, NifPolicy]()
  if defaultPolicy.len > 0:
    result.policies[defaultPolicy] = defaultNifPolicy()

proc definePolicy*(
    policies: var NifPolicySet;
    name: string;
    policy: NifPolicy
) =
  if name.len == 0:
    raise newException(ValueError, "NIF policy name must not be empty")
  policies.policies[name] = policy

proc addRoute*(policies: var NifPolicySet; route: NifPolicyRoute) =
  if route.path.len == 0 and route.pathPrefix.len == 0:
    raise newException(ValueError, "NIF policy route needs path or pathPrefix")
  if route.path.len > 0 and route.pathPrefix.len > 0:
    raise newException(
      ValueError, "NIF policy route cannot use path and pathPrefix together"
    )
  if not policies.policies.hasKey(route.policy):
    raise newException(ValueError, "unknown NIF policy: " & route.policy)
  policies.routes.add route

proc withNifPolicies*(client: Client; policies: NifPolicySet): NifClient =
  if policies.defaultPolicy.len > 0 and
      not policies.policies.hasKey(policies.defaultPolicy):
    raise newException(
      ValueError, "unknown default NIF policy: " & policies.defaultPolicy
    )
  for name, policy in policies.policies:
    if name.len == 0:
      raise newException(ValueError, "NIF policy name must not be empty")
    if policy.maxRequestBytes == 0 or policy.maxResponseBytes == 0:
      raise newException(
        ValueError,
        "NIF policy wire limits must be positive or negative: " & name
      )
    if policy.multipartLimits.maxMetadataBytes == 0 or
        policy.multipartLimits.maxUploadBytes == 0 or
        policy.multipartLimits.maxMultipartBytes == 0:
      raise newException(
        ValueError,
        "NIF multipart limits must be positive or negative: " & name
      )
  for route in policies.routes:
    if route.path.len == 0 and route.pathPrefix.len == 0:
      raise newException(ValueError, "NIF policy route needs path or pathPrefix")
    if route.path.len > 0 and route.pathPrefix.len > 0:
      raise newException(
        ValueError, "NIF policy route cannot use path and pathPrefix together"
      )
    if not policies.policies.hasKey(route.policy):
      raise newException(ValueError, "unknown NIF policy: " & route.policy)
  NifClient(client: client, nifPolicies: policies)

func routePath(path: string): string =
  let parsed = parseUri(path)
  if parsed.path.len == 0:
    return "/"
  if parsed.path[0] == '/':
    parsed.path
  else:
    "/" & parsed.path

func prefixMatches(path, prefix: string): bool =
  if prefix.len == 0:
    return false
  if prefix == "/":
    return path.len > 0 and path[0] == '/'
  if not path.startsWith(prefix):
    return false
  path.len == prefix.len or prefix[^1] == '/' or path[prefix.len] == '/'

proc resolveNifPolicy*(
    policies: NifPolicySet;
    httpMethod: RequestMethod;
    path: string;
    policyName = ""
): NifPolicy =
  ## Explicit selection wins, then exact path, longest prefix, and default.
  var selected = policyName
  if selected.len == 0:
    let normalizedPath = routePath(path)
    var longestPrefix = -1
    for route in policies.routes:
      if route.httpMethods != {} and httpMethod notin route.httpMethods:
        continue
      if route.path.len > 0 and routePath(route.path) == normalizedPath:
        selected = route.policy
        longestPrefix = high(int)
        break
      if route.pathPrefix.len > 0 and
          route.pathPrefix.len > longestPrefix and
          prefixMatches(normalizedPath, route.pathPrefix):
        selected = route.policy
        longestPrefix = route.pathPrefix.len
  if selected.len == 0:
    selected = policies.defaultPolicy
  if not policies.policies.hasKey(selected):
    raise newException(ValueError, "unknown NIF policy: " & selected)
  policies.policies[selected]

func applyPolicy(options: RequestOptions; policy: NifPolicy): RequestOptions =
  result = options
  if result.maxRequestBytes == 0:
    result.maxRequestBytes = policy.maxRequestBytes
  if result.maxResponseBytes == 0:
    result.maxResponseBytes = policy.maxResponseBytes

func effectiveCodecOptions(policy: NifPolicy): NifCodecOptions =
  ## Keep the convenient wire fields authoritative even when a policy was
  ## assembled or modified as an object literal.
  result = policy.codecOptions
  result.encodeLimits.maxInputBytes = policy.maxRequestBytes
  result.encodeLimits.maxOutputBytes = policy.maxRequestBytes
  result.decodeLimits.maxInputBytes = policy.maxResponseBytes

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
  result.codecPath = error.path

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
    # BifError remains NIFKit's compatibility base for legacy failures.
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
    limits = defaultNifEncodeLimits();
    url = ""
): string =
  let encoded = tryEncodeNifPayload(source, limits, url)
  if encoded.isErr:
    raise encoded.error
  result = encoded.value

proc decodeBifResponse*(
    response: Response;
    limits = defaultNifDecodeLimits()
): string =
  let decoded = tryDecodeBifResponse(response, limits)
  if decoded.isErr:
    raise decoded.error
  result = decoded.value

proc tryEncodeNifValue*[T](
    value: T;
    options = defaultNifCodecOptions();
    url = ""
): JResult[string] =
  try:
    result = ok(toBif(value, options.encodeLimits))
  except NifKitError as error:
    result = err[string](error.asNifCodecError(
      "could not encode typed NIF request", url
    ))
  except BifError as error:
    result = err[string](error.asMalformedNifCodecError(
      "could not encode typed NIF request", url
    ))
  except CatchableError as error:
    result = err[string](newJoubakoError(
      jeCodec,
      "could not encode typed NIF request: " & error.msg,
      url
    ))

proc tryDecodeNifValue*[T](
    payload: string;
    _: typedesc[T];
    options = defaultNifCodecOptions();
    url = "";
    status = 0
): JResult[T] =
  try:
    result = ok(fromBif(
      payload, T, options.decodeLimits, options.typedOptions
    ))
  except NifKitError as error:
    result = err[T](error.asNifCodecError(
      "could not decode typed BIF response", url, status
    ))
  except BifError as error:
    result = err[T](error.asMalformedNifCodecError(
      "could not decode typed BIF response", url
    ))
    result.error.status = status
  except CatchableError as error:
    result = err[T](newJoubakoError(
      jeCodec,
      "could not decode typed BIF response: " & error.msg,
      url,
      status
    ))

proc encodeNifValue*[T](
    value: T;
    options = defaultNifCodecOptions();
    url = ""
): string =
  let encoded = tryEncodeNifValue(value, options, url)
  if encoded.isErr:
    raise encoded.error
  encoded.value

proc decodeNifValue*[T](
    payload: string;
    _: typedesc[T];
    options = defaultNifCodecOptions();
    url = "";
    status = 0
): T =
  let decoded = tryDecodeNifValue(payload, T, options, url, status)
  if decoded.isErr:
    raise decoded.error
  decoded.value

proc tryDecodeNifValueResponse[T](
    response: Response;
    _: typedesc[T];
    options: NifCodecOptions
): JResult[T] =
  tryDecodeNifValue(
    response.body,
    T,
    options,
    response.request.url,
    response.status
  )

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

proc nifCodec*[TBody, TResponse](
    _: typedesc[TBody];
    _: typedesc[TResponse];
    options = defaultNifCodecOptions()
): Codec[TBody, TResponse] =
  Codec[TBody, TResponse](
    mediaType: BifMediaType,
    encodeResult: proc(value: TBody): JResult[string] =
      tryEncodeNifValue(value, options),
    decodeResponseResult: proc(response: Response): JResult[TResponse] =
      tryDecodeNifValueResponse(response, TResponse, options)
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

proc getNif*[T](
    client: Client;
    path: string;
    _: typedesc[T];
    headers = initHeaders();
    options = RequestOptions();
    codecOptions = defaultNifCodecOptions()
): Future[JResult[T]] =
  var requestHeaders = headers
  if not requestHeaders.contains("accept"):
    requestHeaders.set("accept", BifMediaType)
  client.getWithCodec(
    path,
    proc(response: Response): JResult[T] =
      tryDecodeNifValueResponse(response, T, codecOptions),
    requestHeaders,
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

proc sendNif*[TBody, TResponse](
    client: Client;
    httpMethod: RequestMethod;
    path: string;
    value: TBody;
    _: typedesc[TResponse];
    headers = initHeaders();
    options = RequestOptions();
    codecOptions = defaultNifCodecOptions()
): Future[JResult[TResponse]] =
  var requestHeaders = headers
  if not requestHeaders.contains("accept"):
    requestHeaders.set("accept", BifMediaType)
  client.sendWithCodec(
    httpMethod,
    path,
    value,
    nifCodec(TBody, TResponse, codecOptions),
    requestHeaders,
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

proc postNif*[TBody, TResponse](
    client: Client;
    path: string;
    value: TBody;
    _: typedesc[TResponse];
    headers = initHeaders();
    options = RequestOptions();
    codecOptions = defaultNifCodecOptions()
): Future[JResult[TResponse]] =
  client.sendNif(
    rmPost, path, value, TResponse, headers, options, codecOptions
  )

proc putNif*(
    client: Client;
    path: string;
    source: string;
    headers = initHeaders();
    options = RequestOptions();
    codecOptions = defaultNifCodecOptions()
): Future[JResult[string]] =
  client.sendNif(rmPut, path, source, headers, options, codecOptions)

proc putNif*[TBody, TResponse](
    client: Client;
    path: string;
    value: TBody;
    _: typedesc[TResponse];
    headers = initHeaders();
    options = RequestOptions();
    codecOptions = defaultNifCodecOptions()
): Future[JResult[TResponse]] =
  client.sendNif(
    rmPut, path, value, TResponse, headers, options, codecOptions
  )

proc patchNif*(
    client: Client;
    path: string;
    source: string;
    headers = initHeaders();
    options = RequestOptions();
    codecOptions = defaultNifCodecOptions()
): Future[JResult[string]] =
  client.sendNif(rmPatch, path, source, headers, options, codecOptions)

proc patchNif*[TBody, TResponse](
    client: Client;
    path: string;
    value: TBody;
    _: typedesc[TResponse];
    headers = initHeaders();
    options = RequestOptions();
    codecOptions = defaultNifCodecOptions()
): Future[JResult[TResponse]] =
  client.sendNif(
    rmPatch, path, value, TResponse, headers, options, codecOptions
  )

proc getNif*(
    client: NifClient;
    path: string;
    headers = initHeaders();
    options = RequestOptions();
    policyName = ""
): Future[JResult[string]] =
  let policy = client.nifPolicies.resolveNifPolicy(
    rmGet, path, policyName
  )
  client.client.getNif(
    path,
    headers,
    options.applyPolicy(policy),
    policy.effectiveCodecOptions()
  )

proc getNif*[T](
    client: NifClient;
    path: string;
    _: typedesc[T];
    headers = initHeaders();
    options = RequestOptions();
    policyName = ""
): Future[JResult[T]] =
  let policy = client.nifPolicies.resolveNifPolicy(
    rmGet, path, policyName
  )
  client.client.getNif(
    path,
    T,
    headers,
    options.applyPolicy(policy),
    policy.effectiveCodecOptions()
  )

proc sendNif*(
    client: NifClient;
    httpMethod: RequestMethod;
    path: string;
    source: string;
    headers = initHeaders();
    options = RequestOptions();
    policyName = ""
): Future[JResult[string]] =
  let policy = client.nifPolicies.resolveNifPolicy(
    httpMethod, path, policyName
  )
  client.client.sendNif(
    httpMethod,
    path,
    source,
    headers,
    options.applyPolicy(policy),
    policy.effectiveCodecOptions()
  )

proc sendNif*[TBody, TResponse](
    client: NifClient;
    httpMethod: RequestMethod;
    path: string;
    value: TBody;
    _: typedesc[TResponse];
    headers = initHeaders();
    options = RequestOptions();
    policyName = ""
): Future[JResult[TResponse]] =
  let policy = client.nifPolicies.resolveNifPolicy(
    httpMethod, path, policyName
  )
  client.client.sendNif(
    httpMethod,
    path,
    value,
    TResponse,
    headers,
    options.applyPolicy(policy),
    policy.effectiveCodecOptions()
  )

template definePolicyAwareNifMethod(name, requestMethod: untyped) =
  proc name*(
      client: NifClient;
      path: string;
      source: string;
      headers = initHeaders();
      options = RequestOptions();
      policyName = ""
  ): Future[JResult[string]] =
    client.sendNif(
      requestMethod, path, source, headers, options, policyName
    )

  proc name*[TBody, TResponse](
      client: NifClient;
      path: string;
      value: TBody;
      _: typedesc[TResponse];
      headers = initHeaders();
      options = RequestOptions();
      policyName = ""
  ): Future[JResult[TResponse]] =
    client.sendNif(
      requestMethod,
      path,
      value,
      TResponse,
      headers,
      options,
      policyName
    )

definePolicyAwareNifMethod(postNif, rmPost)
definePolicyAwareNifMethod(putNif, rmPut)
definePolicyAwareNifMethod(patchNif, rmPatch)

func boundedMultipartOptions(
    options: RequestOptions;
    maxMultipartBytes: int
): RequestOptions =
  result = options
  if maxMultipartBytes < 0:
    if result.maxRequestBytes == 0:
      result.maxRequestBytes = -1
  elif result.maxRequestBytes <= 0 or
      maxMultipartBytes < result.maxRequestBytes:
    result.maxRequestBytes = maxMultipartBytes

func metadataCodecOptions(
    codecOptions: NifCodecOptions;
    maxMetadataBytes: int
): NifCodecOptions =
  result = codecOptions
  result.encodeLimits.maxInputBytes = maxMetadataBytes
  result.encodeLimits.maxOutputBytes = maxMetadataBytes

proc sendNifMultipart[TMetadata](
    client: Client;
    httpMethod: RequestMethod;
    path: string;
    metadata: TMetadata;
    file: MultipartPart;
    metadataName: string;
    headers: Headers;
    options: RequestOptions;
    limits: NifMultipartLimits;
    codecOptions: NifCodecOptions
): Future[JResult[Response]] {.async.} =
  if client == nil or client.transport == nil:
    return err[Response](newJoubakoError(
      jeInvalidRequest, "client has no transport", path
    ))
  if metadataName.len == 0 or
      metadataName.contains({'\0', '\r', '\n', '"'}):
    return err[Response](newJoubakoError(
      jeInvalidRequest, "invalid NIF multipart metadata field name", path
    ))
  if file.filePath.len == 0 or file.body.len > 0 or file.filename.len == 0:
    return err[Response](newJoubakoError(
      jeInvalidRequest,
      "NIF multipart upload requires one file-backed part",
      path
    ))
  if limits.maxMetadataBytes == 0 or limits.maxUploadBytes == 0 or
      limits.maxMultipartBytes == 0:
    return err[Response](newJoubakoError(
      jeInvalidRequest,
      "NIF multipart limits must be positive or negative",
      path
    ))
  if limits.requireRuntimeAccounting and
      not client.transport.supportsRuntimeMultipartLimits():
    return err[Response](newJoubakoError(
      jeInvalidRequest,
      "transport cannot enforce multipart limits while streaming",
      path
    ))
  if headers.contains("content-type"):
    return err[Response](newJoubakoError(
      jeInvalidRequest,
      "NIF multipart content type and boundary are generated automatically",
      path
    ))

  let encoded = tryEncodeNifValue(
    metadata,
    codecOptions.metadataCodecOptions(limits.maxMetadataBytes),
    path
  )
  if encoded.isErr:
    return err[Response](encoded.error)
  if limits.maxMetadataBytes >= 0 and
      encoded.value.len > limits.maxMetadataBytes:
    return err[Response](newJoubakoError(
      jeBodyTooLarge, "NIF multipart metadata exceeded its limit", path
    ))

  var uploadPart = file
  uploadPart.maxBytes = limits.maxUploadBytes
  let metadataPart = MultipartPart(
    name: metadataName,
    filename: "metadata.bif",
    contentType: BifMediaType,
    body: encoded.value,
    maxBytes: limits.maxMetadataBytes.int64
  )
  let response = asyncdispatch.await client.requestMultipart(
    httpMethod,
    path,
    @[metadataPart, uploadPart],
    headers,
    options.boundedMultipartOptions(limits.maxMultipartBytes)
  )
  return response

proc postNifMultipart*[TMetadata](
    client: Client;
    path: string;
    metadata: TMetadata;
    file: MultipartPart;
    metadataName = "metadata";
    headers = initHeaders();
    options = RequestOptions();
    limits = defaultNifMultipartLimits();
    codecOptions = defaultNifCodecOptions()
): Future[JResult[Response]] =
  client.sendNifMultipart(
    rmPost,
    path,
    metadata,
    file,
    metadataName,
    headers,
    options,
    limits,
    codecOptions
  )

proc postNifMultipart*[TMetadata, TResponse](
    client: Client;
    path: string;
    metadata: TMetadata;
    file: MultipartPart;
    _: typedesc[TResponse];
    metadataName = "metadata";
    headers = initHeaders();
    options = RequestOptions();
    limits = defaultNifMultipartLimits();
    codecOptions = defaultNifCodecOptions()
): Future[JResult[TResponse]] {.async.} =
  var requestHeaders = headers
  if not requestHeaders.contains("accept"):
    requestHeaders.set("accept", BifMediaType)
  let response = asyncdispatch.await client.sendNifMultipart(
    rmPost,
    path,
    metadata,
    file,
    metadataName,
    requestHeaders,
    options,
    limits,
    codecOptions
  )
  if response.isErr:
    return err[TResponse](response.error)
  return tryDecodeNifValueResponse(
    response.value, TResponse, codecOptions
  )

proc postNifMultipart*[TMetadata](
    client: NifClient;
    path: string;
    metadata: TMetadata;
    file: MultipartPart;
    metadataName = "metadata";
    headers = initHeaders();
    options = RequestOptions();
    policyName = ""
): Future[JResult[Response]] =
  let policy = client.nifPolicies.resolveNifPolicy(
    rmPost, path, policyName
  )
  var effectiveOptions = options
  if effectiveOptions.maxResponseBytes == 0:
    effectiveOptions.maxResponseBytes = policy.maxResponseBytes
  client.client.postNifMultipart(
    path,
    metadata,
    file,
    metadataName,
    headers,
    effectiveOptions,
    policy.multipartLimits,
    policy.effectiveCodecOptions()
  )

proc postNifMultipart*[TMetadata, TResponse](
    client: NifClient;
    path: string;
    metadata: TMetadata;
    file: MultipartPart;
    _: typedesc[TResponse];
    metadataName = "metadata";
    headers = initHeaders();
    options = RequestOptions();
    policyName = ""
): Future[JResult[TResponse]] =
  let policy = client.nifPolicies.resolveNifPolicy(
    rmPost, path, policyName
  )
  var effectiveOptions = options
  if effectiveOptions.maxResponseBytes == 0:
    effectiveOptions.maxResponseBytes = policy.maxResponseBytes
  client.client.postNifMultipart(
    path,
    metadata,
    file,
    TResponse,
    metadataName,
    headers,
    effectiveOptions,
    policy.multipartLimits,
    policy.effectiveCodecOptions()
  )
