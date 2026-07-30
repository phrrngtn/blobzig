# blob* Zig migration — plan for the remaining repos

Self-contained working document. Assume no memory of the sessions that produced
the current state; everything needed is here or in the file references below.

---

## Rules (non-negotiable)

- Each repo gets a local branch **`zig-port`**. Commit per repo.
- **Never push.** Never touch `main` in any repo.
- **Never touch `~/checkouts/blobboxes`** unless explicitly told — another
  session owns that working tree.
- Verify with the repo's own tests *and* by loading both extensions into DuckDB
  and SQLite before committing. "It compiled" is not verification.
- Use `uv run python`, never bare `python3`, never a bash heredoc for Python.
  For text munging prefer the Edit tool or `sed`.

## Current state

Done, all building with `zig build` only, no CMake:

| Repo | Branch | Adapter | Verified by |
|---|---|---|---|
| blobzig | main | the shared layer | 6 consumers |
| blobjs | zig-port | **all Zig** | 120/120 pytest |
| blobfilters | zig-port | C/C++ | 87/87 C tests |
| blobqueues | zig-port | C/C++ | 12/12 C tests |
| blobgraphs | zig-port | C/C++ + C ABI | 156/156 pytest |
| blobd2 | zig-port | C + Go c-archive | renders SVG |
| blobodbc | zig-port | Zig ODBC + C++ | 3 live drivers |
| blobsketches | zig-port | **ctypes, C shims** | 25/26 pytest, both SQL suites |

Deferred with written notes (`ZIG_PORT_NOTES.md` in each): **blobsolver**
(HiGHS), **blobembed** (llama.cpp).

Pure Python, nothing to do: blobapi, blobrange, blobrule4, blobsensors.

Read `blobzig/MIGRATION.md` first — it has the findings, the bugs discovered,
and the three shapes blobzig supports.

## Toolchain

Zig **0.16.0** (`brew install zig`). 0.16 moved a lot of stdlib; things that
bit, with the replacement:

| Gone | Use |
|---|---|
| `std.fs.cwd()` | `std.Io.Dir.cwd()`, and most calls take an `io` first arg |
| `std.process.argsAlloc` | `pub fn main(init: std.process.Init)`, `init.minimal.args.toSlice(arena)` |
| `std.process.getEnvVarOwned` (in build.zig) | `b.graph.environ_map.get(...)` |
| `std.time.nanoTimestamp` | `std.c.clock_gettime`, or `std.Io` clocks |
| `std.Thread.Mutex` | `std.Io.Mutex` (needs an `Io`), or `std.atomic.Value` + CAS |
| `std.once` | plain atomic/CAS lazy init |
| `Compile.addCSourceFiles` | `compile.root_module.addCSourceFiles` |

Also: `callconv(.c)` is lowercase. Doc comments (`///`) are illegal on
statements inside a function body — use `//`.

Community Zig packages generally do **not** work on 0.16 yet
(`allyourcodebase/quickjs-ng` pins the right version but fails to build).
Prefer compiling upstream C sources directly in `build.zig`; it is usually
30–60 lines.

## How a consumer uses blobzig

`blobzig` is the shared build + ctypes layer. It is a **path dependency**
(`.blobzig = .{ .path = "../blobzig" }`) and an editable uv source while the
family is in flux.

```zig
const blobzig = @import("blobzig");

const bz = b.dependency("blobzig", .{ .target = target, .optimize = optimize });

const artifacts = blobzig.addHostExtensions(b, bz, .{
    .name = "blobfoo",
    .target = target,
    .optimize = optimize,
    .core = core,                      // optional: cdylib for Python ctypes
    .duckdb_module = duckdb_mod,       // escape hatch: C/C++ shim
    .sqlite_module = sqlite_mod,
    // .duckdb_root / .sqlite_root instead, when the shim is Zig
    // .duckdb_abi = .cpp               for blobsso only
    // .allow_undefined = &.{"SQL"}     deliberately-unresolved prefixes
});
artifacts.lib.?.installHeader(b.path("include/blobfoo.h"), "blobfoo.h");
```

