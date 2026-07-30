//! blobzig — the shared build layer for the blob* extension family.
//!
//! Every blob* repo is the same shape: a fat C library, a thin adapter compiled
//! once, and three loadable artifacts (DuckDB, SQLite, a cdylib for Python
//! ctypes) that link it. Under CMake that shape cost each repo ~100 lines of
//! copy-pasted CMakeLists plus its own copy of append_metadata.py — twelve
//! copies of the script, eleven FetchContents of the DuckDB headers, twelve
//! SQLite amalgamation downloads.
//!
//! Here it is one dependency. A consumer's build.zig reduces to: describe the
//! fat library, describe the adapter, call `addHostExtensions`.
//!
//! Usage (in a consumer build.zig):
//!
//!     const blobzig = @import("blobzig");
//!
//!     const bz = b.dependency("blobzig", .{ .target = target, .optimize = optimize });
//!     const core = b.createModule(.{ ... });          // your adapter over the fat lib
//!
//!     _ = blobzig.addHostExtensions(b, bz, .{
//!         .name = "blobjs",
//!         .target = target,
//!         .optimize = optimize,
//!         .core = core,
//!         .duckdb_root = b.path("zig/ext_duckdb.zig"),
//!         .sqlite_root = b.path("zig/ext_sqlite.zig"),
//!     });

const std = @import("std");

