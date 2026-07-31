//! Fail the build when a loadable extension has an undefined symbol it has no
//! business having.
//!
//! WHY THIS EXISTS
//!
//! Loadable extensions must link with unresolved symbols — `duckdb_*` comes from
//! the host process, and libc comes from wherever the host got it — so
//! `linker_allow_shlib_undefined` is set. That flag is all-or-nothing: it also
//! swallows symbols that are missing because something genuinely failed to link.
//!
//! blobd2 is the worked example. Cross-compiling linked a c-archive of the wrong
//! object format; the linker ignored it without complaint, `zig build` exited 0,
//! and the extension died at load with `undefined symbol: d2cgo_render_svg`. A
//! build that succeeds and produces a broken artifact is worse than one that
//! fails, and only running it on the target platform caught it.
//!
//! THE RULE, AND WHERE IT APPLIES
//!
//! This is calibrated for extensions built against the **DuckDB C extension
//! API**, which is what every blob* repo except blobsso uses. There, the API
//! arrives as a function-pointer struct rather than as linkage, so a correctly
//! built extension has *no* undefined `duckdb_*` symbols at all and its
//! undefined set is only libc/libm/pthread/dl. Anything else is a symbol that
//! should have been linked in and was not — which is exactly the failure this
//! catches.
//!
//! A **C++ extension** (blobsso) is the opposite case: it links against DuckDB's
//! C++ API and legitimately leaves a large set of mangled `duckdb::*` symbols to
//! be resolved from the host binary at load. The strict rule would reject all of
//! them. Such a build must allow the C++ ABI prefixes — blobzig's
//! `duckdb_abi = .cpp` does that, adding `_ZN6duckdb` / `_ZNK6duckdb` and the
//! typeinfo and vtable forms. The check still has value there: it catches
//! missing symbols from the extension's OWN fat library, which is the class of
//! bug it exists for.
//!
//! tools/libc_symbols.txt holds the permitted names, seeded from the actual
//! undefined sets of the working extensions in the family. Symbols beginning
//! `__` are also allowed (compiler and runtime internals, and glibc's
//! `__isoc99_*` / `__ctype_*` shims). A repo with a legitimate extra source of
//! undefined symbols — blobodbc resolves `SQL*` from the host's ODBC driver
//! manager — passes prefixes to allow, which doubles as documentation that the
//! artifact is not self-contained.
//!
//! In `c` mode the absence of DuckDB symbols is checked POSITIVELY rather than
//! just left off the allowlist, because an undefined `duckdb_*` has a specific
//! cause worth naming: `duckdb_extension.h` includes `duckdb.h`, so every API
//! function also exists as an ordinary extern prototype. Calling
//! `duckdb_create_scalar_function(...)` instead of
//! `api.duckdb_create_scalar_function.?(...)` compiles, links (the flag allows
//! it), and then fails at load. The jump table is the only correct path, and
//! this is what proves it was taken.
//!
//! usage: check_undefined <binary> <c|cpp> [allowed-prefix...]

const std = @import("std");

