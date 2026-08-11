# Loopback Network Benchmark

This document records a reproducible reference run of
`benchmarks/network_bench.nim`. It is evidence that the ARC and ORC builds
complete the same real HTTP/2 and gRPC workload; it is not a latency or
throughput guarantee for other hosts.

## Method

`nimble benchmarkNetwork` and `nimble benchmarkNetworkOrc` start the Node.js
HTTP/2 interoperability server on `127.0.0.1`. The release-mode Joubako client
then validates every response while measuring:

- 200 sequential HTTP/2 GETs after warmup;
- 200 HTTP/2 GETs in batches of 32 concurrent streams;
- ten bounded streaming uploads of 1 MiB each;
- 200 identity-encoded unary gRPC echo calls after warmup; and
- 200 gzip-compressed unary gRPC echo calls after warmup.

No public network, Docker daemon, external server, or TLS handshake is part of
the measurement. The upload peer echoes the body, so its figure includes both
the request upload and response validation but reports only request bytes.

## Reference run: 2026-08-10

- Linux 6.8.0, x86-64
- AMD Ryzen 5 5600H, 6 cores / 12 threads
- Nim 2.2.10
- Node.js 23.3.0
- libcurl 7.81.0 with nghttp2 1.43.0

| Workload | ARC | ORC |
| --- | ---: | ---: |
| HTTP/2 sequential GET | 226.3 op/s | 206.4 op/s |
| HTTP/2 multiplexed GET, concurrency 32 | 2,647.5 op/s | 1,727.5 op/s |
| HTTP/2 bounded streaming upload | 1.81 MiB/s | 1.78 MiB/s |
| gRPC unary identity | 221.4 op/s | 216.1 op/s |
| gRPC unary gzip | 220.3 op/s | 211.6 op/s |

On this run, issuing 32 concurrent streams increased completed HTTP/2 request
throughput by 11.7x under ARC and 8.4x under ORC compared with the sequential
workload. This demonstrates working multiplexed progress on the tested stack;
it does not imply the same ratio on a remote network or a different libcurl.

## Reproduce

```sh
JOUBAKO_NETWORK_BENCH_FORMAT=jsonl nimble benchmarkNetwork
JOUBAKO_NETWORK_BENCH_FORMAT=jsonl nimble benchmarkNetworkOrc
```

The iteration count, concurrency, upload count, and upload size can be changed
with the environment variables documented in the README. Keep the environment
and workload unchanged when comparing commits.
