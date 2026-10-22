//! The route a vapor app posts its crash reports to, on the app's own
//! reverb server. Recording blocks on Postgres, so it runs on workers of
//! its own and the reply waits for it.
//!
//! Anyone can post to the route; what it guards against is a report big
//! enough to hurt (see `Report.limits`), not a made-up one. With
//! `allowed_origin` set, browsers on other sites are refused too.
const std = @import("std");
const reverb = @import("reverb");
const pg = @import("pg_orm").pg;
const Report = @import("Report.zig");
const record = @import("record.zig").record;

pub const Options = struct {
    path: []const u8 = "/errors/report",
    /// When set, a request whose `Origin` is another is refused (403). A
    /// request with no `Origin` (not from a browser) is let through.
    allowed_origin: ?[]const u8 = null,
    threads: u16 = 1,
    /// Reports that may wait for a worker. Past this, a report answers 503.
    queue: u32 = 64,
};

const Job = struct {
    reply: *reverb.Reply,
    /// Owned by the job.
    body: []u8,
};

var state: struct {
    pool: *pg.Pool,
    options: Options,
    gpa: std.mem.Allocator,
    workers: reverb.Workers(Job, run),
} = undefined;
var running = false;

/// Starts the workers and adds the route. Call `deinit` once `listen` has
/// returned and before `server.deinit`. `gpa` must be threadsafe.
pub fn install(server: anytype, pool: *pg.Pool, options: Options, gpa: std.mem.Allocator, io: std.Io) !void {
    state = .{ .pool = pool, .options = options, .gpa = gpa, .workers = undefined };
    try state.workers.init(gpa, io, .{ .threads = options.threads, .queue = options.queue });
    running = true;
    errdefer deinit();
    try server.post(options.path, receive, &.{});
}

/// Stops the workers. Reports already queued are recorded and answered
/// first.
pub fn deinit() void {
    if (!running) return;
    state.workers.deinit();
    running = false;
}

fn receive(ctx: *reverb.Context) !void {
    if (state.options.allowed_origin) |allowed| {
        const origin = ctx.http_header.origin;
        if (origin.len > 0 and !std.mem.eql(u8, origin, allowed)) {
            return ctx.ERROR(403, "reports must come from the app's origin");
        }
    }
    const body = try state.gpa.dupe(u8, ctx.body());
    errdefer state.gpa.free(body);
    const reply = try ctx.deferReply();
    state.workers.submit(.{ .reply = reply, .body = body }) catch {
        state.gpa.free(body);
        reply.send(503, "text/plain; charset=utf-8", "too many reports are waiting");
    };
}

fn run(job: Job) void {
    defer state.gpa.free(job.body);
    var arena: std.heap.ArenaAllocator = .init(state.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const report = Report.parse(a, job.body) catch {
        return job.reply.send(400, "text/plain; charset=utf-8", "the body is not a crash report");
    };
    const recorded = record(state.pool, a, report) catch |err| {
        std.log.err("reverb-errors: could not record a report: {any}", .{err});
        return job.reply.send(500, "text/plain; charset=utf-8", "the report could not be recorded");
    };
    const answer = std.fmt.allocPrint(a, "{{\"group_id\":\"{s}\",\"report_id\":\"{s}\"}}", .{
        recorded.group_id, recorded.report_id,
    }) catch return job.reply.send(500, "text/plain; charset=utf-8", "out of memory");
    job.reply.send(201, "application/json", answer);
}
