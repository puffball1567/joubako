import std/[times, unittest]
import joubako

suite "Cookie jar":
  test "host-only cookies return only to the originating host":
    let jar = newCookieJar()
    check jar.store("https://api.example.test/v1/login", "sid=one")
    check jar.cookieHeader("https://api.example.test/v1/users") == "sid=one"
    check jar.cookieHeader("https://www.example.test/v1/users") == ""

  test "default paths use the containing directory":
    let jar = newCookieJar()
    check jar.store("https://example.test/a/b/login", "sid=one")
    check jar.cookieHeader("https://example.test/a/b/users") == "sid=one"
    check jar.cookieHeader("https://example.test/a/bad") == ""

  test "an explicit path matches only complete path segments":
    let jar = newCookieJar()
    check jar.store("https://example.test/", "sid=one; Path=/docs")
    check jar.cookieHeader("https://example.test/docs") == "sid=one"
    check jar.cookieHeader("https://example.test/docs/page") == "sid=one"
    check jar.cookieHeader("https://example.test/documents") == ""

  test "domain cookies include subdomains but reject unrelated domains":
    let jar = newCookieJar()
    check jar.store(
      "https://api.example.test/", "shared=yes; Domain=example.test"
    )
    check jar.cookieHeader("https://www.example.test/") == "shared=yes"
    check jar.store(
      "https://api.example.test/", "dotted=yes; Domain=.example.test"
    )
    check not jar.store(
      "https://api.example.test/", "bad=yes; Domain=attacker.test"
    )
    check not jar.store(
      "http://127.0.0.1/", "bad=yes; Domain=0.0.1"
    )

  test "secure cookies are neither accepted nor sent over plaintext HTTP":
    let jar = newCookieJar()
    check not jar.store("http://example.test/", "sid=one; Secure")
    check jar.store("https://example.test/", "sid=one; Secure")
    check jar.cookieHeader("http://example.test/") == ""
    check jar.cookieHeader("https://example.test/") == "sid=one"

  test "Max-Age overrides Expires and removes matching cookies":
    let jar = newCookieJar()
    let now = fromUnix(1_000)
    check jar.store("https://example.test/", "sid=one", now)
    check jar.store(
      "https://example.test/",
      "sid=gone; Max-Age=0; Expires=Wed, 01 Jan 2100 00:00:00 GMT",
      now
    )
    check jar.cookieHeader("https://example.test/", now) == ""
    check jar.store(
      "https://example.test/",
      "sid=alive; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Max-Age=10",
      now
    )
    check jar.cookieHeader("https://example.test/", now) == "sid=alive"

  test "expired persistent cookies are evicted lazily":
    let jar = newCookieJar()
    let now = fromUnix(1_000)
    check jar.store("https://example.test/", "sid=one; Max-Age=2", now)
    check jar.len(now + initDuration(seconds = 1)) == 1
    check jar.len(now + initDuration(seconds = 2)) == 0

  test "invalid Expires attributes leave session cookies usable":
    let jar = newCookieJar()
    check jar.store(
      "https://example.test/", "sid=one; Expires=definitely-not-a-date"
    )
    check jar.cookieHeader("https://example.test/") == "sid=one"

  test "replacement retains ordering and updates the value":
    let jar = newCookieJar()
    check jar.store("https://example.test/", "first=1; Path=/")
    check jar.store("https://example.test/", "second=2; Path=/")
    check jar.store("https://example.test/", "first=updated; Path=/")
    check jar.cookieHeader("https://example.test/") ==
      "first=updated; second=2"

  test "deletion matches name domain and path independently":
    let jar = newCookieJar()
    check jar.store("https://example.test/a", "sid=root; Path=/")
    check jar.store("https://example.test/a", "sid=nested; Path=/a")
    check jar.store(
      "https://example.test/a", "sid=gone; Path=/a; Max-Age=0"
    )
    check jar.cookieHeader("https://example.test/a") == "sid=root"

  test "longer paths are emitted before shorter paths":
    let jar = newCookieJar()
    check jar.store("https://example.test/", "root=1; Path=/")
    check jar.store("https://example.test/a/", "nested=2; Path=/a")
    check jar.cookieHeader("https://example.test/a/item") ==
      "nested=2; root=1"

  test "cookie prefixes enforce their transport contracts":
    let jar = newCookieJar()
    check not jar.store("https://example.test/", "__Secure-a=1")
    check jar.store("https://example.test/", "__Secure-a=1; Secure")
    check not jar.store(
      "https://example.test/", "__Host-b=1; Secure; Domain=example.test"
    )
    check not jar.store(
      "https://example.test/", "__Host-b=1; Secure; Path=/nested"
    )
    check jar.store(
      "https://example.test/", "__Host-b=1; Secure; Path=/"
    )

  test "SameSite=None requires Secure":
    let jar = newCookieJar()
    check not jar.store(
      "https://example.test/", "cross=1; SameSite=None"
    )
    check jar.store(
      "https://example.test/", "cross=1; SameSite=None; Secure"
    )

  test "unknown attributes are ignored and empty values are valid":
    let jar = newCookieJar()
    check jar.store(
      "https://example.test/", "empty=; Priority=High; Partitioned"
    )
    check jar.cookieHeader("https://example.test/") == "empty="

  test "invalid names values and oversized fields are rejected":
    let jar = newCookieJar(maxCookieBytes = 12)
    check not jar.store("https://example.test/", "bad name=1")
    check not jar.store("https://example.test/", "name=bad,value")
    check not jar.store("https://example.test/", "name=bad value")
    check not jar.store("https://example.test/", "long=123456789")
    check jar.len == 0

  test "per-domain and global limits evict the oldest cookies":
    let jar = newCookieJar(maxCookies = 2, maxCookiesPerDomain = 1)
    check jar.store("https://a.example/", "old=1")
    check jar.store("https://a.example/", "new=2")
    check jar.cookieHeader("https://a.example/") == "new=2"
    check jar.store("https://b.example/", "b=1")
    check jar.store("https://c.example/", "c=1")
    check jar.len == 2
    check jar.cookieHeader("https://b.example/") == "b=1"
    check jar.cookieHeader("https://c.example/") == "c=1"

  test "clear removes all cookies":
    let jar = newCookieJar()
    check jar.store("https://example.test/", "sid=one")
    jar.clear()
    check jar.len == 0

  test "snapshots expose parsed metadata for explicit persistence":
    let jar = newCookieJar()
    let now = fromUnix(1_000)
    check jar.store(
      "https://api.example.test/a",
      "sid=one; Domain=example.test; Path=/a; Secure; HttpOnly; " &
        "SameSite=Strict; Max-Age=10",
      now
    )
    let cookies = jar.snapshot(now)
    check cookies.len == 1
    check cookies[0].domain == "example.test"
    check cookies[0].path == "/a"
    check cookies[0].secure
    check cookies[0].httpOnly
    check not cookies[0].hostOnly
    check cookies[0].sameSite == cssStrict
    check cookies[0].persistent
