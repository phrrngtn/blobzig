# blob* → Zig migration

Status of moving the blob* extension family off CMake and onto `zig build`.
Everything below is on local `zig-port` branches. Nothing has been pushed and no
`main` branch has been touched.

`blobboxes` was excluded throughout — another session owned that working tree.

## Where things stand

| Repo | Build | Adapter | Tests |
|---|---|---|---|
| **blobzig** | — | shared layer | consumed by 6 repos |
| **blobjs** | zig | **all Zig** | 120/120 |
| **blobfilters** | zig | C/C++ | 87/87 |
| **blobqueues** | zig | C/C++ | 12/12 |
| **blobgraphs** | zig | C/C++ | 375 checks |
| **blobd2** | zig | C + Go c-archive | renders SVG, both hosts |
| **blobodbc** | zig, blocked | C++ | see below |
| **blobsketches** | zig | **ctypes** + C shims | 25/26, both SQL suites |
| **blobsolver** | deferred | — | see below |
| **blobembed** | deferred | — | see below |

Every "zig" row was verified by that repo's own test suite *and* by loading both
extensions into DuckDB 1.5.0 and SQLite 3.51.0. Not just "it compiled".

## What blobzig replaces

Per repo, the CMake layer was ~100–190 lines of near-identical boilerplate.
Across the family:

| Duplicated artifact | Copies before |
|---|---|
| `duckdb_ext/append_metadata.py` | **12** (8 byte-identical, 3 byte-identical, 1 variant) |
| `FetchContent(extension-template-c)` for DuckDB headers | 11 |
| nanobind block + `Python COMPONENTS Development.Module` | 11 |
| SQLite amalgamation download | 12 |
| `-undefined dynamic_lookup` + `.so`→`.dylib` symlink | 12 |

A consumer's `build.zig` is now: describe the fat library, describe the adapter,
call `addHostExtensions`. blobjs went 218 → 121 lines; the others are 50–90.

## The three shapes blobzig has to support

These were discovered from real consumers, not designed up front:

1. **Zig adapter + Zig shims** (blobjs) — `duckdb_root` / `sqlite_root`.
2. **C/C++ shims** (blobfilters, blobqueues, blobgraphs, blobd2, blobodbc) — the
   `duckdb_module` / `sqlite_module` escape hatch. This is what lets a repo drop
   CMake *before* porting its shims, which is the only workable order where the
   fat library needs a permanent `extern "C"` island.
3. **No cdylib** (blobgraphs) — a header-only C++ library with no C ABI has
   nothing worth publishing for ctypes, so `core` is optional.

## Findings

### The DuckDB C extension API needs no C at all

`duckdb_extension.h` is 435 macros, 367 of them
`#define duckdb_foo duckdb_ext_api.duckdb_foo`. Those exist only so C written
against `duckdb.h` compiles unchanged; Zig calls through the
`duckdb_ext_api_v1` function-pointer struct directly. The entrypoint macro is
about a dozen lines, hand-written once in `src/duckdb.zig`. SQLite is the same
story with `sqlite3_api_routines` — and because nothing then references a bare
`sqlite3_*` symbol, `-undefined dynamic_lookup` is no longer needed anywhere.

### Wheels are ABI-independent now

The nanobind build produced `cp314-cp314-macosx_…` — one wheel per interpreter.
ctypes over the C ABI produces `py3-none-<platform>`: **ABI tag `none`**. One
wheel serves every CPython. Combined with `-Dtarget=`, every platform's wheel
cross-builds from one machine — verified by building a
`manylinux_2_17_x86_64` wheel on an arm64 Mac and running the full blobjs suite
(117/117 at the time) on x86_64 Linux under CPython 3.12, and again with
blobsketches driving its core, DuckDB extension and SQLite extension there.

One correction to the mechanism: the artifacts cannot be selected by
force-including `zig-out/lib` wholesale. `zig build` leaves each target's output
in place, so after a cross-build the directory holds both, and the names do not
separate them — `libblobsketches.so` may be a stale Linux core while
`blobsketches.so` is the SQLite extension and is correct on macOS too.
blobsketches' `hatch_build.py` checks each file's magic number against the
platform tag. blobjs still has the unfiltered version.

