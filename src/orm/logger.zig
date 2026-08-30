//! GORM-style logging: every query is timed and reported at the level that
//! matches its outcome (error / slow / trace). The default logger prints to
//! stderr; replace it per-`Db` with `db.setLogger(...)`.

const std = @import("std");
const pq = @import("../pq.zig");
const time_mod = @import("time.zig");
const value_mod = @import("value.zig");

pub const LogLevel = enum(u8) {
    /// Nothing is logged.
    silent = 0,
    /// Only failed queries.
    err = 1,
    /// Failed queries and slow queries.
    warn = 2,
    /// Every query is traced (plus everything above).
    info = 3,
};

/// A replaceable logger. Wrap your own sink in `logFn` (and optionally pass
/// a context pointer through). The default implementation writes to stderr.
pub const Logger = struct {
    context: ?*anyopaque = null,
    /// Minimum level that is emitted.
    level: LogLevel = .warn,
    /// Queries slower than this are logged at warn level. 0 disables.
    slow_threshold_ms: u64 = 200,
    /// The sink. The message is already formatted and level-tagged.
    logFn: *const fn (ctx: ?*anyopaque, level: LogLevel, msg: []const u8) void = defaultLog,

    pub const discard: Logger = .{ .level = .silent };

    /// The built-in stderr logger.
    pub const default: Logger = .{};

    pub fn enabled(l: *const Logger, level: LogLevel) bool {
        return @intFromEnum(level) <= @intFromEnum(l.level);
    }

    pub fn log(l: *const Logger, level: LogLevel, msg: []const u8) void {
        if (!l.enabled(level)) return;
        l.logFn(l.context, level, msg);
    }

    pub fn err(l: *const Logger, msg: []const u8) void {
        l.log(.err, msg);
    }

    pub fn warn(l: *const Logger, msg: []const u8) void {
        l.log(.warn, msg);
    }

    pub fn info(l: *const Logger, msg: []const u8) void {
        l.log(.info, msg);
    }

    fn defaultLog(ctx: ?*anyopaque, level: LogLevel, msg: []const u8) void {
        _ = ctx;
        const tag = switch (level) {
            .silent => "SILENT",
            .err => "ERROR",
            .warn => "WARN ",
            .info => "INFO ",
        };
        std.debug.print("[zorm] [{s}] {s}\n", .{ tag, msg });
    }
};

/// Formats one query outcome into `buf` and returns the message slice:
/// the SQL with placeholders inlined, a suffix of (elapsed, rows) and the
/// error when present.
pub fn formatQuery(l: *const Logger, buf: []u8, sql: []const u8, params: []const pq.Param, elapsed_ns: u128, rows: i64, err: ?anyerror) []const u8 {
    return formatQueryMsg(l, buf, sql, params, elapsed_ns, rows, err);
}

/// Formats one query outcome into `buf` and returns the message slice:
/// the SQL with placeholders inlined, a suffix of (elapsed, rows) and the
/// error when present.
fn formatQueryMsg(
    l: *const Logger,
    buf: []u8,
    sql: []const u8,
    params: []const pq.Param,
    elapsed_ns: u128,
    rows: i64,
    err: ?anyerror,
) []const u8 {
    var fbs: std.Io.Writer = .fixed(buf);
    const w = &fbs;

    const ms = elapsed_ns / std.time.ns_per_ms;
    const sub_ms = (elapsed_ns % std.time.ns_per_ms) / std.time.ns_per_us;

    if (err) |e| {
        w.print("SQL error ({s}): ", .{@errorName(e)}) catch {};
    } else if (l.slow_threshold_ms > 0 and ms >= l.slow_threshold_ms) {
        w.print("SLOW SQL ({d}.{d:0>3}ms >= {d}ms): ", .{ ms, sub_ms, l.slow_threshold_ms }) catch {};
    } else {
        w.print("({d}.{d:0>3}ms, rows={d}) ", .{ ms, sub_ms, rows }) catch {};
    }

    // SQL with $N placeholders inlined for copy-paste friendliness.
    inlineSqlParams(w, sql, params) catch {};

    if (params.len > 0) {
        w.writeAll("  [") catch {};
        for (params, 0..) |p, i| {
            if (i > 0) w.writeAll(", ") catch {};
            w.print("${d}=", .{i + 1}) catch {};
            formatParamValue(w, p) catch {};
        }
        w.writeByte(']') catch {};
    }
    return fbs.buffered();
}

