# Sanitizer support

Joubako runs each sanitizer where its runtime and the Nim toolchain are both
maintainable. Unsupported combinations are replaced by other mandatory gates;
they are not silently treated as successful sanitizer runs.

| Gate | Linux | macOS | Windows | Memory managers |
| --- | --- | --- | --- | --- |
| Full tests and type checks | Required | Required | Required | ARC and ORC |
| AddressSanitizer | Required, leak detection enabled | Required, leak detection disabled | Required with Clang, leak detection disabled | ARC and ORC |
| UndefinedBehaviorSanitizer | Required with Clang | Required with Clang | Excluded: LLVM runtime link incompatibility | ARC and ORC |
| Standalone LeakSanitizer | Required with Clang | Required with Clang | Unsupported runtime | ARC and ORC |
| ThreadSanitizer | Required with Clang | Required with Clang | Unsupported runtime | ARC and ORC |
| Valgrind allocation leak probe | Required | Not applicable | Not applicable | ARC and ORC |

Windows UBSan is excluded because the LLVM runtime has unresolved symbols when
linked with the Windows Nim toolchain. Windows still requires the complete test
matrix, type checks, and Clang ASan for both ARC and ORC. Linux and macOS supply
the UBSan coverage.

macOS and Windows set `ASAN_OPTIONS=detect_leaks=0`. Linux ASan performs its
integrated leak check, while Linux and macOS also run a dedicated standalone
LSan lifecycle executable. Linux additionally runs the broader Valgrind suite.

The TSan executable starts four native threads and repeatedly exercises CBOR,
Protobuf, gRPC framing, and query construction. Shared completion state is
explicitly synchronized so reports identify library races rather than an
intentional race in the test harness.

Sanitizer instrumentation is used only for CI test executables. Release
artifacts and downstream builds do not inherit sanitizer compiler or linker
flags. A sanitizer runtime initialization or link failure is investigated as a
toolchain issue and never counted as a passing product test. A platform is
excluded only when the incompatibility is reproducible and its substitute
coverage is documented here.
