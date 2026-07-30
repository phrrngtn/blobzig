//! Reusable scaffolding for a DuckDB **C extension API** loadable extension in Zig.
//!
//! Nothing here is blobjs-specific — this is the piece intended to be lifted into a
//! shared package for the other blob* repos.
//!
//! Why there is no C in this file, despite `duckdb_extension.h` being 435 macros:
//! 367 of those macros are of the form
//!
//!     #define duckdb_open  duckdb_ext_api.duckdb_open
//!
//! and exist solely so C code written against plain `duckdb.h` compiles unchanged
//! against the extension API. Zig code is written fresh, so it skips the shim and
//! calls through the function-pointer struct directly. The remaining macro that
//! matters, DUCKDB_EXTENSION_ENTRYPOINT, expands to the dozen lines in `init` below.
//!
//! IMPORTANT: `c` also re-exports the plain `duckdb.h` prototypes (duckdb_extension.h
//! includes it). Calling `c.duckdb_connect(...)` would link against an undefined
//! symbol instead of going through the loaded API table. Always go through `api`.

const std = @import("std");

pub const c = @cImport({
    @cInclude("duckdb_extension.h");
});

/// The API version this extension is compiled against; handed to DuckDB at load
/// time so it can refuse an incompatible host. Matches the header's
/// DUCKDB_EXTENSION_API_VERSION_{MAJOR,MINOR,PATCH}.
pub const api_version = std.fmt.comptimePrint("v{d}.{d}.{d}", .{
    c.DUCKDB_EXTENSION_API_VERSION_MAJOR,
    c.DUCKDB_EXTENSION_API_VERSION_MINOR,
    c.DUCKDB_EXTENSION_API_VERSION_PATCH,
});

/// The loaded function-pointer table. Populated by `init`; every DuckDB call in
/// the extension goes through this. (DUCKDB_EXTENSION_GLOBAL.)
pub var api: c.duckdb_ext_api_v1 = undefined;

pub const Access = c.struct_duckdb_extension_access;

/// The body of DUCKDB_EXTENSION_ENTRYPOINT: fetch the API table, open a connection.
/// Returns null (with the error already reported to DuckDB) if the host refuses.
/// On success the caller owns the connection and must pass it to `deinit`.
pub fn init(info: c.duckdb_extension_info, access: *Access) ?c.duckdb_connection {
    const table = access.get_api.?(info, api_version) orelse return null;
    api = @as(*const c.duckdb_ext_api_v1, @ptrCast(@alignCast(table))).*;

    const db = access.get_database.?(info);
    var conn: c.duckdb_connection = null;
    if (api.duckdb_connect.?(db.*, &conn) == c.DuckDBError) {
        access.set_error.?(info, "Failed to open connection to database");
        return null;
    }
    return conn;
}

pub fn deinit(conn: c.duckdb_connection) void {
    var mut = conn;
    api.duckdb_disconnect.?(&mut);
}

// ── Vector helpers ─────────────────────────────────────────────────

/// Borrow a DuckDB string_t as a slice. Short strings live inline in the struct;
/// longer ones point into a shared blob. Either way the bytes are NOT
/// NUL-terminated — the caller must not hand them to a C string API.
pub fn str(s: *const c.duckdb_string_t) []const u8 {
    const len = s.value.inlined.length;
    const p: [*]const u8 = if (len <= 12)
        @ptrCast(&s.value.inlined.inlined)
    else
        @ptrCast(s.value.pointer.ptr);
    return p[0..len];
}

pub fn rowIsValid(validity: ?[*]u64, row: c.idx_t) bool {
    const v = validity orelse return true;
    return api.duckdb_validity_row_is_valid.?(v, row);
}

pub fn setRowInvalid(output: c.duckdb_vector, row: c.idx_t) void {
    api.duckdb_vector_ensure_validity_writable.?(output);
    api.duckdb_validity_set_row_invalid.?(api.duckdb_vector_get_validity.?(output), row);
}

/// Assign a (possibly non-terminated) slice as the row's string value.
pub fn setString(output: c.duckdb_vector, row: c.idx_t, s: []const u8) void {
    api.duckdb_vector_assign_string_element_len.?(output, row, s.ptr, s.len);
}

// ── Registration helper ────────────────────────────────────────────

/// Register a scalar function taking `n_params` VARCHARs and returning VARCHAR.
/// Covers every function blobjs exposes; widen when a sibling repo needs more.
pub fn registerVarcharScalar(
    conn: c.duckdb_connection,
    name: [*:0]const u8,
    n_params: usize,
    func: c.duckdb_scalar_function_t,
) void {
    const varchar = api.duckdb_create_logical_type.?(c.DUCKDB_TYPE_VARCHAR);
    defer {
        var t = varchar;
        api.duckdb_destroy_logical_type.?(&t);
    }

    const f = api.duckdb_create_scalar_function.?();
    defer {
        var g = f;
        api.duckdb_destroy_scalar_function.?(&g);
    }

    api.duckdb_scalar_function_set_name.?(f, name);
    for (0..n_params) |_| api.duckdb_scalar_function_add_parameter.?(f, varchar);
    api.duckdb_scalar_function_set_return_type.?(f, varchar);
    api.duckdb_scalar_function_set_function.?(f, func);
    _ = api.duckdb_register_scalar_function.?(conn, f);
}
