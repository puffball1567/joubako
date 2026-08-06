# Releasing Joubako

This checklist is the release contract for maintainers. Run it from a clean
checkout with no tracked changes and with the release dependencies available.

## Prepare

1. Create a release branch from `devel`.
2. Confirm `joubako.nimble` contains the intended Semantic Versioning version.
3. Move the matching section in `CHANGELOG.md` from `Unreleased` to the release
   date in `YYYY-MM-DD` form.
4. Confirm direct dependency minimums and their licenses:
   FlowBrigade, NIFKit, nim-zlib, libcurl, faststreams, and the vendored
   nim-graphql parser.
5. Confirm `nimble.paths`, `nimble.develop`, build products, credentials, keys,
   and machine-specific paths are not tracked. The certificates under
   `tests/testdata/tls` are test-only fixtures and must never be used outside
   the test suite.

## Verify

Use Nim 2.2 or newer and verify both ARC and ORC. Local sibling checkouts may
be registered with `nimble develop`; CI checks out exact dependency releases
independently.

```sh
nimble check
nim check --mm:arc --path:src src/joubako.nim
nim check --mm:orc --path:src src/joubako.nim
nim c --mm:arc --path:src examples/basic.nim
nim c --mm:orc --path:src examples/basic.nim
nimble test
nimble testOrc
nimble testSsl
nimble testSslOrc
nimble fuzz
nimble fuzzOrc
nimble soak
nimble soakOrc
nimble e2e
nimble e2eOrc
nimble benchmark
```

On Linux with Valgrind installed:

```sh
nimble leak
nimble leakOrc
```

Push the release branch and require all GitHub Actions jobs to pass. The matrix
must cover Linux, macOS, and Windows with the oldest supported Nim release and
the current stable release. Both ARC and ORC variants of the Linux SSL, Docker
E2E, and Valgrind jobs must also pass.

## Release

1. Merge the verified release branch into `devel`.
2. Merge `devel` into `main` without rebasing or squashing the verified merge.
3. From `main`, confirm the version and changelog one final time.
4. Create an annotated `vMAJOR.MINOR.PATCH` tag at the release commit.
5. Push `main`, `devel`, and the tag.
6. Publish the package through the Nim package registry workflow.
7. Install the published version in a fresh directory and compile a program
   that imports only `joubako`.

Do not tag a commit whose cross-platform CI is pending or failing. If the tag
must be corrected before publication, delete it locally and remotely only
after confirming that no package release refers to it; published versions are
never replaced.