It provides:

- `bz.module("duckdb")` / `bz.module("sqlite")` — Zig bindings for shims.
- `bz.namedLazyPath("duckdb_capi_include")` / `("sqlite_include")` — include
  paths, for shims still in C/C++.
- The DuckDB metadata footer, stamped for the **target** (not the host).
- The undefined-symbol check on every artifact.
- `blobzig` Python package: `Artifacts`, `returns_string`, `take`, `Error`.

### The escape hatch is the normal path for these three

A repo can drop CMake **before** porting its shims to Zig, by passing
`duckdb_module` / `sqlite_module` — modules you build yourself with C/C++
sources. blobfilters, blobqueues, blobgraphs and blobd2 all do this. For repos
whose fat library is header-only C++ templates, that island is **permanent**,
because Zig's `@cImport` reads C headers, not C++ templates.

## Traps already hit — do not rediscover

1. **Zig runs UBSan on C by default** (Debug/ReleaseSafe); CMake never did.
   Expect latent UB in vendored C to surface. Two real ones found so far:
   utf8proc does pointer arithmetic on NULL (benign, suppressed for that TU with
   `-fno-sanitize=undefined`), and CRoaring's `arena_alloc` misaligns container
   structs (a genuine bug, fixed at source). **Diagnose before suppressing.**
2. **Cross-compiling C with SIMD**: CRoaring's AVX-512 kernels need `evex512`,
   which baseline x86_64 lacks. Runtime dispatch still has to *compile* every
   path. Fix with a macro (`CROARING_COMPILER_SUPPORTS_AVX512=0`), not `-mavx512`.
3. **`brew --prefix X` prints a path whether or not X is installed.** Probe for
   a real header instead — see `blobodbc/build.zig`'s `odbcPrefix`.
4. **Prebuilt/system libraries break cross-compilation silently.** The linker
   ignores an archive of the wrong object format and the build exits 0. The
   undefined-symbol check now catches this; keep it enabled.
5. **`zig fetch --save` corrupts a single-line `.dependencies = .{ ... }`.**
   Write the manifest multi-line first.
6. **Fingerprints**: a new `build.zig.zon` needs the fingerprint Zig prints in
   its error message. Write a placeholder, run `zig build`, copy the suggestion.
7. **Wheels**: copy `hatch_build.py` from blobzig and use
   `[tool.hatch.build.targets.wheel.hooks.custom]`. The tag must be
   `py3-none-<platform>` — ABI-independent, one wheel per platform. Override the
   platform with `BLOB_WHEEL_PLATFORM` for cross-built wheels.
8. **ctypes**: any function returning a pointer you must free needs
   `restype = ctypes.c_void_p`, never `c_char_p` — ctypes converts `c_char_p` to
   `bytes` and discards the pointer, leaking every call. Use
   `blobzig.returns_string`.
9. **`zig-out/lib` is not per-target.** A cross-build leaves its artifacts there
   and the next native build does not clear them, so a plain
   `force-include = {"zig-out/lib" = "<pkg>"}` ships both. Names do not separate
   them either: `lib<name>.so` may be a stale Linux core while `<name>.so` is the
   SQLite extension and is correct on macOS too. blobsketches' `hatch_build.py`
   checks each file's magic number against the platform tag; copy that. **blobjs
   still has the unfiltered force-include** and wants the same fix.

---

# The work

## Phase 1 — blobsketches — **DONE** (2 commits on `zig-port`)

It was the easiest of the three, as expected: DataSketches 5.2.0 is all `.hpp`,
so the fat library was ten include paths (one per component — there is no
umbrella directory, and upstream's own CMake INTERFACE target omits several).
Both shims stayed C via the escape hatch; the C++ island is permanent.

Worth carrying forward from it:

- Three CMakeLists went, not one: `ext/duckdb/` and `ext/sqlite/` each held a
  near-copy of the root file to rebuild what the root build had already
  produced. **blobtemplates and blobhttp: check for an `ext/` before assuming
  one CMakeLists.** Those wheel projects are now plain hatchling packages over
  `zig-out/lib`.
- Four symbols joined blobzig's libc allowlist (`arc4random`, `atexit`, `exp2`,
  `roundf`). Expect one or two more per new consumer; they are ordinary libc,
  not a reason to reach for `allow_undefined`.
