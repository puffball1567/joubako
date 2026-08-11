## Typed GraphQL document construction and execution over a Joubako Client.
##
## The builder owns safe rendering. status-im/nim-graphql owns executable
## document parsing; Joubako owns HTTP policy, JSON envelopes, and Result
## boundaries.

import std/[asyncdispatch, json, jsonutils, monotimes, options, sets, strutils,
  times]
import pkg/faststreams/inputs
import ./vendor/nim_graphql/graphql/query_parser
import ./vendor/nim_graphql/graphql/common/errors
import ./[client, jsoncodec, result, types]
import ./transports/websocket

const GraphqlTransportWs* = "graphql-transport-ws"

type
  GraphqlOperationKind* = enum
    gokQuery = "query"
    gokMutation = "mutation"
    gokSubscription = "subscription"

  GraphqlValueKind = enum
    gvkVariable, gvkString, gvkInt, gvkFloat, gvkBoolean, gvkNull,
    gvkEnum, gvkList, gvkObject

  GraphqlValue* = object
    case kind: GraphqlValueKind
    of gvkVariable, gvkString, gvkEnum:
      text: string
    of gvkInt:
      intValue: int64
    of gvkFloat:
      floatValue: float64
    of gvkBoolean:
      boolValue: bool
    of gvkList:
      items: seq[GraphqlValue]
    of gvkObject:
      fields: seq[GraphqlArgument]
    of gvkNull:
      discard

  GraphqlArgument* = object
    name: string
    value: GraphqlValue

  GraphqlDirective* = object
    name: string
    arguments: seq[GraphqlArgument]

  GraphqlSelectionKind = enum
    gskField, gskFragmentSpread, gskInlineFragment

  GraphqlSelection* = object
    directives: seq[GraphqlDirective]
    selection: seq[GraphqlSelection]
    case kind: GraphqlSelectionKind
    of gskField:
      fieldName: string
      alias: string
      arguments: seq[GraphqlArgument]
    of gskFragmentSpread:
      fragmentName: string
    of gskInlineFragment:
      typeCondition: string

  GraphqlVariableDefinition* = object
    name: string
    typeRef: string
    hasDefault: bool
    defaultValue: GraphqlValue
    directives: seq[GraphqlDirective]

  GraphqlOperation* = object
    kind: GraphqlOperationKind
    name: string
    variables: seq[GraphqlVariableDefinition]
    directives: seq[GraphqlDirective]
    selection: seq[GraphqlSelection]

  GraphqlFragment* = object
    name: string
    typeCondition: string
    directives: seq[GraphqlDirective]
    selection: seq[GraphqlSelection]

  GraphqlDocument* = object
    rawSource: string
    operations: seq[GraphqlOperation]
    fragments: seq[GraphqlFragment]

  GraphqlLocation* = object
    line*: int
    column*: int

  GraphqlError* = object
    message*: string
    locations*: seq[GraphqlLocation]
    path*: JsonNode
    extensions*: JsonNode

  GraphqlResponse*[T] = object
    data*: Option[T]
    errors*: seq[GraphqlError]
    extensions*: JsonNode

  GraphqlSubscriptionOptions* = object
    ## WebSocket upgrade deadline. A negative value disables it.
    handshakeTimeoutMs*: int
    ## Maximum wait for `connection_ack`. A negative value disables it.
    connectionAckTimeoutMs*: int
    ## Maximum size of one protocol message. A negative value disables it.
    maxMessageBytes*: int
    cancellation*: CancellationToken

  GraphqlSubscription*[T] = ref object
    websocket: WebSocket
    codecOptions: JsonCodecOptions
    cancellation: CancellationToken
    maxMessageBytes: int
    url*: string
    operationId*: string
    completed*: bool

func defaultGraphqlSubscriptionOptions*(): GraphqlSubscriptionOptions =
  GraphqlSubscriptionOptions(
    handshakeTimeoutMs: 30_000,
    connectionAckTimeoutMs: 30_000,
    maxMessageBytes: 16 * 1024 * 1024
  )

proc gqlVariable*(name: string): GraphqlValue =
  GraphqlValue(kind: gvkVariable, text: name)

proc gqlString*(value: string): GraphqlValue =
  GraphqlValue(kind: gvkString, text: value)

proc gqlInt*(value: SomeInteger): GraphqlValue =
  GraphqlValue(kind: gvkInt, intValue: value.int64)

proc gqlFloat*(value: SomeFloat): GraphqlValue =
  GraphqlValue(kind: gvkFloat, floatValue: value.float64)

proc gqlBool*(value: bool): GraphqlValue =
  GraphqlValue(kind: gvkBoolean, boolValue: value)

