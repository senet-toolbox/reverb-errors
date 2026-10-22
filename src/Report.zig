//! One crash, as a vapor app posts it: JSON, parsed with unknown fields
//! ignored. Times are microseconds since the Unix epoch.
//!
//! The shape is the one vapor's reporter sent to reverb's old
//! `/recordError`, so the tables and ryven's dashboard read it unchanged.
const std = @import("std");

const Report = @This();

/// The id of the element whose callback crashed, if one did.
element_id: ?[]const u8 = null,
element_type: ?[]const u8 = null,
/// The crashed callback's arguments, as JSON.
args: ?[]const u8 = null,
wasmError: WasmError,
/// What the user did before the crash, oldest first.
events: []const TraceEvent = &.{},
timestamp: i64,

/// The app's route, such as "/dashboard/settings".
route: ?[]const u8 = null,
/// The full browser URL.
url: ?[]const u8 = null,
session_id: ?[]const u8 = null,
user_agent: ?[]const u8 = null,
/// Such as "production".
environment: ?[]const u8 = null,
/// A version or a commit.
release: ?[]const u8 = null,
user_id: ?[]const u8 = null,
/// The fetch in flight when it crashed, if any.
request_context: ?RequestContext = null,

pub const WasmError = struct {
    /// Such as "RuntimeError".
    type: []const u8,
    message: []const u8,
    /// A trap (`unreachable`, out of bounds), not a thrown JS error.
    is_wasm_trap: bool = false,
    crash_site: ?StackFrame = null,
    user_stack: []const StackFrame = &.{},
};

pub const StackFrame = struct {
    function: ?[]const u8 = null,
    wasm_function_index: ?u32 = null,
    wasm_offset: ?[]const u8 = null,
    file: ?[]const u8 = null,
    line: ?u32 = null,
    column: ?u32 = null,
    /// "wasm", "js" or "unknown".
    frame_type: []const u8 = "unknown",
};

pub const TraceEvent = struct {
    timestamp: i64,
    /// Such as "click" or "input".
    event_type: []const u8,
    element_id: ?[]const u8 = null,
    /// JSON.
    serialized_args: ?[]const u8 = null,
};

pub const RequestContext = struct {
    method: []const u8 = "GET",
    url: []const u8 = "",
    status_code: ?u32 = null,
    body: ?[]const u8 = null,
    elapsed_ms: ?i64 = null,
};

/// The most of each kind a report keeps: anyone can post to the route, so
/// one report cannot fill the database.
pub const limits = struct {
    pub const frames = 64;
    pub const events = 100;
    /// Bytes of a message, a request body or callback arguments.
    pub const long_text = 8 * 1024;
    /// Bytes of any other string.
    pub const text = 1024;
};

