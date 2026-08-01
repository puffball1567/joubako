import std/times
import joubako

const Iterations = 5_000

let jar = newCookieJar(maxCookies = 128, maxCookiesPerDomain = 32)
let now = fromUnix(1_000)
for index in 0 ..< Iterations:
  let host = "https://api" & $(index mod 4) & ".example.test/a/login"
  doAssert jar.store(
    host,
    "session" & $(index mod 40) & "=" & $index &
      "; Domain=example.test; Path=/a; Max-Age=60; HttpOnly",
    now
  )
  discard jar.cookieHeader(
    "https://www.example.test/a/resource", now
  )
  if index mod 17 == 0:
    doAssert jar.store(
      host,
      "session" & $(index mod 40) & "=deleted; Domain=example.test; " &
        "Path=/a; Max-Age=0",
      now
    )

doAssert jar.len(now) <= 32
discard jar.snapshot(now)
jar.clear()
doAssert jar.len(now) == 0