/// Kept only as a fast path, not as the source of truth.
///
/// The authority is `libcProvides` below, which asks the target's own libc.
/// Consulting this list first just avoids spawning a compiler for the symbols
/// that are obviously fine, which is nearly all of them on a green build.
const libc_symbols = @embedFile("libc_symbols.txt");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        std.debug.print("usage: {s} <binary> [allowed-prefix...]\n", .{args[0]});
        std.process.exit(2);
    }
    const path = args[1];
    const cpp = args.len > 2 and std.mem.eql(u8, args[2], "cpp");
    // Optional, and only used when something is about to be reported: the
    // compiler to probe with, and the target to probe for.
    const zig_exe = if (args.len > 3 and args[3].len != 0) args[3] else null;
    const target_triple = if (args.len > 4 and args[4].len != 0) args[4] else null;
    const prefixes = if (args.len > 5) args[5..] else args[args.len..];

    // The C++ extension API resolves these from the host binary at load.
    const cpp_prefixes = [_][]const u8{
        "_ZN6duckdb", "_ZNK6duckdb", "_ZTIN6duckdb", "_ZTVN6duckdb", "_ZTSN6duckdb",
    };

    var allowed: std.StringHashMapUnmanaged(void) = .empty;
    defer allowed.deinit(gpa);
    var it = std.mem.tokenizeAny(u8, libc_symbols, " \r\n\t");
    while (it.next()) |name| try allowed.put(gpa, name, {});

    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(bytes);

    var undefined_names: std.ArrayList([]const u8) = .empty;
    defer undefined_names.deinit(gpa);

    if (std.mem.startsWith(u8, bytes, "\x7fELF")) {
        try collectElf(gpa, bytes, &undefined_names);
    } else if (isMachO(bytes)) {
        try collectMachO(gpa, bytes, &undefined_names);
    } else if (std.mem.startsWith(u8, bytes, "MZ")) {
        // PE/COFF has no notion of an unresolved symbol in a finished DLL: every
        // import is bound at LINK time to a named DLL and recorded in the import
        // table. The failure this tool exists to catch — an archive the linker
        // silently skipped, leaving a symbol to blow up at load — is therefore a
        // hard link error on Windows already. Nothing useful to add, so pass.
        return;
    } else {
        std.debug.print("check_undefined: {s}: unrecognised object format\n", .{path});
        std.process.exit(2);
    }

    // Collected rather than printed as we go, so the two categories do not
    // interleave under each other's heading.
    var missing: std.ArrayList([]const u8) = .empty;
    defer missing.deinit(gpa);
    var leaked: std.ArrayList([]const u8) = .empty;
    defer leaked.deinit(gpa);

    for (undefined_names.items) |raw| {
        // Mach-O prefixes every C symbol with an underscore. Mangled C++ names
        // start `_Z`, so only strip a single leading underscore.
        const name = if (raw.len > 1 and raw[0] == '_' and raw[1] != '_' and !std.mem.startsWith(u8, raw, "_Z"))
            raw[1..]
        else
            raw;

        // Reaching the host by linkage rather than through its jump table. Both
        // hosts work the same way — DuckDB via duckdb_ext_api_v1, SQLite via
        // sqlite3_api_routines — so both get the same positive check, reported
        // separately from ordinary missing symbols because the fix is specific.
        //
        // (The Python side needs no equivalent: the cdylib exports its own C ABI
        // and ctypes binds at runtime, so it has no CPython linkage to leak.)
        const host_leak = (!cpp and std.mem.startsWith(u8, name, "duckdb_")) or
            std.mem.startsWith(u8, name, "sqlite3_");
        if (host_leak) {
            try leaked.append(gpa, name);
            continue;
        }

        if (std.mem.startsWith(u8, name, "__")) continue;
        // Supplied by the dynamic loader itself rather than by any library.
        // Mach-O emits this into every dylib; it is not resolvable by linking
        // anything, so no probe can vindicate it.
        if (std.mem.eql(u8, name, "dyld_stub_binder")) continue;
        if (allowed.contains(name)) continue;

        var ok = false;
        if (cpp) for (cpp_prefixes) |p| {
            if (std.mem.startsWith(u8, name, p)) ok = true;
        };
        if (!ok) for (prefixes) |p| {
            if (std.mem.startsWith(u8, name, p)) ok = true;
        };
        if (ok) continue;
        try missing.append(gpa, name);
    }

    // Everything above was decided against a hand-maintained list, which is
    // necessarily incomplete — glibc alone exports thousands of names, and the
    // list grew by ~250 entries in one evening of porting two repos.
    //
    // So before reporting anything, ask the actual libc. Only the suspects are
    // probed, and only when there are suspects, so a green build never spawns a
    // compiler.
    if (missing.items.len != 0) {
        if (zig_exe) |exe| if (target_triple) |triple| {
            const real = libcProvides(gpa, io, exe, triple, missing.items, path) catch null;
            if (real) |provided| {
                defer gpa.free(provided);
                var kept: std.ArrayList([]const u8) = .empty;
                for (missing.items, provided) |name, in_libc| {
                    if (!in_libc) try kept.append(gpa, name);
                }
                missing.deinit(gpa);
                missing = kept;
            }
        };
    }

    const bad = missing.items.len;
    const duckdb_leak = leaked.items.len;

    if (duckdb_leak != 0) {
        std.debug.print(
            "check_undefined: {s} references its host by linkage, not through the jump table:\n",
            .{path},
        );
        for (leaked.items) |n| std.debug.print("    {s}\n", .{n});
        std.debug.print(
            \\
            \\Both host headers declare every API function as a plain extern
            \\prototype as well as routing it through a table, so calling one
            \\directly compiles and links and then fails at load. Go through the
            \\table:
            \\
            \\    api.duckdb_create_scalar_function.?(...)   not duckdb_create_scalar_function(...)
            \\    api.result_text.?(...)                     not sqlite3_result_text(...)
            \\
            \\(If this extension really does use DuckDB's C++ API, set
            \\duckdb_abi = .cpp.)
            \\
        , .{});
    }
    if (bad != 0) {
        std.debug.print("check_undefined: {s} has unresolved symbols that are not libc:\n", .{path});
        for (missing.items) |n| std.debug.print("    {s}\n", .{n});
        std.debug.print(
            \\
            \\{d} symbol(s) above should have been linked in and were not — most
            \\likely a static library or object the linker silently skipped (a
            \\common cause is an archive built for a different target).
            \\
            \\If the host genuinely resolves them at load time, pass their prefix
            \\to blobzig's `allow_undefined` — each entry is a portability caveat,
            \\so listing them is the point.
            \\
        , .{bad});
    }
    if (bad != 0 or duckdb_leak != 0) std.process.exit(1);
}

