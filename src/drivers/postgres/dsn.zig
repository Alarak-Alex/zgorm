//! Connection string parsing.
//!
//! Supported forms:
//!   postgres://user:password@host:5432/dbname?sslmode=require
//!   host=127.0.0.1 port=5432 user=postgres password='two words' dbname=app
//!   host=/var/run/postgresql dbname=app      (unix socket directory)
//!
//! All strings in the returned Config either point into the DSN itself or are
//! allocated from the given arena.

const std = @import("std");
const conn = @import("conn.zig");

pub const Config = conn.Config;
pub const SslMode = conn.SslMode;
const Error = conn.Error;

pub fn parse(arena: std.mem.Allocator, dsn: []const u8) Error!Config {
    if (std.mem.startsWith(u8, dsn, "postgres://") or std.mem.startsWith(u8, dsn, "postgresql://")) {
        return parseUrl(arena, dsn);
    }
    return parseKeywords(arena, dsn);
}

fn parseUrl(arena: std.mem.Allocator, dsn: []const u8) Error!Config {
    var cfg: Config = .{};
    var rest: []const u8 = undefined;
    if (std.mem.startsWith(u8, dsn, "postgresql://")) {
        rest = dsn["postgresql://".len..];
    } else {
        rest = dsn["postgres://".len..];
    }

    // Query part.
    var query: []const u8 = "";
    if (std.mem.indexOfScalar(u8, rest, '?')) |q| {
        query = rest[q + 1 ..];
        rest = rest[0..q];
    }

    // Path (database).
    if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
        const db = rest[slash + 1 ..];
        if (db.len > 0) cfg.database = try percentDecode(arena, db);
        rest = rest[0..slash];
    }

    // Userinfo.
    if (std.mem.lastIndexOfScalar(u8, rest, '@')) |at| {
        const userinfo = rest[0..at];
        rest = rest[at + 1 ..];
        if (std.mem.indexOfScalar(u8, userinfo, ':')) |colon| {
            cfg.user = try percentDecode(arena, userinfo[0..colon]);
            cfg.password = try percentDecode(arena, userinfo[colon + 1 ..]);
        } else {
            cfg.user = try percentDecode(arena, userinfo);
        }
    }

    // Host / port (handle [ipv6]:port).
    var host = rest;
    if (std.mem.startsWith(u8, host, "[")) {
        const close = std.mem.indexOfScalar(u8, host, ']') orelse return error.InvalidDsn;
        cfg.host = try arena.dupe(u8, host[1..close]);
        host = host[close + 1 ..];
        if (host.len > 0) {
            if (host[0] != ':') return error.InvalidDsn;
            cfg.port = std.fmt.parseInt(u16, host[1..], 10) catch return error.InvalidDsn;
        }
    } else if (std.mem.indexOfScalar(u8, host, ':')) |colon| {
        cfg.host = try percentDecode(arena, host[0..colon]);
        cfg.port = std.fmt.parseInt(u16, host[colon + 1 ..], 10) catch return error.InvalidDsn;
    } else if (host.len > 0) {
        cfg.host = try percentDecode(arena, host);
    }

    try applyQuery(arena, &cfg, query);
    if (cfg.user.len == 0) return error.InvalidDsn;
    return cfg;
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

/// Cursor-based parser so that quoted values may contain spaces
/// (`password='two words'`).
fn parseKeywords(arena: std.mem.Allocator, dsn: []const u8) Error!Config {
    var cfg: Config = .{};
    var i: usize = 0;
    while (true) {
        while (i < dsn.len and isSpace(dsn[i])) i += 1;
        if (i >= dsn.len) break;

        const key_start = i;
        while (i < dsn.len and dsn[i] != '=' and !isSpace(dsn[i])) i += 1;
        const key = dsn[key_start..i];
        if (key.len == 0 or i >= dsn.len or dsn[i] != '=') return error.InvalidDsn;
        i += 1; // '='

        var value: []const u8 = "";
        if (i < dsn.len and dsn[i] == '\'') {
            i += 1;
            const vstart = i;
            while (i < dsn.len and dsn[i] != '\'') i += 1;
            if (i >= dsn.len) return error.InvalidDsn;
            value = dsn[vstart..i];
            i += 1; // closing quote
        } else {
            const vstart = i;
            while (i < dsn.len and !isSpace(dsn[i])) i += 1;
            value = dsn[vstart..i];
        }
        try applyKeyword(arena, &cfg, key, value);
    }
    if (cfg.user.len == 0) return error.InvalidDsn;
    return cfg;
}

