# Building the Blob Family

The canonical build instructions for every `blob*` repository. Individual repos
link here rather than repeating this, so there is one place to correct.

**One prerequisite: Zig 0.16.0.** No CMake, no Make, no `configure`, no vendored
CI toolchain. Two repos need one extra tool, noted under [Per-repo
exceptions](#per-repo-exceptions).

```sh
brew install zig      # or https://ziglang.org/download/
zig version           # must be 0.16.0
```

## The whole thing

```sh
git clone <repo>
cd <repo>
zig build
```

Dependencies are fetched automatically, pinned by content hash in
`build.zig.zon`. Artifacts land in `zig-out/lib/`:

| file | what it is |
| --- | --- |
| `<name>.duckdb_extension` | DuckDB loadable extension, metadata footer stamped |
| `<name>.so` / `<name>.dylib` | SQLite loadable extension |
| `lib<name>.dylib` / `.so` | the core C ABI, which the Python package loads via ctypes |

A successful build prints **nothing**. That is not a mistake — Zig is quiet on
success, so silence means it worked. Use `zig build --summary all` to see the
step tree, including which steps were cached.

## Common commands

```sh
zig build                       # everything
zig build --summary all         # ...and show the step tree
zig build -Doptimize=ReleaseFast
zig build test                  # Zig unit tests, where a repo has them
zig build test-c                # C-level smoke test, where a repo has one
zig build --list-steps          # what this repo actually offers
```

Test step names differ by repo because they test different things:
`test-c` (blobsketches, blobtemplates, blobqueues, blobgraphs, blobfilters,
blobsolver), `test` (blobjs, blobsolver, blobboxes), `test-core` (blobhttp).
`--list-steps` is authoritative.

## Cross-compilation

```sh
zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseFast
zig build -Dtarget=aarch64-linux-gnu
```

This works for most of the family, and it is one of the main reasons for the
migration. Two repos cannot cross-compile, and say so loudly at build time
rather than producing a broken artifact — see below.

## Verifying an extension actually loads

Building is not verification. An extension can link cleanly and fail at
`dlopen`, which is why `check_undefined` runs as part of every build. To confirm
end to end:

```sh
duckdb -unsigned -c "LOAD './zig-out/lib/<name>.duckdb_extension'; SELECT ...;"
/opt/homebrew/opt/sqlite/bin/sqlite3 :memory: ".load ./zig-out/lib/<name>" "SELECT ...;"
```

`-unsigned` is required: these are locally built and unsigned. macOS's system
`sqlite3` has extension loading **disabled** — use the Homebrew one.

From Python:

```python
import duckdb
con = duckdb.connect(config={"allow_unsigned_extensions": "true"})
```

## Building every repo at once

```sh
blobzig/tools/build_all.sh            # rebuild working checkouts, cold cache
blobzig/tools/build_all.sh --fresh    # clone from scratch, empty global cache
blobzig/tools/build_all.sh --pause    # stop between repos so you can read
```

`--fresh` is the honest "what does a new contributor wait for" number: real
clones plus an empty `--global-cache-dir`, so every dependency is downloaded and
compiled from nothing. Run it before claiming a repo builds — a working tree can
hold artifacts that a clean checkout cannot, which is exactly how blobd2 shipped
unbuildable for a while.

Reference: a cold compile of all twelve is ~146s, nine of them under 11s.
blobtemplates ~20s, blobhttp ~25s and blobboxes ~43s are the outliers, being
where the vendored C and C++ actually gets compiled.

## Per-repo exceptions

Everything below is enforced by the build rather than left to documentation —
each fails loudly with an explanation rather than producing something broken.

| repo | exception |
| --- | --- |
| **blobd2** | Needs the **Go toolchain** on the first build, to produce a 48 MB D2 c-archive (~30s). Later builds reuse it. Cannot cross-compile: the archive is host-only, and Go's cross build silently emits an empty one. |
| **blobsolver** | Linux builds must be **native**. HiGHS's Linux prebuilt is a libstdc++ build and Zig links libc++, so a g++ shim seals it — and that shim cannot be cross-built. See [[SSO Layering — spnego-token, blobsso, blobhttp]] for the family's other C++-boundary case. |
| **blobboxes** | Ships `libpdfium` beside the extension. PDFium is `dlopen`'d rather than linked, so the extension loads without it and only the PDF backend errors. Optional backends: `-Dxlsx`, `-Dxls`, `-Dhtml`, `-Ddocx`, `-Dtext`, all on by default. |
| **blobhttp** | `-Dstatic-curl` links a private libcurl instead of the system one. Regenerating `curl_config.h` on a curl bump needs CMake once, per platform — the only CMake residue in the family, and no contributor needs it to build. |
| **blobembed** | **Not ported.** Still CMake, deferred by decision on packaging burden rather than blocked. |
| **duckdb_spnego_sso** | **Deliberately not ported.** Keeps CMake so it looks like a normal DuckDB community extension. |

## Python packages

Wheels are `py3-none-<platform>`: platform-specific because they carry a native
library, ABI-agnostic because ctypes binds at runtime rather than against the
CPython C API. One wheel per platform, not one per interpreter version.

```sh
zig build -Doptimize=ReleaseFast
uv build --wheel
BLOB_WHEEL_PLATFORM=manylinux_2_17_x86_64 uv build --wheel   # for a cross build
```

Use `uv` throughout, never bare `pip` or `python`. Prebuilt wheels are published
to the dc1 Forgejo registry, which is the default index in `~/.config/uv/uv.toml`.

## When something goes wrong

**`check_undefined` reports unresolved symbols.** The artifact would have failed
at load. Usually a static library or object the linker silently skipped — most
often an archive built for a different target. If the host genuinely resolves
them at load time, add the prefix to `allow_undefined`; each entry is a real
portability caveat, so listing it is the point.

**A symbol you believe is in libc is reported.** It should not be — the checker
probes the target's actual libc by linking against it, rather than consulting a
list. If it is wrong, that is a bug in `check_undefined`, not something to work
around.

**Stale cache after switching targets.** `zig-out/` is not cleared between
targets, so it can hold artifacts from several. `rm -rf zig-out .zig-cache` and
rebuild.

## Related

- [[Zig Build vs CMake — An Honest Assessment]] — what the migration actually
  bought and cost, written to be unflattering where the evidence is
- `blobzig/PLAN.md` — the migration plan and the fat-dependency policy
- `blobzig/MIGRATION.md` — traps hit, so they are not rediscovered
