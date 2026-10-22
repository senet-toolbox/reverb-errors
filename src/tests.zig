//! Against a real Postgres (`TEST_DATABASE_URL`, by default the 54329
//! container ryven and assembler-backend test against), and the route on a
//! real server over a socket. Skipped, saying so, when no database answers.
//!
//! Each test works in a schema of its own, `reverb_errors_test`, dropped
//! after it.
const std = @import("std");
const testing = std.testing;
const reverb = @import("reverb");
const pg = @import("pg_orm").pg;
const errors = @import("root.zig");
const Report = errors.Report;

test {
    _ = @import("Report.zig");
    _ = @import("fingerprint.zig");
    testing.refAllDecls(errors);
}

const default_test_database_url = "postgres://postgres:postgres@127.0.0.1:54329/assembler_test";
const schema_name = "reverb_errors_test";

/// One connection, so the `search_path` set on it holds for everything.
const TestDb = struct {
    pool: *pg.Pool,

    fn open() !TestDb {
        var env = try testing.environ.createMap(testing.allocator);
        defer env.deinit();
        const uri = try std.Uri.parse(env.get("TEST_DATABASE_URL") orelse default_test_database_url);
        // Probed first: pg logs a refused connection as an error, which
        // fails the test it was meant to skip.
        var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
        const host = try uri.getHost(&host_buf);
        const address = try std.Io.net.IpAddress.parse(host.bytes, uri.port orelse 5432);
        const probe = address.connect(testing.io, .{ .mode = .stream }) catch |err| {
            std.debug.print("skipped: no test database at {s}:{d} ({any})\n", .{ host.bytes, uri.port orelse 5432, err });
            return error.SkipZigTest;
        };
        probe.close(testing.io);
        const pool = try pg.Pool.initUri(testing.io, testing.allocator, uri, .{ .size = 1 });
        errdefer pool.deinit();
        try simple(pool, "DROP SCHEMA IF EXISTS " ++ schema_name ++ " CASCADE; CREATE SCHEMA " ++ schema_name ++ "; SET search_path TO " ++ schema_name);
        return .{ .pool = pool };
    }

    fn close(db: TestDb) void {
        simple(db.pool, "DROP SCHEMA IF EXISTS " ++ schema_name ++ " CASCADE") catch {};
        db.pool.deinit();
    }

    /// Calls one of `errors.read` on the pool's connection.
    fn read(db: TestDb, comptime f: anytype, args: anytype) anyerror!@typeInfo(@typeInfo(@TypeOf(f)).@"fn".return_type.?).error_union.payload {
        const conn = try db.pool.acquire();
        defer db.pool.release(conn);
        return @call(.auto, f, .{conn} ++ args);
    }

    fn migrated() !TestDb {
        const db = try open();
        errdefer db.close();
        try errors.migrate(db.pool);
        return db;
    }

    fn count(db: TestDb, comptime sql: []const u8) !i64 {
        var row = (try db.pool.row(sql, .{})).?;
        defer row.deinit() catch {};
        return row.get(i64, 0);
    }

    fn text(db: TestDb, allocator: std.mem.Allocator, comptime sql: []const u8) ![]u8 {
        var row = (try db.pool.row(sql, .{})).?;
        defer row.deinit() catch {};
        return allocator.dupe(u8, try row.get([]const u8, 0));
    }
};

/// Several statements, as Postgres's simple query protocol takes them.
fn simple(pool: *pg.Pool, sql: []const u8) !void {
    const conn = try pool.acquire();
    defer pool.release(conn);
    try conn.execIgnoringState(sql);
}

fn trap(message: []const u8) Report {
    return .{
        .element_id = "save-button",
        .args = "{\"draft\":7}",
        .wasmError = .{
            .type = "RuntimeError",
            .message = message,
            .is_wasm_trap = true,
            .crash_site = .{ .function = "main.save", .file = "src/main.zig", .line = 41, .wasm_function_index = 841, .wasm_offset = "0xbd070", .frame_type = "wasm" },
            .user_stack = &.{
                .{ .function = "main.save", .file = "src/main.zig", .line = 41, .frame_type = "wasm" },
                .{ .function = "main.onClick", .file = "src/main.zig", .line = 12, .frame_type = "wasm" },
            },
        },
        .events = &.{
            .{ .timestamp = 1_771_446_260_000_000, .event_type = "input", .element_id = "title", .serialized_args = "{\"value\":\"hi\"}" },
            .{ .timestamp = 1_771_446_261_000_000, .event_type = "click", .element_id = "save-button" },
        },
        .timestamp = 1_771_446_261_500_000,
        .route = "/drafts",
        .environment = "production",
        .release = "1.2.3",
        .request_context = .{ .method = "POST", .url = "/api/drafts", .status_code = 500, .elapsed_ms = 12 },
    };
}

