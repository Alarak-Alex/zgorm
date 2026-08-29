//! Naming conventions, evaluated at comptime.

const std = @import("std");

/// Converts a Zig identifier (camelCase or PascalCase) to a snake_case SQL
/// identifier: "userName" -> "user_name", "HTTPServer" -> "http_server".
pub fn toSnakeCase(comptime name: []const u8) []const u8 {
    comptime {
        var buf: [name.len * 2]u8 = undefined;
        var len: usize = 0;
        for (name, 0..) |ch, i| {
            const is_upper = ch >= 'A' and ch <= 'Z';
            var needs_underscore = false;
            if (is_upper and i > 0) {
                const prev = name[i - 1];
                const next: u8 = if (i + 1 < name.len) name[i + 1] else 0;
                const prev_is_lower = (prev >= 'a' and prev <= 'z') or (prev >= '0' and prev <= '9');
                const next_is_lower = next >= 'a' and next <= 'z';
                needs_underscore = prev_is_lower or
                    ((prev >= 'A' and prev <= 'Z') and next_is_lower);
            }
            if (needs_underscore) {
                buf[len] = '_';
                len += 1;
            }
            buf[len] = if (is_upper) ch + ('a' - 'A') else ch;
            len += 1;
        }
        const final = buf;
        return final[0..len];
    }
}

test "snake case conversions" {
    const t = std.testing;
    try t.expectEqualStrings("user_name", comptime toSnakeCase("userName"));
    try t.expectEqualStrings("id", comptime toSnakeCase("id"));
    try t.expectEqualStrings("created_at", comptime toSnakeCase("createdAt"));
    try t.expectEqualStrings("http_server", comptime toSnakeCase("HTTPServer"));
    try t.expectEqualStrings("user_id", comptime toSnakeCase("userID"));
    try t.expectEqualStrings("user_id", comptime toSnakeCase("userId"));
    try t.expectEqualStrings("user", comptime toSnakeCase("User"));
    try t.expectEqualStrings("oauth2_token", comptime toSnakeCase("oauth2Token"));
}
