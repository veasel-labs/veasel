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

The command form is `v -cc <compiler> -prod ...`. `-prod` enables V's
production optimization profile and turns additional warnings into errors.
The pinned [V build help](https://github.com/vlang/v/blob/ea5156d504c627f3f9f1a5ee6d8c251ddd17abbf/vlib/v/help/build/build.txt)
and [compiler notes](https://github.com/vlang/v/blob/ea5156d504c627f3f9f1a5ee6d8c251ddd17abbf/vlib/v/README.md)
describe optimization and LTO choices as part of that profile, including
`-O3 -flto` for generated C units under 8 MiB and `-O2 -flto` for units at or
above 8 MiB. Clang also uses a bounded inline threshold for large units. Veasel
does not duplicate those choices with extra `-cflags`; V applies them as part
of `-prod`. This keeps compiler defaults owned by the pinned V revision and
avoids changing the profile between a release binary and a benchmark build.

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
  self-build, as shown in V's [PGO build script](https://github.com/vlang/v/blob/ea5156d504c627f3f9f1a5ee6d8c251ddd17abbf/vlib/v/build_pgo.sh),
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

Build the same profile locally with the compiler for the host:

```sh
mkdir -p dist
v run "$VROOT/vlib/db/sqlite/install_thirdparty_sqlite.vsh" # Linux
mkdir -p /tmp/veasel-empty-pkgconfig
PKG_CONFIG_PATH= PKG_CONFIG_LIBDIR=/tmp/veasel-empty-pkgconfig \
  v -cc gcc -prod -o dist/veasel .     # Linux
v -cc clang -prod -o dist/veasel .     # macOS
```

Set `VROOT` to the source directory of the exact V revision in `.v-version`.
The Linux release profile must be built on Ubuntu 22.04 to preserve the
documented glibc baseline. Windows builds use the V SQLite amalgamation too;
see the CI workflow for the GCC object build required by that target.

Write the provenance file so the benchmark can include the same toolchain
details as CI:

```sh
VEASEL_BUILD_CC=gcc VEASEL_BUILD_COMMIT="$(git rev-parse HEAD)" \
  VEASEL_BUILD_FLAGS='PKG_CONFIG_PATH= PKG_CONFIG_LIBDIR=/tmp/veasel-empty-pkgconfig -cc gcc -prod -o dist/veasel .' \
  node scripts/build-manifest.mjs dist/veasel dist/build.json
```

Use `clang` and the matching output path in both the build and manifest command
on macOS.

Windows release builds must use GCC for both the bundled SQLite object and the
Veasel binary unless SQLite is rebuilt with a different compatible toolchain.
Do not compare a development build, TCC build, or a build with custom flags to
the release-profile benchmark.
