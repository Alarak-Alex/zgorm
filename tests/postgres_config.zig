const std = @import("std");

/// Reads the live test process environment. The caller owns the DSN.
pub fn dsn() ![]u8 {
    const gpa = std.testing.allocator;
    var env = try std.testing.environ.createMap(gpa);
    defer env.deinit();
    const url = env.get("ZORM_DSN") orelse "";
    if (url.len != 0) return gpa.dupe(u8, url);
    if (std.mem.eql(u8, env.get("CI") orelse "", "true")) return error.MissingPostgresDsn;
    return error.SkipZigTest;
}