test "migrate builds reverb's tables, columns, constraints and indexes, exactly" {
    const db = try TestDb.open();
    defer db.close();
    try simple(db.pool, "CREATE SCHEMA reverb_errors_reverb; SET search_path TO reverb_errors_reverb;\n" ++
        @embedFile("testdata/reverb_001_create_error_tables.sql") ++ "\n" ++
        @embedFile("testdata/reverb_002_context_columns.sql") ++
        "\nSET search_path TO " ++ schema_name);
    defer simple(db.pool, "DROP SCHEMA reverb_errors_reverb CASCADE") catch {};
    try errors.migrate(db.pool);
    // Again: every statement is IF NOT EXISTS.
    try errors.migrate(db.pool);

    // Each of these lists a property of one schema; the two schemas must
    // list the same rows.
    const properties = [_][]const u8{
        "SELECT table_name, column_name, ordinal_position, data_type, is_nullable, column_default FROM information_schema.columns WHERE table_schema = $1",
        "SELECT table_name, constraint_name, constraint_type FROM information_schema.table_constraints WHERE table_schema = $1 AND constraint_type <> 'CHECK'",
        "SELECT constraint_name, delete_rule FROM information_schema.referential_constraints WHERE constraint_schema = $1",
        "SELECT tablename, indexname, replace(indexdef, $1 || '.', '') FROM pg_indexes WHERE schemaname = $1",
    };
    var columns: i64 = 0;
    for (properties) |property| {
        const reverb_side = try std.mem.replaceOwned(u8, testing.allocator, property, "$1", "'reverb_errors_reverb'");
        defer testing.allocator.free(reverb_side);
        const model_side = try std.mem.replaceOwned(u8, testing.allocator, property, "$1", "'" ++ schema_name ++ "'");
        defer testing.allocator.free(model_side);
        const sql = try std.fmt.allocPrint(testing.allocator,
            \\SELECT (SELECT count(*) FROM (({0s}) EXCEPT ({1s})) a) + (SELECT count(*) FROM (({1s}) EXCEPT ({0s})) b),
            \\       (SELECT count(*) FROM ({0s}) c)
        , .{ reverb_side, model_side });
        defer testing.allocator.free(sql);
        var row = (try db.pool.row(sql, .{})).?;
        defer row.deinit() catch {};
        const differences = try row.get(i64, 0);
        if (differences != 0) std.debug.print("differs: {s}\n", .{property});
        try testing.expectEqual(0, differences);
        if (columns == 0) columns = try row.get(i64, 1);
    }
    // error_groups 17, error_reports 29, stack_frames 10, trace_events 7.
    try testing.expectEqual(63, columns);
}

test "record writes the group, the report, its stack and its events" {
    const db = try TestDb.migrated();
    defer db.close();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const recorded = try errors.record(db.pool, a, trap("unreachable"));
    try testing.expectEqual(1, try db.count("SELECT count(*) FROM error_groups"));
    try testing.expectEqualStrings("RuntimeError|main.save|41|t|1|unresolved|production|/drafts", try db.text(a,
        \\SELECT concat_ws('|', error_type, crash_function, crash_line, is_wasm_trap, occurrence_count, status, environment, route)
        \\FROM error_groups
    ));
    try testing.expectEqualStrings(&errors.fingerprint(trap("unreachable")), try db.text(a, "SELECT fingerprint FROM error_groups"));
    try testing.expectEqualStrings("save-button|{\"draft\": 7}|1771446261500000|wasm|POST|500|12", try db.text(a,
        \\SELECT concat_ws('|', error_id, callback_args, (extract(epoch FROM timestamp) * 1e6)::bigint, crash_frame_type,
        \\  request_method, request_status_code, request_elapsed_ms)
        \\FROM error_reports
    ));
    try testing.expectEqualStrings("0 main.save, 1 main.onClick", try db.text(
        a,
        "SELECT string_agg(position || ' ' || function_name, ', ' ORDER BY position) FROM stack_frames",
    ));
    // Milliseconds before the crash.
    try testing.expectEqualStrings("input -1500 {\"value\": \"hi\"}, click -500 ", try db.text(
        a,
        "SELECT string_agg(concat(event_type, ' ', delta_ms, ' ', serialized_args), ', ' ORDER BY timestamp) FROM trace_events",
    ));
    try testing.expectEqualStrings(&recorded.group_id, try db.text(a, "SELECT id::text FROM error_groups"));
}

