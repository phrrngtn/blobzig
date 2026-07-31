# blobzig

> **Note:** Almost entirely AI-authored (Claude, Anthropic) under close human
> supervision, for research and experimentation.

The shared build layer for the `blob*` extension family. Not an extension
itself — it is what the other twelve repositories depend on to produce theirs.

## What it does

Every blob* repo ships the same three artifacts: a DuckDB loadable extension, a
SQLite loadable extension, and a cdylib exposing the C ABI for Python's ctypes.
Producing those correctly involves more fiddly detail than it sounds, and before
this each repo carried its own copy of it — including twelve copies of the same
Python metadata script.

```zig
const blobzig = @import("blobzig");

const bz = b.dependency("blobzig", .{ .target = target, .optimize = optimize });

const artifacts = blobzig.addHostExtensions(b, bz, .{
    .name = "blobfoo",
    .target = target,
    .optimize = optimize,
    .core = core,                  // cdylib for Python ctypes
    .duckdb_module = duckdb_mod,   // escape hatch when the shim is C/C++
    .sqlite_module = sqlite_mod,
});
```

It also brings the DuckDB C API headers and the SQLite amalgamation headers, so
consumers name neither.

## The tools

Written in Zig and run as build steps, rather than shelled out to another
toolchain:

| tool | what it does |
| --- | --- |
| `append_metadata` | Stamps the footer DuckDB checks before loading. Derives the platform from the **target**, not the host — the Python version it replaced used the host, so every cross-built extension was stamped wrong and refused to load. |
| `check_undefined` | Fails the build when an artifact carries a symbol that would be unresolved at `dlopen`. Turns "works on my machine, dies on yours" into a compile error. |
| `set_nodelete` | Sets `DF_1_NODELETE` on ELF output. Without it, a Linux host that `dlclose`s an extension segfaults at process exit — see `MIGRATION.md` for the six-line reproducer and why `-Wl,-z,nodelete` was not available. |

## Why `check_undefined` earns its place

It has the least obvious value and the most demonstrated. It caught a HiGHS ABI
mismatch in blobsolver that had been shipping silently under CMake: the Linux
prebuilt is a libstdc++ build while Zig links libc++, and nothing before it
noticed.

It originally compared against a hand-curated list of libc symbols, which cost
about 250 entries and six rebuild round-trips in a single evening. It now asks
the **target's actual libc**, by linking a probe against it and letting the
linker adjudicate — exact for cross builds too, which a host-derived list could
never be.

## Python

`blobzig` is also a small pure-Python package: artifact discovery, the
`c_void_p` result convention that stops borrowed pointers leaking into Python,
and the `Error` type the family's packages raise. No native code of its own.

## Building the family

```sh
tools/build_all.sh --fresh     # clone everything and build from nothing
tools/build_all.sh --pause     # stop between repos so you can read the output
```

Run it from a real terminal — Zig's progress meter needs a TTY, and a successful
build is otherwise silent.

## Documentation

- [Building the Blob Family](docs/Building%20the%20Blob%20Family.md) — canonical
  build instructions for every repo; the others link here rather than repeat it
- [blobzig Project](docs/blobzig%20Project.md) — overview
- [Zig Build vs CMake — An Honest Assessment](docs/Zig%20Build%20vs%20CMake%20—%20An%20Honest%20Assessment.md)
  — what the migration bought and cost, written to be unflattering where the
  evidence is
- `PLAN.md` — the migration plan and the fat-dependency policy
- `MIGRATION.md` — traps hit, recorded so they are not rediscovered