/// Ask the target's libc which of `names` it actually provides.
///
/// Rather than curating a list, link a program that references every suspect
/// and let the linker adjudicate. Zig ships libc for every target it supports —
/// glibc stubs, musl, Darwin's tbd — so this is exact for cross builds too,
/// which a host-derived list could never be.
///
/// Returns a bool per input name, or null if the probe could not be run at all
/// (no compiler, unwritable scratch, ...). Null means "no opinion", and the
/// caller falls back to the embedded list rather than passing everything.
///
/// **Scope, so the result is not over-read.** This answers "is this symbol in
/// the target's libc", which is narrower than "will this resolve at load".
/// A symbol from a system library the artifact genuinely links — libiconv on
/// Darwin is the case in practice — is correctly reported as not-libc and still
/// resolves fine at runtime. That is what `allow_undefined` is for, and listing
/// it is the point: it records a real portability requirement.
///
/// One symbol per link would be exact but is O(n) compiler spawns. Instead this
/// bisects: link them all, and if that fails, split and recurse. A green probe
/// is one spawn; a real failure costs log(n) rather than n.
fn libcProvides(
    gpa: std.mem.Allocator,
    io: std.Io,
    zig_exe: []const u8,
    triple: []const u8,
    names: []const []const u8,
    near: []const u8,
) ![]bool {
    const out = try gpa.alloc(bool, names.len);
    errdefer gpa.free(out);
    @memset(out, false);

    // Scratch lives beside the artifact under test — that is inside the build
    // cache, so it is writable and gets cleaned with everything else.
    const dir = std.fs.path.dirname(near) orelse ".";

    const all = try probeLinks(gpa, io, zig_exe, triple, names, dir);
    if (all) {
        @memset(out, true);
        return out;
    }
    if (names.len == 1) return out; // it alone failed to link: genuinely absent

    const mid = names.len / 2;
    const lo = try libcProvides(gpa, io, zig_exe, triple, names[0..mid], near);
    defer gpa.free(lo);
    const hi = try libcProvides(gpa, io, zig_exe, triple, names[mid..], near);
    defer gpa.free(hi);
    @memcpy(out[0..mid], lo);
    @memcpy(out[mid..], hi);
    return out;
}

