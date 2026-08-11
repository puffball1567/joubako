# Sanitizer support policy

Sanitizers should run only where their runtime, target architecture, and
toolchain combination can be executed and maintained. An unsupported
combination must be replaced by mandatory checks on supported platforms; a
successful compilation alone is not a successful sanitizer run.

## Current CI matrix

| Gate | Linux | macOS | Windows | Memory managers |
| --- | --- | --- | --- | --- |
| Full tests and type checks | Required | Required | Required | ARC and ORC |
| AddressSanitizer | Required, leak detection enabled | Required, leak detection disabled | Required with Clang, leak detection disabled | ARC and ORC |
| UndefinedBehaviorSanitizer | Required with Clang | Required with Clang | Excluded: LLVM runtime link incompatibility | ARC and ORC |
| Standalone LeakSanitizer | Required with Clang | Excluded: CI Apple Clang on arm64 rejects `-fsanitize=leak` | Unsupported runtime | ARC and ORC |
| ThreadSanitizer | Required with Clang | Required with Clang | Unsupported runtime | ARC and ORC |
| Valgrind allocation leak probe | Required | Not applicable | Not applicable | ARC and ORC |

Windows UBSan is excluded because the LLVM runtime has unresolved symbols when
linked with the Windows Nim toolchain. Windows still requires the complete test
matrix, type checks, and Clang ASan for both ARC and ORC. Linux and macOS supply
the UBSan coverage.

macOS and Windows set `ASAN_OPTIONS=detect_leaks=0`. Linux ASan performs its
integrated LSan check and also runs a dedicated standalone LSan lifecycle
executable. Linux additionally runs the broader Valgrind suite. macOS and
Windows compensate with their full ARC/ORC test and type-check matrices plus
ASan memory-safety checks; no leak result is inferred from `detect_leaks=0`.

The standalone LSan gate is deliberately Linux-only. The Apple Clang supplied
by the macOS arm64 CI image rejects `-fsanitize=leak`, so that combination is
not a maintainable product gate. This is a CI image/toolchain constraint, not a
product test failure or a claim that every macOS toolchain lacks LSan. Enabling
another platform requires passing ARC and ORC runtime probes on the actual
target runner; successful compilation alone is insufficient.

The TSan executable starts four native threads and repeatedly exercises CBOR,
Protobuf, gRPC framing, and query construction. Shared completion state is
explicitly synchronized so reports identify library races rather than an
intentional race in the test harness.

Sanitizer instrumentation is used only for CI test executables. Release
artifacts and downstream builds do not inherit sanitizer compiler or linker
flags.

Every sanitizer failure is classified before changing the matrix:

1. a product test or memory-safety failure;
2. an incorrect compiler or linker configuration;
3. a missing or unsupported sanitizer runtime.

Compiler, linker, and runtime placement problems are fixed first. A combination
is excluded only when its incompatibility remains reproducible, and the reason
and substitute coverage are documented here. Runtime initialization or link
failure is never counted as a passing product test. The goal is reproducible,
meaningful detection of memory corruption, undefined behavior, leaks, and data
races rather than maximizing the number of CI entries.
