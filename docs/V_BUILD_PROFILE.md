# V build profile

Veasel release binaries and V-backed runtime benchmarks use one production
profile: the V revision pinned by `.v-version`, `-prod`, and an explicit native
C compiler selected for the target platform. CI records the V source commit,
V version, C compiler/version, target, exact Veasel build arguments, and SHA-256
of the packaged executable in `build.json`. The SQLite runtime benchmark stores
that provenance with its result and records its own compile command.

| Target runner | C compiler | Rationale |
| --- | --- | --- |
| Linux (`ubuntu-22.04`) | `gcc` | Matches V's Linux release build convention and holds the glibc ABI baseline at 2.35 for Debian 12 and newer Linux environments. |
| macOS | `clang` | Matches V's macOS release build convention. |
| Windows | `gcc` | The Windows build links V's bundled SQLite object compiled by GCC; using the same compiler avoids mixing incompatible object formats/toolchains. |

The command form is `v -cc <compiler> -prod ...`. Release builds also pass
`-d "veasel_version=<planned version>"`, which embeds the version calculated by
the release workflow into `--version` and the health endpoint. `-prod` enables
V's production optimization profile and turns additional warnings into errors.
The pinned [V build help](https://github.com/vlang/v/blob/ffc38ada48df34cbf3aa818c3410ce7fcdef5c1f/vlib/v/help/build/build.txt)
and [compiler notes](https://github.com/vlang/v/blob/ffc38ada48df34cbf3aa818c3410ce7fcdef5c1f/vlib/v/README.md)
describe optimization and LTO choices as part of that profile, including
`-O3 -flto` for generated C units under 8 MiB and `-O2 -flto` for units at or
above 8 MiB. Clang also uses a bounded inline threshold for large units. Veasel
does not duplicate those choices with extra `-cflags`; V applies them as part
of `-prod`. This keeps compiler defaults owned by the pinned V revision and
avoids changing the profile between a release binary and a benchmark build.

Historical pin evaluation: on 2026-10-12, V HEAD
`02cf4bd2243e40e1d4bd4ea7b8956dd4832b3fc0` and revision
`9494950d9d6482e70913c70446ccbf8c47f418b7` failed to bootstrap on Windows in
`vlang/setup-v` because `S_IFMT`, `S_IFDIR`, `S_IFREG`, and related CRT
constants were undeclared. Commit `cbe6ea8bbbc30ff7630eac5f507809182bfa027c`
was investigated as a possible compatibility boundary because it is the parent
of V commit `aae3f51f7d298138ea605e67c3fc8fd87f7335da`, which changed C header
emission; it was not established as the root cause. On 2026-10-22, local `v up`
advanced `.v-version` to `ffc38ada48df34cbf3aa818c3410ce7fcdef5c1f` (V 0.5.2).
The exact pin passed Veasel CI on Linux, macOS, and Windows at commit
[`8c3600c`](https://github.com/veasel-labs/veasel/commit/8c3600c68e4b21bad8b9183d61fc10528502aba3)
([workflow run](https://github.com/veasel-labs/veasel/actions/runs/40124234763)).
Repeat the complete release-target matrix whenever `.v-version` changes.

The selected compilers, commands, and toolchain versions are explicit data in
CI artifacts. This makes the build profile auditable even though hosted runner
images and compiler patch versions can change. Benchmark comparisons should
only compare like target, architecture, and compiler profile; reports must
retain each run's build manifest.

Linux and Windows release builds use V's bundled SQLite amalgamation. Linux CI
prepares it with V's `install_thirdparty_sqlite.vsh` script, which verifies the
download size and SHA3 checksum published by SQLite. The build isolates
`pkg-config` discovery so an installed system SQLite development package cannot
silently switch the build back to dynamic SQLite linking. CI runs the Linux
release executable in a Debian 12 container without installing SQLite and
verifies `--version`.

V's runtime is compiled into the Veasel executable; Veasel has no separately
installed V runtime. Linux executables still use the platform's C library, so
the release runner remains pinned to Ubuntu 22.04 (glibc 2.35) to retain
compatibility with Debian 12 and newer glibc distributions.

## Flags deliberately not enabled

- `-gc none` disables collection. Veasel is a long-running process with
  provider requests, sessions, maps, strings, and plugin runtimes; no lifetime
  analysis or end-to-end evidence currently supports removing the collector.
- `-autofree` is not applied globally; the V documentation says the feature is
  not production ready.
- `-prealloc` and related arena behavior are used by V for its own compiler
  self-build, as shown in V's [PGO build script](https://github.com/vlang/v/blob/ffc38ada48df34cbf3aa818c3410ce7fcdef5c1f/vlib/v/build_pgo.sh),
  not recommended as a generic application setting.
- `-compress` is an artifact-size option shown for specialized static
  distributions; Veasel does not yet have a measured static-link profile.
- Custom `-cflags`, `-no-prod-options`, CPU-specific flags, and PGO are not
  enabled. They can change portability or invalidate comparisons and need a
  workload-specific experiment before adoption.

V's own documentation notes a GCC inlining issue for some versions newer than
12 and gives `-fno-inline-small-functions` as a workaround. Veasel currently
does not add that flag because the pinned V build passes on the supported CI
matrix. If a compiler version begins failing, pin or change the affected
toolchain first, then validate any workaround against correctness and runtime
benchmarks before making it part of this profile.

## Benchmark interpretation

The `store_benchmark_test.v` CI result measures SQLite session persistence in
memory under V's production profile. It is a deterministic runtime microbench,
not an agent-quality or end-to-end coding benchmark. Hosted timings are noisy;
use the report for same-runner trend evidence and preserve toolchain metadata.

Set `VROOT` to the source directory for the exact V commit in `.v-version`,
and set `VEASEL_VERSION` to the version you want embedded. Then build the same
profile locally with the compiler for the host:

```sh
: "${VROOT:?Set VROOT to the V source directory pinned in .v-version}"
export PATH="$VROOT:$PATH"
mkdir -p dist
v run "$VROOT/vlib/db/sqlite/install_thirdparty_sqlite.vsh" # Linux
mkdir -p /tmp/veasel-empty-pkgconfig
VEASEL_VERSION="${VEASEL_VERSION:-0.1.0-dev}"
PKG_CONFIG_PATH= PKG_CONFIG_LIBDIR=/tmp/veasel-empty-pkgconfig \
  v -cc gcc -prod -d "veasel_version=$VEASEL_VERSION" -o dist/veasel . # Linux
v -cc clang -prod -d "veasel_version=$VEASEL_VERSION" -o dist/veasel . # macOS
```

The Linux release profile must be built on Ubuntu 22.04 to preserve the
documented glibc baseline. Windows builds use the V SQLite amalgamation too;
see the CI workflow for the GCC object build required by that target.

## Standalone terminal client

CI pins Bun 1.4.2 to build the TypeScript/OpenTUI client as a standalone
`veasel-tui` executable for Linux x64, macOS arm64, and Windows x64. The build
embeds the Bun runtime and client assets; end users do not install Bun. The
binary still uses the operating system's normal C runtime libraries. On Linux,
CI checks that the executable resolves its shared libraries and does not
introduce external ICU or C++ runtime dependencies. `build.json` records the
TUI binary hash, Bun build version, and target alongside backend provenance.

The local Linux build equivalent, after installing the pinned V and Bun
toolchains, is:

```sh
export VEASEL_TUI_VERSION="${VEASEL_VERSION:-0.1.0-dev}"
export VEASEL_TUI_TARGET=bun-linux-x64
export VEASEL_TUI_BUN_VERSION="$(bun --version)"
bun run --cwd tui build:standalone -- "$VEASEL_TUI_TARGET" ../dist/veasel-tui
```

Write the provenance file so the benchmark can include the same toolchain
details as CI:

```sh
export VEASEL_BUILD_CC=gcc
export VEASEL_BUILD_COMMIT="$(git rev-parse HEAD)"
export VEASEL_TUI_TARGET=bun-linux-x64
export VEASEL_TUI_BUN_VERSION="$(bun --version)"
export VEASEL_BUILD_FLAGS='PKG_CONFIG_PATH= PKG_CONFIG_LIBDIR=/tmp/veasel-empty-pkgconfig -cc gcc -prod -d veasel_version=0.1.0-dev -o dist/veasel .'
node scripts/build-manifest.mjs dist/veasel dist/veasel-tui dist/build.json
```

Use `clang` and the matching output path in both the build and manifest command
on macOS.

Windows release builds must use GCC for both the bundled SQLite object and the
Veasel binary unless SQLite is rebuilt with a different compatible toolchain.
Do not compare a development build, TCC build, or a build with custom flags to
the release-profile benchmark.