test "the same crash counts again; a resolved group regresses, an ignored one stays ignored" {
    const db = try TestDb.migrated();
    defer db.close();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const first = try errors.record(db.pool, a, trap("unreachable"));
    var later = trap("unreachable");
    later.timestamp += 60_000_000;
    later.release = "1.2.4";
    const second = try errors.record(db.pool, a, later);
    try testing.expectEqualStrings(&first.group_id, &second.group_id);
    try testing.expect(!std.mem.eql(u8, &first.report_id, &second.report_id));
    try testing.expectEqualStrings("2|1.2.4|60", try db.text(
        a,
        "SELECT concat_ws('|', occurrence_count, release, extract(epoch FROM last_seen - first_seen)::int) FROM error_groups",
    ));

    try db.read(errors.read.setStatus, .{ &first.group_id, .resolved });
    try testing.expectEqual(1, try db.count("SELECT count(*) FROM error_groups WHERE resolved_at IS NOT NULL"));
    _ = try errors.record(db.pool, a, trap("unreachable"));
    try testing.expectEqualStrings("regressed|", try db.text(a, "SELECT concat(status, '|', resolved_at) FROM error_groups"));

    try db.read(errors.read.setStatus, .{ &first.group_id, .ignored });
    _ = try errors.record(db.pool, a, trap("unreachable"));
    try testing.expectEqualStrings("ignored|4", try db.text(a, "SELECT concat(status, '|', occurrence_count) FROM error_groups"));

    // With no crash site, another message is another group.
    var elsewhere = trap("index out of bounds");
    elsewhere.wasmError.crash_site = null;
    _ = try errors.record(db.pool, a, elsewhere);
    try testing.expectEqual(2, try db.count("SELECT count(*) FROM error_groups"));
}

test "a report that fails part way leaves nothing behind" {
    const db = try TestDb.migrated();
    defer db.close();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // The last write, the events, fails.
    try simple(db.pool, "ALTER TABLE trace_events ADD CONSTRAINT no_clicks CHECK (event_type <> 'click')");
    try testing.expectError(error.PG, errors.record(db.pool, arena.allocator(), trap("unreachable")));
    try testing.expectEqual(0, try db.count("SELECT (SELECT count(*) FROM error_groups) + (SELECT count(*) FROM error_reports) + (SELECT count(*) FROM stack_frames)"));
    // And the connection is fine for the next one.
    try simple(db.pool, "ALTER TABLE trace_events DROP CONSTRAINT no_clicks");
    _ = try errors.record(db.pool, arena.allocator(), trap("unreachable"));
    try testing.expectEqual(1, try db.count("SELECT count(*) FROM error_groups"));
}

