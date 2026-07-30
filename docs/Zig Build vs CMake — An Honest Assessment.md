# Zig Build vs CMake — An Honest Assessment

Written mid-migration, after porting blobsketches, blobtemplates, blobhttp,
blobodbc, blobjs, blobfilters, blobqueues, blobgraphs, blobd2, blobsolver and
the core of blobboxes from CMake to `zig build`. The point of this note is to
record what actually happened rather than what the migration was supposed to
achieve, because the honest answer is more useful later than a favourable one.

**Summary judgement: worth doing, but not for the reason usually given.** It is
not meaningfully simpler or smaller. It is better in *kind* — integrity,
cross-compilation, and catching load-time failures at build time — and it
introduced one genuinely annoying new failure mode that we should engineer away.

## The size claim does not survive contact

blobboxes, the largest CMakeLists in the family, measured after the core port:

| | total lines | comments/blank | substance |
| --- | ---: | ---: | ---: |
| `CMakeLists.txt` | 317 | 75 | **242** |
| `build.zig` + `build.zig.zon` | 395 | 156 | **239** |

Dead even. Anyone claiming a large reduction in build-system size from this kind
of migration should be asked to show the comment-adjusted numbers.

## Genuine strengths

### Dependencies are content-addressed

`FetchContent` pinned git tags. A tag is mutable: a retagged upstream silently
changes the build, and nothing detects it. `build.zig.zon` carries a hash per
dependency and refuses to proceed on a mismatch. This is the single most
valuable difference and it is invisible until the day it matters.

### `check_undefined` catches what CMake could not

blobzig runs an undefined-symbol check over every artifact before install. It
turns "links cleanly, dies at `dlopen` on someone else's machine" into a build
error.

This is not hypothetical. blobsolver's CMake build had HiGHS linked as a shared
library and never noticed that the prebuilt Linux archive is **libstdc++** while
Zig links **libc++** — 1580 `__cxx11` symbols in `libhighs.a` versus none on
macOS. The check surfaced it immediately. See [[blobsolver ZIG_PORT_NOTES]].

### Cross-compilation is a flag, not a project

`zig build -Dtarget=x86_64-linux-gnu` works for anything that does not need a
platform-specific external toolchain. Under CMake this was a sysroot expedition.

Caveat, so this is not oversold: it stops working the moment a dependency ships
a prebuilt built against a runtime Zig does not carry. blobsolver's Linux build
must be native, because Zig ships libc++ for every target and libstdc++ for
none.

### One language, with types and functions

`build.zig` is Zig. Dependencies are values, helpers are functions, and a typo
is a compile error. CMake is a string-macro language where a misspelled variable
is the empty string and the build silently does something else. The `-lstdc++`
that silently linked nothing during the blobsolver port is the kind of failure
CMake produces constantly and Zig produces occasionally.

### No `find_package`, no shelling out to brew

PDFium needed a CMake config module; lexbor and libxls were `execute_process`
calls to `brew --prefix`. Under Zig these are fetched dependencies or vendored
sources. Fewer things that work on the author's laptop and nowhere else.

## Genuine weaknesses

### The libc allowlist is the real tax

`check_undefined` compares against `tools/libc_symbols.txt`, a **hand-curated
list**. Anything legitimately provided by libc but missing from the list fails
the build.

In a single session this cost four separate round trips and roughly a hundred
added symbols — `atof`, `dlerror`, `memset_pattern16`, then the glibc LFS
aliases, then the `*at` family, then most of stdio and `<time.h>`. Each round
trip is a full rebuild, and on Linux a cross-machine one.

CMake never had this problem, because CMake never made the check. **This is a
design flaw in blobzig, not in Zig**: the checker should resolve against Zig's
own libc for the target rather than against a list a human maintains. Until it
does, every new repo pays an initialisation tax in rebuild cycles.

It has a second, quieter cost: the list is flat, so a Darwin-only symbol like
`memset_pattern16` is accepted on Linux too. The check is slightly weaker than
it appears.