- The ctypes port collapsed 533 lines of nanobind into 470 of Python. Its
  `_native.py` is a better model than blobjs' for anything with out-param
  lengths, arrays or row structs — blobjs is all "string in, string out".
- See trap 9 about `zig-out/lib` and wheels; it was found here.

## Phase 2 — blobtemplates

**Fat libraries: inja 3.4.0, jsoncons 1.1.0, dtl 1.21 (all header-only C++) and
ryml 0.11.0 (NOT header-only — rapidyaml compiles, and pulls c4core).**

Sizes: `src/blobtemplates_core.cpp` 928, `duckdb_ext/src/*.c` 662 (C),
`sqlite_ext/src/*.c` 431 (C), `python/bindings.cpp` 249, C ABI header 254.

Same shape as Phase 1, with one extra piece: rapidyaml must be *built*. Fetch
`biojppm/rapidyaml` at v0.11.0 and `biojppm/c4core`, and add their `src/` C++
files to the module. rapidyaml's CMake also generates nothing important, so a
plain source list should work — enumerate `src/**/*.cpp` for both.

If rapidyaml proves awkward, check first whether YAML is load-bearing:
`grep -n "ryml" src/blobtemplates_core.cpp`. If it is one function, consider
whether it earns the dependency, and **ask** rather than dropping it.

Then the ctypes port, as Phase 1 step 6.

## Phase 3 — blobhttp (hardest; expect to stop and report)

**This is not "header-only C++ templates" like the other two.** It has three
distinct problems:

1. **cpr 1.11.2 is FetchContent'd and builds libcurl AND zlib from source via
   CMake.** That is a large CMake subtree, not an include path. This is the real
   blocker and it is nothing like blobsketches.
2. **jsoncons jsonschema + jmespath** — permanent C++ island. JSON Schema
   validation and JMESPath are real specs; do not attempt to reimplement.
3. **Five build systems already in the tree**: `Makefile`, `configure`,
   `cmake/`, `cmake_build/`, `build_sqlite/`, plus vendored `extension-ci-tools/`
   and `duckdb_capi/`. Removing them is most of the value.

Note there is **no `src/`** — the code lives in `duckdb_ext/src/*.cpp` (1449
lines) and `sqlite_ext/src/*.cpp` (835), with shared headers in `include/`
(`http_config.hpp`, `rate_limiter.hpp`, `lru_pool.hpp`, `negotiate_auth.hpp`).
There is no C ABI header — one would have to be designed, as was done for
blobgraphs (see `blobgraphs/include/blobgraphs.h` and `src/c_api.cpp` for the
pattern: opaque handles, JSON strings for structured results).

### Investigated: can we borrow DuckDB's curl? No. (Measured, not assumed.)

DuckDB **does** ship curl — I was wrong to say otherwise, and it is worth
recording exactly why it still does not help:

| Where | Finding |
|---|---|
| `duckdb` CLI and `libduckdb.dylib` | **0** curl symbols. Core uses cpp-httplib + mbedtls, statically. |
| `httpfs.duckdb_extension` | **878 curl symbols DEFINED, 0 undefined, 0 exported** |
| DuckDB C++ API (`_ZN6duckdb`) | 17,649 exported (+2,838 const, 765 vtables) |
| DuckDB's bundled httplib | **1** real exported symbol; the rest are static-init guards |

So curl is statically linked into a **sibling extension** with hidden
visibility. Not dead-code elimination — the symbols are complete, just local.
Extensions do not link against each other and nothing guarantees httpfs is
loaded. (`dentiny/duckdb-curl-filesystem` and `cache_httpfs` are the same
story.)

