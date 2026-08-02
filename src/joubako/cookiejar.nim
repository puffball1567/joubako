import std/[algorithm, parseutils, strutils, times, uri]

type
  CookieSameSite* = enum
    cssUnspecified,
    cssLax,
    cssStrict,
    cssNone

  Cookie* = object
    name*: string
    value*: string
    domain*: string
    path*: string
    secure*: bool
    httpOnly*: bool
    hostOnly*: bool
    sameSite*: CookieSameSite
    persistent*: bool
    expiresAt*: Time
    creationIndex: int64

  CookieJar* = ref object
    cookies: seq[Cookie]
    nextCreationIndex: int64
    maxCookies*: int
    maxCookiesPerDomain*: int
    maxCookieBytes*: int

func newCookieJar*(
    maxCookies = 3_000;
    maxCookiesPerDomain = 180;
    maxCookieBytes = 4_096
): CookieJar =
  CookieJar(
    maxCookies: maxCookies,
    maxCookiesPerDomain: maxCookiesPerDomain,
    maxCookieBytes: maxCookieBytes
  )

func canonicalHost(url: Uri): string =
  url.hostname.strip(chars = {'.'}).toLowerAscii

func domainMatches(host, domain: string): bool =
  host == domain or
    (host.len > domain.len and host.endsWith("." & domain))

func defaultPath(url: Uri): string =
  let path = url.path
  if path.len == 0 or path[0] != '/':
    return "/"
  let lastSlash = path.rfind('/')
  if lastSlash <= 0: "/" else: path[0 ..< lastSlash]

func pathMatches(requestPath, cookiePath: string): bool =
  if requestPath == cookiePath:
    return true
  if not requestPath.startsWith(cookiePath):
    return false
  cookiePath.endsWith('/') or
    (requestPath.len > cookiePath.len and requestPath[cookiePath.len] == '/')

func validCookieName(name: string): bool =
  if name.len == 0:
    return false
  for character in name:
    if character <= '\x20' or character >= '\x7f' or
        character in {'(', ')', '<', '>', '@', ',', ';', ':', '\\', '"',
                      '/', '[', ']', '?', '=', '{', '}'}:
      return false
  true

func validCookieValue(value: string): bool =
  for character in value:
    if character < '\x21' or character >= '\x7f' or
        character in {'"', ',', ';', '\\'}:
      return false
  true

func looksLikeIpAddress(host: string): bool =
  if ':' in host:
    return true
  if host.len == 0:
    return false
  for character in host:
    if character notin {'0' .. '9', '.'}:
      return false
  true

proc parseCookieDate(value: string; parsed: var Time): bool =
  for format in [
    "ddd, dd MMM yyyy HH:mm:ss 'GMT'",
    "dddd, dd-MMM-yy HH:mm:ss 'GMT'",
    "ddd MMM d HH:mm:ss yyyy"
  ]:
    try:
      parsed = parse(value, format, utc()).toTime
      return true
    except TimeParseError:
      discard

proc removeExpired(jar: CookieJar; now: Time) =
  if jar == nil:
    return
  var retained: seq[Cookie]
  for cookie in jar.cookies:
    if not cookie.persistent or cookie.expiresAt > now:
      retained.add cookie
  jar.cookies = move(retained)

proc removeAt(jar: CookieJar; index: int) =
  jar.cookies.delete(index)

proc oldestIndex(jar: CookieJar; domain = ""): int =
  result = -1
  for index, cookie in jar.cookies:
    if domain.len > 0 and cookie.domain != domain:
      continue
    if result < 0 or
        cookie.creationIndex < jar.cookies[result].creationIndex:
      result = index

proc enforceLimits(jar: CookieJar; domain: string) =
  var domainCount = 0
  for cookie in jar.cookies:
    if cookie.domain == domain:
      inc domainCount
  while jar.maxCookiesPerDomain >= 0 and
      domainCount > jar.maxCookiesPerDomain:
    let index = jar.oldestIndex(domain)
    if index < 0:
      break
    jar.removeAt(index)
    dec domainCount
  while jar.maxCookies >= 0 and jar.cookies.len > jar.maxCookies:
    let index = jar.oldestIndex()
    if index < 0:
      break
    jar.removeAt(index)