proc gqlNull*(): GraphqlValue =
  GraphqlValue(kind: gvkNull)

proc gqlEnum*(value: string): GraphqlValue =
  GraphqlValue(kind: gvkEnum, text: value)

proc gqlList*(items: openArray[GraphqlValue]): GraphqlValue =
  GraphqlValue(kind: gvkList, items: @items)

proc gqlArgument*(name: string; value: GraphqlValue): GraphqlArgument =
  GraphqlArgument(name: name, value: value)

proc gqlObject*(fields: openArray[GraphqlArgument]): GraphqlValue =
  GraphqlValue(kind: gvkObject, fields: @fields)

proc gqlDirective*(
    name: string;
    arguments: openArray[GraphqlArgument] = []
): GraphqlDirective =
  GraphqlDirective(name: name, arguments: @arguments)

proc gqlField*(
    name: string;
    alias = "";
    arguments: openArray[GraphqlArgument] = [];
    directives: openArray[GraphqlDirective] = [];
    selection: openArray[GraphqlSelection] = []
): GraphqlSelection =
  GraphqlSelection(
    kind: gskField,
    fieldName: name,
    alias: alias,
    arguments: @arguments,
    directives: @directives,
    selection: @selection
  )

proc gqlFragmentSpread*(
    name: string;
    directives: openArray[GraphqlDirective] = []
): GraphqlSelection =
  GraphqlSelection(
    kind: gskFragmentSpread,
    fragmentName: name,
    directives: @directives
  )

proc gqlInlineFragment*(
    typeCondition = "";
    directives: openArray[GraphqlDirective] = [];
    selection: openArray[GraphqlSelection] = []
): GraphqlSelection =
  GraphqlSelection(
    kind: gskInlineFragment,
    typeCondition: typeCondition,
    directives: @directives,
    selection: @selection
  )

proc gqlVariableDefinition*(
    name, typeRef: string;
    directives: openArray[GraphqlDirective] = []
): GraphqlVariableDefinition =
  GraphqlVariableDefinition(
    name: name,
    typeRef: typeRef,
    directives: @directives
  )

proc gqlVariableDefinition*(
    name, typeRef: string;
    defaultValue: GraphqlValue;
    directives: openArray[GraphqlDirective] = []
): GraphqlVariableDefinition =
  GraphqlVariableDefinition(
    name: name,
    typeRef: typeRef,
    hasDefault: true,
    defaultValue: defaultValue,
    directives: @directives
  )

proc gqlOperation*(
    kind: GraphqlOperationKind;
    name: string;
    variables: openArray[GraphqlVariableDefinition] = [];
    directives: openArray[GraphqlDirective] = [];
    selection: openArray[GraphqlSelection] = []
): GraphqlOperation =
  GraphqlOperation(
    kind: kind,
    name: name,
    variables: @variables,
    directives: @directives,
    selection: @selection
  )

proc gqlFragment*(
    name, typeCondition: string;
    directives: openArray[GraphqlDirective] = [];
    selection: openArray[GraphqlSelection] = []
): GraphqlFragment =
  GraphqlFragment(
    name: name,
    typeCondition: typeCondition,
    directives: @directives,
    selection: @selection
  )

proc gqlDocument*(
    operations: openArray[GraphqlOperation];
    fragments: openArray[GraphqlFragment] = []
): GraphqlDocument =
  GraphqlDocument(operations: @operations, fragments: @fragments)

proc gqlQuery*(
    name: string;
    variables: openArray[GraphqlVariableDefinition] = [];
    directives: openArray[GraphqlDirective] = [];
    selection: openArray[GraphqlSelection] = [];
    fragments: openArray[GraphqlFragment] = []
): GraphqlDocument =
  gqlDocument(
    [gqlOperation(gokQuery, name, variables, directives, selection)],
    fragments
  )

proc gqlMutation*(
    name: string;
    variables: openArray[GraphqlVariableDefinition] = [];
    directives: openArray[GraphqlDirective] = [];
    selection: openArray[GraphqlSelection] = [];
    fragments: openArray[GraphqlFragment] = []
): GraphqlDocument =
  gqlDocument(
    [gqlOperation(gokMutation, name, variables, directives, selection)],
    fragments
  )

proc gqlSubscription*(
    name: string;
    variables: openArray[GraphqlVariableDefinition] = [];
    directives: openArray[GraphqlDirective] = [];
    selection: openArray[GraphqlSelection] = [];
    fragments: openArray[GraphqlFragment] = []
): GraphqlDocument =
  gqlDocument(
    [gqlOperation(gokSubscription, name, variables, directives, selection)],
    fragments
  )