Corollary: **targeting the C++ extension API does not help here.** It is
perfectly viable — 21k exported `duckdb::` symbols, which is how blobsso works —
but it supplies no HTTP client. The API choice and the transport choice are
orthogonal. Do not switch to the C++ API expecting to gain curl.

### Therefore: drop cpr, use libcurl's C API directly

`cpr` is a C++ wrapper over a C API — the same category as nanodbc, which had to
be removed from blobodbc when it stopped compiling against a current libc++.
The C API underneath is exactly what Zig binds best.

Verified: `@cImport({@cInclude("curl/curl.h")})` plus `-lcurl` works on macOS
(SDK header present; the dylib lives in the dyld shared cache), and
`curl_easy_init` **and `curl_multi_init`** both resolve — `curl_multi` being what
`cpr::MultiPerform` wraps.

The coupling is thinner than it looks. The rate limiting, connection pooling and
auth are **our** code, not cpr's:

    include/rate_limiter.hpp    210 lines
    include/http_config.hpp     318      (references cpr)
    include/lru_pool.hpp         91      (references cpr)
    include/negotiate_auth.hpp   32

Only two of those four touch cpr at all. And the cpr surface used across the
whole repo is 14 constructs, each a direct libcurl mapping:

    Session, MultiPerform, Response, Header, Url, Timeout, VerifySsl,
    Proxies, Body, SslOptions, Parameters, Parameter, Get, ssl

Plan: `linkSystemLibrary("curl")`, declare `allow_undefined = &.{"curl_"}` so
the symbol check documents that the artifact is not self-contained (as blobodbc
does for `SQL`), and replace the 14 constructs with `curl_easy_setopt` /
`curl_multi_*` calls. The cost is cross-compilation, which a system library
cannot provide without a sysroot — acceptable, and honest, because it is
declared rather than discovered.

If cross-compilation later matters for this repo, build curl from source
(`allyourcodebase/curl` + zlib + an SSL backend) — but check it builds on Zig
0.16 first; most community ports do not.

### Considered and NOT chosen: std.http.Client

Worth recording so it is not relitigated from scratch. Zig 0.16 does have a real
HTTP client (`std/http/Client.zig`): connection pool, proxy support, TLS via
`std.crypto.tls`. What it lacks against this repo's needs:

- HTTP/1.1 only — no HTTP/2.
- No Negotiate / NTLM / Digest auth schemes.
- TLS is Zig's own implementation rather than the platform's.
- No multi-interface: concurrent fan-out (`cpr::MultiPerform`) becomes threads.
- 0.16 reworked the whole IO layer, so it is the least-settled part of a very
  fresh release.

Two things make the comparison narrower than it first appears, and both are
worth knowing:

1. **Caching and rate limiting are not curl features either.** They are ours —
   `rate_limiter.hpp` and `lru_pool.hpp`. They survive any transport choice, so
   they are not an argument for or against.
2. **SPNEGO is already self-generated.** `negotiate_auth.hpp` acquires the token
   via GSS-API/SSPI and passes it as a header; nothing depends on
   `CURLAUTH_NEGOTIATE`. So std.http's missing auth schemes are not
   disqualifying, and equally the curl usage is plain enough to swap easily.

Chose libcurl on risk, not capability: proven TLS against the system trust
store, HTTP/2, and a like-for-like swap beneath code that already works. Moving
to std.http is a transport rewrite with new failure modes against production
endpoints — a reasonable experiment on its own, but not to be bundled into a
build-system migration. Revisit once std.http settles.

### What this repo does NOT have, and why that matters

Unlike every other repo in the family, blobhttp has **no core library and no C
ABI**:

    src/          negotiate_auth.cpp     <- one file
    include/      4 headers, all C++     <- http_config, lru_pool,
                                            rate_limiter, negotiate_auth
    duckdb_ext/   1,449 lines of .cpp    <- the actual logic lives here
    sqlite_ext/     835 lines of .cpp    <- and again, duplicated

