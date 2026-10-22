//! The tables, as pg-orm models: reverb's `src/store/queries/001` and `002`,
//! unchanged (a test compares them column by column). Times are
//! microseconds since the Unix epoch on the Zig side.
const std = @import("std");
const pg_orm = @import("pg_orm");
const pg = pg_orm.pg;
const defaults = pg_orm.schema.defaults;

/// Reports of one error, at one place.
pub const ErrorGroup = struct {
    id: [16]u8,
    fingerprint: []const u8,
    error_type: []const u8,
    message: []const u8,
    crash_function: ?[]const u8 = null,
    crash_file: ?[]const u8 = null,
    crash_line: ?i32 = null,
    is_wasm_trap: bool = false,
    occurrence_count: i32 = 1,
    first_seen: i64,
    last_seen: i64,
    /// "unresolved", "resolved", "ignored" or "regressed".
    status: []const u8 = "unresolved",
    resolved_at: ?i64 = null,
    created_at: i64,
    environment: ?[]const u8 = null,
    release: ?[]const u8 = null,
    route: ?[]const u8 = null,

    pub const orm = .{
        .table = "error_groups",
        .primary_key = .id,
        .schema = .{
            .id = .{ .default = defaults.gen_random_uuid },
            .fingerprint = .{ .not_null = true, .unique = true },
            .error_type = .{ .not_null = true },
            .message = .{ .not_null = true },
            .is_wasm_trap = .{ .not_null = true, .default = false },
            .occurrence_count = .{ .not_null = true, .default = 1 },
            .first_seen = .{ .type = .timestamptz, .not_null = true },
            .last_seen = .{ .type = .timestamptz, .not_null = true },
            .status = .{ .not_null = true, .default = "'unresolved'" },
            .resolved_at = .{ .type = .timestamptz },
            .created_at = .{ .type = .timestamptz, .not_null = true, .default = defaults.now },
        },
        .indexes = .{
            .{ .name = "idx_error_groups_status", .columns = .{.status} },
            .{ .name = "idx_error_groups_last_seen", .columns = .{.last_seen}, .descending = true },
            .{ .name = "idx_error_groups_environment", .columns = .{.environment} },
            .{ .name = "idx_error_groups_release", .columns = .{.release} },
        },
    };
};

/// One crash.
pub const ErrorReport = struct {
    id: [16]u8,
    group_id: [16]u8,
    error_id: []const u8,
    error_type: []const u8,
    message: []const u8,
    is_wasm_trap: bool = false,
    callback_args: ?[]const u8 = null,
    element_type: ?[]const u8 = null,
    route: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    timestamp: i64,
    crash_function: ?[]const u8 = null,
    crash_file: ?[]const u8 = null,
    crash_line: ?i32 = null,
    crash_column: ?i32 = null,
    crash_wasm_index: ?i32 = null,
    crash_wasm_offset: ?[]const u8 = null,
    crash_frame_type: ?[]const u8 = null,
    created_at: i64,
    url: ?[]const u8 = null,
    user_agent: ?[]const u8 = null,
    environment: ?[]const u8 = null,
    release: ?[]const u8 = null,
    user_id: ?[]const u8 = null,
    request_method: ?[]const u8 = null,
    request_url: ?[]const u8 = null,
    request_status_code: ?i32 = null,
    request_body: ?[]const u8 = null,
    request_elapsed_ms: ?i64 = null,

    pub const orm = .{
        .table = "error_reports",
        .primary_key = .id,
        .schema = .{
            .id = .{ .default = defaults.gen_random_uuid },
            .group_id = .{ .not_null = true, .references = "error_groups(id)", .on_delete = .cascade },
            .error_id = .{ .not_null = true },
            .error_type = .{ .not_null = true },
            .message = .{ .not_null = true },
            .is_wasm_trap = .{ .not_null = true, .default = false },
            .callback_args = .{ .type = .jsonb },
            .timestamp = .{ .type = .timestamptz, .not_null = true },
            .created_at = .{ .type = .timestamptz, .not_null = true, .default = defaults.now },
        },
        .indexes = .{
            .{ .name = "idx_error_reports_group_id", .columns = .{.group_id} },
            .{ .name = "idx_error_reports_timestamp", .columns = .{.timestamp}, .descending = true },
            .{ .name = "idx_error_reports_session", .columns = .{.session_id} },
            .{ .name = "idx_error_reports_user", .columns = .{.user_id} },
            .{ .name = "idx_error_reports_route", .columns = .{.route} },
        },
    };
};

/// A frame of a report's stack, innermost first.
pub const StackFrame = struct {
    id: [16]u8,
    error_report_id: [16]u8,
    position: i32,
    function_name: ?[]const u8 = null,
    file: ?[]const u8 = null,
    line: ?i32 = null,
    col: ?i32 = null,
    wasm_function_index: ?i32 = null,
    wasm_offset: ?[]const u8 = null,
    frame_type: ?[]const u8 = null,

    pub const orm = .{
        .table = "stack_frames",
        .primary_key = .id,
        .schema = .{
            .id = .{ .default = defaults.gen_random_uuid },
            .error_report_id = .{ .not_null = true, .references = "error_reports(id)", .on_delete = .cascade },
            .position = .{ .not_null = true },
        },
        .indexes = .{
            .{ .name = "idx_stack_frames_report", .columns = .{.error_report_id} },
        },
    };
};

/// Something the user did before a crash.
pub const TraceEvent = struct {
    id: [16]u8,
    error_report_id: [16]u8,
    event_type: []const u8,
    element_id: ?[]const u8 = null,
    serialized_args: ?[]const u8 = null,
    timestamp: i64,
    delta_ms: ?i32 = null,

    pub const orm = .{
        .table = "trace_events",
        .primary_key = .id,
        .schema = .{
            .id = .{ .default = defaults.gen_random_uuid },
            .error_report_id = .{ .not_null = true, .references = "error_reports(id)", .on_delete = .cascade },
            .event_type = .{ .not_null = true },
            .serialized_args = .{ .type = .jsonb },
            .timestamp = .{ .type = .timestamptz, .not_null = true },
        },
        .indexes = .{
            .{ .name = "idx_trace_events_report", .columns = .{.error_report_id} },
        },
    };
};

/// Parents before children, as the foreign keys need.
const models = .{ ErrorGroup, ErrorReport, StackFrame, TraceEvent };

/// Every statement that creates the tables and their indexes. Each one is
/// `IF NOT EXISTS`, so running them again changes nothing.
pub const ddl: []const []const u8 = blk: {
    var statements: []const []const u8 = &.{};
    for (models) |Model| {
        statements = statements ++ .{pg_orm.schema.createTableSql(Model)} ++ pg_orm.schema.createIndexesSql(Model);
    }
    break :blk statements;
};

/// Creates the tables and indexes that are missing, in one transaction.
/// Safe to call at every start.
pub fn migrate(pool: *pg.Pool) !void {
    const conn = try pool.acquire();
    defer pool.release(conn);
    try conn.begin();
    errdefer conn.rollback() catch {};
    for (ddl) |statement| _ = try conn.exec(statement, .{});
    try conn.commit();
}
