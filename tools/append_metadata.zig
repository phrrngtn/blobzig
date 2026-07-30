//! Append the DuckDB extension metadata footer to a shared library.
//!
//! Replaces duckdb_ext/append_metadata.py. Beyond deleting one of the twelve
//! byte-identical copies of that script across the blob* repos, this fixes a real
//! cross-compilation bug: the Python version derived the platform string from
//! `platform.machine()` — the HOST — so a cross-built extension was stamped with
//! the build machine's platform and DuckDB refused to load it on the target. Here
//! the platform is passed in from build.zig, which knows the actual target.
//!
//! usage: append_metadata <in.so> <out.duckdb_extension> <platform> <ext-version> <duckdb-version>

const std = @import("std");

const FIELD_LEN = 32;
const SIGNATURE_LEN = 256;

/// WebAssembly custom section header required by DuckDB's metadata parser.
const wasm_prefix = [_]u8{
    0x00, // custom section id
    0x93, 0x04, // section length (531 bytes)
    0x10, // name length (16)
} ++ "duckdb_signature".* ++ [_]u8{ 0x80, 0x04 }; // payload length (512)

fn pad(out: []u8, s: []const u8) void {
    @memset(out, 0);
    const n = @min(s.len, out.len);
    @memcpy(out[0..n], s[0..n]);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 6) {
        std.debug.print(
            "usage: {s} <in.so> <out.duckdb_extension> <platform> <ext-version> <duckdb-version>\n",
            .{args[0]},
        );
        std.process.exit(1);
    }
    const src, const dst, const platform, const ext_version, const duckdb_version =
        .{ args[1], args[2], args[3], args[4], args[5] };

    const cwd = std.Io.Dir.cwd();
    const body = try cwd.readFileAlloc(io, src, gpa, .unlimited);
    defer gpa.free(body);

    // Fields are written in reverse order (8 down to 1), then the signature.
    const footer_len = wasm_prefix.len + 8 * FIELD_LEN + SIGNATURE_LEN;
    const out = try gpa.alloc(u8, body.len + footer_len);
    defer gpa.free(out);

    @memcpy(out[0..body.len], body);
    var at = body.len;

    @memcpy(out[at..][0..wasm_prefix.len], &wasm_prefix);
    at += wasm_prefix.len;

    const fields = [_][]const u8{
        "", // field8: reserved
        "", // field7: reserved
        "", // field6: reserved
        "C_STRUCT", // field5: abi type
        ext_version, // field4: extension version
        duckdb_version, // field3: duckdb version (stable API baseline)
        platform, // field2: platform
        "4", // field1: magic
    };
    for (fields) |f| {
        pad(out[at..][0..FIELD_LEN], f);
        at += FIELD_LEN;
    }
    @memset(out[at..][0..SIGNATURE_LEN], 0); // signature placeholder

    try cwd.writeFile(io, .{ .sub_path = dst, .data = out });
}
