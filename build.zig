const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dsn_opt = b.option([]const u8, "dsn", "PostgreSQL DSN (example + integration tests)");
    const mysql_port = b.option(u16, "mysql-port", "MySQL/MariaDB port for driver tests");
    const mysql_host = b.option([]const u8, "mysql-host", "MySQL/MariaDB host") orelse "127.0.0.1";
    const mysql_user = b.option([]const u8, "mysql-user", "MySQL/MariaDB user") orelse "zgorm";
    const mysql_password = b.option([]const u8, "mysql-password", "MySQL/MariaDB password") orelse "zgorm";
    const mysql_database = b.option([]const u8, "mysql-database", "MySQL/MariaDB database") orelse "zgorm";
    const mysql_ssl = b.option(bool, "mysql-ssl", "Require TLS for MySQL/MariaDB driver tests") orelse false;

    // Library module "zgorm". The SQLite driver declares its C ABI but the
    // module stays free of link flags, so consumers that never use that driver
    // can cross-compile. Build targets below link sqlite3 where they need it.
    const mod = b.addModule("zgorm", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Example executable.
    const example = b.addExecutable(.{
        .name = "zgorm-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("example/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zgorm", .module = mod },
            },
        }),
    });
    example.root_module.linkSystemLibrary("sqlite3", .{});
    b.installArtifact(example);

    const run_step = b.step("run", "Run the example (set ZORM_DSN to override)");
    const run_cmd = b.addRunArtifact(example);
    if (dsn_opt) |dsn| run_cmd.setEnvironmentVariable("ZORM_DSN", dsn);
    run_step.dependOn(&run_cmd.step);

    // Unit tests. A separate module keeps the sqlite link off the library
    // module that consumers import.
    const unit_test_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    unit_test_module.linkSystemLibrary("sqlite3", .{});
    const unit_tests = b.addTest(.{ .root_module = unit_test_module });
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
                .{ .name = "zgorm", .module = mod },
                .{ .name = "test_options", .module = test_options.createModule() },
            },
        }),
    });
    // The test binary inherits the invoking environment, so ZORM_DSN set on
    // the `zig build` command line is visible to it.
    const run_integration = b.addRunArtifact(integration_tests);
    const integration_step = b.step("test-integration", "Run integration tests (requires ZORM_DSN)");
    integration_step.dependOn(&run_integration.step);

    const driver_options = b.addOptions();
    driver_options.addOption(?u16, "mysql_port", mysql_port);
    driver_options.addOption([]const u8, "mysql_host", mysql_host);
    driver_options.addOption([]const u8, "mysql_user", mysql_user);
    driver_options.addOption([]const u8, "mysql_password", mysql_password);
    driver_options.addOption([]const u8, "mysql_database", mysql_database);
    driver_options.addOption(bool, "mysql_ssl", mysql_ssl);
    const driver_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/drivers.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zgorm", .module = mod },
                .{ .name = "driver_options", .module = driver_options.createModule() },
            },
        }),
    });
    driver_tests.root_module.linkSystemLibrary("sqlite3", .{});
    const run_driver_tests = b.addRunArtifact(driver_tests);
    const driver_step = b.step("test-drivers", "Run SQLite and optional MySQL driver tests");
    driver_step.dependOn(&run_driver_tests.step);

    const benchmark = b.addExecutable(.{
        .name = "zgorm-benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmark/zgorm.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "zgorm", .module = mod },
            },
        }),
    });
    const run_benchmark = b.addRunArtifact(benchmark);
    if (dsn_opt) |dsn| run_benchmark.setEnvironmentVariable("ZORM_DSN", dsn);
    const benchmark_step = b.step("benchmark", "Run the zgorm PostgreSQL benchmark suite");
    benchmark_step.dependOn(&run_benchmark.step);
    const install_benchmark = b.addInstallArtifact(benchmark, .{});
    const benchmark_build_step = b.step("benchmark-build", "Build the zgorm benchmark executable");
    benchmark_build_step.dependOn(&install_benchmark.step);
}