fn applyQuery(arena: std.mem.Allocator, cfg: *Config, query: []const u8) Error!void {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        try applyKeyword(arena, cfg, pair[0..eq], pair[eq + 1 ..]);
    }
}

fn applyKeyword(arena: std.mem.Allocator, cfg: *Config, key: []const u8, raw_value: []const u8) Error!void {
    const value = try percentDecode(arena, raw_value);
    if (std.mem.eql(u8, key, "host")) {
        cfg.host = value;
    } else if (std.mem.eql(u8, key, "port")) {
        cfg.port = std.fmt.parseInt(u16, value, 10) catch return error.InvalidDsn;
    } else if (std.mem.eql(u8, key, "user")) {
        cfg.user = value;
    } else if (std.mem.eql(u8, key, "password")) {
        cfg.password = value;
    } else if (std.mem.eql(u8, key, "dbname") or std.mem.eql(u8, key, "database")) {
        cfg.database = value;
    } else if (std.mem.eql(u8, key, "application_name")) {
        cfg.application_name = value;
    } else if (std.mem.eql(u8, key, "sslmode")) {
        cfg.ssl_mode = std.meta.stringToEnum(SslMode, value) orelse return error.InvalidDsn;
    }
    // Unknown parameters are ignored for forward compatibility.
}

fn percentDecode(arena: std.mem.Allocator, s: []const u8) Error![]const u8 {
    if (std.mem.indexOfScalar(u8, s, 0) != null) return error.InvalidDsn;
    if (std.mem.indexOfScalar(u8, s, '%') == null) return s;
    const out = try arena.alloc(u8, s.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '%') {
            if (i + 2 >= s.len) return error.InvalidDsn;
            const hi = std.fmt.charToDigit(s[i + 1], 16) catch return error.InvalidDsn;
            const lo = std.fmt.charToDigit(s[i + 2], 16) catch return error.InvalidDsn;
            out[n] = @as(u8, hi) * 16 + lo;
            if (out[n] == 0) return error.InvalidDsn;
            n += 1;
            i += 3;
        } else {
            out[n] = s[i];
            n += 1;
            i += 1;
        }
    }
    return out[0..n];
}

const testing = std.testing;

test "parse url dsn" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const cfg = try parse(a, "postgres://bob:secret@db.example.com:5433/mydb?sslmode=require");
    try testing.expectEqualStrings("bob", cfg.user);
    try testing.expectEqualStrings("secret", cfg.password);
    try testing.expectEqualStrings("db.example.com", cfg.host);
    try testing.expectEqual(@as(u16, 5433), cfg.port);
    try testing.expectEqualStrings("mydb", cfg.database);
    try testing.expectEqual(SslMode.require, cfg.ssl_mode);

    const cfg2 = try parse(a, "postgresql://alice@192.168.1.1/app");
    try testing.expectEqualStrings("alice", cfg2.user);
    try testing.expectEqual(@as(u16, 5432), cfg2.port);
    try testing.expectEqualStrings("app", cfg2.database);
    try testing.expectEqual(SslMode.disable, cfg2.ssl_mode);
}

test "parse keyword dsn" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const cfg = try parse(a, "host=/var/run/postgresql port=5432 user=pg password='two words' dbname=test");
    try testing.expectEqualStrings("/var/run/postgresql", cfg.host);
    try testing.expectEqual(@as(u16, 5432), cfg.port);
    try testing.expectEqualStrings("pg", cfg.user);
    try testing.expectEqualStrings("two words", cfg.password);
    try testing.expectEqualStrings("test", cfg.database);
}

test "percent decoding" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const cfg = try parse(a, "postgres://u%40mail:p%23ss@127.0.0.1/db");
    try testing.expectEqualStrings("u@mail", cfg.user);
    try testing.expectEqualStrings("p#ss", cfg.password);
}

test "reject missing user" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(error.InvalidDsn, parse(arena_state.allocator(), "postgres://127.0.0.1/db"));
}

test "reject malformed URL encoding and IPv6 suffixes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try testing.expectError(error.InvalidDsn, parse(a, "postgres://u%ZZ@127.0.0.1/db"));
    try testing.expectError(error.InvalidDsn, parse(a, "postgres://u%00x@127.0.0.1/db"));
    try testing.expectError(error.InvalidDsn, parse(a, "postgres://u@[::1]junk/db"));
}
