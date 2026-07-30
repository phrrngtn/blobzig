//! Reusable scaffolding for a SQLite loadable extension in Zig.
//!
//! Nothing here is blobjs-specific — companion to duckdb.zig for the shared package.
//!
//! Same story as DuckDB: `sqlite3ext.h` works by redefining every `sqlite3_foo` into
//! `sqlite3_api->foo`, which is a source-compatibility shim for C. Zig goes through
//! the `sqlite3_api_routines` table directly (`api.result_text.?(...)`).
//!
//! A real benefit falls out of that: because nothing here references a `sqlite3_*`
//! symbol, the built module has no undefined symbols and does not need the
//! `-undefined dynamic_lookup` link flag the CMake build carried on macOS.

const std = @import("std");

pub const c = @cImport({
    @cInclude("sqlite3ext.h");
});

/// The loaded function-pointer table. (SQLITE_EXTENSION_INIT1.)
pub var api: *const c.sqlite3_api_routines = undefined;

/// Populated from the entrypoint's `pApi`. (SQLITE_EXTENSION_INIT2.)
pub fn init(p_api: *const c.sqlite3_api_routines) void {
    api = p_api;
}

pub const Destructor = *const fn (?*anyopaque) callconv(.c) void;

pub const OK = c.SQLITE_OK;
pub const UTF8 = c.SQLITE_UTF8;
pub const DETERMINISTIC = c.SQLITE_DETERMINISTIC;
pub const DIRECTONLY = c.SQLITE_DIRECTONLY;

/// Borrow an argument as a NUL-terminated C string, or null if the value is NULL.
pub fn valueText(v: ?*c.sqlite3_value) ?[*:0]const u8 {
    return @ptrCast(api.value_text.?(v));
}

/// Hand SQLite ownership of a NUL-terminated result; it calls `destructor` when done.
///
/// The C version passed SQLITE_TRANSIENT and freed the buffer itself, which makes
/// SQLite memcpy every result. Transferring ownership avoids that copy per row.
/// (It also sidesteps SQLITE_TRANSIENT, which is `(sqlite3_destructor_type)-1` —
/// a sentinel Zig cannot @ptrFromInt into a function pointer.)
pub fn resultTextOwned(ctx: ?*c.sqlite3_context, s: [*:0]const u8, destructor: Destructor) void {
    api.result_text.?(ctx, s, -1, destructor);
}

pub fn resultError(ctx: ?*c.sqlite3_context, msg: [*:0]const u8) void {
    api.result_error.?(ctx, msg, -1);
}

pub fn resultNull(ctx: ?*c.sqlite3_context) void {
    api.result_null.?(ctx);
}

pub fn getAuxdata(ctx: ?*c.sqlite3_context, arg: c_int) ?*anyopaque {
    return api.get_auxdata.?(ctx, arg);
}

pub fn setAuxdata(
    ctx: ?*c.sqlite3_context,
    arg: c_int,
    data: *anyopaque,
    destructor: *const fn (?*anyopaque) callconv(.c) void,
) void {
    api.set_auxdata.?(ctx, arg, data, destructor);
}

pub const ScalarFn = *const fn (?*c.sqlite3_context, c_int, [*c]?*c.sqlite3_value) callconv(.c) void;

pub fn createFunction(
    db: ?*c.sqlite3,
    name: [*:0]const u8,
    n_args: c_int,
    flags: c_int,
    func: ScalarFn,
) c_int {
    return api.create_function.?(db, name, n_args, flags, null, func, null, null);
}
