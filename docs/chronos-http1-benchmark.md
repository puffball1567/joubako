# Joubako and Chronos HTTP/1.1 Benchmark

This document records controlled HTTP/1.1 client comparisons between Joubako
and Chronos v4.4.0. It measures deliberately narrow workloads; it is not a
claim that either project is universally faster.

The benchmark was added after the v0.2.0 release without changing Joubako's
runtime sources. The measured `v0.2.0` tag and the benchmark branch have no
differences under `src/`.

## Method

Both clients contact the same Node.js HTTP/1.1 server on `127.0.0.1`. Every
request receives status 200 and a 128-byte body. Each client validates both the
status and complete body length before counting the operation.

Each workload uses:

- a release build (`-d:release`);
- Nim 2.2.10;
- ARC and ORC builds;
- 50 unmeasured warmup requests;
- 1,000 measured requests per sample;
- five samples per independent run;
- the median sample from each run; and
- the median of three independent runs as the published result.

ARC and ORC were run in different orders, and the order was reversed between
runs to reduce systematic ordering bias. The server remained the same for all
clients. No public network, DNS lookup, TLS handshake, JSON parsing, retry,
redirect, compression, or application work is included.

The source is checked in as:

- `benchmarks/http1_bench_server.mjs`;
- `benchmarks/joubako_http1_bench.nim`;
- `benchmarks/chronos_http1_bench.nim`; and
- `benchmarks/http1_bench_common.nim`.

## Environment

- Linux 6.8.0, x86-64
- AMD Ryzen 5 5600H, 6 cores / 12 threads
- Nim 2.2.10
- Node.js 23.3.0
- Joubako v0.2.0 (`0897b55c2c2962d597d0b98e064db382ded06ac4`)
- Joubako v0.2.2 (release tag `v0.2.2`)
- Chronos v4.4.0 (`55adad164db35f7f6973177c5b5ff48fcd6b6450`)
- nim-bearssl v0.2.12 (`945ac7beb5f18172c04f253e6210ebe9b0545050`)

## Configuration

Chronos v4.4.0 deliberately disables persistent connections by default. Its
source currently uses the deprecated `Http11Pipeline` flag as the gate for
connection reuse, while noting that pipelining itself is not implemented.
The benchmark therefore reports both the actual default and the explicit
persistent-pool configuration.

Joubako v0.2.0 retains up to eight idle connections by default. Its baseline
benchmark reports that default and a pool sized to the concurrency level of
32. Joubako v0.2.2 raises the default to 32 and additionally retains the legacy
8-connection mode for regression measurements. Chronos uses a maximum of 32
connections in both modes.

## v0.2.2 optimization update

Joubako v0.2.2 increases its default idle pool to 32 and removes avoidable
request copies, empty-header allocations, response-header normalization,
duplicate Content-Length parsing, and common-path orchestration Futures. It
retains request validation, typed Results, response limits, deadlines,
cancellation, and the standard `asyncdispatch` and `AsyncHttpClient` runtime.

The update was measured on the same host described below with 200 warmup
requests and 5,000 measured requests per sample. Each published value is the
median of three independent runs, with five samples per run. Client order was
reversed between runs. Both clients used at most 32 persistent HTTP/1.1
connections and allowed only one active request per connection.

Chronos names the flag that gates persistent reuse `Http11Pipeline`, but
Chronos v4.4.0 marks it deprecated and explicitly states that pipelining is not
implemented. It enables keep-alive reuse for this benchmark; it does not send
multiple simultaneous requests on one connection.

### ARC

| Workload | Joubako v0.2.2 | Chronos v4.4.0 persistent | Joubako difference |
| --- | ---: | ---: | ---: |
| Sequential GET | 8,478.5 op/s | 8,316.2 op/s | +2.0% |
| Concurrent GET (32) | 20,875.0 op/s | 25,498.0 op/s | -18.1% |

### ORC

| Workload | Joubako v0.2.2 | Chronos v4.4.0 persistent | Joubako difference |
| --- | ---: | ---: | ---: |
| Sequential GET | 8,298.5 op/s | 8,057.3 op/s | +3.0% |
| Concurrent GET (32) | 20,557.7 op/s | 24,979.2 op/s | -17.7% |

Joubako wins this sequential loopback workload but does not beat Chronos under
32-request concurrency. Chronos completes about 22% more concurrent ARC
operations and 22% more concurrent ORC operations when expressed relative to
Joubako's throughput.

A Linux syscall diagnostic observed approximately 20,448 `epoll_ctl` calls
for 5,000 Joubako requests and 64 for the equivalent Chronos run. This is an
important lead, not proof that selector behavior explains the entire
throughput difference: the clients also have different HTTP parsers, stream
implementations, Future scheduling, timeout handling, and pool internals. A
fixed-connection raw TCP benchmark is needed to isolate the event loops.

