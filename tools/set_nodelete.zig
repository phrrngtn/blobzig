//! Set DF_1_NODELETE on an ELF shared library.
//!
//! Without it, a Linux host that dlcloses an extension segfaults at process
//! exit. The mechanism, bisected to six lines:
//!
//!     static std::string g_global = "hello";   // a namespace-scope global
//!
//! That gets an INIT_ARRAY entry and registers a destructor through
//! __cxa_atexit at load. Zig-built shared libraries define no __dso_handle, so
//! the registration is anonymous and dlclose cannot unregister it. The handler
//! then outlives the mapping, and exit() jumps into unmapped memory:
//!
//!     #0  0x00007ffff78dbcc0 in ?? ()
//!     #1  __run_exit_handlers ... at ./stdlib/exit.c:108
//!
//! Everything works right up to that point — the extension loads, functions
//! register, queries return correct answers — so this hides behind buffered
//! stdout and only shows up in the exit status.
//!
//! Function-local statics are NOT affected: they initialise lazily and get no
//! INIT_ARRAY entry. Nor is it fixable by dropping our own globals, since the
//! ones that bite come from dependencies.
//!
//! `-Wl,-z,nodelete` fixes it at link time and works through `zig c++`, but
//! Zig 0.16's build API cannot express it: Step.Compile exposes link_z_notext,
//! relro, lazy, defs and the page-size options, with no raw-linker-arg escape
//! hatch. Hence a post-link step, in the same shape as append_metadata.
//!
//! Marking an extension non-unloadable is defensible on its own terms: it has
//! registered function pointers with its host, and unloading them under the
//! host's feet is exactly the hazard here. DuckDB never unloads extensions for
//! that reason.
//!
//! Mach-O and PE inputs are copied through untouched — only ELF has the
//! problem, because only glibc really unmaps.
//!
//! usage: set_nodelete <in.so> <out.so>

const std = @import("std");

const DT_NULL: i64 = 0;
const DT_FLAGS_1: i64 = 0x6ffffffb;
const DF_1_NODELETE: u64 = 0x00000008;
const PT_DYNAMIC: u32 = 2;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 3) {
        std.debug.print("usage: {s} <in.so> <out.so>\n", .{args[0]});
        std.process.exit(1);
    }

    const cwd = std.Io.Dir.cwd();
    const buf = try cwd.readFileAlloc(io, args[1], gpa, .unlimited);
    defer gpa.free(buf);

    if (!isElf64(buf)) {
        // Nothing to do — write it through so the build graph still has a
        // single, predictable output path per target.
        try cwd.writeFile(io, .{ .sub_path = args[2], .data = buf });
        return;
    }
    try setNodelete(buf);
    try cwd.writeFile(io, .{ .sub_path = args[2], .data = buf });
}

fn isElf64(b: []const u8) bool {
    return b.len > 6 and std.mem.eql(u8, b[0..4], "\x7fELF") and b[4] == 2;
}

/// OR DF_1_NODELETE into the existing DT_FLAGS_1 entry.
///
/// Deliberately does not create the entry when absent: that would mean growing
/// the dynamic section and relocating everything after it. Every artifact this
/// runs on already carries DT_FLAGS_1 (Zig sets `Flags: NOW`), so a missing
/// entry means an assumption has changed and should be looked at rather than
/// worked around.
fn setNodelete(b: []u8) !void {
    const little = b[5] == 1;
    if (!little) return error.BigEndianUnsupported;

    const e_phoff = std.mem.readInt(u64, b[0x20..0x28], .little);
    const e_phentsize = std.mem.readInt(u16, b[0x36..0x38], .little);
    const e_phnum = std.mem.readInt(u16, b[0x38..0x3a], .little);

    var dyn_off: ?u64 = null;
    var dyn_size: u64 = 0;
    var i: u16 = 0;
    while (i < e_phnum) : (i += 1) {
        const base = e_phoff + @as(u64, i) * e_phentsize;
        if (base + 0x38 > b.len) return error.TruncatedProgramHeader;
        const p_type = std.mem.readInt(u32, b[@intCast(base)..][0..4], .little);
        if (p_type == PT_DYNAMIC) {
            dyn_off = std.mem.readInt(u64, b[@intCast(base + 0x08)..][0..8], .little);
            dyn_size = std.mem.readInt(u64, b[@intCast(base + 0x20)..][0..8], .little);
            break;
        }
    }
    const off = dyn_off orelse return error.NoDynamicSegment;

    var at = off;
    while (at + 16 <= off + dyn_size and at + 16 <= b.len) : (at += 16) {
        const d_tag = std.mem.readInt(i64, b[@intCast(at)..][0..8], .little);
        if (d_tag == DT_NULL) break;
        if (d_tag == DT_FLAGS_1) {
            const d_val = std.mem.readInt(u64, b[@intCast(at + 8)..][0..8], .little);
            std.mem.writeInt(u64, b[@intCast(at + 8)..][0..8], d_val | DF_1_NODELETE, .little);
            return;
        }
    }
    return error.NoDtFlags1;
}
