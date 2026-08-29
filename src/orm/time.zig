//! `zorm.Time` — a timestamp value type mapped to PostgreSQL `timestamptz`.
//!
//! Internally stores microseconds since the Unix epoch (UTC). Parses and
//! formats the ISO text representation PostgreSQL uses on the wire
//! (`2026-08-29 12:34:56.789012+08`).

const std = @import("std");

pub const ParseError = error{InvalidTime};

pub const Time = struct {
    /// Microseconds since 1970-01-01T00:00:00Z.
    micros: i64,

    pub const __zorm_time = true; // comptime marker for the schema/codec layer

    pub fn now(io: std.Io) Time {
        return .{ .micros = std.Io.Timestamp.now(io, .real).toMicroseconds() };
    }

    pub fn fromUnix(secs: i64) Time {
        return .{ .micros = secs * std.time.us_per_s };
    }

    pub fn fromUnixMilli(ms: i64) Time {
        return .{ .micros = ms * std.time.us_per_ms };
    }

    pub fn fromUnixMicros(micros: i64) Time {
        return .{ .micros = micros };
    }

    pub fn unixSeconds(t: Time) i64 {
        return @divTrunc(t.micros, std.time.us_per_s);
    }

    pub fn unixMilli(t: Time) i64 {
        return @divTrunc(t.micros, std.time.us_per_ms);
    }

    pub const DateTime = struct {
        year: i64,
        month: u8, // 1..12
        day: u8, // 1..31
        hour: u8,
        minute: u8,
        second: u8,
        micros: u32, // sub-second part
    };

    /// UTC calendar representation.
    pub fn dateTimeUtc(t: Time) DateTime {
        const secs = @divFloor(t.micros, std.time.us_per_s);
        var rem_us = @mod(t.micros, std.time.us_per_s);
        if (rem_us < 0) rem_us += std.time.us_per_s;
        const days = @divFloor(secs, 86_400);
        const secs_of_day: u32 = @intCast(secs - days * 86_400);
        const civil = civilFromDays(days);
        return .{
            .year = civil.y,
            .month = civil.m,
            .day = civil.d,
            .hour = @intCast(secs_of_day / 3600),
            .minute = @intCast((secs_of_day / 60) % 60),
            .second = @intCast(secs_of_day % 60),
            .micros = @intCast(rem_us),
        };
    }

    /// Formats as PG ISO text with UTC offset, e.g.
    /// `2026-08-29 12:34:56.789012+00`. `buf` must be >= `pg_text_len`.
    pub fn toPgText(t: Time, buf: []u8) []const u8 {
        const dt = t.dateTimeUtc();
        const frac: u32 = dt.micros;
        if (frac != 0) {
            return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>6}+00", .{
                @as(u64, @intCast(@max(dt.year, 0))), dt.month,  dt.day,
                dt.hour,                              dt.minute, dt.second,
                frac,
            }) catch unreachable;
        }
        return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}+00", .{
            @as(u64, @intCast(@max(dt.year, 0))), dt.month,  dt.day,
            dt.hour,                              dt.minute, dt.second,
        }) catch unreachable;
    }

    pub const pg_text_len = 32;

    /// Parses the text PostgreSQL sends for `timestamp` / `timestamptz`
    /// columns: `2026-08-29 12:34:56.789012+08`, with or without sub-second
    /// precision and timezone (`+08`, `-05:30`, `+0530`, `Z`, or none —
    /// missing timezone is interpreted as UTC).
    pub fn parsePg(text: []const u8) ParseError!Time {
        var it = std.mem.tokenizeAny(u8, text, " T");
        const date_part = it.next() orelse return error.InvalidTime;
        var time_part: []const u8 = "";
        var bc = false;
        const rest = it.next() orelse "";
        if (rest.len > 0) {
            time_part = rest;
        }

        var d = date_part;
        if (std.mem.endsWith(u8, d, " BC")) {
            bc = true;
            d = d[0 .. d.len - 3];
        }
        var dit = std.mem.splitScalar(u8, d, '-');
        const ys = dit.next() orelse return error.InvalidTime;
        const ms = dit.next() orelse return error.InvalidTime;
        const ds = dit.next() orelse return error.InvalidTime;
        if (dit.next() != null) return error.InvalidTime;
        const year = std.fmt.parseInt(i64, ys, 10) catch return error.InvalidTime;
        const month = std.fmt.parseInt(u8, ms, 10) catch return error.InvalidTime;
        const day = std.fmt.parseInt(u8, ds, 10) catch return error.InvalidTime;
        if (month < 1 or month > 12 or day < 1 or day > 31) return error.InvalidTime;

        var hour: u32 = 0;
        var minute: u32 = 0;
        var second: u32 = 0;
        var frac_us: u32 = 0;
        var offset_secs: i32 = 0;

        if (time_part.len > 0) {
            // Split timezone suffix if present.
            var tp = time_part;
            var tz_start: ?usize = null;
            for (tp, 0..) |ch, i| {
                if (ch == '+' or ch == '-' or ch == 'Z') {
                    // '-' may belong to nothing else in a time part; safe.
                    tz_start = i;
                    break;
                }
            }
            var tz: []const u8 = "";
            if (tz_start) |i| {
                tz = tp[i..];
                tp = tp[0..i];
            }

            var tit = std.mem.splitScalar(u8, tp, ':');
            const hs = tit.next() orelse return error.InvalidTime;
            hour = std.fmt.parseInt(u32, hs, 10) catch return error.InvalidTime;
            if (tit.next()) |mins| {
                minute = std.fmt.parseInt(u32, mins, 10) catch return error.InvalidTime;
            }
            if (tit.next()) |secs| {
                if (std.mem.indexOfScalar(u8, secs, '.')) |dot| {
                    second = std.fmt.parseInt(u32, secs[0..dot], 10) catch return error.InvalidTime;
                    frac_us = parseFraction(secs[dot + 1 ..]) catch return error.InvalidTime;
                } else {
                    second = std.fmt.parseInt(u32, secs, 10) catch return error.InvalidTime;
                }
            }
            if (hour > 23 or minute > 59 or second > 60) return error.InvalidTime;

            if (tz.len > 0) {
                if (tz[0] == 'Z') {
                    offset_secs = 0;
                } else {
                    const sign: i32 = if (tz[0] == '-') -1 else 1;
                    var digits = tz[1..];
                    var oh: i32 = 0;
                    var om: i32 = 0;
                    if (std.mem.indexOfScalar(u8, digits, ':')) |colon| {
                        oh = std.fmt.parseInt(i32, digits[0..colon], 10) catch return error.InvalidTime;
                        om = std.fmt.parseInt(i32, digits[colon + 1 ..], 10) catch return error.InvalidTime;
                    } else switch (digits.len) {
                        1, 2 => oh = std.fmt.parseInt(i32, digits, 10) catch return error.InvalidTime,
                        3 => {
                            oh = std.fmt.parseInt(i32, digits[0..2], 10) catch return error.InvalidTime;
                            om = std.fmt.parseInt(i32, digits[2..3], 10) catch return error.InvalidTime;
                        },
                        4 => {
                            oh = std.fmt.parseInt(i32, digits[0..2], 10) catch return error.InvalidTime;
                            om = std.fmt.parseInt(i32, digits[2..4], 10) catch return error.InvalidTime;
                        },
                        else => return error.InvalidTime,
                    }
                    offset_secs = sign * (oh * 3600 + om * 60);
                }
            }
        }

        if (bc) return error.InvalidTime; // BC dates are out of scope for v1

        const days = daysFromCivil(year, month, day);
        var total_secs: i64 = days * 86_400 +
            @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second);
        total_secs -= offset_secs;
        return .{ .micros = total_secs * std.time.us_per_s + frac_us };
    }

    fn parseFraction(frac: []const u8) !u32 {
        // Up to 6 digits are significant; pad/truncate accordingly.
        var us: u32 = 0;
        for (frac, 0..) |ch, i| {
            if (i >= 6) break;
            if (ch < '0' or ch > '9') return error.InvalidTime;
            us = us * 10 + (ch - '0');
        }
        var digits = @min(frac.len, 6);
        while (digits < 6) : (digits += 1) us *= 10;
        return us;
    }
};