proc gqlSource*(source: string): GraphqlDocument =
  ## Wraps an existing executable document. It is still parsed before dispatch.
  GraphqlDocument(rawSource: source)

func isGraphqlName(value: string): bool =
  if value.len == 0 or not (value[0] in {'A'..'Z', 'a'..'z', '_'}):
    return false
  for character in value:
    if character notin {'A'..'Z', 'a'..'z', '0'..'9', '_'}:
      return false
  true

func isTypeRef(value: string): bool =
  if value.len == 0:
    return false
  for character in value:
    if character notin {'A'..'Z', 'a'..'z', '0'..'9', '_', '[', ']', '!',
        ' ', '\t', '\r', '\n'}:
      return false
  true

proc invalidName(kind, value: string): ref JoubakoError =
  newJoubakoError(
    jeInvalidRequest,
    "invalid GraphQL " & kind & ": " & value
  )

proc renderValue(value: GraphqlValue; output: var string): ref JoubakoError

proc renderArguments(
    arguments: openArray[GraphqlArgument]; output: var string
): ref JoubakoError =
  if arguments.len == 0:
    return
  output.add '('
  for index, argument in arguments:
    if not argument.name.isGraphqlName:
      return invalidName("argument name", argument.name)
    if index > 0:
      output.add ", "
    output.add argument.name
    output.add ": "
    result = argument.value.renderValue(output)
    if result != nil:
      return
  output.add ')'

proc renderValue(value: GraphqlValue; output: var string): ref JoubakoError =
  case value.kind
  of gvkVariable:
    if not value.text.isGraphqlName:
      return invalidName("variable name", value.text)
    output.add '$'
    output.add value.text
  of gvkString:
    output.add $(%value.text)
  of gvkInt:
    output.add $value.intValue
  of gvkFloat:
    output.add $value.floatValue
  of gvkBoolean:
    output.add(if value.boolValue: "true" else: "false")
  of gvkNull:
    output.add "null"
  of gvkEnum:
    if not value.text.isGraphqlName or value.text in ["true", "false", "null"]:
      return invalidName("enum value", value.text)
    output.add value.text
  of gvkList:
    output.add '['
    for index, item in value.items:
      if index > 0:
        output.add ", "
      result = item.renderValue(output)
      if result != nil:
        return
    output.add ']'
  of gvkObject:
    output.add '{'
    for index, field in value.fields:
      if not field.name.isGraphqlName:
        return invalidName("input field name", field.name)
      if index > 0:
        output.add ", "
      output.add field.name
      output.add ": "
      result = field.value.renderValue(output)
      if result != nil:
        return
    output.add '}'

proc renderDirectives(
    directives: openArray[GraphqlDirective]; output: var string
): ref JoubakoError =
  for directive in directives:
    if not directive.name.isGraphqlName:
      return invalidName("directive name", directive.name)
    output.add " @"
    output.add directive.name
    result = directive.arguments.renderArguments(output)
    if result != nil:
      return

proc renderSelections(
    selections: openArray[GraphqlSelection]; output: var string
): ref JoubakoError =
  if selections.len == 0:
    return newJoubakoError(
      jeInvalidRequest, "GraphQL selection set must not be empty"
    )
  output.add " { "
  for index, selection in selections:
    if index > 0:
      output.add ' '
    case selection.kind
    of gskField:
      if not selection.fieldName.isGraphqlName:
        return invalidName("field name", selection.fieldName)
      if selection.alias.len > 0:
        if not selection.alias.isGraphqlName:
          return invalidName("field alias", selection.alias)
        output.add selection.alias
        output.add ": "
      output.add selection.fieldName
      result = selection.arguments.renderArguments(output)
      if result != nil:
        return
    of gskFragmentSpread:
      if not selection.fragmentName.isGraphqlName:
        return invalidName("fragment name", selection.fragmentName)
      output.add "..."
      output.add selection.fragmentName
    of gskInlineFragment:
      output.add "..."
      if selection.typeCondition.len > 0:
        if not selection.typeCondition.isGraphqlName:
          return invalidName("type condition", selection.typeCondition)
        output.add " on "
        output.add selection.typeCondition
    result = selection.directives.renderDirectives(output)
    if result != nil:
      return
    if selection.kind != gskFragmentSpread and selection.selection.len > 0:
      result = selection.selection.renderSelections(output)
      if result != nil:
        return
    elif selection.kind == gskInlineFragment:
      return newJoubakoError(
        jeInvalidRequest, "GraphQL inline fragment must select at least one field"
      )
  output.add " }"