test "the reads give ryven's /errors page its shapes" {
    const db = try TestDb.migrated();
    defer db.close();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const recorded = try errors.record(db.pool, a, trap("unreachable"));
    const id: []const u8 = &recorded.group_id;

    // The structs ryven's ErrorStore parses into.
    const Group = struct { id: []const u8, fingerprint: []const u8, error_type: []const u8, message: []const u8, crash_function: ?[]const u8, crash_file: ?[]const u8, crash_line: ?i32, is_wasm_trap: bool, occurrence_count: i64, first_seen: []const u8, last_seen: []const u8, status: []const u8, environment: ?[]const u8, release: ?[]const u8, route: ?[]const u8 };
    const groups = try std.json.parseFromSliceLeaky([]Group, a, try db.read(errors.read.groups, .{a}), .{});
    try testing.expectEqual(1, groups.len);
    try testing.expectEqualStrings(id, groups[0].id);
    // Unix seconds, as text.
    try testing.expectEqualStrings("1771446261", groups[0].last_seen);
    try testing.expectEqualStrings("main.save", groups[0].crash_function.?);

    const Frame = struct { position: i32, function_name: ?[]const u8, file: ?[]const u8, line: ?i32, col: ?i32, wasm_function_index: ?i32, wasm_offset: ?[]const u8, frame_type: []const u8 };
    const frames = try std.json.parseFromSliceLeaky([]Frame, a, try db.read(errors.read.frames, .{ a, id }), .{});
    try testing.expectEqual(2, frames.len);
    try testing.expectEqualStrings("main.onClick", frames[1].function_name.?);

    const Event = struct { event_type: []const u8, element_id: ?[]const u8, serialized_args: ?[]const []const u8, timestamp: []const u8, delta_ms: ?i32 };
    const events = try std.json.parseFromSliceLeaky([]Event, a, try db.read(errors.read.events, .{ a, id }), .{});
    try testing.expectEqual(2, events.len);
    try testing.expectEqualStrings("{\"value\": \"hi\"}", events[0].serialized_args.?[0]);
    try testing.expectEqual(null, events[1].serialized_args);
    try testing.expectEqualStrings("1771446260000", events[0].timestamp);

    try testing.expectEqualStrings("{\"draft\": 7}", try db.read(errors.read.args, .{ a, id }));

    const Point = struct { hour_epoch: i64, count: i64, fatal_count: i64 };
    // The report is from February; move it to two hours ago.
    try simple(db.pool, "UPDATE error_reports SET timestamp = now() - interval '2 hours'");
    const points = try std.json.parseFromSliceLeaky([]Point, a, try db.read(errors.read.timeseries, .{a}), .{});
    try testing.expectEqual(24, points.len);
    try testing.expectEqual(1, points[21].count);
    try testing.expectEqual(1, points[21].fatal_count);
    try testing.expectEqual(0, points[22].count);
    try testing.expectEqual(3600, points[23].hour_epoch - points[22].hour_epoch);

    // An unknown group, and a malformed id.
    const unknown = "00000000-0000-0000-0000-000000000000";
    try testing.expectEqualStrings("[]", try db.read(errors.read.frames, .{ a, unknown }));
    try testing.expectEqualStrings("null", try db.read(errors.read.args, .{ a, unknown }));
    try testing.expectError(error.InvalidId, db.read(errors.read.frames, .{ a, "1; DROP TABLE error_groups" }));
    try testing.expectError(error.NotFound, db.read(errors.read.setStatus, .{ unknown, .resolved }));
    try testing.expectError(error.NotFound, db.read(errors.read.deleteGroup, .{unknown}));
}

test "deleting a group takes its reports, frames and events with it" {
    const db = try TestDb.migrated();
    defer db.close();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const kept = try errors.record(db.pool, a, trap("kept"));
    var resolved_report = trap("resolved");
    resolved_report.wasmError.crash_site = null;
    const resolved = try errors.record(db.pool, a, resolved_report);
    var deleted_report = trap("deleted");
    deleted_report.wasmError.crash_site.?.line = 99;
    const deleted = try errors.record(db.pool, a, deleted_report);

    try db.read(errors.read.deleteGroup, .{&deleted.group_id});
    try db.read(errors.read.setStatus, .{ &resolved.group_id, .resolved });
    try testing.expectEqual(1, try db.read(errors.read.deleteResolved, .{}));
    try testing.expectEqualStrings(&kept.group_id, try db.text(a, "SELECT string_agg(id::text, ',') FROM error_groups"));
    try testing.expectEqual(1, try db.count("SELECT count(*) FROM error_reports"));
    try testing.expectEqual(2, try db.count("SELECT count(*) FROM stack_frames"));
    try testing.expectEqual(2, try db.count("SELECT count(*) FROM trace_events"));
}

test "before the tables exist, the lists are empty" {
    const db = try TestDb.open();
    defer db.close();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const id = "00000000-0000-0000-0000-000000000000";
    try testing.expectEqualStrings("[]", try db.read(errors.read.groups, .{a}));
    try testing.expectEqualStrings("[]", try db.read(errors.read.events, .{ a, id }));
    try testing.expectEqualStrings("[]", try db.read(errors.read.timeseries, .{a}));
    try testing.expectEqual(0, try db.read(errors.read.deleteResolved, .{}));
    try testing.expectError(error.NotFound, db.read(errors.read.setStatus, .{ id, .resolved }));
}

// ── the route ──────────────────────────────────────────────────────────────

const Config = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 0,
    max: usize = 64,
    max_body_size: usize = 256 * 1024,
};
const Server = reverb.Server(Config);
const app_origin = "https://app.test";

