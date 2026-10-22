//! What a dashboard shows, as JSON that Postgres builds: ryven's `/errors`
//! page reads these as they are. Each call blocks on Postgres. Before the
//! tables exist, the lists are empty.
//!
//! They take a connection rather than a pool, so the caller can set it up
//! first: a dashboard whose connections also run its users' SQL resets
//! them (`DISCARD ALL`) so a `search_path` one of them set is not used.
const std = @import("std");
const pg = @import("pg_orm").pg;

/// Error groups, most recently seen first; times are Unix seconds, as text.
pub fn groups(conn: *pg.Conn, allocator: std.mem.Allocator) ![]u8 {
    return json(conn, allocator,
        \\SELECT coalesce(json_agg(g ORDER BY g.last_seen::bigint DESC), '[]')::text FROM (
        \\  SELECT id::text AS id, fingerprint, error_type, message,
        \\    crash_function, crash_file, crash_line, is_wasm_trap, occurrence_count,
        \\    floor(extract(epoch FROM first_seen))::bigint::text AS first_seen,
        \\    floor(extract(epoch FROM last_seen))::bigint::text AS last_seen,
        \\    status, environment, release, route
        \\  FROM error_groups ORDER BY last_seen DESC LIMIT 500
        \\) g
    , .{}, "[]");
}

/// The stack of a group's latest report, innermost first.
pub fn frames(conn: *pg.Conn, allocator: std.mem.Allocator, group_id: []const u8) ![]u8 {
    try checkId(group_id);
    return json(conn, allocator,
        \\SELECT coalesce(json_agg(f ORDER BY f.position), '[]')::text FROM (
        \\  SELECT position, function_name, file, line, col, wasm_function_index, wasm_offset,
        \\    coalesce(frame_type, 'unknown') AS frame_type
        \\  FROM stack_frames
        \\  WHERE error_report_id = (SELECT id FROM error_reports WHERE group_id = $1::uuid ORDER BY timestamp DESC LIMIT 1)
        \\) f
    , .{group_id}, "[]");
}

/// What the user did before a group's latest crash, oldest first; times are
/// Unix milliseconds, as text, and the arguments a one-string array.
pub fn events(conn: *pg.Conn, allocator: std.mem.Allocator, group_id: []const u8) ![]u8 {
    try checkId(group_id);
    return json(conn, allocator,
        \\SELECT coalesce(json_agg(e ORDER BY e.timestamp::bigint), '[]')::text FROM (
        \\  SELECT event_type, element_id,
        \\    CASE WHEN serialized_args IS NULL THEN NULL ELSE json_build_array(serialized_args::text) END AS serialized_args,
        \\    floor(extract(epoch FROM timestamp) * 1000)::bigint::text AS timestamp,
        \\    delta_ms
        \\  FROM trace_events
        \\  WHERE error_report_id = (SELECT id FROM error_reports WHERE group_id = $1::uuid ORDER BY timestamp DESC LIMIT 1)
        \\) e
    , .{group_id}, "[]");
}

/// The callback arguments of a group's latest report, as JSON; `null` when
/// there are none.
pub fn args(conn: *pg.Conn, allocator: std.mem.Allocator, group_id: []const u8) ![]u8 {
    try checkId(group_id);
    return json(conn, allocator,
        \\SELECT coalesce(
        \\  (SELECT callback_args::text FROM error_reports WHERE group_id = $1::uuid ORDER BY timestamp DESC LIMIT 1),
        \\  'null')
    , .{group_id}, "null");
}

/// Reports per hour over the last 24 hours, oldest first, with hours that
/// had none at zero; `fatal_count` counts wasm traps.
pub fn timeseries(conn: *pg.Conn, allocator: std.mem.Allocator) ![]u8 {
    return json(conn, allocator,
        \\SELECT json_agg(json_build_object(
        \\    'hour_epoch', extract(epoch FROM h.hour)::bigint,
        \\    'count', coalesce(c.count, 0),
        \\    'fatal_count', coalesce(c.fatal_count, 0)) ORDER BY h.hour)::text
        \\FROM generate_series(date_trunc('hour', now()) - interval '23 hours', date_trunc('hour', now()), interval '1 hour') AS h(hour)
        \\LEFT JOIN (
        \\  SELECT date_trunc('hour', timestamp) AS hour, count(*) AS count,
        \\    count(*) FILTER (WHERE is_wasm_trap) AS fatal_count
        \\  FROM error_reports
        \\  WHERE timestamp >= date_trunc('hour', now()) - interval '23 hours'
        \\  GROUP BY 1
        \\) c ON c.hour = h.hour
    , .{}, "[]");
}

pub const Status = enum { unresolved, resolved, ignored };

/// Sets a group's status. `error.NotFound` when there is no such group.
pub fn setStatus(conn: *pg.Conn, group_id: []const u8, status: Status) !void {
    try checkId(group_id);
    const changed = try exec(conn,
        \\UPDATE error_groups SET status = $2,
        \\  resolved_at = CASE WHEN $2 = 'resolved' THEN now() END
        \\WHERE id = $1::uuid
    , .{ group_id, @as([]const u8, @tagName(status)) });
    if (changed == 0) return error.NotFound;
}

/// Deletes a group and its reports. `error.NotFound` when there is no such
/// group.
pub fn deleteGroup(conn: *pg.Conn, group_id: []const u8) !void {
    try checkId(group_id);
    if (try exec(conn, "DELETE FROM error_groups WHERE id = $1::uuid", .{group_id}) == 0) return error.NotFound;
}

/// Deletes every resolved group and its reports; returns how many groups.
pub fn deleteResolved(conn: *pg.Conn) !i64 {
    return exec(conn, "DELETE FROM error_groups WHERE status = 'resolved'", .{});
}

/// `error.InvalidId` unless `id` is a UUID, so Postgres never sees it
/// malformed.
fn checkId(id: []const u8) !void {
    if (id.len != 36) return error.InvalidId;
    for (id, 0..) |c, i| switch (i) {
        8, 13, 18, 23 => if (c != '-') return error.InvalidId,
        else => if (!std.ascii.isHex(c)) return error.InvalidId,
    };
}

/// Runs a query whose one row's one column is the JSON. `when_missing`
/// stands for it before the tables exist.
fn json(conn: *pg.Conn, allocator: std.mem.Allocator, sql: []const u8, values: anytype, when_missing: []const u8) ![]u8 {
    var row = (conn.row(sql, values) catch |err| {
        if (undefinedTable(conn, err)) return allocator.dupe(u8, when_missing);
        return err;
    }) orelse return error.NothingReturned;
    defer row.deinit() catch {};
    return allocator.dupe(u8, try row.get([]const u8, 0));
}

/// The rows a statement changed; 0 before the tables exist.
fn exec(conn: *pg.Conn, sql: []const u8, values: anytype) !i64 {
    return (conn.exec(sql, values) catch |err| {
        if (undefinedTable(conn, err)) return 0;
        return err;
    }) orelse 0;
}

fn undefinedTable(conn: *pg.Conn, err: anyerror) bool {
    if (err != error.PG) return false;
    const pg_err = conn.err orelse return false;
    return std.mem.eql(u8, pg_err.code, "42P01");
}