proc renderVariableDefinitions(
    variables: openArray[GraphqlVariableDefinition]; output: var string
): ref JoubakoError =
  if variables.len == 0:
    return
  output.add '('
  for index, variable in variables:
    if not variable.name.isGraphqlName:
      return invalidName("variable name", variable.name)
    if not variable.typeRef.isTypeRef:
      return invalidName("variable type", variable.typeRef)
    if index > 0:
      output.add ", "
    output.add '$'
    output.add variable.name
    output.add ": "
    output.add variable.typeRef
    if variable.hasDefault:
      output.add " = "
      result = variable.defaultValue.renderValue(output)
      if result != nil:
        return
    result = variable.directives.renderDirectives(output)
    if result != nil:
      return
  output.add ')'

proc renderOperation(
    operation: GraphqlOperation; output: var string
): ref JoubakoError =
  output.add $operation.kind
  if operation.name.len > 0:
    if not operation.name.isGraphqlName:
      return invalidName("operation name", operation.name)
    output.add ' '
    output.add operation.name
  result = operation.variables.renderVariableDefinitions(output)
  if result != nil:
    return
  result = operation.directives.renderDirectives(output)
  if result != nil:
    return
  result = operation.selection.renderSelections(output)

proc renderFragment(
    fragment: GraphqlFragment; output: var string
): ref JoubakoError =
  if not fragment.name.isGraphqlName:
    return invalidName("fragment name", fragment.name)
  if fragment.name == "on":
    return invalidName("fragment name", fragment.name)
  if not fragment.typeCondition.isGraphqlName:
    return invalidName("type condition", fragment.typeCondition)
  output.add "fragment "
  output.add fragment.name
  output.add " on "
  output.add fragment.typeCondition
  result = fragment.directives.renderDirectives(output)
  if result != nil:
    return
  result = fragment.selection.renderSelections(output)

proc parseExecutable(source: string): ref JoubakoError =
  try:
    var stream = unsafeMemoryInput(source)
    defer: stream.close()
    var parser = Parser.init(stream)
    var document: QueryDocument
    parser.parseDocument(document)
    if parser.error != errNone:
      return newJoubakoError(
        jeInvalidRequest,
        "invalid GraphQL document: " & $parser.err
      )
  except CatchableError as error:
    return newJoubakoError(
      jeInvalidRequest,
      "could not parse GraphQL document: " & error.msg
    )

proc renderGraphql*(document: GraphqlDocument): JResult[string] =
  var source: string
  if document.rawSource.len > 0:
    source = document.rawSource
  else:
    if document.operations.len == 0:
      return err[string](newJoubakoError(
        jeInvalidRequest, "GraphQL document must contain an operation"
      ))
    var operationNames = initHashSet[string]()
    for index, operation in document.operations:
      if operation.name.len > 0:
        if operation.name in operationNames:
          return err[string](newJoubakoError(
            jeInvalidRequest,
            "duplicate GraphQL operation name: " & operation.name
          ))
        operationNames.incl operation.name
      if index > 0:
        source.add '\n'
      let renderingError = operation.renderOperation(source)
      if renderingError != nil:
        return err[string](renderingError)
    var fragmentNames = initHashSet[string]()
    for fragment in document.fragments:
      if fragment.name in fragmentNames:
        return err[string](newJoubakoError(
          jeInvalidRequest,
          "duplicate GraphQL fragment name: " & fragment.name
        ))
      fragmentNames.incl fragment.name
      source.add '\n'
      let renderingError = fragment.renderFragment(source)
      if renderingError != nil:
        return err[string](renderingError)
  let parsingError = parseExecutable(source)
  if parsingError != nil:
    return err[string](parsingError)
  ok(source)

func hasErrors*[T](response: GraphqlResponse[T]): bool =
  response.errors.len > 0

proc validateSelectedOperation(
    document: GraphqlDocument; operationName, path: string
): ref JoubakoError =
  # Raw documents are syntax checked by nim-graphql and selected by the server.
  # Builder documents contain enough trusted structure for an early semantic
  # check that prevents an avoidable network request.
  if document.rawSource.len > 0:
    return nil
  if document.operations.len > 1 and operationName.len == 0:
    return newJoubakoError(
      jeInvalidRequest,
      "operationName is required for a GraphQL document with multiple operations",
      path
    )
  if operationName.len == 0:
    return nil
  for operation in document.operations:
    if operation.name == operationName:
      return nil
  newJoubakoError(
    jeInvalidRequest,
    "GraphQL operation was not found: " & operationName,
    path
  )