### Generated headers become committed headers

Three so far: blobhttp's `curl_config.h`, blobboxes' `miniz_export.h`, and
blobboxes' `xlnt_cmake_export.h`. Each was produced by CMake at configure time
and is now hand-authored and committed.

This follows the project's own generate-once-and-commit rule and is defensible,
but be clear about the trade: a generated file cannot drift from its generator,
and a committed one can. Each is a small ongoing liability whose only mitigation
is a comment explaining how to regenerate it.

There is a discovery cost too. Auditing xlnt for generated headers by grepping
`configure_file` returned nothing relevant, and the conclusion "xlnt has no
generated headers" was recorded and was **wrong** — CMake also generates through
`generate_export_header`, a separate command. The error surfaced as 72
compilation failures. When surveying a CMake project for what it generates,
grep for both.

### "Enumerate, do not glob" can be undone by the enumeration

The rule exists so a build lists its inputs explicitly. It does not help if the
list is *produced* by a glob with the wrong pattern: enumerating xlnt with
`*.cpp` silently dropped `sha1.c` and `sha512.c`, and the build failed at link
with undefined `sha1_hash`/`sha512_hash` rather than at compile, which is a
worse place to find out. Check the extensions actually present in the tree
before trusting a generated source list.

### Zig 0.16 API churn, and documentation that lags it

Hit in one session: `std.process.SpawnOptions.StdIo.Ignore` is now `.ignore`;
`runAllowFail` wants a mutable `*u8`; `std.ArrayList` is unmanaged so every
method takes an allocator. None is hard, all cost a compile-fix cycle, and none
is well covered by searchable material. CMake is unpleasant but it is 2005-era
stable and every error message has fifteen years of answers behind it.

### `zig fetch --save` does not reliably write hashes

It reported success and left `.hash` absent, so hashes had to be captured from
bare `zig fetch` and edited into the `.zon` by hand. An empty `.hash = ""` is
also a hard error rather than a prompt to fill it in. Rough edges in the
first-run path, exactly where a newcomer meets them.

### Prebuilts must be enumerated per target

Selecting a per-platform prebuilt is a `switch` over `os.tag` and `cpu.arch`
plus one lazy dependency entry per platform in the `.zon`. CMake's `if/elseif`
chain building a URL string is more compact. The Zig version is more honest —
every supported platform is declared and hashed — but it is more to write, and
adding a platform touches two files.

### URL-pinned shared layer costs a round trip per change

Repinning `blobzig` from `.path = "../blobzig"` to a GitHub URL makes each repo
self-contained and buildable on a machine that has only that repo — which is
what unblocked building on dc1. The cost is that a blobzig edit no longer flows
to consumers: it is now commit, push, and repin with a new hash in each repo.
That bit within minutes of making the change, twice.

This is a deliberate trade rather than a Zig deficiency, but it is a real
day-to-day cost during active development of the shared layer.

## Neither, on inspection

- **The HiGHS shim `.so`** looks like new complexity introduced by the
  migration. It is new machinery, but it fixed a latent bug CMake was concealing
  by happening to link a shared `libhighs`. Under CMake the mismatch existed and
  went unremarked.
- **`install_name_tool` on PDFium** is a wash. CMake did the same call; the Zig
  version produces a corrected copy rather than mutating the download in place,
  because `zig-pkg` is content-addressed. Marginally better, same effort.

## What would change the verdict

If `check_undefined` resolved against Zig's target libc instead of a curated
list, the single largest source of friction in this migration would disappear,
and the honest summary would move from "worth it for correctness properties" to
"straightforwardly better". That is the highest-value outstanding item in
blobzig.

## Related

- [[SSO Layering — spnego-token, blobsso, blobhttp]]
- `blobzig/PLAN.md` — the migration plan and the fat-dependency policy
- `blobzig/MIGRATION.md` — traps hit, so they are not rediscovered