pub const DUCKDB_API_VERSION = "v1.2.0"; // stable C extension API baseline

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The DuckDB C extension API. translate-C over duckdb_extension.h gives the
    // duckdb_ext_api_v1 function-pointer struct, which is all a Zig extension
    // needs; the header's 367 `#define duckdb_foo duckdb_ext_api.duckdb_foo`
    // macros exist only so C written against duckdb.h compiles unchanged, and
    // Zig calls through the struct directly. See src/duckdb.zig.
    const capi = b.dependency("duckdb_capi", .{}).path("duckdb_capi");
    const duckdb = b.addModule("duckdb", .{
        .root_source_file = b.path("src/duckdb.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    duckdb.addIncludePath(capi);

    const sqlite = b.addModule("sqlite", .{
        .root_source_file = b.path("src/sqlite.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    sqlite.addIncludePath(b.path("third_party/sqlite"));

    // The same headers as include paths, for repos whose shims are still C or
    // C++. A Zig module import is no use to a .c file, and this saves each repo
    // re-fetching the DuckDB headers and re-downloading the SQLite amalgamation.
    b.addNamedLazyPath("duckdb_capi_include", capi);
    b.addNamedLazyPath("sqlite_include", b.path("third_party/sqlite"));

    // Host-native: these inspect or rewrite a built artifact, so they run on the
    // build machine even when the artifact itself is cross-compiled. Both parse
    // the object format themselves rather than shelling out to nm or objcopy,
    // which on macOS cannot read a Linux object at all.
    const stamp = b.addExecutable(.{
        .name = "append_metadata",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/append_metadata.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    b.installArtifact(stamp);

    const check = b.addExecutable(.{
        .name = "check_undefined",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/check_undefined.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    b.installArtifact(check);
}

// ── Build-time API for consumers ───────────────────────────────────

pub const Options = struct {
    /// Extension name. Determines the DuckDB entrypoint symbol
    /// (`<name>_init_c_api`), the SQLite entrypoint (`sqlite3_<name>_init`),
    /// and every output filename.
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    /// The adapter module over the fat C library, published as a cdylib for the
    /// Python ctypes wrapper to bind.
    ///
    /// Null when the project has no C ABI to publish — a header-only C++ library
    /// consumed only through the two SQL extensions (blobgraphs) has nothing a
    /// cdylib could usefully export. Zig shims still get it as their `core`
    /// import when present.
    core: ?*std.Build.Module = null,
    /// Root source of the DuckDB registration shim, when it is Zig. blobzig
    /// creates the module and wires the `duckdb` and `core` imports.
    duckdb_root: ?std.Build.LazyPath = null,
    /// Root source of the SQLite registration shim, when it is Zig.
    sqlite_root: ?std.Build.LazyPath = null,

    /// Escape hatch: supply the shim module yourself. Use this when the shim is
    /// still C or C++ — a repo can drop CMake first and port its shims to Zig
    /// afterwards, which is the only sane order for the ones whose fat library
    /// needs a permanent extern "C" island (jsoncons, DataSketches, inja).
    /// Takes precedence over the matching `*_root`.
    duckdb_module: ?*std.Build.Module = null,
    sqlite_module: ?*std.Build.Module = null,

    ext_version: []const u8 = "v0.1.0",

    /// Which DuckDB API the extension is built against. Determines what the
    /// undefined-symbol check treats as legitimately unresolved.
    ///
    /// `.c` — the C extension API, where the API is a function-pointer struct
    /// and a correct extension has NO undefined `duckdb_*` symbols. Every blob*
    /// repo except blobsso.
    ///
    /// `.cpp` — the C++ extension API, which resolves a large set of mangled
    /// `duckdb::*` symbols from the host binary at load. Those get allowed
    /// automatically.
    duckdb_abi: enum { c, cpp } = .c,

    /// Extra prefixes the undefined-symbol check should permit, for artifacts
    /// that are deliberately not self-contained. blobodbc passes `SQL` because
    /// it resolves the ODBC entry points from the host's driver manager.
    ///
    /// Every entry here is a portability caveat, so listing them is the point:
    /// the target must supply these or the extension will not load.
    allow_undefined: []const []const u8 = &.{},
};

pub const Artifacts = struct {
    /// Null when `Options.core` was null — see the comment there.
    lib: ?*std.Build.Step.Compile = null,
    duckdb: ?*std.Build.Step.Compile = null,
    sqlite: ?*std.Build.Step.Compile = null,
};

/// Build the cdylib plus whichever loadable extensions were requested, and wire
/// up installation under the names each host expects.
pub fn addHostExtensions(
    b: *std.Build,
    bz: *std.Build.Dependency,
    opts: Options,
) Artifacts {
    var out: Artifacts = .{};

    // Fail the build if `art` has an unresolved symbol it should not have.
    // See tools/check_undefined.zig — this is what turns "linked fine, dies at
    // load" into a build error.
    const Check = struct {
        fn add(bld: *std.Build, dep: *std.Build.Dependency, o: Options, art: *std.Build.Step.Compile) void {
            const run = bld.addRunArtifact(dep.artifact("check_undefined"));
            run.addArtifactArg(art);
            run.addArg(if (o.duckdb_abi == .cpp) "cpp" else "c");
            for (o.allow_undefined) |p| run.addArg(p);
            bld.getInstallStep().dependOn(&run.step);
        }
    };

    if (opts.core) |core| {
        out.lib = b.addLibrary(.{
            .name = opts.name,
            .linkage = .dynamic,
            .root_module = core,
        });
        b.installArtifact(out.lib.?);
        Check.add(b, bz, opts, out.lib.?);
    }

    if (opts.duckdb_module orelse zigShim(b, bz, opts, "duckdb", opts.duckdb_root)) |mod| {
        const ext = b.addLibrary(.{
            .name = b.fmt("{s}_duckdb", .{opts.name}),
            .linkage = .dynamic,
            .root_module = mod,
        });
        // DuckDB supplies the API table at load time; nothing to link against.
        ext.linker_allow_shlib_undefined = true;

        // Stamp the footer DuckDB checks before loading. The platform comes from
        // the TARGET — append_metadata.py derived it from the host, so any
        // cross-built extension was stamped wrong and refused to load.
        const stamp = b.addRunArtifact(bz.artifact("append_metadata"));
        stamp.addArtifactArg(ext);
        const stamped = stamp.addOutputFileArg(b.fmt("{s}.duckdb_extension", .{opts.name}));
        stamp.addArgs(&.{ duckdbPlatform(opts.target.result), opts.ext_version, DUCKDB_API_VERSION });

        b.getInstallStep().dependOn(&b.addInstallFileWithDir(
            stamped,
            .lib,
            b.fmt("{s}.duckdb_extension", .{opts.name}),
        ).step);
        Check.add(b, bz, opts, ext);
        out.duckdb = ext;
    }

    if (opts.sqlite_module orelse zigShim(b, bz, opts, "sqlite", opts.sqlite_root)) |mod| {
        // No `-undefined dynamic_lookup` for a Zig shim: everything goes through
        // the sqlite3_api_routines table, so there are no undefined symbols.
        const ext = b.addLibrary(.{
            .name = b.fmt("{s}_sqlite", .{opts.name}),
            .linkage = .dynamic,
            .root_module = mod,
        });

        // SQLite's .load appends a platform suffix to a path that has none, so
        // macOS needs a .dylib next to the .so. CMake symlinked; installing the
        // artifact twice is simpler and survives being copied into a wheel.
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(
            ext.getEmittedBin(),
            .lib,
            b.fmt("{s}.so", .{opts.name}),
        ).step);
        if (opts.target.result.os.tag == .macos) {
            b.getInstallStep().dependOn(&b.addInstallFileWithDir(
                ext.getEmittedBin(),
                .lib,
                b.fmt("{s}.dylib", .{opts.name}),
            ).step);
        }
        Check.add(b, bz, opts, ext);
        out.sqlite = ext;
    }

    return out;
}

/// Build the module for a Zig shim, wiring the host binding and the adapter.
/// Returns null when this repo has no shim of that kind, or supplies its own.
fn zigShim(
    b: *std.Build,
    bz: *std.Build.Dependency,
    opts: Options,
    comptime host: []const u8,
    root: ?std.Build.LazyPath,
) ?*std.Build.Module {
    const src = root orelse return null;
    const mod = b.createModule(.{
        .root_source_file = src,
        .target = opts.target,
        .optimize = opts.optimize,
        .link_libc = true,
    });
    mod.addImport(host, bz.module(host));
    if (opts.core) |core| mod.addImport("core", core);
    return mod;
}

/// DuckDB's platform identifiers, which are its own vocabulary — not Zig triples.
///
/// Every case is spelled out and anything unrecognised is a hard build failure.
/// The Python version this replaces ended in `else: plat = "windows_amd64"`, so a
/// target it did not know about got silently stamped Windows and produced an
/// extension DuckDB would refuse to load, with nothing pointing at why. Zig makes
/// obscure targets one flag away, so that default would now be hit routinely.
pub fn duckdbPlatform(t: std.Target) []const u8 {
    const arch = switch (t.cpu.arch) {
        .x86_64 => "amd64",
        .aarch64 => "arm64",
        else => std.debug.panic(
            "blobzig: no DuckDB platform name for CPU '{s}' — DuckDB ships x86_64 and aarch64 only",
            .{@tagName(t.cpu.arch)},
        ),
    };
    const os = switch (t.os.tag) {
        .linux => "linux",
        .macos => "osx",
        .windows => "windows",
        else => std.debug.panic(
            "blobzig: no DuckDB platform name for OS '{s}' (arch {s})",
            .{ @tagName(t.os.tag), arch },
        ),
    };
    // DuckDB distinguishes glibc from musl on Linux, and Zig reaches musl with a
    // single -Dtarget flag, so this is a real case rather than a curiosity.
    const suffix = if (t.os.tag == .linux and t.abi.isMusl()) "_musl" else "";
    return std.fmt.allocPrint(
        std.heap.page_allocator,
        "{s}_{s}{s}",
        .{ os, arch, suffix },
    ) catch @panic("OOM");
}