proc decodeGraphqlError(node: JsonNode): GraphqlError =
  if node.kind != JObject or not node.hasKey("message") or
      node["message"].kind != JString:
    raise newException(ValueError, "GraphQL error must contain a string message")
  result.message = node["message"].getStr
  if node.hasKey("locations"):
    if node["locations"].kind != JArray:
      raise newException(ValueError, "GraphQL error locations must be an array")
    for location in node["locations"]:
      if location.kind != JObject or not location.hasKey("line") or
          not location.hasKey("column"):
        raise newException(ValueError, "invalid GraphQL error location")
      result.locations.add GraphqlLocation(
        line: location["line"].getInt,
        column: location["column"].getInt
      )
  if node.hasKey("path"):
    if node["path"].kind != JArray:
      raise newException(ValueError, "GraphQL error path must be an array")
    result.path = node["path"]
  if node.hasKey("extensions"):
    if node["extensions"].kind != JObject:
      raise newException(ValueError, "GraphQL error extensions must be an object")
    result.extensions = node["extensions"]

proc decodeGraphqlPayload[T](
    root: JsonNode;
    codecOptions: JsonCodecOptions
): GraphqlResponse[T] =
  if root.kind != JObject:
    raise newException(ValueError, "GraphQL response must be a JSON object")
  if not root.hasKey("data") and not root.hasKey("errors"):
    raise newException(ValueError, "GraphQL response has neither data nor errors")
  if root.hasKey("data") and root["data"].kind != JNull:
    result.data = some(root["data"].jsonTo(T, codecOptions.decodeOptions))
  if root.hasKey("errors"):
    if root["errors"].kind != JArray or root["errors"].len == 0:
      raise newException(ValueError, "GraphQL errors must be a non-empty array")
    for error in root["errors"]:
      result.errors.add decodeGraphqlError(error)
  if root.hasKey("extensions"):
    if root["extensions"].kind != JObject:
      raise newException(ValueError, "GraphQL extensions must be an object")
    result.extensions = root["extensions"]

proc decodeGraphqlResponse[T](
    response: Response;
    codecOptions: JsonCodecOptions
): GraphqlResponse[T] =
  if response.headers.contains("content-type"):
    let mediaType = response.headers.get("content-type")
      .split(';', maxsplit = 1)[0].strip.toLowerAscii
    if mediaType notin ["application/json", "application/graphql-response+json"]:
      raise newException(ValueError, "unexpected GraphQL response media type")
  decodeGraphqlPayload[T](response.body.parseJson, codecOptions)

proc decodeGraphqlResponseResult[T](
    response: Response;
    codecOptions: JsonCodecOptions
): JResult[GraphqlResponse[T]] =
  try:
    ok(decodeGraphqlResponse[T](response, codecOptions))
  except CatchableError as error:
    let decodingError = newJoubakoError(
      jeCodec,
      "could not decode GraphQL response: " & error.msg,
      response.request.url,
      response.status
    )
    decodingError.attachResponse(response)
    err[GraphqlResponse[T]](decodingError)

proc executeGraphql*[T](
    client: Client;
    path: string;
    document: GraphqlDocument;
    variables: JsonNode = nil;
    operationName = "";
    headers = initHeaders();
    options = RequestOptions();
    codecOptions = defaultJsonCodecOptions()
): Future[JResult[GraphqlResponse[T]]] {.async.} =
  let rendered = document.renderGraphql()
  if rendered.isErr:
    rendered.error.url = path
    return err[GraphqlResponse[T]](rendered.error)
  if operationName.len > 0 and not operationName.isGraphqlName:
    return err[GraphqlResponse[T]](invalidName("operation name", operationName))
  let selectionError = document.validateSelectedOperation(operationName, path)
  if selectionError != nil:
    return err[GraphqlResponse[T]](selectionError)
  if variables != nil and variables.kind != JObject:
    return err[GraphqlResponse[T]](newJoubakoError(
      jeInvalidRequest, "GraphQL variables must be a JSON object", path
    ))

  var payload = newJObject()
  payload["query"] = %rendered.value
  payload["variables"] = if variables == nil: newJObject() else: variables
  if operationName.len > 0:
    payload["operationName"] = %operationName

  var requestHeaders = headers
  if not requestHeaders.contains("content-type"):
    requestHeaders.set("content-type", "application/json")
  if not requestHeaders.contains("accept"):
    requestHeaders.set(
      "accept", "application/graphql-response+json, application/json"
    )
  let response = await client.request(
    rmPost, path, $payload, requestHeaders, options
  )
  if response.isErr:
    return err[GraphqlResponse[T]](response.error)
  return decodeGraphqlResponseResult[T](response.value, codecOptions)

proc executeGraphql*[T](
    client: Client;
    path: string;
    document: GraphqlDocument;
    _: typedesc[T];
    variables: JsonNode = nil;
    operationName = "";
    headers = initHeaders();
    options = RequestOptions();
    codecOptions = defaultJsonCodecOptions()
): Future[JResult[GraphqlResponse[T]]] =
  executeGraphql[T](
    client, path, document, variables, operationName, headers, options,
    codecOptions
  )