const Harness = struct {
    arena: std.heap.ArenaAllocator,
    server: Server,
    thread: std.Thread,
    port: u16,

    /// `h` must not move while the server runs.
    fn start(h: *Harness, db: TestDb) !void {
        h.arena = .init(testing.allocator);
        errdefer h.arena.deinit();
        try h.server.new(.{}, h.arena.allocator());
        errdefer h.server.deinit();
        // Leak-checks every reply.
        h.server.reply_allocator = testing.allocator;
        try errors.install(&h.server, db.pool, .{ .allowed_origin = app_origin }, testing.allocator, testing.io);
        errdefer errors.deinit();
        try h.server.bindListener();
        h.port = try h.server.boundPort();
        h.thread = try std.Thread.spawn(.{}, serve, .{&h.server});
    }

    fn serve(server: *Server) void {
        server.listen() catch |err| std.debug.print("test server stopped: {any}\n", .{err});
    }

    fn stop(h: *Harness) void {
        h.server.stop();
        h.thread.join();
        errors.deinit();
        h.server.deinit();
        h.arena.deinit();
    }

    /// Posts a report. Caller frees the body.
    fn post(h: *Harness, headers: []const u8, body: []const u8) !Response {
        const request = try std.fmt.allocPrint(
            testing.allocator,
            "POST /errors/report HTTP/1.1\r\nHost: x\r\n{s}Content-Type: text/plain\r\nContent-Length: {d}\r\n\r\n{s}",
            .{ headers, body.len, body },
        );
        defer testing.allocator.free(request);
        const io = testing.io;
        const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(h.port) };
        const stream = try address.connect(io, .{ .mode = .stream });
        defer stream.close(io);
        var write_buf: [4096]u8 = undefined;
        var writer = stream.writer(io, &write_buf);
        try writer.interface.writeAll(request);
        try writer.interface.flush();

        var read_buf: [16 * 1024]u8 = undefined;
        var reader = stream.reader(io, &read_buf);
        var head: std.ArrayList(u8) = .empty;
        defer head.deinit(testing.allocator);
        while (!std.mem.endsWith(u8, head.items, "\r\n\r\n")) try head.append(testing.allocator, try reader.interface.takeByte());
        const status = try std.fmt.parseInt(u16, head.items[9..12], 10);
        const length_header = "Content-Length: ";
        const at = std.mem.indexOf(u8, head.items, length_header) orelse return error.NoContentLength;
        const end = std.mem.indexOfPos(u8, head.items, at, "\r\n").?;
        const length = try std.fmt.parseInt(usize, head.items[at + length_header.len .. end], 10);
        return .{ .status = status, .body = try reader.interface.readAlloc(testing.allocator, length) };
    }
};

const Response = struct { status: u16, body: []u8 };

fn reportJson(allocator: std.mem.Allocator, report: Report) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, report, .{});
}

test "the route records a report from the app, and refuses other sites and junk" {
    const db = try TestDb.migrated();
    defer db.close();
    var h: Harness = undefined;
    try h.start(db);
    defer h.stop();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = try reportJson(a, trap("unreachable"));

    const ok = try h.post("Origin: " ++ app_origin ++ "\r\n", body);
    defer testing.allocator.free(ok.body);
    try testing.expectEqual(201, ok.status);
    const Ids = struct { group_id: []const u8, report_id: []const u8 };
    const ids = try std.json.parseFromSliceLeaky(Ids, a, ok.body, .{});
    try testing.expectEqualStrings(ids.group_id, try db.text(a, "SELECT id::text FROM error_groups"));

    // Not from a browser: no Origin.
    const server_side = try h.post("", body);
    defer testing.allocator.free(server_side.body);
    try testing.expectEqual(201, server_side.status);

    const elsewhere = try h.post("Origin: https://elsewhere.test\r\n", body);
    defer testing.allocator.free(elsewhere.body);
    try testing.expectEqual(403, elsewhere.status);

    const junk = try h.post("Origin: " ++ app_origin ++ "\r\n", "{\"wasmError\": 3}");
    defer testing.allocator.free(junk.body);
    try testing.expectEqual(400, junk.status);

    try testing.expectEqual(2, try db.count("SELECT count(*) FROM error_reports"));
}

test "the route keeps a huge report to the limits" {
    const db = try TestDb.migrated();
    defer db.close();
    var h: Harness = undefined;
    try h.start(db);
    defer h.stop();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var report = trap("unreachable");
    const frames = try a.alloc(Report.StackFrame, 1000);
    for (frames) |*f| f.* = .{ .function = "deep" };
    report.wasmError.user_stack = frames;
    const events = try a.alloc(Report.TraceEvent, 1000);
    for (events) |*e| e.* = .{ .timestamp = report.timestamp, .event_type = "mousemove" };
    report.events = events;

    const res = try h.post("", try reportJson(a, report));
    defer testing.allocator.free(res.body);
    try testing.expectEqual(201, res.status);
    try testing.expectEqual(Report.limits.frames, try db.count("SELECT count(*) FROM stack_frames"));
    try testing.expectEqual(Report.limits.events, try db.count("SELECT count(*) FROM trace_events"));
}
