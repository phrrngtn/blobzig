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

---

# The work

## Phase 1 — blobsketches (easiest; do first)

**Fat library: Apache DataSketches 5.2.0 — header-only C++.** Nothing to
compile: it is all `.hpp` (`cpc_sketch.hpp`, `hll.hpp`, `kll_sketch.hpp`,
`req_sketch.hpp`, `tdigest.hpp`, `frequent_items_sketch.hpp`,
`array_of_doubles_sketch.hpp`). This is the *easiest* of the three, not the
hardest — an include path and nothing else.

Sizes: `src/blobsketches_core.cpp` 1055, `duckdb_ext/src/*.c` 1508 (already C),
`sqlite_ext/src/*.c` 768 (already C), `python/bindings.cpp` 533 (nanobind),
`include/blobsketches.h` 311 (the C ABI already exists).

Steps:

1. `git checkout -b zig-port`.
2. `build.zig.zon`: `blobzig` path dep, plus `datasketches` via
   `zig fetch --save git+https://github.com/apache/datasketches-cpp#5.2.0`.
   Vendor `nlohmann/json.hpp` single header into `third_party/nlohmann/` (as
   blobfilters and blobqueues do) — `zig fetch` of a `.zip` fails in this
   environment; use `curl` for single headers.
3. `build.zig`: model on **`blobfilters/build.zig`**. Include paths for each
   DataSketches component (its layout is
   `<component>/include/`, e.g. `cpc/include`, `hll/include`, `kll/include`,
   `req/include`, `tdigest/include`, `fi/include`, `tuple/include`,
   `common/include`) — check the tarball layout and add each. `link_libcpp = true`.
   Shims stay C via `duckdb_module` / `sqlite_module`.
4. Verify: `zig build`, load both extensions, run whatever tests exist
   (`ls test/`). Then `zig build -Dtarget=x86_64-linux-gnu` to confirm
   cross-compilation.
5. Delete `CMakeLists.txt`. Commit.
6. **Then** port `python/bindings.cpp` to ctypes — the C ABI already exists in
   `include/blobsketches.h`, so follow `blobjs/python/blobjs/_native.py`
   exactly. Update `pyproject.toml` to hatchling + `blobzig` dep + editable uv
   source. Run its Python tests. Commit separately.

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

Options for curl, in preference order:

- **(a) Drop cpr, link system libcurl.** `curl` is present on every target that
  matters. Costs cross-compilation (a system library cannot be cross-linked
  without a sysroot) — declare it via `allow_undefined` so the check documents
  it, exactly as blobodbc does for `SQL`. Fastest path to no-CMake.
- **(b) Build curl from source in `build.zig`.** There are community ports
  (`allyourcodebase/curl`, which also needs zlib and an SSL backend). Preserves
  cross-compilation. Verify the port builds on Zig 0.16 before committing to it.
- **(c) Defer** with a `ZIG_PORT_NOTES.md`, as blobsolver and blobembed did.

Do **(a)** unless (b) turns out to be quick. Either way, keep cpr out — it is a
C++ wrapper over a C API, the same category as nanodbc, which had to be removed
from blobodbc when it stopped compiling against a current libc++.

Expect this phase to need a decision. Stopping to ask is correct.

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