proc protocolMessage(message, url: string): JResult[JsonNode] =
  var parsed: JsonNode
  try:
    parsed = message.parseJson
  except CatchableError as error:
    return err[JsonNode](newJoubakoError(
      jeCodec, "invalid GraphQL WebSocket JSON: " & error.msg, url
    ))
  if parsed.kind != JObject or not parsed.hasKey("type") or
      parsed["type"].kind != JString:
    return err[JsonNode](newJoubakoError(
      jeCodec, "GraphQL WebSocket message must contain a string type", url
    ))
  ok(parsed)

func hasValidControlPayload(message: JsonNode): bool =
  not message.hasKey("payload") or
    message["payload"].kind in {JObject, JNull}

proc receiveProtocolMessage(
    websocket: WebSocket;
    url: string;
    maxMessageBytes, timeoutMs: int;
    cancellation: CancellationToken
): Future[JResult[string]] {.async.} =
  let received = settle(
    fallible(websocket.receiveMessage(maxMessageBytes)), jeTransport, url
  )
  if cancellation != nil:
    let cancelled = cancellation.cancellationFuture()
    if timeoutMs >= 0:
      let timer = sleepAsync(timeoutMs)
      await ((received or cancelled) or timer)
    else:
      await (received or cancelled)
    if not received.finished:
      websocket.abort()
      discard await received
      if cancellation.cancelled:
        return err[string](newJoubakoError(
          jeCancelled, cancellation.reason, url
        ))
      return err[string](newJoubakoError(
        jeTimeout, "GraphQL WebSocket acknowledgement timed out", url
      ))
  elif timeoutMs >= 0 and not await received.withTimeout(timeoutMs):
    websocket.abort()
    discard await received
    return err[string](newJoubakoError(
      jeTimeout, "GraphQL WebSocket acknowledgement timed out", url
    ))
  return await received

proc sendProtocolMessage(
    websocket: WebSocket;
    payload: JsonNode;
    maxMessageBytes: int
): Future[JResult[void]] =
  let encoded = $payload
  if maxMessageBytes >= 0 and encoded.len > maxMessageBytes:
    return completedResult(err[void](newJoubakoError(
      jeBodyTooLarge,
      "GraphQL WebSocket message exceeded the configured limit",
      websocket.url
    )))
  settle(fallible(websocket.sendText(encoded)), jeTransport, websocket.url)

proc respondToPing(
    websocket: WebSocket;
    message: JsonNode;
    maxMessageBytes: int
): Future[JResult[void]] =
  var pong = %*{"type": "pong"}
  if message.hasKey("payload"):
    pong["payload"] = message["payload"]
  websocket.sendProtocolMessage(pong, maxMessageBytes)

