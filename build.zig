const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const reverb = b.dependency("reverb", .{ .target = target, .optimize = optimize });
    const pg_orm = b.dependency("pg_orm", .{ .target = target, .optimize = optimize });
    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "reverb", .module = reverb.module("reverb") },
        .{ .name = "pg_orm", .module = pg_orm.module("pg_orm") },
    };

    // Error reports from vapor apps, stored in the app's own Postgres:
    // the tables, `record`, the route vapor posts to, and the reads a
    // dashboard (ryven) shows.
    _ = b.addModule("reverb_errors", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports,
    });

    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports,
    }) });
    const run_tests = b.addRunArtifact(tests);
    // The test database is an input the cache cannot see.
    run_tests.has_side_effects = true;
    const test_step = b.step("test", "Run the tests");
    test_step.dependOn(&run_tests.step);
}