fn formatParamValue(w: *std.Io.Writer, p: pq.Param) !void {
    if (p.is_null) return w.writeAll("NULL");
    switch (p.format) {
        // Binary params: decode the well-known scalars, hex the rest.
        1 => switch (p.data.len) {
            1 => {
                if (p.oid == pq.proto.Oid.bool_) {
                    return w.writeAll(if (p.data[0] != 0) "'t'" else "'f'");
                }
            },
            8 => {
                if (p.oid == pq.proto.Oid.int8) {
                    const v = std.mem.readInt(i64, p.data[0..8], .big);
                    return w.print("'{d}'", .{v});
                }
                if (p.oid == pq.proto.Oid.float8) {
                    const f: f64 = @bitCast(std.mem.readInt(u64, p.data[0..8], .big));
                    return w.print("'{d}'", .{f});
                }
                if (p.oid == pq.proto.Oid.timestamptz) {
                    const t = time_mod.Time.fromUnixMicros(
                        std.mem.readInt(i64, p.data[0..8], .big) + value_mod.pg_epoch_us,
                    );
                    var ts_buf: [time_mod.Time.pg_text_len]u8 = undefined;
                    return w.print("'{s}'", .{t.toPgText(&ts_buf)});
                }
            },
            else => {},
        },
        else => {},
    }
    try w.writeByte('\'');
    for (p.data) |ch| {
        if (ch == '\'') {
            try w.writeAll("''");
        } else if (ch >= 0x20 and ch < 0x7f) {
            try w.writeByte(ch);
        } else {
            try w.print("\\x{x:0>2}", .{ch});
        }
    }
    try w.writeByte('\'');
}

/// Replaces `$N` placeholders with the formatted parameter values.
fn inlineSqlParams(w: *std.Io.Writer, sql: []const u8, params: []const pq.Param) !void {
    var i: usize = 0;
    var in_string = false;
    while (i < sql.len) : (i += 1) {
        const ch = sql[i];
        if (in_string) {
            try w.writeByte(ch);
            if (ch == '\'') in_string = false;
            continue;
        }
        switch (ch) {
            '\'' => {
                in_string = true;
                try w.writeByte(ch);
            },
            '$' => {
                var j = i + 1;
                while (j < sql.len and sql[j] >= '0' and sql[j] <= '9') j += 1;
                if (j > i + 1) {
                    const n = std.fmt.parseInt(usize, sql[i + 1 .. j], 10) catch 0;
                    if (n >= 1 and n <= params.len) {
                        try formatParamValue(w, params[n - 1]);
                        i = j - 1;
                        continue;
                    }
                }
                try w.writeByte(ch);
            },
            else => try w.writeByte(ch),
        }
    }
}

test "formatQuery inlines params and reports timing" {
    const l = Logger{ .level = .info, .slow_threshold_ms = 0 };
    var buf: [1024]u8 = undefined;
    const msg = formatQuery(
        &l,
        &buf,
        "SELECT * FROM users WHERE id = $1 AND name = $2",
        &.{
            .{ .oid = pq.proto.Oid.int8, .format = 1, .data = &.{ 0, 0, 0, 0, 0, 0, 0, 7 } },
            .{ .oid = pq.proto.Oid.text, .format = 0, .data = "bo'b" },
        },
        1_500_000,
        1,
        null,
    );
    try std.testing.expectEqualStrings(
        "(1.500ms, rows=1) SELECT * FROM users WHERE id = '7' AND name = 'bo''b'  [$1='7', $2='bo''b']",
        msg,
    );
}

test "formatQuery marks slow queries and errors" {
    const l = Logger{ .level = .info, .slow_threshold_ms = 100 };
    var buf: [1024]u8 = undefined;
    const slow = formatQuery(&l, &buf, "SELECT 1", &.{}, 300_000_000, 0, null);
    try std.testing.expect(std.mem.startsWith(u8, slow, "SLOW SQL (300.000ms >= 100ms)"));

    const err_msg = formatQuery(&l, &buf, "SELECT 1", &.{}, 0, 0, error.UniqueViolation);
    try std.testing.expect(std.mem.startsWith(u8, err_msg, "SQL error (UniqueViolation)"));
}

test "formatQuery skips inlining inside string literals" {
    const l = Logger{ .level = .info };
    var buf: [512]u8 = undefined;
    const msg = formatQuery(&l, &buf, "SELECT '$1' AS tag", &.{.{ .oid = pq.proto.Oid.text, .format = 0, .data = "x" }}, 0, 0, null);
    try std.testing.expectEqualStrings("(0.000ms, rows=0) SELECT '$1' AS tag  [$1='x']", msg);
}