proc openGraphqlSubscriptionImpl[T](
    url: string;
    source: string;
    variables: JsonNode;
    operationName: string;
    headers: Headers;
    connectionParams, extensions: JsonNode;
    operationId: string;
    options: GraphqlSubscriptionOptions;
    codecOptions: JsonCodecOptions
): Future[JResult[GraphqlSubscription[T]]] {.async.} =
  let connected = await settle(fallible(connectWebSocket(
    url, headers, options.handshakeTimeoutMs, options.cancellation,
    GraphqlTransportWs
  )), jeTransport, url)
  if connected.isErr:
    return err[GraphqlSubscription[T]](connected.error)
  let websocket = connected.value
  var retained = false
  defer:
    if not retained:
      websocket.abort()

  var connectionInit = %*{"type": "connection_init"}
  if connectionParams != nil:
    connectionInit["payload"] = connectionParams
  let initSent = await websocket.sendProtocolMessage(
    connectionInit, options.maxMessageBytes
  )
  if initSent.isErr:
    return err[GraphqlSubscription[T]](initSent.error)

  let acknowledgementStarted = getMonoTime()
  while true:
    let acknowledgementRemaining =
      if options.connectionAckTimeoutMs < 0:
        -1
      else:
        max(0, options.connectionAckTimeoutMs - int(
          (getMonoTime() - acknowledgementStarted).inMilliseconds
        ))
    let received = await websocket.receiveProtocolMessage(
      url, options.maxMessageBytes, acknowledgementRemaining,
      options.cancellation
    )
    if received.isErr:
      return err[GraphqlSubscription[T]](received.error)
    let decoded = protocolMessage(received.value, url)
    if decoded.isErr:
      return err[GraphqlSubscription[T]](decoded.error)
    let message = decoded.value
    case message["type"].getStr
    of "connection_ack":
      if not message.hasValidControlPayload:
        return err[GraphqlSubscription[T]](newJoubakoError(
          jeCodec, "GraphQL connection_ack payload must be an object or null",
          url
        ))
      break
    of "ping":
      if not message.hasValidControlPayload:
        return err[GraphqlSubscription[T]](newJoubakoError(
          jeCodec, "GraphQL ping payload must be an object or null", url
        ))
      let sent = await websocket.respondToPing(message, options.maxMessageBytes)
      if sent.isErr:
        return err[GraphqlSubscription[T]](sent.error)
    of "pong":
      if not message.hasValidControlPayload:
        return err[GraphqlSubscription[T]](newJoubakoError(
          jeCodec, "GraphQL pong payload must be an object or null", url
        ))
    else:
      return err[GraphqlSubscription[T]](newJoubakoError(
        jeTransport,
        "expected connection_ack from GraphQL WebSocket server",
        url
      ))

  var subscribePayload = newJObject()
  subscribePayload["query"] = %source
  subscribePayload["variables"] =
    if variables == nil: newJObject() else: variables
  if operationName.len > 0:
    subscribePayload["operationName"] = %operationName
  if extensions != nil:
    subscribePayload["extensions"] = extensions
  let subscribe = %*{
    "id": operationId,
    "type": "subscribe",
    "payload": subscribePayload
  }
  let subscribed = await websocket.sendProtocolMessage(
    subscribe, options.maxMessageBytes
  )
  if subscribed.isErr:
    return err[GraphqlSubscription[T]](subscribed.error)
  retained = true
  return ok(GraphqlSubscription[T](
    websocket: websocket,
    codecOptions: codecOptions,
    cancellation: options.cancellation,
    maxMessageBytes: options.maxMessageBytes,
    url: url,
    operationId: operationId
  ))

proc openGraphqlSubscription*[T](
    url: string;
    document: GraphqlDocument;
    _: typedesc[T];
    variables: JsonNode = nil;
    operationName = "";
    headers = initHeaders();
    connectionParams: JsonNode = nil;
    extensions: JsonNode = nil;
    operationId = "1";
    options = defaultGraphqlSubscriptionOptions();
    codecOptions = defaultJsonCodecOptions()
): Future[JResult[GraphqlSubscription[T]]] =
  if options.handshakeTimeoutMs < -1 or options.connectionAckTimeoutMs < -1 or
      options.maxMessageBytes < -1:
    return completedResult(err[GraphqlSubscription[T]](newJoubakoError(
      jeInvalidRequest, "GraphQL WebSocket limits must be -1 or greater", url
    )))
  if options.cancellation != nil and options.cancellation.cancelled:
    return completedResult(err[GraphqlSubscription[T]](newJoubakoError(
      jeCancelled, options.cancellation.reason, url
    )))
  if operationId.len == 0 or operationId.contains({'\0', '\r', '\n'}):
    return completedResult(err[GraphqlSubscription[T]](newJoubakoError(
      jeInvalidRequest, "GraphQL WebSocket operation ID is invalid", url
    )))
  if operationName.len > 0 and not operationName.isGraphqlName:
    let nameError = invalidName("operation name", operationName)
    nameError.url = url
    return completedResult(err[GraphqlSubscription[T]](nameError))
  let rendered = document.renderGraphql()
  if rendered.isErr:
    rendered.error.url = url
    return completedResult(err[GraphqlSubscription[T]](rendered.error))
  let selectionError = document.validateSelectedOperation(operationName, url)
  if selectionError != nil:
    return completedResult(err[GraphqlSubscription[T]](selectionError))
  if variables != nil and variables.kind != JObject:
    return completedResult(err[GraphqlSubscription[T]](newJoubakoError(
      jeInvalidRequest, "GraphQL variables must be a JSON object", url
    )))
  if connectionParams != nil and connectionParams.kind != JObject:
    return completedResult(err[GraphqlSubscription[T]](newJoubakoError(
      jeInvalidRequest, "GraphQL connection parameters must be a JSON object", url
    )))
  if extensions != nil and extensions.kind != JObject:
    return completedResult(err[GraphqlSubscription[T]](newJoubakoError(
      jeInvalidRequest, "GraphQL extensions must be a JSON object", url
    )))
  settleResult(fallible(openGraphqlSubscriptionImpl[T](
    url, rendered.value, variables, operationName, headers, connectionParams,
    extensions, operationId, options, codecOptions
  )), jeTransport, url)

