//! Writes a report: its group, the report, its stack and its events, in one
//! transaction. It blocks on Postgres, so a server calls it from a worker.
const std = @import("std");
const pg = @import("pg_orm").pg;
const Report = @import("Report.zig");
const fingerprint = @import("fingerprint.zig");

pub const Recorded = struct {
    /// UUIDs, as text.
    group_id: [36]u8,
    report_id: [36]u8,
};

/// Records `report`, cut to `Report.limits` first. `arena` holds what the
/// cut re-encodes. A group seen again counts one more; a resolved one
/// becomes "regressed", and an ignored one stays ignored.
pub fn record(pool: *pg.Pool, arena: std.mem.Allocator, report: Report) !Recorded {
    const r = try report.bounded(arena);
    const conn = try pool.acquire();
    defer pool.release(conn);
    try conn.begin();
    errdefer conn.rollback() catch {};

    const fp = fingerprint.compute(r);
    const crash = r.wasmError.crash_site orelse Report.StackFrame{};
    const group_id = try returningId(conn,
        \\INSERT INTO error_groups (
        \\  fingerprint, error_type, message, crash_function, crash_file, crash_line,
        \\  is_wasm_trap, first_seen, last_seen, environment, release, route
        \\) VALUES ($1, $2, $3, $4, $5, $6, $7, to_timestamp($8::bigint / 1e6), to_timestamp($8::bigint / 1e6), $9, $10, $11)
        \\ON CONFLICT (fingerprint) DO UPDATE SET
        \\  occurrence_count = error_groups.occurrence_count + 1,
        \\  last_seen = GREATEST(error_groups.last_seen, EXCLUDED.last_seen),
        \\  environment = COALESCE(EXCLUDED.environment, error_groups.environment),
        \\  release = COALESCE(EXCLUDED.release, error_groups.release),
        \\  route = COALESCE(EXCLUDED.route, error_groups.route),
        \\  status = CASE error_groups.status WHEN 'resolved' THEN 'regressed' ELSE error_groups.status END,
        \\  resolved_at = CASE error_groups.status WHEN 'resolved' THEN NULL ELSE error_groups.resolved_at END
        \\RETURNING id::text
    , .{
        @as([]const u8, &fp),     r.wasmError.type, r.wasmError.message,
        crash.function,           crash.file,       int(crash.line),
        r.wasmError.is_wasm_trap, r.timestamp,      r.environment,
        r.release,                r.route,
    });

    const rc = r.request_context orelse Report.RequestContext{};
    const report_id = try returningId(conn,
        \\INSERT INTO error_reports (
        \\  group_id, error_id, error_type, message, is_wasm_trap, callback_args, element_type,
        \\  timestamp, crash_function, crash_file, crash_line, crash_column,
        \\  crash_wasm_index, crash_wasm_offset, crash_frame_type,
        \\  route, url, session_id, user_agent, environment, release, user_id,
        \\  request_method, request_url, request_status_code, request_body, request_elapsed_ms
        \\) VALUES (
        \\  $1::uuid, $2, $3, $4, $5, $6::jsonb, $7,
        \\  to_timestamp($8::bigint / 1e6), $9, $10, $11, $12,
        \\  $13, $14, $15,
        \\  $16, $17, $18, $19, $20, $21, $22,
        \\  $23, $24, $25, $26, $27
        \\) RETURNING id::text
    , .{
        @as([]const u8, &group_id),                                                       r.element_id orelse "",
        r.wasmError.type,                                                                 r.wasmError.message,
        r.wasmError.is_wasm_trap,                                                         r.args,
        r.element_type,                                                                   r.timestamp,
        crash.function,                                                                   crash.file,
        int(crash.line),                                                                  int(crash.column),
        int(crash.wasm_function_index),                                                   crash.wasm_offset,
        if (r.wasmError.crash_site != null) @as(?[]const u8, crash.frame_type) else null, r.route,
        r.url,                                                                            r.session_id,
        r.user_agent,                                                                     r.environment,
        r.release,                                                                        r.user_id,
        if (r.request_context != null) @as(?[]const u8, rc.method) else null,             if (r.request_context != null) @as(?[]const u8, rc.url) else null,
        int(rc.status_code),                                                              rc.body,
        rc.elapsed_ms,
    });

    for (r.wasmError.user_stack, 0..) |frame, position| {
        _ = try conn.exec(
            \\INSERT INTO stack_frames (error_report_id, position, function_name, file, line, col,
            \\  wasm_function_index, wasm_offset, frame_type)
            \\VALUES ($1::uuid, $2, $3, $4, $5, $6, $7, $8, $9)
        , .{
            @as([]const u8, &report_id),    @as(i32, @intCast(position)), frame.function,
            frame.file,                     int(frame.line),              int(frame.column),
            int(frame.wasm_function_index), frame.wasm_offset,            frame.frame_type,
        });
    }

    for (r.events) |event| {
        _ = try conn.exec(
            \\INSERT INTO trace_events (error_report_id, event_type, element_id, serialized_args, timestamp, delta_ms)
            \\VALUES ($1::uuid, $2, $3, $4::jsonb, to_timestamp($5::bigint / 1e6), $6)
        , .{
            @as([]const u8, &report_id), event.event_type,                                                                                                               event.element_id, event.serialized_args,
            event.timestamp,
                // Milliseconds before the crash, negative; clamped to the column.
                        @as(i32, @intCast(std.math.clamp(@divTrunc(event.timestamp - r.timestamp, 1000), std.math.minInt(i32), std.math.maxInt(i32)))),
        });
    }

    try conn.commit();
    return .{ .group_id = group_id, .report_id = report_id };
}

/// Runs an `INSERT ... RETURNING id::text`.
fn returningId(conn: *pg.Conn, sql: []const u8, values: anytype) ![36]u8 {
    var row = (try conn.row(sql, values)) orelse return error.NothingReturned;
    defer row.deinit() catch {};
    const text = try row.get([]const u8, 0);
    if (text.len != 36) return error.UnexpectedId;
    return text[0..36].*;
}

/// The columns are `integer`; a report's numbers past that are dropped.
fn int(value: anytype) ?i32 {
    const v = value orelse return null;
    return std.math.cast(i32, v);
}
