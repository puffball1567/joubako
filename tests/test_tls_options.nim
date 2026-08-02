import std/unittest
import joubako

suite "HTTP TLS options":
  test "peer verification is enabled by default":
    let options = defaultTlsOptions()
    check options.verifyMode == tvmPeer
    let transport = newHttpTransport()
    check transport.tlsOptions.verifyMode == tvmPeer

  test "environment CA lookup is explicit":
    var options = defaultTlsOptions()
    options.verifyMode = tvmPeerUseEnvVars
    let transport = newHttpTransport(tlsOptions = options)
    check transport.tlsOptions.verifyMode == tvmPeerUseEnvVars

  test "verification disabling is explicit and inspectable":
    var options = defaultTlsOptions()
    options.verifyMode = tvmNone
    let transport = newHttpTransport(tlsOptions = options)
    check transport.tlsOptions.verifyMode == tvmNone

  test "custom trust client identity and ciphers are retained":
    let options = TlsOptions(
      verifyMode: tvmPeer,
      caFile: "/certs/ca.pem",
      caDir: "/certs/roots",
      certFile: "/certs/client.pem",
      keyFile: "/certs/client-key.pem",
      cipherList: "ECDHE-RSA-AES128-GCM-SHA256",
      cipherSuites: "TLS_AES_128_GCM_SHA256"
    )
    let transport = newHttpTransport(tlsOptions = options)
    check transport.tlsOptions == options

  test "client certificates require a matching private key":
    expect ValueError:
      discard newHttpTransport(tlsOptions = TlsOptions(
        certFile: "/certs/client.pem"
      ))

  test "private keys require a matching client certificate":
    expect ValueError:
      discard newHttpTransport(tlsOptions = TlsOptions(
        keyFile: "/certs/client-key.pem"
      ))