proc nextImpl[T](
    subscription: GraphqlSubscription[T]
): Future[JResult[Option[GraphqlResponse[T]]]] {.async.} =
  if subscription.completed:
    return ok(none(GraphqlResponse[T]))
  while true:
    let received = await subscription.websocket.receiveProtocolMessage(
      subscription.url, subscription.maxMessageBytes, -1,
      subscription.cancellation
    )
    if received.isErr:
      subscription.completed = true
      subscription.websocket.abort()
      return err[Option[GraphqlResponse[T]]](received.error)
    let decoded = protocolMessage(received.value, subscription.url)
    if decoded.isErr:
      subscription.completed = true
      subscription.websocket.abort()
      return err[Option[GraphqlResponse[T]]](decoded.error)
    let message = decoded.value
    let messageType = message["type"].getStr
    if messageType == "ping":
      if not message.hasValidControlPayload:
        subscription.completed = true
        subscription.websocket.abort()
        return err[Option[GraphqlResponse[T]]](newJoubakoError(
          jeCodec, "GraphQL ping payload must be an object or null",
          subscription.url
        ))
      let sent = await subscription.websocket.respondToPing(
        message, subscription.maxMessageBytes
      )
      if sent.isErr:
        subscription.completed = true
        subscription.websocket.abort()
        return err[Option[GraphqlResponse[T]]](sent.error)
      continue
    if messageType == "pong":
      if not message.hasValidControlPayload:
        subscription.completed = true
        subscription.websocket.abort()
        return err[Option[GraphqlResponse[T]]](newJoubakoError(
          jeCodec, "GraphQL pong payload must be an object or null",
          subscription.url
        ))
      continue
    if messageType notin ["next", "error", "complete"] or
        not message.hasKey("id") or message["id"].kind != JString:
      subscription.completed = true
      subscription.websocket.abort()
      return err[Option[GraphqlResponse[T]]](newJoubakoError(
        jeCodec, "invalid GraphQL WebSocket operation message", subscription.url
      ))
    if message["id"].getStr != subscription.operationId:
      continue
    case messageType
    of "next":
      if not message.hasKey("payload") or message["payload"].kind != JObject:
        subscription.completed = true
        subscription.websocket.abort()
        return err[Option[GraphqlResponse[T]]](newJoubakoError(
          jeCodec, "GraphQL next message must contain an object payload",
          subscription.url
        ))
      try:
        return ok(some(decodeGraphqlPayload[T](
          message["payload"], subscription.codecOptions
        )))
      except CatchableError as error:
        subscription.completed = true
        subscription.websocket.abort()
        return err[Option[GraphqlResponse[T]]](newJoubakoError(
          jeCodec, "could not decode GraphQL response: " & error.msg,
          subscription.url
        ))
    of "error":
      subscription.completed = true
      if not message.hasKey("payload") or message["payload"].kind != JArray:
        subscription.websocket.abort()
        return err[Option[GraphqlResponse[T]]](newJoubakoError(
          jeCodec, "GraphQL error message must contain an array payload",
          subscription.url
        ))
      var payload = newJObject()
      payload["errors"] = message["payload"]
      try:
        return ok(some(decodeGraphqlPayload[T](
          payload, subscription.codecOptions
        )))
      except CatchableError as error:
        subscription.websocket.abort()
        return err[Option[GraphqlResponse[T]]](newJoubakoError(
          jeCodec, "could not decode GraphQL response: " & error.msg,
          subscription.url
        ))
    of "complete":
      subscription.completed = true
      return ok(none(GraphqlResponse[T]))
    else:
      discard

proc next*[T](
    subscription: GraphqlSubscription[T]
): Future[JResult[Option[GraphqlResponse[T]]]] =
  if subscription == nil:
    return completedResult(err[Option[GraphqlResponse[T]]](newJoubakoError(
      jeInvalidRequest, "GraphQL subscription is nil"
    )))
  settleResult(fallible(subscription.nextImpl()), jeCodec, subscription.url)

proc closeImpl[T](
    subscription: GraphqlSubscription[T]
): Future[JResult[void]] {.async.} =
  if subscription == nil or subscription.websocket == nil:
    return ok()
  var outcome = ok()
  if not subscription.completed and not subscription.websocket.closed:
    outcome = await subscription.websocket.sendProtocolMessage(%*{
      "id": subscription.operationId,
      "type": "complete"
    }, subscription.maxMessageBytes)
  subscription.completed = true
  let closed = await settle(
    fallible(subscription.websocket.close()), jeTransport, subscription.url
  )
  if outcome.isErr:
    return outcome
  closed

proc close*[T](
    subscription: GraphqlSubscription[T]
): Future[JResult[void]] =
  if subscription == nil:
    return completedResult(ok())
  settleResult(fallible(subscription.closeImpl()), jeTransport, subscription.url)
