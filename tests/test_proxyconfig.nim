import std/[os, unittest, uri]
import joubako

suite "Proxy configuration":
  test "scheme-specific proxies take precedence over the fallback":
    let options = ProxyOptions(
      httpProxy: "http://http-proxy.test:8080",
      httpsProxy: "socks5h://secure-proxy.test:1080",
      allProxy: "http://fallback.test:3128"
    )
    check options.proxyUrlFor("http://example.test/") ==
      "http://http-proxy.test:8080"
    check options.proxyUrlFor("https://example.test/") ==
      "socks5h://secure-proxy.test:1080"

  test "fallback proxies apply when a scheme override is absent":
    let options = ProxyOptions(allProxy: "http://fallback.test:3128")
    check options.proxyUrlFor("https://example.test/") ==
      "http://fallback.test:3128"

  test "NO_PROXY rules match domains only at label boundaries":
    let target = parseUri("https://api.example.test/")
    check bypassRuleMatches("example.test", target)
    check bypassRuleMatches(".example.test", target)
    check bypassRuleMatches("*.example.test", target)
    check not bypassRuleMatches("ample.test", target)

  test "NO_PROXY port restrictions use effective ports":
    let implicit = parseUri("https://example.test/")
    let explicit = parseUri("https://example.test:8443/")
    check bypassRuleMatches("example.test:443", implicit)
    check not bypassRuleMatches("example.test:443", explicit)
    check bypassRuleMatches("example.test:8443", explicit)

  test "wildcards and bracketed IPv6 hosts are supported":
    check "https://anything.test/".isProxyBypassed(["*"])
    check "http://[::1]:8080/".isProxyBypassed(["[::1]:8080"])
    check not "http://[::1]:8081/".isProxyBypassed(["[::1]:8080"])

  test "bypass rules suppress explicit proxy selection":
    let options = ProxyOptions(
      allProxy: "http://proxy.test:3128",
      noProxy: @["internal.test"]
    )
    check options.proxyUrlFor("https://api.internal.test/") == ""

  test "proxy URL validation rejects unsafe or incomplete URLs":
    expect ValueError:
      ProxyOptions(httpProxy: "https://proxy.test").validate()
    expect ValueError:
      ProxyOptions(httpProxy: "http:///missing-host").validate()
    ProxyOptions(httpProxy: "socks5h://proxy.test:1080").validate()

  test "lowercase environment variables are resolved":
    let existed = existsEnv("http_proxy")
    let previous = getEnv("http_proxy")
    defer:
      if existed: putEnv("http_proxy", previous) else: delEnv("http_proxy")
    putEnv("http_proxy", "http://environment.test:8080")
    var options = environmentProxyOptions()
    options.noProxy = @["never.example"]
    check options.proxyUrlFor("http://example.test/") ==
      "http://environment.test:8080"

  test "environment NO_PROXY is applied before proxy selection":
    let existed = existsEnv("no_proxy")
    let previous = getEnv("no_proxy")
    defer:
      if existed: putEnv("no_proxy", previous) else: delEnv("no_proxy")
    putEnv("no_proxy", ".internal.test")
    var options = environmentProxyOptions()
    options.allProxy = "http://proxy.test:3128"
    check options.proxyUrlFor("https://api.internal.test/") == ""
