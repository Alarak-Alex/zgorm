const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dsn_opt = b.option([]const u8, "dsn", "PostgreSQL DSN (example + integration tests)");

    // Library module "zorm".
    const mod = b.addModule("zorm", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Example executable.
    const example = b.addExecutable(.{
        .name = "zorm-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("example/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zorm", .module = mod },
            },
        }),
    });
    b.installArtifact(example);

    const run_step = b.step("run", "Run the example (set ZORM_DSN to override)");
    const run_cmd = b.addRunArtifact(example);
    if (dsn_opt) |dsn| run_cmd.setEnvironmentVariable("ZORM_DSN", dsn);
    run_step.dependOn(&run_cmd.step);

    // Unit tests.
    const unit_tests = b.addTest(.{ .root_module = mod });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Integration tests against a real PostgreSQL. Skipped unless a DSN is
    // provided:  zig build test-integration -Ddsn='postgres://...'
    const test_options = b.addOptions();
    test_options.addOption(?[]const u8, "dsn", dsn_opt);
    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zorm", .module = mod },
                .{ .name = "test_options", .module = test_options.createModule() },
            },
        }),
    });
    // The test binary inherits the invoking environment, so ZORM_DSN set on
    // the `zig build` command line is visible to it.
    const run_integration = b.addRunArtifact(integration_tests);
    const integration_step = b.step("test-integration", "Run integration tests (requires ZORM_DSN)");
    integration_step.dependOn(&run_integration.step);
}