## v0.2.0 baseline results

Higher operations per second are better.

### ARC

| Configuration | Workload | Joubako v0.2.0 | Chronos v4.4.0 |
| --- | --- | ---: | ---: |
| Library default | Sequential GET | 3,591.3 op/s | 2,586.0 op/s |
| Library default | Concurrent GET (32) | 3,932.7 op/s | 4,979.6 op/s |
| Connection reuse | Sequential GET | 3,607.5 op/s | 5,042.8 op/s |
| Connection reuse | Concurrent GET (32) | 6,513.4 op/s | 13,486.9 op/s |

### ORC

| Configuration | Workload | Joubako v0.2.0 | Chronos v4.4.0 |
| --- | --- | ---: | ---: |
| Library default | Sequential GET | 3,631.4 op/s | 2,552.6 op/s |
| Library default | Concurrent GET (32) | 4,011.2 op/s | 4,869.7 op/s |
| Connection reuse | Sequential GET | 3,483.2 op/s | 5,022.6 op/s |
| Connection reuse | Concurrent GET (32) | 6,292.8 op/s | 13,933.7 op/s |

## Interpretation

Under the libraries' actual defaults, Joubako completed about 39% more ARC
sequential requests and 42% more ORC sequential requests than Chronos. Chronos
completed about 27% more ARC and 21% more ORC concurrent requests with the
defaults.

With persistent pools configured, Chronos completed about 1.4 times as many
sequential requests and 2.1 to 2.2 times as many concurrent requests. This is
a clear optimization target for Joubako's high-concurrency connection-pool
scheduling and per-request overhead.

Joubako v0.2.0 had not undergone a dedicated performance-optimization phase.
The result shows competitive ordinary sequential performance while also
quantifying the advantage of Chronos's mature async runtime and connection
management under high connection reuse.

The projects also make different architectural choices. Joubako's default
HTTP/1.1 transport intentionally retains Nim's standard `asyncdispatch`
Future, event loop, and `AsyncHttpClient` interoperability. Chronos supplies a
lower-level runtime optimized around its own networking primitives. Joubako
uses this benchmark to find avoidable overhead in its application-facing
layers and to prevent regressions; it does not treat replacing the standard
runtime or maintaining a private HTTP/1.1 stack as a prerequisite for success.

## Limitations

- This is loopback HTTP/1.1, not remote-network performance.
- It does not compare Joubako's libcurl-backed HTTP/2 transport with Chronos;
  Chronos v4.4.0's tested client is HTTP/1.1.
- It does not measure TLS, large bodies, uploads, streaming, codecs, memory,
  allocations, cancellation, retry, or tail latency.
- Joubako and Chronos operate at different abstraction levels. Joubako applies
  its high-level Result, request validation, response limits, and transport
  boundary; Chronos is an async networking framework with a lower-level HTTP
  client.
- Results describe this host and toolchain. They are not performance promises
  for other systems.

## Reproduce

Start the server:

```sh
node benchmarks/http1_bench_server.mjs
```

Build and run Joubako:

```sh
nim c -d:release -r --mm:arc --path:src benchmarks/joubako_http1_bench.nim
nim c -d:release -r --mm:orc --path:src benchmarks/joubako_http1_bench.nim
```

Clone the exact Chronos and BearSSL releases (BearSSL requires its C-source
submodule):

```sh
git clone --depth 1 --branch v4.4.0 \
  https://github.com/status-im/nim-chronos.git /tmp/chronos-v4.4.0
git clone --recurse-submodules --depth 1 --branch v0.2.12 \
  https://github.com/status-im/nim-bearssl.git /tmp/bearssl-v0.2.12
```

With Chronos's other declared dependencies installed through Nimble, build and
run it with the tagged sources explicitly selected:

```sh
nim c -d:release -r --mm:arc \
  --path:/tmp/chronos-v4.4.0 --path:/tmp/bearssl-v0.2.12 \
  benchmarks/chronos_http1_bench.nim
nim c -d:release -r --mm:orc \
  --path:/tmp/chronos-v4.4.0 --path:/tmp/bearssl-v0.2.12 \
  benchmarks/chronos_http1_bench.nim
```

The workload is configurable through `JOUBAKO_HTTP1_BENCH_ITERATIONS`,
`JOUBAKO_HTTP1_BENCH_CONCURRENCY`, `JOUBAKO_HTTP1_BENCH_SAMPLES`,
`JOUBAKO_HTTP1_BENCH_WARMUP`, and `JOUBAKO_HTTP1_BENCH_URL`. Use
`JOUBAKO_HTTP1_BENCH_WORKLOAD=get|post|all` to select the request type,
`JOUBAKO_HTTP1_BENCH_POOL=legacy|default|matched|all` for Joubako, and
`JOUBAKO_HTTP1_BENCH_CHRONOS_MODE=default|persistent|all` for Chronos.