proc store*(
    jar: CookieJar;
    requestUrl: string;
    setCookie: string;
    now = getTime()
): bool =
  ## Parses and stores one Set-Cookie field. Invalid or out-of-scope cookies
  ## are ignored and return false.
  if jar == nil or setCookie.len == 0 or
      (jar.maxCookieBytes >= 0 and setCookie.len > jar.maxCookieBytes):
    return false
  let url = parseUri(requestUrl)
  let host = url.canonicalHost
  if host.len == 0:
    return false
  let parts = setCookie.split(';')
  let separator = parts[0].find('=')
  if separator <= 0:
    return false
  let name = parts[0][0 ..< separator].strip
  var value = parts[0][separator + 1 .. ^1].strip
  if value.len >= 2 and value[0] == '"' and value[^1] == '"':
    value = value[1 .. ^2]
  if not name.validCookieName or not value.validCookieValue:
    return false

  var cookie = Cookie(
    name: name,
    value: value,
    domain: host,
    path: url.defaultPath,
    hostOnly: true,
    creationIndex: jar.nextCreationIndex
  )
  inc jar.nextCreationIndex
  var deleteCookie = false
  var sawDomain = false
  var maxAgeSet = false
  for index in 1 ..< parts.len:
    let attribute = parts[index].strip
    let equals = attribute.find('=')
    let attributeName = (if equals < 0: attribute else: attribute[0 ..< equals])
      .strip.toLowerAscii
    let attributeValue =
      if equals < 0: "" else: attribute[equals + 1 .. ^1].strip
    case attributeName
    of "domain":
      let domain = attributeValue.strip(chars = {'.'}).toLowerAscii
      if domain.len == 0 or not host.domainMatches(domain) or
          (host.looksLikeIpAddress and domain != host):
        return false
      cookie.domain = domain
      cookie.hostOnly = false
      sawDomain = true
    of "path":
      if attributeValue.len > 0 and attributeValue[0] == '/':
        cookie.path = attributeValue
    of "secure":
      cookie.secure = true
    of "httponly":
      cookie.httpOnly = true
    of "samesite":
      case attributeValue.toLowerAscii
      of "lax": cookie.sameSite = cssLax
      of "strict": cookie.sameSite = cssStrict
      of "none": cookie.sameSite = cssNone
      else: discard
    of "max-age":
      var seconds: BiggestInt
      if parseBiggestInt(attributeValue, seconds) == attributeValue.len:
        maxAgeSet = true
        cookie.persistent = true
        if seconds <= 0:
          deleteCookie = true
        else:
          deleteCookie = false
          let boundedSeconds = min(
            int64(seconds), high(int64) div 1_000_000_000'i64
          )
          cookie.expiresAt = now + initDuration(seconds = boundedSeconds)
    of "expires":
      if not maxAgeSet:
        var expiresAt: Time
        if attributeValue.parseCookieDate(expiresAt):
          cookie.persistent = true
          cookie.expiresAt = expiresAt
          deleteCookie = expiresAt <= now
    else:
      discard

  if cookie.secure and url.scheme.toLowerAscii != "https":
    return false
  if name.startsWith("__Secure-") and
      (not cookie.secure or url.scheme.toLowerAscii != "https"):
    return false
  if name.startsWith("__Host-") and
      (not cookie.secure or sawDomain or cookie.path != "/" or
       url.scheme.toLowerAscii != "https"):
    return false
  if cookie.sameSite == cssNone and not cookie.secure:
    return false

  jar.removeExpired(now)
  for index in countdown(jar.cookies.high, 0):
    let existing = jar.cookies[index]
    if existing.name == cookie.name and existing.domain == cookie.domain and
        existing.path == cookie.path:
      if deleteCookie:
        jar.removeAt(index)
        return true
      cookie.creationIndex = existing.creationIndex
      jar.cookies[index] = cookie
      return true
  if deleteCookie:
    return true
  jar.cookies.add cookie
  jar.enforceLimits(cookie.domain)
  true

proc cookieHeader*(
    jar: CookieJar;
    requestUrl: string;
    now = getTime()
): string =
  if jar == nil:
    return ""
  jar.removeExpired(now)
  let url = parseUri(requestUrl)
  let host = url.canonicalHost
  let requestPath = if url.path.len == 0: "/" else: url.path
  let secureRequest = url.scheme.toLowerAscii == "https"
  var selected: seq[Cookie]
  for cookie in jar.cookies:
    if (cookie.hostOnly and host != cookie.domain) or
        (not cookie.hostOnly and not host.domainMatches(cookie.domain)) or
        not requestPath.pathMatches(cookie.path) or
        (cookie.secure and not secureRequest):
      continue
    selected.add cookie
  selected.sort(proc(left, right: Cookie): int =
    result = cmp(right.path.len, left.path.len)
    if result == 0:
      result = cmp(left.creationIndex, right.creationIndex)
  )
  for cookie in selected:
    if result.len > 0:
      result.add "; "
    result.add cookie.name & "=" & cookie.value

proc clear*(jar: CookieJar) =
  if jar != nil:
    jar.cookies.setLen(0)

proc len*(jar: CookieJar; now = getTime()): int =
  if jar == nil:
    return 0
  jar.removeExpired(now)
  jar.cookies.len

proc snapshot*(jar: CookieJar; now = getTime()): seq[Cookie] =
  if jar == nil:
    return @[]
  jar.removeExpired(now)
  result = jar.cookies