/// Parses a report from JSON, into `arena`.
pub fn parse(arena: std.mem.Allocator, json: []const u8) !Report {
    return std.json.parseFromSliceLeaky(Report, arena, json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

/// The report cut to `limits`, with JSON fields that do not parse kept as
/// JSON strings. Allocates from `arena` only to re-encode those.
pub fn bounded(r: Report, arena: std.mem.Allocator) !Report {
    var out = r;
    out.element_id = cut(r.element_id, limits.text);
    out.element_type = cut(r.element_type, limits.text);
    out.args = try asJson(arena, cut(r.args, limits.long_text));
    out.wasmError.type = cut(r.wasmError.type, limits.text).?;
    out.wasmError.message = cut(r.wasmError.message, limits.long_text).?;
    out.wasmError.crash_site = if (r.wasmError.crash_site) |site| boundedFrame(site) else null;
    const stack = r.wasmError.user_stack[0..@min(r.wasmError.user_stack.len, limits.frames)];
    const frames = try arena.alloc(StackFrame, stack.len);
    for (stack, frames) |frame, *f| f.* = boundedFrame(frame);
    out.wasmError.user_stack = frames;
    // The last ones: those right before the crash.
    const recent = r.events[r.events.len - @min(r.events.len, limits.events) ..];
    const events = try arena.alloc(TraceEvent, recent.len);
    for (recent, events) |event, *e| e.* = .{
        .timestamp = event.timestamp,
        .event_type = cut(event.event_type, limits.text).?,
        .element_id = cut(event.element_id, limits.text),
        .serialized_args = try asJson(arena, cut(event.serialized_args, limits.long_text)),
    };
    out.events = events;
    out.route = cut(r.route, limits.text);
    out.url = cut(r.url, limits.text);
    out.session_id = cut(r.session_id, limits.text);
    out.user_agent = cut(r.user_agent, limits.text);
    out.environment = cut(r.environment, limits.text);
    out.release = cut(r.release, limits.text);
    out.user_id = cut(r.user_id, limits.text);
    if (r.request_context) |rc| out.request_context = .{
        .method = cut(rc.method, limits.text).?,
        .url = cut(rc.url, limits.text).?,
        .status_code = rc.status_code,
        .body = cut(rc.body, limits.long_text),
        .elapsed_ms = rc.elapsed_ms,
    };
    return out;
}

fn boundedFrame(f: StackFrame) StackFrame {
    return .{
        .function = cut(f.function, limits.text),
        .wasm_function_index = f.wasm_function_index,
        .wasm_offset = cut(f.wasm_offset, limits.text),
        .file = cut(f.file, limits.text),
        .line = f.line,
        .column = f.column,
        .frame_type = cut(f.frame_type, limits.text).?,
    };
}

/// At most `max` bytes, cut back to a whole UTF-8 character.
fn cut(s: ?[]const u8, max: usize) ?[]const u8 {
    const text = s orelse return null;
    if (text.len <= max) return text;
    var end = max;
    while (end > 0 and text[end] & 0xC0 == 0x80) end -= 1;
    return text[0..end];
}

/// `s` if it is JSON, else `s` encoded as a JSON string. A cut can leave
/// JSON unfinished, and the columns are `jsonb`.
fn asJson(arena: std.mem.Allocator, s: ?[]const u8) !?[]const u8 {
    const text = s orelse return null;
    if (try std.json.validate(arena, text)) return text;
    return try std.json.Stringify.valueAlloc(arena, text, .{});
}

test "a report parses, ignoring fields it does not know" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(),
        \\{"element_id":"btn-1","args":"{\"n\":1}","timestamp":1771446261518000,
        \\ "wasmError":{"type":"RuntimeError","message":"unreachable","is_wasm_trap":true,
        \\   "crash_site":{"function":"main.save","wasm_function_index":841,"wasm_offset":"0xbd070","frame_type":"wasm"},
        \\   "user_stack":[{"function":"main.save","frame_type":"wasm"},{"function":"main.onClick","file":"src/main.zig","line":12}]},
        \\ "events":[{"timestamp":1771446261000000,"event_type":"click","element_id":"btn-1","serialized_args":"{}"}],
        \\ "route":"/settings","something_new":42}
    );
    try std.testing.expectEqualStrings("main.save", r.wasmError.crash_site.?.function.?);
    try std.testing.expectEqual(2, r.wasmError.user_stack.len);
    try std.testing.expectEqualStrings("unknown", r.wasmError.user_stack[1].frame_type);
    try std.testing.expectEqualStrings("/settings", r.route.?);
}

test "bounded keeps a report to its limits" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const frames = try a.alloc(StackFrame, limits.frames + 10);
    for (frames) |*f| f.* = .{};
    const events = try a.alloc(TraceEvent, limits.events + 5);
    for (events, 0..) |*e, i| e.* = .{ .timestamp = @intCast(i), .event_type = "click" };
    // "é" is two bytes; a cut must not split it.
    const message = try a.alloc(u8, limits.long_text + 1);
    @memset(message, 'x');
    message[limits.long_text - 1] = 0xC3;
    message[limits.long_text] = 0xA9;
    const r = try bounded(.{
        .wasmError = .{ .type = "RuntimeError", .message = message, .user_stack = frames },
        .events = events,
        .timestamp = 0,
        .args = "{\"cut\": \"half",
    }, a);
    try std.testing.expectEqual(limits.frames, r.wasmError.user_stack.len);
    try std.testing.expectEqual(limits.events, r.events.len);
    // The most recent events are the ones kept.
    try std.testing.expectEqual(limits.events + 4, r.events[r.events.len - 1].timestamp);
    try std.testing.expectEqual(limits.long_text - 1, r.wasmError.message.len);
    try std.testing.expectEqualStrings("\"{\\\"cut\\\": \\\"half\"", r.args.?);
}