/// Does a program referencing every one of `names` link against libc?
fn probeLinks(
    gpa: std.mem.Allocator,
    io: std.Io,
    zig_exe: []const u8,
    triple: []const u8,
    names: []const []const u8,
    dir: []const u8,
) !bool {
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);

    // `extern char x;` then `&x` resolves by NAME, which is all a linker cares
    // about — so this works for functions as well as data, without needing the
    // real prototypes. Referencing through a volatile sink stops the optimiser
    // discarding the references before the linker sees them.
    for (names) |n| try src.print(gpa, "extern char {s};\n", .{n});
    try src.appendSlice(gpa, "void *volatile bb_sink;\nint main(void) {\n");
    for (names) |n| try src.print(gpa, "    bb_sink = (void *)&{s};\n", .{n});
    try src.appendSlice(gpa, "    return 0;\n}\n");

    const c_path = try std.fmt.allocPrint(gpa, "{s}/bb_libc_probe.c", .{dir});
    defer gpa.free(c_path);
    const exe_path = try std.fmt.allocPrint(gpa, "{s}/bb_libc_probe.out", .{dir});
    defer gpa.free(exe_path);

    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = c_path, .data = src.items });
    defer cwd.deleteFile(io, c_path) catch {};
    defer cwd.deleteFile(io, exe_path) catch {};

    var child = std.process.spawn(io, .{
        .argv = &.{
            zig_exe,          "cc",
            "-target",        triple,
            // Clang declares printf, abort, memcpy and friends as builtins, and
            // `extern char printf;` then collides with the builtin's type —
            // "redefinition as a different kind of symbol". That is a COMPILE
            // error, so without this the probe fails before the linker is ever
            // consulted and every symbol looks absent. It cost a debugging
            // round: the first run reported printf and abort as not-libc.
            "-fno-builtin",
            // The declarations are deliberately the wrong type; we only care
            // whether the names resolve.
            "-w",
            "-o",             exe_path,
            c_path,
        },
        // The compiler's diagnostics are not the answer we want — the exit
        // status is. Discarding them keeps a probe from printing a wall of
        // "undefined symbol" noise above the report we are about to write.
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return error.ProbeFailed;
    const term = child.wait(io) catch return error.ProbeFailed;
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn isMachO(b: []const u8) bool {
    if (b.len < 4) return false;
    const m = std.mem.readInt(u32, b[0..4], .little);
    return m == std.macho.MH_MAGIC_64 or m == std.macho.MH_CIGAM_64;
}

/// Undefined entries of `.dynsym` — the symbols the loader must satisfy.
fn collectElf(gpa: std.mem.Allocator, b: []const u8, out: *std.ArrayList([]const u8)) !void {
    if (b.len < @sizeOf(std.elf.Elf64_Ehdr)) return error.Truncated;
    const eh: *align(1) const std.elf.Elf64_Ehdr = @ptrCast(b.ptr);
    if (eh.e_ident[std.elf.EI_CLASS] != std.elf.ELFCLASS64) return error.Unsupported;

    const shoff = eh.e_shoff;
    const shnum = eh.e_shnum;
    if (shoff == 0 or shnum == 0) return;

    const sh: []align(1) const std.elf.Elf64_Shdr =
        @as([*]align(1) const std.elf.Elf64_Shdr, @ptrCast(b.ptr + shoff))[0..shnum];

    for (sh) |s| {
        if (s.sh_type != std.elf.SHT_DYNSYM) continue;
        const strtab = sh[s.sh_link];
        const syms: []align(1) const std.elf.Elf64_Sym =
            @as([*]align(1) const std.elf.Elf64_Sym, @ptrCast(b.ptr + s.sh_offset))[0 .. s.sh_size / @sizeOf(std.elf.Elf64_Sym)];
        for (syms) |sym| {
            if (sym.st_shndx != std.elf.SHN_UNDEF) continue;
            if (sym.st_name == 0) continue;
            const base = b[strtab.sh_offset + sym.st_name ..];
            const name = std.mem.sliceTo(base, 0);
            if (name.len != 0) try out.append(gpa, name);
        }
    }
}

/// External undefined entries of LC_SYMTAB.
fn collectMachO(gpa: std.mem.Allocator, b: []const u8, out: *std.ArrayList([]const u8)) !void {
    const hdr: *align(1) const std.macho.mach_header_64 = @ptrCast(b.ptr);
    var off: usize = @sizeOf(std.macho.mach_header_64);
    var i: u32 = 0;
    while (i < hdr.ncmds) : (i += 1) {
        const lc: *align(1) const std.macho.load_command = @ptrCast(b.ptr + off);
        if (lc.cmd == .SYMTAB) {
            const st: *align(1) const std.macho.symtab_command = @ptrCast(b.ptr + off);
            const syms: []align(1) const std.macho.nlist_64 =
                @as([*]align(1) const std.macho.nlist_64, @ptrCast(b.ptr + st.symoff))[0..st.nsyms];
            for (syms) |sym| {
                // Zig models n_type as a union; a non-zero is_stab means the
                // entry is debug info rather than a real symbol.
                const bits = sym.n_type.bits;
                if (bits.is_stab != 0) continue;
                if (bits.type != .undf) continue; // defined somewhere in this image
                if (!bits.ext) continue; // not externally visible
                const name = std.mem.sliceTo(b[st.stroff + sym.n_strx ..], 0);
                if (name.len != 0) try out.append(gpa, name);
            }
        }
        off += lc.cmdsize;
    }
}
