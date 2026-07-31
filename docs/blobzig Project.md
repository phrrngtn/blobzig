# blobzig Project

The shared build layer for the `blob*` family. Not an extension itself — it is
what the other twelve repositories depend on to produce theirs.

## What it provides

**`addHostExtensions`** — one call that turns a core module into the three
loadable artifacts every blob* repo ships: a DuckDB extension with its metadata
footer stamped, a SQLite extension, and a cdylib exposing the C ABI for ctypes.
Before this, each repo carried its own copy of the same scaffolding, including
twelve copies of a Python metadata script.

**Build tools, written in Zig rather than shelled out to:**

| tool | what it does |
| --- | --- |
| `append_metadata` | stamps the footer DuckDB checks before loading. Derives the platform from the *target*, so cross-built extensions are stamped correctly — the Python version used the host and silently produced unloadable artifacts |
| `check_undefined` | fails the build when an artifact has a symbol that would be unresolved at `dlopen`. Turns "works here, dies on your machine" into a build error |
| `set_nodelete` | sets `DF_1_NODELETE` on ELF output. Without it a Linux host that `dlclose`s an extension segfaults at process exit — see `MIGRATION.md` for the six-line reproducer |

**`blobzig` (Python)** — the shared ctypes plumbing: artifact discovery, the
`c_void_p` result convention that stops borrowed pointers leaking, and the
`Error` type the packages raise.

## Why `check_undefined` earns its place

It is the piece with the least obvious value and the most demonstrated. It
caught a HiGHS ABI mismatch in blobsolver that had been shipping silently under
CMake — the Linux prebuilt is libstdc++ while Zig links libc++, and nothing
before it noticed.

It originally compared against a hand-curated list of libc symbols, which cost
roughly 250 entries and six rebuild round-trips in one evening. It now asks the
**target's actual libc** by linking a probe against it, so the answer is exact
for cross builds too. See [[Zig Build vs CMake — An Honest Assessment]].

## Related

- [[Building the Blob Family]] — the canonical build instructions
- [[Zig Build vs CMake — An Honest Assessment]] — the migration, honestly assessed
- `PLAN.md`, `MIGRATION.md` — the plan, and the traps hit along the way