/// Howard Hinnant's days_from_civil algorithm.
fn daysFromCivil(y_in: i64, m: u8, d: u8) i64 {
    var y = y_in;
    y -= if (m <= 2) 1 else 0;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400; // [0, 399]
    const mp: i64 = if (m > 2) @as(i64, m) - 3 else @as(i64, m) + 9;
    const doy = @divFloor(153 * mp + 2, 5) + d - 1; // [0, 365]
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy; // [0, 146096]
    return era * 146097 + doe - 719468;
}

fn civilFromDays(z_in: i64) struct { y: i64, m: u8, d: u8 } {
    const z = z_in + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097; // [0, 146096]
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365); // [0, 399]
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100)); // [0, 365]
    const mp = @divFloor(5 * doy + 2, 153); // [0, 11]
    const d = doy - @divFloor(153 * mp + 2, 5) + 1; // [1, 31]
    const m: i64 = if (mp < 10) mp + 3 else mp - 9; // [1, 12]
    return .{
        .y = y + @intFromBool(m <= 2),
        .m = @intCast(m),
        .d = @intCast(d),
    };
}

const testing = std.testing;

test "epoch basics" {
    try testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    try testing.expectEqual(@as(i64, 1970), civilFromDays(0).y);
    try testing.expectEqual(@as(u8, 1), civilFromDays(0).m);
    try testing.expectEqual(@as(u8, 1), civilFromDays(0).d);
}

