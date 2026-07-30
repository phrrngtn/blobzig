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
| **blobodbc** | zig | **Zig ODBC** + C++ | 3 live drivers |
| **blobsketches** | zig | **ctypes** + C shims | 25/26, both SQL suites |
| **blobtemplates** | zig | **ctypes** + C shims | 39/39, both SQL suites |
| **blobhttp** | zig | **ctypes** + C++ core | 35/35, 20/20 core ABI |
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

### blobodbc — done

Was blocked on nanodbc, which does not compile against a current libc++ (it
instantiates `std::basic_string<unsigned char>`; libc++ removed the primary
`std::char_traits<T>` template per P1148R0). Not Zig-specific — the CMake build
survived only on AppleClang's older libc++, so it was a latent problem for that
repo regardless.

Fixed the way the note said it should be: nanodbc is gone, replaced by
`src/odbc.zig` (569 lines) calling the ODBC C API directly. Verified against
three live drivers. The only remaining mentions of nanodbc are comments in
`src/odbc.h` documenting the mapping from its API to ours.

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

### Linux: extensions segfault at process exit after dlclose

**Affects every Zig-built loadable extension in the family on Linux.** Found
2026-07-30 on dc1 (Ubuntu 24.04, glibc 2.39); reproduced with blobsketches and
blobhttp, under SQLite 3.45.1 and 3.53.4 and under Python's `sqlite3`.

Everything *works*. The extension loads, functions register, queries return
correct results. The process then dies with SIGSEGV inside `exit()`:

    #0  0x00007ffff78dbcc0 in ?? ()          <- unmapped
    #1  __run_exit_handlers ... at ./stdlib/exit.c:108

It hides well: `sqlite3` buffers stdout, so the crash discards the output and
reads as "the query returned nothing" rather than as a crash. Only `$?` shows
it, which is why it survived a full day of testing — until a CLI was installed
on dc1.

#### Cause, established by bisection

Reproduced in six lines. A **namespace-scope global with a destructor**,
compiled by `zig c++` into a shared library:

    static std::string g_global = "hello";     // INIT_ARRAY entry, dtor registered
    -> dlopen + dlclose + exit  ==  SIGSEGV

The artifact defines no `__dso_handle`, so `__cxa_atexit` registrations are
anonymous and `dlclose` cannot unregister them. The handler outlives the
mapping.

What it is **not** — each ruled out by experiment:

| hypothesis | verdict |
|---|---|
| blobhttp-specific | no — blobsketches too |
| the static-curl build | no — both build modes |
| the SQLite version | no — 3.45.1 and 3.53.4 alike |
| the host being C vs C++ | no — a C++ loader and a C++-linked sqlite3 CLI both crash |
| function-local statics | no — those initialise lazily, no INIT_ARRAY, no crash |
| defining `__dso_handle` ourselves | does not take; the symbol is not exported and the crash persists |

Host behaviour is the only variable, and we do not control it:

| host | unloads? | result |
|---|---|---|
| SQLite CLI or Python `sqlite3`, Linux | yes, on connection close (4 mappings -> 0) | **SIGSEGV** |
| DuckDB | never unloads | clean |
| anything on macOS | dlclose effectively a no-op | clean |

#### Fix: DF_1_NODELETE

`-Wl,-z,nodelete` through `zig c++` fixes it outright. An extension that
registers callbacks with its host arguably should never be unloadable anyway —
which is precisely why DuckDB refuses to unload extensions.

**Zig 0.16's build API cannot express it.** `Step.Compile` exposes
`link_z_notext`, `relro`, `lazy`, `defs`, `common_page_size`, `max_page_size` —
no `nodelete`, and no raw-linker-arg escape hatch.

So it needs a post-link step, which fits the shape blobzig already has for
`append_metadata`: set `DF_1_NODELETE` in the existing `DT_FLAGS_1` entry. A
pure in-place byte edit — the dynamic section does not grow, since our
artifacts already carry `DT_FLAGS_1` (`Flags: NOW`). Verified end to end:

    bhttp.so         before rc=139   after rc=0
    blobsketches.so  before rc=139   after rc=0
    sqlite3 CLI + patched bhttp:      rc=0, 10 functions
    python sqlite3 + patched bhttp:   rc=0, 10 functions

Proof-of-concept patcher in blobhttp's session scratch; wants porting to a Zig
tool in `blobzig/tools/` and wiring into `addHostExtensions` for ELF targets.