### Four pre-existing bugs, three found by Zig's UB sanitizer on C

CMake never ran UBSan on C. Zig does by default in Debug and ReleaseSafe.

1. **blobjs compile cache — silent wrong answers.** The pointer fast path treated
   "same buffer address + same length" as "same function". DuckDB reuses vector
   storage across queries, so it would apply the *wrong* compiled lambda and
   return a plausible, wrong number. Reproduced deterministically against the old
   CMake binary. Fixed; `python/tests/test_cache.py` fails 2/3 against the old
   build.
2. **blobfilters — misaligned container structs (upstream CRoaring).**
   `roaring_bitmap_portable_deserialize_frozen` allocates its container structs
   from an arena, and CRoaring's `arena_alloc` is a bump allocator with no
   alignment. The allocation order ends with `num_containers` single-byte
   typecodes, so whenever `num_containers % 8 != 0` every container after it is
   misaligned and each field access is UB. Fixed at the point of construction by
   realigning the arena before the container loop
   (`third_party/roaring/roaring.c`, marked "BLOBFILTERS PATCH (alignment)").
   Worth sending upstream. Deserialization stays zero-copy — important, because
   the probe operand varies per row while the reference is cached, so any cost
   there is paid per row of a scan.
3. **utf8proc — NULL pointer arithmetic** in its length-measuring call. Real UB,
   provably harmless, upstream's. Sanitizer disabled for that one translation
   unit.
4. **`append_metadata.py` — cross-compilation bug.** It derived the DuckDB
   platform string from `platform.machine()`, the *host*, so any cross-built
   extension was stamped wrong and would be refused. All twelve copies had it.
   The Zig version takes the platform from the target.

Also: `duckdbPlatform()` enumerates every supported target and panics otherwise.
The Python original ended in a bare `else: windows_amd64`, so an unrecognised
target was silently stamped Windows.

### `brew --prefix` lies

It prints a path whether or not the formula is installed. `brew --prefix highs`
returned `/opt/homebrew/opt/highs` for a package that was never installed. Any
CMake `execute_process(brew --prefix …)` check is therefore unreliable; blobodbc's
`build.zig` probes for an actual header instead.

### Zig 0.16 caveat

0.16 is recent and its stdlib moved a lot (`std.process.argsAlloc`,
`std.time.nanoTimestamp`, `std.fs.Dir`, `std.process.getEnvVarOwned` all gone or
relocated). Community packages have not caught up: `allyourcodebase/quickjs-ng`
pins the right quickjs version but does not compile on 0.16, so blobjs builds the
five upstream C files directly — about 30 lines, and one less upstream to track.
Expect similar for other community build.zig ports.

## Outstanding

### blobodbc — blocked, fix is known

`build.zig` is complete and committed. nanodbc does not compile against a current
libc++ (it instantiates `std::basic_string<unsigned char>`; libc++ removed the
primary `std::char_traits<T>` template per P1148R0 — 15 hard errors, no macro
reinstates it). **This is not Zig-specific**: the CMake build survives only on
AppleClang's older libc++, so it is a latent problem for that repo regardless.
Fix is to drop nanodbc and call the ODBC C API directly — always the plan, since
nanodbc is a convenience wrapper over a C API. ~1,525 lines, wants doing
attentively.

### blobsolver — needs a decision

HiGHS: 161 C++ files, a CMake-*generated* `HConfig.h`, C++-only API, no system
build available. Three options written up in that repo.

### blobembed — needs a decision

llama.cpp: 119 sources, runtime CPU feature dispatch, and Metal shader
compilation on macOS. Unusually, the build is hard while the port is easy —
`llama.h` is `extern "C"`. Recommended: build llama.cpp out-of-band and link the
static archive, exactly as blobd2 links its Go c-archive.

### Cross-cutting

- CI workflows in every repo still invoke CMake.
- `blobzig` is a **path** dependency (`../blobzig`) and an editable uv source
  while the family is in flux. Pin it to a dc1 git URL once it settles.
- blobgraphs' Python binding is still nanobind — it is the one repo with no C
  ABI, so ctypes needs one designed first.
- Nothing pushed anywhere.