test "format and parse round trip" {
    var buf: [Time.pg_text_len]u8 = undefined;
    const t = Time.fromUnix(1_800_000_000); // 2027-01-15 08:00:00 UTC
    const text = t.toPgText(&buf);
    try testing.expectEqualStrings("2027-01-15 08:00:00+00", text);
    const back = try Time.parsePg(text);
    try testing.expectEqual(t.micros, back.micros);

    const t2 = Time.fromUnixMicros(1_800_000_000_123_456);
    const text2 = t2.toPgText(&buf);
    try testing.expectEqualStrings("2027-01-15 08:00:00.123456+00", text2);
    const back2 = try Time.parsePg(text2);
    try testing.expectEqual(t2.micros, back2.micros);
}

test "parse PG variants" {
    const cases = .{
        .{ "2026-08-29 12:34:56.789+08", 1_787_978_096_789_000 },
        .{ "2026-08-29 12:34:56-05:30", 1_788_026_696_000_000 },
        .{ "2026-08-29 12:34:56+0530", 1_787_987_096_000_000 },
        .{ "2026-08-29 12:34:56Z", 1_788_006_896_000_000 },
        .{ "2026-08-29 12:34:56", 1_788_006_896_000_000 },
        .{ "2026-08-29", 1_787_961_600_000_000 },
        .{ "2026-08-29T12:34:56.5Z", 1_788_006_896_500_000 },
    };
    inline for (cases) |case| {
        const got = try Time.parsePg(case[0]);
        try testing.expectEqual(@as(i64, case[1]), got.micros);
    }
    try testing.expectError(error.InvalidTime, Time.parsePg("garbage"));
    try testing.expectError(error.InvalidTime, Time.parsePg("2026-13-40 00:00:00"));
}

test "civil conversions are inverses" {
    var days: i64 = -25000;
    while (days < 25000) : (days += 997) {
        const c = civilFromDays(days);
        try testing.expectEqual(days, daysFromCivil(c.y, c.m, c.d));
    }
}
