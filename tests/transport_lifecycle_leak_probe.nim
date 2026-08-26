import std/asyncdispatch
import joubako

type LifecycleProbeTransport = ref object of Transport
  closed: bool

method close(transport: LifecycleProbeTransport): Future[void] =
  transport.closed = true
  result = newFuture[void]("transport_lifecycle_leak_probe.close")
  result.complete()

for _ in 0 ..< 500:
  let delegate = LifecycleProbeTransport()
  let cached = newCachingTransport(delegate)
  let wrapped = newFaultInjectingTransport(
    cached, newSeq[FaultStep]()
  )
  let client = newClient(wrapped)
  let first = client.close()
  let second = client.close()
  doAssert first == second
  let closed = waitFor first
  doAssert closed.isOk
  doAssert client.isClosed
  doAssert delegate.closed
