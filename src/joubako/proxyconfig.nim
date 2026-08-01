import std/[os, strutils, uri]

type ProxyOptions* = object
  httpProxy*: string
  httpsProxy*: string
  allProxy*: string
  noProxy*: seq[string]
  useEnvironment*: bool

func environmentProxyOptions*(): ProxyOptions =
  ProxyOptions(useEnvironment: true)

func effectivePort(url: Uri): string =
  if url.port.len > 0:
    url.port
  elif url.scheme.toLowerAscii == "https":
    "443"
  else:
    "80"

func bypassRuleMatches*(rule: string; target: Uri): bool =
  var normalized = rule.strip.toLowerAscii
  if normalized.len == 0:
    return false
  if normalized == "*":
    return true

  var rulePort = ""
  if normalized[0] == '[':
    let closing = normalized.find(']')
    if closing < 0:
      return false
    if closing + 1 < normalized.len:
      if normalized[closing + 1] != ':':
        return false
      rulePort = normalized[closing + 2 .. ^1]
    normalized = normalized[1 ..< closing]
  elif normalized.count(':') == 1:
    let separator = normalized.rfind(':')
    rulePort = normalized[separator + 1 .. ^1]
    normalized = normalized[0 ..< separator]

  if rulePort.len > 0 and rulePort != target.effectivePort:
    return false
  if normalized.startsWith("*."):
    normalized = normalized[2 .. ^1]
  elif normalized.startsWith('.'):
    normalized = normalized[1 .. ^1]
  let host = target.hostname.strip(chars = {'.'}).toLowerAscii
  host == normalized or
    (host.len > normalized.len and host.endsWith("." & normalized))

func isProxyBypassed*(
    targetUrl: string;
    rules: openArray[string]
): bool =
  let target = parseUri(targetUrl)
  for rule in rules:
    if rule.bypassRuleMatches(target):
      return true

proc environmentValue(lowerName, upperName: string): string =
  result = getEnv(lowerName)
  if result.len > 0:
    return
  # Uppercase HTTP_PROXY is attacker-controlled in CGI environments.
  if upperName == "HTTP_PROXY" and existsEnv("REQUEST_METHOD"):
    return
  result = getEnv(upperName)

proc proxyUrlFor*(options: ProxyOptions; targetUrl: string): string =
  let target = parseUri(targetUrl)
  var bypassRules = options.noProxy
  if bypassRules.len == 0 and options.useEnvironment:
    let configured = environmentValue("no_proxy", "NO_PROXY")
    if configured.len > 0:
      bypassRules = configured.split(',')
  if targetUrl.isProxyBypassed(bypassRules):
    return ""

  let scheme = target.scheme.toLowerAscii
  if scheme == "https" and options.httpsProxy.len > 0:
    return options.httpsProxy
  if scheme == "http" and options.httpProxy.len > 0:
    return options.httpProxy
  if options.allProxy.len > 0:
    return options.allProxy
  if not options.useEnvironment:
    return ""
  if scheme == "https":
    result = environmentValue("https_proxy", "HTTPS_PROXY")
  elif scheme == "http":
    result = environmentValue("http_proxy", "HTTP_PROXY")
  if result.len == 0:
    result = environmentValue("all_proxy", "ALL_PROXY")

proc validateProxyUrl*(proxyUrl: string) =
  if proxyUrl.len == 0:
    return
  let parsed = parseUri(proxyUrl)
  if parsed.scheme.toLowerAscii notin ["http", "socks5", "socks5h"] or
      parsed.hostname.len == 0:
    raise newException(
      ValueError,
      "proxy URL must use http, socks5, or socks5h and include a host"
    )

proc validate*(options: ProxyOptions) =
  options.httpProxy.validateProxyUrl()
  options.httpsProxy.validateProxyUrl()
  options.allProxy.validateProxyUrl()
