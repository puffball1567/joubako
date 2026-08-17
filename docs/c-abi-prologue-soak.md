# C ABI and Prologue soak test

This release gate exercises Joubako's compiled C ABI against a real Prologue
0.6.10 HTTP server using JSON. It is separate from the in-process Nim tests:
the client is compiled as C11, linked to the generated Joubako shared library,
and communicates with Prologue over a loopback TCP socket.

Each cycle verifies:

- `GET /api/health` returns JSON and `200`;
- `GET /api/users/1` returns JSON and `200`;
- a valid JSON `POST /api/messages` carries a custom header and returns `201`;
- an invalid message returns a preserved JSON `422` response;
- a missing user returns a preserved JSON `404` response; and
- malformed request JSON is rejected locally before network dispatch.

The runner samples resident memory and open file descriptors for both client
and server after warm-up. A run fails on any request mismatch, process failure,
more than 64 MiB of observed RSS variation, or more than eight descriptors of
variation. The port is selected dynamically so the test does not interfere
with other local services.

Run the complete release gate with:

```sh
nimble soakPrologueCAbi
```

For a short reproduction using the identical build and request path:

```sh
python3 tests/cabi/run_prologue_soak.py \
  --duration-seconds 30 \
  --warmup-seconds 5 \
  --sample-seconds 5
```

## v0.2.3 release result

The ARC release gate ran for exactly three hours across 2026-08-16 and
2026-08-17 and passed:

| Measurement | Result |
| --- | ---: |
| Duration | 10,800 seconds |
| Completed cycles | 508,161 |
| Network requests | 2,540,805 |
| Failures | 0 |
| Monitoring samples | 180 per process |
| Client RSS initial / final / peak | 3,104 / 2,716 / 3,104 KiB |
| Client RSS span | 388 KiB |
| Client FD initial / final / peak | 5 / 5 / 5 |
| Prologue RSS initial / final / peak | 5,980 / 3,080 / 5,980 KiB |
| Prologue RSS span | 2,900 KiB |
| Prologue FD initial / final / peak | 52 / 52 / 52 |

The measured rate was approximately 235.3 requests per second. Both processes
finished with zero descriptor growth. Neither process showed monotonic RSS
growth, and both remained far below the 64 MiB variation limit.
