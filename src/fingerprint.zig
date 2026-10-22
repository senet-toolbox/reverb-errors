//! What groups reports together: the same error at the same place.
const std = @import("std");
const Report = @import("Report.zig");

/// SHA-256, in hex, of `type::function::file::line::message`.
///
/// Crashes at one place group even when the message varies; the message
/// tells apart errors with no crash site (a JS error with no wasm frame).
/// Unchanged from reverb's `src/errors/fingerprint.zig`, so groups recorded
/// by it still match.
pub fn compute(report: Report) [64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});

    hasher.update(report.wasmError.type);
    hasher.update("::");

    if (report.wasmError.crash_site) |cs| {
        hasher.update(cs.function orelse "");
        hasher.update("::");
        hasher.update(cs.file orelse "");
        hasher.update("::");
        if (cs.line) |line| {
            var buf: [16]u8 = undefined;
            hasher.update(std.fmt.bufPrint(&buf, "{d}", .{line}) catch unreachable);
        }
    } else {
        hasher.update("::");
        hasher.update("::");
    }

    hasher.update("::");
    hasher.update(report.wasmError.message);

    return std.fmt.bytesToHex(hasher.finalResult(), .lower);
}

const trap: Report = .{
    .wasmError = .{
        .type = "RuntimeError",
        .message = "unreachable",
        .is_wasm_trap = true,
        .crash_site = .{ .function = "main.sample", .wasm_function_index = 841, .wasm_offset = "0xbd070", .frame_type = "wasm" },
    },
    .timestamp = 1234567890,
};

test "the same crash has the same fingerprint" {
    var later = trap;
    later.timestamp += 1;
    later.route = "/elsewhere";
    try std.testing.expectEqualSlices(u8, &compute(trap), &compute(later));
}

test "the fingerprint is reverb's" {
    // `printf '%s' 'RuntimeError::main.sample::::::unreachable' | shasum -a 256`:
    // the string reverb's `compute` hashes for this report.
    try std.testing.expectEqualStrings(
        "4c4d976e0df597a30a07f0b0ea1f84410122dec80af23e3a80507f1e0ede1a5a",
        &compute(trap),
    );
}

test "another crash site is another group" {
    var other = trap;
    other.wasmError.crash_site = .{ .function = "main.other", .frame_type = "wasm" };
    try std.testing.expect(!std.mem.eql(u8, &compute(trap), &compute(other)));
}

test "with no crash site, the message tells errors apart" {
    var a = trap;
    a.wasmError.crash_site = null;
    var b = a;
    b.wasmError.message = "x is not a function";
    try std.testing.expect(!std.mem.eql(u8, &compute(a), &compute(b)));
}