The only `extern "C"` in the repo is the SQLite entrypoint, and
`python/bindings.cpp` is nanobind over the C++ classes directly. So:

- there is nothing for ctypes to bind to until a C ABI is designed and written,
  as was done for blobgraphs (`include/blobgraphs.h` + `src/c_api.cpp`);
- extracting that core also de-duplicates the two extensions, which currently
  each carry their own copy of the logic.

That is the largest single piece of work in this phase and it is a genuine
refactor, not a build change. Do not conflate it with dropping CMake.

Note also that the C++ island here is permanent regardless of the transport
choice: the extension code uses jsoncons jsonschema and jmespath, which have no
Zig equivalent and are not worth reimplementing.

### Is a Zig layer over libcurl worth it here?

Optional, unlike blobodbc. There, `src/odbc.zig` earned its place because ODBC is
a return-code-and-out-parameter API whose error discipline suits Zig's `defer`
and error unions. libcurl's `curl_easy_setopt` style is perfectly comfortable
from C++, so swapping cpr for libcurl **inline in the existing C++** is a smaller
and equally legitimate option. Decide on the day; do not assume the blobodbc
shape transfers.

### Sequence

1. Build the existing C++ under `zig build` via the escape hatch; delete the
   five build systems (`Makefile`, `configure`, `cmake/`, `cmake_build/`,
   `build_sqlite/`, and the vendored `extension-ci-tools/` and `duckdb_capi/`).
   Verify, commit. **This alone is most of the value.**
2. Replace cpr with libcurl. Verify against real endpoints, commit.
3. Only then: extract a core, design the C ABI, port Python to ctypes. Separate
   commits — and worth confirming it is wanted before starting, since steps 1
   and 2 already deliver the migration's goals for this repo.

---

## Verification checklist (per repo, before committing)

```bash
cd ~/checkouts/<repo>
zig build                                    # must be silent; runs the symbol check
zig build test-c            # if the repo has a C test target
uv run pytest python/tests -q                # if it has Python tests
duckdb -unsigned -c "LOAD './zig-out/lib/<name>.duckdb_extension'; SELECT ...;"
/opt/homebrew/opt/sqlite/bin/sqlite3 :memory: ".load ./zig-out/lib/<name>" "SELECT ...;"
zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseFast   # cross-compile
```

macOS's system `sqlite3` has extension loading disabled — use the brew one.

Cross-compiled artifacts can be tested on **dc1** (`ssh phrrngtn@dc1`,
x86_64 Ubuntu, glibc 2.39, DuckDB v1.5.5 installed):

```bash
scp zig-out/lib/<name>.duckdb_extension phrrngtn@dc1:/tmp/
ssh phrrngtn@dc1 'duckdb -unsigned -c "LOAD '\''/tmp/<name>.duckdb_extension'\''; SELECT ...;"'
```

## After the three phases

1. Restore wheel publishing in `blobfilters` and `blobodbc` CI (removed
   deliberately; it needs their ctypes ports done first — see the note at the
   top of each `.forgejo/workflows/build-and-publish.yml`).
2. Pin `blobzig` to a dc1 git URL instead of a path dependency, once it settles.
3. Rewrite `blobembed/ZIG_PORT_NOTES.md`: it recommends linking a prebuilt
   llama.cpp archive. That is still the right call, but the note predates the
   undefined-symbol check and should say that a prebuilt is only safe *with*
   per-target fetching plus that check — blobd2 demonstrated a prebuilt linking
   "successfully" into a broken artifact.
4. Port `blobgraphs`'s remaining nanobind binding — it is the last one in the
   ported set.
5. `blobsso` — C++ extension API, needs `duckdb_abi = .cpp`. Only 44 lines of
   CMake but a vendored DuckDB; assess separately.
6. `blobboxes` — the repo that started this. PDFium (prebuilt, per-platform
   tarball), xlnt (with a maintained patch), lexbor and libxls (both brew).
   Do **not** start it without checking whether the other session still owns it.
