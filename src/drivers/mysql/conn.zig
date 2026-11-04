//! MySQL/MariaDB text-protocol driver with mysql_native_password authentication.

const std = @import("std");
const net = std.Io.net;
const types = @import("../shared/types.zig");
const pool_mod = @import("../shared/pool.zig");
const auth = @import("auth.zig");

pub const Error = types.Error;
pub const SslMode = types.SslMode;

pub const Config = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 3306,
    user: []const u8,
    password: []const u8 = "",
    database: []const u8 = "",
    ssl_mode: SslMode = .disable,
    ca_file: ?[]const u8 = null,
    query_timeout_ms: u64 = 0,
    prepared_cache_size: usize = 64,
};

pub const PoolOptions = pool_mod.Options;
pub const PoolStats = pool_mod.Stats;

const PoolContext = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    config: Config,
};

fn poolCreate(context: *PoolContext) Error!*Conn {
    return Conn.connect(context.gpa, context.io, context.config);
}

fn poolDestroy(conn: *Conn) void {
    conn.deinit();
}

fn poolPing(conn: *Conn) Error!void {
    try conn.ping();
}

pub const Pool = pool_mod.Pool(*Conn, PoolContext, poolCreate, poolDestroy, poolPing);

pub fn openPool(gpa: std.mem.Allocator, io: std.Io, config: Config, options: PoolOptions) Error!*Pool {
    return Pool.init(gpa, io, options, .{ .gpa = gpa, .io = io, .config = config });
}

pub const Result = types.Result;

pub const Conn = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    stream: net.Stream,
    sock_rd: net.Stream.Reader,
    sock_wr: net.Stream.Writer,
    tls: ?*std.crypto.tls.Client = null,
    tls_mem: []u8 = &.{},
    ca_bundle: ?*std.crypto.Certificate.Bundle = null,
    ca_lock: std.Io.RwLock = .init,
    rd: *std.Io.Reader,
    wr: *std.Io.Writer,
    read_buf: []u8,
    write_buf: []u8,
    packet: std.ArrayList(u8) = .empty,
    last_error: ?types.ServerError = null,

    query_timeout_ms: u64 = 0,
    broken: bool = false,
    prepared_cache_size: usize = 64,
    prepared_next_id: u64 = 1,
    prepared: std.ArrayList(PreparedEntry) = .empty,

    const PreparedEntry = struct {
        sql: []u8,
        name: [32]u8 = undefined,
        name_len: u8,

        fn statementName(entry: *const PreparedEntry) []const u8 {
            return entry.name[0..entry.name_len];
        }
    };

    const QueryGuard = struct {
        conn: *Conn,
        timeout_ms: u64,
        done: std.atomic.Value(bool) = .init(false),
        expired: std.atomic.Value(bool) = .init(false),
        group: std.Io.Group = .init,

        fn start(guard: *QueryGuard) void {
            guard.group.async(guard.conn.io, expire, .{guard});
        }

        fn expire(guard: *QueryGuard) std.Io.Cancelable!void {
            try guard.conn.io.sleep(.fromMilliseconds(@intCast(guard.timeout_ms)), .awake);
            if (guard.done.swap(true, .acq_rel)) return;
            guard.expired.store(true, .release);
            guard.conn.broken = true;
            guard.conn.stream.shutdown(guard.conn.io, .both) catch {};
        }

        fn finish(guard: *QueryGuard) bool {
            _ = guard.done.swap(true, .acq_rel);
            guard.group.cancel(guard.conn.io);
            return guard.expired.load(.acquire);
        }
    };
    pub fn connect(gpa: std.mem.Allocator, io: std.Io, cfg: Config) Error!*Conn {
        const stream = blk: {
            const addr = net.IpAddress.parse(cfg.host, cfg.port) catch {
                const host = net.HostName.init(cfg.host) catch return error.ConnectionFailed;
                break :blk host.connect(io, cfg.port, .{ .mode = .stream }) catch return error.ConnectionFailed;
            };
            break :blk net.IpAddress.connect(&addr, io, .{ .mode = .stream }) catch return error.ConnectionFailed;
        };
        errdefer stream.close(io);
        const read_buf = gpa.alloc(u8, 64 * 1024) catch return error.OutOfMemory;
        errdefer gpa.free(read_buf);
        const write_buf = gpa.alloc(u8, 16 * 1024) catch return error.OutOfMemory;
        errdefer gpa.free(write_buf);
        const conn = gpa.create(Conn) catch return error.OutOfMemory;
        errdefer gpa.destroy(conn);
        conn.* = .{
            .gpa = gpa,
            .io = io,
            .stream = stream,
            .sock_rd = net.Stream.Reader.init(stream, io, read_buf),
            .sock_wr = net.Stream.Writer.init(stream, io, write_buf),
            .rd = undefined,
            .wr = undefined,
            .read_buf = read_buf,
            .write_buf = write_buf,
            .query_timeout_ms = cfg.query_timeout_ms,
            .prepared_cache_size = cfg.prepared_cache_size,
        };
        conn.rd = &conn.sock_rd.interface;
        conn.wr = &conn.sock_wr.interface;
        errdefer conn.packet.deinit(gpa);
        errdefer conn.deinitTls();
        try conn.authenticate(cfg);
        return conn;
    }

    pub fn deinit(conn: *Conn) void {
        conn.writePacket(0, &.{0x01}) catch {};
        conn.deinitTls();
        conn.stream.close(conn.io);
        for (conn.prepared.items) |entry| conn.gpa.free(entry.sql);
        conn.prepared.deinit(conn.gpa);
        conn.packet.deinit(conn.gpa);
        conn.gpa.free(conn.read_buf);
        conn.gpa.free(conn.write_buf);
        const gpa = conn.gpa;
        gpa.destroy(conn);
    }

    fn ensureRead(conn: *Conn, n: usize) Error!void {
        conn.rd.fill(n) catch return error.ConnectionClosed;
    }

    fn readPacket(conn: *Conn) Error![]const u8 {
        try conn.ensureRead(4);
        const head = conn.rd.buffered()[0..4];
        const len = @as(usize, head[0]) | (@as(usize, head[1]) << 8) | (@as(usize, head[2]) << 16);
        conn.rd.seek += 4;
        conn.packet.clearRetainingCapacity();
        conn.packet.resize(conn.gpa, len) catch return error.OutOfMemory;
        var offset: usize = 0;
        while (offset < len) {
            try conn.ensureRead(1);
            const available = conn.rd.buffered();
            const take = @min(available.len, len - offset);
            @memcpy(conn.packet.items[offset .. offset + take], available[0..take]);
            conn.rd.seek += take;
            offset += take;
        }
        return conn.packet.items;
    }

    fn writePacket(conn: *Conn, sequence: u8, payload: []const u8) Error!void {
        if (payload.len > 0xffffff) return error.ProtocolViolation;
        const head = [4]u8{
            @truncate(payload.len),
            @truncate(payload.len >> 8),
            @truncate(payload.len >> 16),
            sequence,
        };
        conn.wr.writeAll(&head) catch return error.ConnectionClosed;
        conn.wr.writeAll(payload) catch return error.ConnectionClosed;
        conn.wr.flush() catch return error.ConnectionClosed;
    }

    fn authenticate(conn: *Conn, cfg: Config) Error!void {
        const greeting = try conn.readPacket();
        if (greeting.len < 34 or greeting[0] != 10) return error.ProtocolViolation;
        const version_end = std.mem.indexOfScalarPos(u8, greeting, 1, 0) orelse return error.ProtocolViolation;
        var pos = version_end + 1 + 4;
        if (pos + 9 > greeting.len) return error.ProtocolViolation;
        var scramble: [20]u8 = undefined;
        @memcpy(scramble[0..8], greeting[pos .. pos + 8]);
        pos += 9;
        if (pos + 18 > greeting.len) return error.ProtocolViolation;
        const lower = std.mem.readInt(u16, greeting[pos..][0..2], .little);
        pos += 2;
        pos += 1 + 2;
        const upper = std.mem.readInt(u16, greeting[pos..][0..2], .little);
        const server_caps = @as(u32, lower) | (@as(u32, upper) << 16);
        pos += 2;
        const auth_len = greeting[pos];
        pos += 1 + 10;
        if (pos > greeting.len) return error.ProtocolViolation;
        const advertised_tail_len: usize = if (auth_len > 8) @as(usize, auth_len) - 8 else 0;
        const auth_tail_len: usize = @min(12, @min(greeting.len - pos, advertised_tail_len));
        @memset(scramble[8..], 0);
        @memcpy(scramble[8 .. 8 + auth_tail_len], greeting[pos .. pos + auth_tail_len]);
        pos += @min(greeting.len - pos, @max(@as(usize, 13), advertised_tail_len));
        var plugin = if (pos < greeting.len)
            greeting[pos .. std.mem.indexOfScalarPos(u8, greeting, pos, 0) orelse greeting.len]
        else
            "mysql_native_password";

        const protocol_41: u32 = 0x00000200;
        const ssl: u32 = 0x00000800;
        const secure_connection: u32 = 0x00008000;
        const plugin_auth: u32 = 0x00080000;
        const connect_with_db: u32 = 0x00000008;
        var caps: u32 = protocol_41 | secure_connection | plugin_auth;
        if (cfg.database.len > 0) caps |= connect_with_db;
        if (cfg.ssl_mode != .disable) caps |= ssl;
        caps &= server_caps;
        if (cfg.ssl_mode != .disable and caps & ssl == 0) return error.TlsUnsupported;

        var sequence: u8 = 1;
        if (cfg.ssl_mode != .disable) {
            var request: [32]u8 = @splat(0);
            std.mem.writeInt(u32, request[0..4], caps, .little);
            std.mem.writeInt(u32, request[4..8], 0x01000000, .little);
            request[8] = 45;
            try conn.writePacket(sequence, &request);
            sequence += 1;
            try conn.startTls(cfg);
        }

        var auth_buf: [32]u8 = undefined;
        const response = try auth.response(plugin, cfg.password, &scramble, &auth_buf);
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(conn.gpa);
        var caps_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &caps_bytes, caps, .little);
        payload.appendSlice(conn.gpa, &caps_bytes) catch return error.OutOfMemory;
        var max_packet_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &max_packet_bytes, 0x01000000, .little);
        payload.appendSlice(conn.gpa, &max_packet_bytes) catch return error.OutOfMemory;
        payload.append(conn.gpa, 45) catch return error.OutOfMemory;
        payload.appendNTimes(conn.gpa, 0, 23) catch return error.OutOfMemory;
        payload.appendSlice(conn.gpa, cfg.user) catch return error.OutOfMemory;
        payload.append(conn.gpa, 0) catch return error.OutOfMemory;
        payload.append(conn.gpa, @intCast(response.len)) catch return error.OutOfMemory;
        payload.appendSlice(conn.gpa, response) catch return error.OutOfMemory;
        if (cfg.database.len > 0) {
            payload.appendSlice(conn.gpa, cfg.database) catch return error.OutOfMemory;
            payload.append(conn.gpa, 0) catch return error.OutOfMemory;
        }
        payload.appendSlice(conn.gpa, plugin) catch return error.OutOfMemory;
        payload.append(conn.gpa, 0) catch return error.OutOfMemory;
        try conn.writePacket(sequence, payload.items);

        while (true) {
            const server = try conn.readPacket();
            if (server.len == 0) return error.ProtocolViolation;
            switch (server[0]) {
                0x00 => return,
                0xff => {
                    switch (conn.serverError(server)) {
                        else => {},
                    }
                    return error.AuthenticationFailed;
                },
                0xfe => {
                    const name_end = std.mem.indexOfScalarPos(u8, server, 1, 0) orelse return error.ProtocolViolation;
                    const switched_plugin = server[1..name_end];
                    plugin = switched_plugin;
                    var switched_scramble: [20]u8 = @splat(0);
                    const bytes = std.mem.trimEnd(u8, server[name_end + 1 ..], &.{0});
                    @memcpy(switched_scramble[0..@min(bytes.len, switched_scramble.len)], bytes[0..@min(bytes.len, switched_scramble.len)]);
                    const switched = try auth.response(switched_plugin, cfg.password, &switched_scramble, &auth_buf);
                    sequence += 2;
                    try conn.writePacket(sequence, switched);
                },
                0x01 => {
                    if (server.len < 2) return error.ProtocolViolation;
                    switch (server[1]) {
                        0x03 => {
                            const final = try conn.readPacket();
                            if (final.len > 0 and final[0] == 0x00) return;
                            if (final.len > 0 and final[0] == 0xff) switch (conn.serverError(final)) {
                                else => {},
                            };
                            return error.AuthenticationFailed;
                        },
                        0x04 => {
                            sequence += 2;
                            if (conn.tls) |_| {
                                var password: std.ArrayList(u8) = .empty;
                                defer password.deinit(conn.gpa);
                                password.appendSlice(conn.gpa, cfg.password) catch return error.OutOfMemory;
                                password.append(conn.gpa, 0) catch return error.OutOfMemory;
                                try conn.writePacket(sequence, password.items);
                            } else {
                                try conn.writePacket(sequence, &.{0x02});
                                const key_packet = try conn.readPacket();
                                if (key_packet.len < 2 or key_packet[0] != 0x01) return error.AuthenticationFailed;
                                const encrypted = try auth.encryptCachingSha2Password(
                                    conn.gpa,
                                    conn.io,
                                    cfg.password,
                                    &scramble,
                                    std.mem.trimEnd(u8, key_packet[1..], &.{0}),
                                );
                                defer conn.gpa.free(encrypted);
                                sequence += 2;
                                try conn.writePacket(sequence, encrypted);
                            }
                        },
                        else => return error.AuthenticationFailed,
                    }
                },
                else => return error.AuthenticationFailed,
            }
        }
    }

    fn startTls(conn: *Conn, cfg: Config) Error!void {
        const tls_client = conn.gpa.create(std.crypto.tls.Client) catch return error.OutOfMemory;
        errdefer conn.gpa.destroy(tls_client);
        const tls_buffer_len = 16 * 1024;
        const tls_mem = conn.gpa.alloc(u8, 2 * tls_buffer_len) catch return error.OutOfMemory;
        errdefer conn.gpa.free(tls_mem);
        var entropy: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
        conn.io.random(&entropy);

        const CaOpt = @TypeOf(@as(std.crypto.tls.Client.Options, undefined).ca);
        var ca_opt: ?CaOpt = null;
        var ca_bundle: ?*std.crypto.Certificate.Bundle = null;
        errdefer if (ca_bundle) |bundle| {
            bundle.deinit(conn.gpa);
            conn.gpa.destroy(bundle);
        };
        if (cfg.ssl_mode == .verify_ca or cfg.ssl_mode == .verify_full) {
            const bundle = conn.gpa.create(std.crypto.Certificate.Bundle) catch return error.OutOfMemory;
            bundle.* = .empty;
            ca_bundle = bundle;
            if (cfg.ca_file) |file| {
                bundle.addCertsFromFilePath(conn.gpa, conn.io, std.Io.Timestamp.now(conn.io, .real), std.Io.Dir.cwd(), file) catch return error.TlsUnsupported;
            } else {
                bundle.rescan(conn.gpa, conn.io, std.Io.Timestamp.now(conn.io, .real)) catch return error.TlsUnsupported;
            }
            if (bundle.map.count() == 0) return error.TlsUnsupported;
            ca_opt = .{ .bundle = .{
                .gpa = conn.gpa,
                .io = conn.io,
                .lock = &conn.ca_lock,
                .bundle = bundle,
            } };
        }
        tls_client.* = std.crypto.tls.Client.init(
            &conn.sock_rd.interface,
            &conn.sock_wr.interface,
            .{
                .host = if (cfg.ssl_mode == .verify_full) .{ .explicit = cfg.host } else .no_verification,
                .ca = ca_opt orelse .no_verification,
                .write_buffer = tls_mem[0..tls_buffer_len],
                .read_buffer = tls_mem[tls_buffer_len..],
                .entropy = &entropy,
                .realtime_now = std.Io.Clock.real.now(conn.io),
            },
        ) catch return error.TlsUnsupported;
        conn.tls = tls_client;
        conn.tls_mem = tls_mem;
        conn.ca_bundle = ca_bundle;
        conn.rd = &tls_client.reader;
        conn.wr = &tls_client.writer;
    }

    fn deinitTls(conn: *Conn) void {
        if (conn.tls) |tls_client| {
            tls_client.end() catch {};
            conn.gpa.destroy(tls_client);
            conn.gpa.free(conn.tls_mem);
            conn.tls = null;
            conn.tls_mem = &.{};
        }
        if (conn.ca_bundle) |bundle| {
            bundle.deinit(conn.gpa);
            conn.gpa.destroy(bundle);
            conn.ca_bundle = null;
        }
    }

    pub fn ping(conn: *Conn) Error!void {
        if (conn.broken) return error.ConnectionClosed;
        try conn.writePacket(0, &.{0x0e});
        const response = try conn.readPacket();
        if (response.len == 0 or response[0] != 0x00) return error.QueryFailed;
    }

    fn execOnce(conn: *Conn, sql: []const u8) Error!Result {
        if (conn.broken) return error.ConnectionClosed;
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(conn.gpa);
        payload.append(conn.gpa, 0x03) catch return error.OutOfMemory;
        payload.appendSlice(conn.gpa, sql) catch return error.OutOfMemory;
        try conn.writePacket(0, payload.items);

        const arena_state = conn.gpa.create(std.heap.ArenaAllocator) catch return error.OutOfMemory;
        arena_state.* = std.heap.ArenaAllocator.init(conn.gpa);
        errdefer {
            arena_state.deinit();
            conn.gpa.destroy(arena_state);
        }
        const arena = arena_state.allocator();
        const first = try conn.readPacket();
        if (first.len == 0) return error.ProtocolViolation;
        if (first[0] == 0xff) return conn.serverError(first);
        if (first[0] == 0x00) {
            var at: usize = 1;
            const affected = std.math.cast(i64, try readLenInt(first, &at)) orelse return error.TypeMismatch;
            const last_insert_id = try readLenInt(first, &at);
            return .{
                .arena = arena_state,
                .affected = affected,
                .last_insert_id = last_insert_id,
            };
        }

        var at: usize = 0;
        const column_count: usize = @intCast(try readLenInt(first, &at));
        var columns: std.ArrayList(Result.Column) = .empty;
        for (0..column_count) |_| {
            const definition = try conn.readPacket();
            var field: usize = 0;
            for (0..4) |_| _ = try readLenBytes(definition, &field);
            const name = try readLenBytes(definition, &field);
            _ = try readLenBytes(definition, &field);
            if (field + 1 > definition.len or definition[field] != 0x0c) return error.ProtocolViolation;
            field += 1;
            if (field + 7 > definition.len) return error.ProtocolViolation;
            const mysql_type = definition[field + 6];
            columns.append(arena, .{
                .name = arena.dupe(u8, name) catch return error.OutOfMemory,
                .type_oid = mysql_type,
            }) catch return error.OutOfMemory;
        }
        _ = try conn.readPacket();

        var rows: std.ArrayList(Result.Row) = .empty;
        while (true) {
            const packet = try conn.readPacket();
            if (packet.len == 0) return error.ProtocolViolation;
            if ((packet[0] == 0xfe and packet.len < 9) or packet[0] == 0x00) break;
            if (packet[0] == 0xff) return conn.serverError(packet);
            const row = arena.alloc(?[]const u8, column_count) catch return error.OutOfMemory;
            @memset(row, null);
            var row_at: usize = 0;
            for (row) |*cell| {
                if (row_at >= packet.len) return error.ProtocolViolation;
                if (packet[row_at] == 0xfb) {
                    row_at += 1;
                } else {
                    const bytes = try readLenBytes(packet, &row_at);
                    cell.* = arena.dupe(u8, bytes) catch return error.OutOfMemory;
                }
            }
            rows.append(arena, row) catch return error.OutOfMemory;
        }
        const row_count = rows.items.len;
        return .{
            .arena = arena_state,
            .columns = columns.toOwnedSlice(arena) catch return error.OutOfMemory,
            .rows = rows.toOwnedSlice(arena) catch return error.OutOfMemory,
            .affected = @intCast(row_count),
        };
    }

    pub fn exec(conn: *Conn, sql: []const u8) Error!Result {
        return conn.execParamsTimeout(sql, &.{}, conn.query_timeout_ms);
    }
    fn execParamsOnce(conn: *Conn, sql: []const u8, params: []const types.Param) Error!Result {
        if (params.len == 0) return conn.execOnce(sql);
        if (conn.prepared_cache_size == 0) {
            var arena_state = std.heap.ArenaAllocator.init(conn.gpa);
            defer arena_state.deinit();
            var rendered: std.Io.Writer.Allocating = .init(arena_state.allocator());
            try renderSql(&rendered.writer, sql, params);
            return conn.execOnce(rendered.writer.buffered());
        }
        const name = try conn.ensurePrepared(sql);
        var arena_state = std.heap.ArenaAllocator.init(conn.gpa);
        defer arena_state.deinit();
        var set_sql: std.Io.Writer.Allocating = .init(arena_state.allocator());
        set_sql.writer.writeAll("SET ") catch return error.OutOfMemory;
        for (params, 0..) |param, index| {
            if (index != 0) set_sql.writer.writeAll(", ") catch return error.OutOfMemory;
            set_sql.writer.print("@zgorm_p{d} = ", .{index}) catch return error.OutOfMemory;
            try writeParam(&set_sql.writer, param);
        }
        try conn.execControl(set_sql.writer.buffered());
        var execute_sql: std.Io.Writer.Allocating = .init(arena_state.allocator());
        execute_sql.writer.print("EXECUTE {s} USING ", .{name}) catch return error.OutOfMemory;
        for (params, 0..) |_, index| {
            if (index != 0) execute_sql.writer.writeAll(", ") catch return error.OutOfMemory;
            execute_sql.writer.print("@zgorm_p{d}", .{index}) catch return error.OutOfMemory;
        }
        return conn.execOnce(execute_sql.writer.buffered());
    }

    fn ensurePrepared(conn: *Conn, sql: []const u8) Error![]const u8 {
        for (conn.prepared.items) |*entry| {
            if (std.mem.eql(u8, entry.sql, sql)) return entry.statementName();
        }
        if (conn.prepared.items.len >= conn.prepared_cache_size) {
            const old = conn.prepared.orderedRemove(0);
            var deallocate_buf: [64]u8 = undefined;
            const command = std.fmt.bufPrint(&deallocate_buf, "DEALLOCATE PREPARE {s}", .{old.statementName()}) catch
                return error.OutOfMemory;
            conn.execControl(command) catch {};
            conn.gpa.free(old.sql);
        }
        var entry = PreparedEntry{
            .sql = conn.gpa.dupe(u8, sql) catch return error.OutOfMemory,
            .name_len = 0,
        };
        errdefer conn.gpa.free(entry.sql);
        const name = std.fmt.bufPrint(&entry.name, "zgorm_{x}", .{conn.prepared_next_id}) catch
            return error.OutOfMemory;
        entry.name_len = @intCast(name.len);
        conn.prepared_next_id +%= 1;

        var arena_state = std.heap.ArenaAllocator.init(conn.gpa);
        defer arena_state.deinit();
        var set_source: std.Io.Writer.Allocating = .init(arena_state.allocator());
        set_source.writer.writeAll("SET @zgorm_sql = CONVERT(X'") catch return error.OutOfMemory;
        for (sql) |byte| set_source.writer.print("{x:0>2}", .{byte}) catch return error.OutOfMemory;
        set_source.writer.writeAll("' USING utf8mb4)") catch return error.OutOfMemory;
        try conn.execControl(set_source.writer.buffered());
        var prepare_buf: [96]u8 = undefined;
        const prepare_sql = std.fmt.bufPrint(&prepare_buf, "PREPARE {s} FROM @zgorm_sql", .{entry.statementName()}) catch
            return error.OutOfMemory;
        try conn.execControl(prepare_sql);
        conn.prepared.append(conn.gpa, entry) catch {
            var deallocate_buf: [64]u8 = undefined;
            const command = std.fmt.bufPrint(&deallocate_buf, "DEALLOCATE PREPARE {s}", .{entry.statementName()}) catch "";
            if (command.len > 0) conn.execControl(command) catch {};
            return error.OutOfMemory;
        };
        return conn.prepared.items[conn.prepared.items.len - 1].statementName();
    }

    pub fn execParams(conn: *Conn, sql: []const u8, params: []const types.Param) Error!Result {
        return conn.execParamsTimeout(sql, params, conn.query_timeout_ms);
    }

    pub fn execParamsTimeout(conn: *Conn, sql: []const u8, params: []const types.Param, timeout_ms: u64) Error!Result {
        const effective = if (conn.query_timeout_ms == 0) timeout_ms else if (timeout_ms == 0)
            conn.query_timeout_ms
        else
            @min(conn.query_timeout_ms, timeout_ms);
        if (effective == 0) return conn.execParamsOnce(sql, params);
        var guard = QueryGuard{ .conn = conn, .timeout_ms = effective };
        guard.start();
        const result = conn.execParamsOnce(sql, params) catch |err| {
            return if (guard.finish()) error.QueryTimeout else err;
        };
        if (guard.finish()) {
            var owned = result;
            owned.deinit();
            return error.QueryTimeout;
        }
        return result;
    }
    pub fn lastError(conn: *const Conn) ?types.ServerError {
        return conn.last_error;
    }

    fn serverError(conn: *Conn, packet: []const u8) Error {
        if (packet.len < 3 or packet[0] != 0xff) return error.ProtocolViolation;
        const number = std.mem.readInt(u16, packet[1..3], .little);
        var message_at: usize = 3;
        var state: []const u8 = "";
        if (packet.len >= 9 and packet[3] == '#') {
            state = packet[4..9];
            message_at = 9;
        }
        conn.last_error = .{
            .severity = "ERROR",
            .code = state,
            .message = packet[message_at..],
        };
        return switch (number) {
            1062 => error.UniqueViolation,
            1451, 1452 => error.ForeignKeyViolation,
            1048 => error.NotNullViolation,
            3819, 4025 => error.CheckViolation,
            1213 => error.DeadlockDetected,
            1146 => error.UndefinedTable,
            1054 => error.UndefinedColumn,
            1064 => error.SyntaxError,
            1044, 1045, 1142, 1143 => error.InsufficientPrivilege,
            1264 => error.NumericValueOutOfRange,
            1366 => error.InvalidTextRepresentation,
            else => error.QueryFailed,
        };
    }

    pub fn beginTransaction(conn: *Conn) Error!void {
        try conn.execControl("START TRANSACTION");
    }

    pub fn commit(conn: *Conn) Error!void {
        try conn.execControl("COMMIT");
    }

    pub fn rollback(conn: *Conn) Error!void {
        try conn.execControl("ROLLBACK");
    }

    fn execControl(conn: *Conn, sql: []const u8) Error!void {
        var result = try conn.execOnce(sql);
        result.deinit();
    }
};

pub const Orm = @import("../shared/orm.zig").Orm(Conn, .mysql);

pub fn orm(conn: *Conn) Orm {
    return .init(conn);
}

pub const Migrator = @import("../shared/migrator.zig").Migrator(Orm);

pub fn migrator(db: *Orm) Migrator {
    return .init(db);
}

fn renderSql(w: *std.Io.Writer, sql: []const u8, params: []const types.Param) Error!void {
    const State = enum { normal, single, double, backtick, line_comment, block_comment };
    var state: State = .normal;
    var sequential: usize = 0;
    var i: usize = 0;
    while (i < sql.len) {
        const ch = sql[i];
        switch (state) {
            .normal => {
                if (ch == '\'' or ch == '"' or ch == '`') {
                    state = switch (ch) {
                        '\'' => .single,
                        '"' => .double,
                        else => .backtick,
                    };
                    w.writeByte(ch) catch return error.OutOfMemory;
                    i += 1;
                    continue;
                }
                if (ch == '#' or (ch == '-' and i + 1 < sql.len and sql[i + 1] == '-')) {
                    state = .line_comment;
                    w.writeByte(ch) catch return error.OutOfMemory;
                    i += 1;
                    continue;
                }
                if (ch == '/' and i + 1 < sql.len and sql[i + 1] == '*') {
                    state = .block_comment;
                    w.writeAll("/*") catch return error.OutOfMemory;
                    i += 2;
                    continue;
                }
                if (ch == '?') {
                    if (sequential >= params.len) return error.InvalidQuery;
                    try writeParam(w, params[sequential]);
                    sequential += 1;
                    i += 1;
                    continue;
                }
                if (ch == '$' and i + 1 < sql.len and std.ascii.isDigit(sql[i + 1])) {
                    var end = i + 1;
                    while (end < sql.len and std.ascii.isDigit(sql[end])) : (end += 1) {}
                    const number = std.fmt.parseInt(usize, sql[i + 1 .. end], 10) catch return error.InvalidQuery;
                    if (number == 0 or number > params.len) return error.InvalidQuery;
                    try writeParam(w, params[number - 1]);
                    i = end;
                    continue;
                }
                w.writeByte(ch) catch return error.OutOfMemory;
                i += 1;
            },
            .single, .double, .backtick => {
                w.writeByte(ch) catch return error.OutOfMemory;
                const delimiter: u8 = switch (state) {
                    .single => '\'',
                    .double => '"',
                    .backtick => '`',
                    else => unreachable,
                };
                i += 1;
                if (ch == delimiter) {
                    if (i < sql.len and sql[i] == delimiter) {
                        w.writeByte(sql[i]) catch return error.OutOfMemory;
                        i += 1;
                    } else {
                        state = .normal;
                    }
                } else if (ch == '\\' and i < sql.len) {
                    w.writeByte(sql[i]) catch return error.OutOfMemory;
                    i += 1;
                }
            },
            .line_comment => {
                w.writeByte(ch) catch return error.OutOfMemory;
                i += 1;
                if (ch == '\n') state = .normal;
            },
            .block_comment => {
                w.writeByte(ch) catch return error.OutOfMemory;
                i += 1;
                if (ch == '*' and i < sql.len and sql[i] == '/') {
                    w.writeByte('/') catch return error.OutOfMemory;
                    i += 1;
                    state = .normal;
                }
            },
        }
    }
    if (state == .single or state == .double or state == .backtick or state == .block_comment)
        return error.InvalidQuery;
    if (sequential != 0 and sequential != params.len) return error.InvalidQuery;
}

fn writeParam(w: *std.Io.Writer, param: types.Param) Error!void {
    if (param.is_null or param.kind == .null_) {
        w.writeAll("NULL") catch return error.OutOfMemory;
        return;
    }
    switch (param.kind) {
        .null_ => unreachable,
        .boolean => {
            const truthy = if (param.format == 1)
                param.data.len == 1 and param.data[0] != 0
            else
                std.mem.eql(u8, param.data, "1") or std.ascii.eqlIgnoreCase(param.data, "true");
            w.writeByte(if (truthy) '1' else '0') catch return error.OutOfMemory;
        },
        .signed => {
            if (param.format == 1) {
                if (param.data.len != 8) return error.TypeMismatch;
                const value: i64 = @bitCast(std.mem.readInt(u64, param.data[0..8], .big));
                w.print("{d}", .{value}) catch return error.OutOfMemory;
            } else {
                try writeCheckedNumber(w, param.data);
            }
        },
        .unsigned => {
            if (param.format == 1) {
                if (param.data.len != 8) return error.TypeMismatch;
                w.print("{d}", .{std.mem.readInt(u64, param.data[0..8], .big)}) catch return error.OutOfMemory;
            } else {
                try writeCheckedNumber(w, param.data);
            }
        },
        .float => {
            if (param.format == 1) {
                if (param.data.len != 8) return error.TypeMismatch;
                const value: f64 = @bitCast(std.mem.readInt(u64, param.data[0..8], .big));
                if (!std.math.isFinite(value)) return error.TypeMismatch;
                w.print("{d}", .{value}) catch return error.OutOfMemory;
            } else {
                try writeCheckedNumber(w, param.data);
            }
        },
        .bytes => try writeHexLiteral(w, param.data, false),
        .text, .json, .time => {
            const text = if (param.canonical.len > 0) param.canonical else param.data;
            try writeHexLiteral(w, text, true);
        },
    }
}

fn writeCheckedNumber(w: *std.Io.Writer, text: []const u8) Error!void {
    if (text.len == 0) return error.TypeMismatch;
    var digit = false;
    for (text) |ch| {
        if (std.ascii.isDigit(ch)) {
            digit = true;
            continue;
        }
        if (ch != '+' and ch != '-' and ch != '.' and ch != 'e' and ch != 'E')
            return error.TypeMismatch;
    }
    if (!digit) return error.TypeMismatch;
    w.writeAll(text) catch return error.OutOfMemory;
}

fn writeHexLiteral(w: *std.Io.Writer, bytes: []const u8, text: bool) Error!void {
    if (text) w.writeAll("CONVERT(") catch return error.OutOfMemory;
    w.writeAll("X'") catch return error.OutOfMemory;
    for (bytes) |byte| w.print("{x:0>2}", .{byte}) catch return error.OutOfMemory;
    w.writeByte('\'') catch return error.OutOfMemory;
    if (text) w.writeAll(" USING utf8mb4)") catch return error.OutOfMemory;
}

fn readLenInt(data: []const u8, at: *usize) Error!u64 {
    if (at.* >= data.len) return error.ProtocolViolation;
    const first = data[at.*];
    at.* += 1;
    return switch (first) {
        0xfc => @as(u64, try takeInt(u16, data, at)),
        0xfd => blk: {
            if (at.* + 3 > data.len) return error.ProtocolViolation;
            const value = @as(u64, data[at.*]) | (@as(u64, data[at.* + 1]) << 8) | (@as(u64, data[at.* + 2]) << 16);
            at.* += 3;
            break :blk value;
        },
        0xfe => takeInt(u64, data, at),
        0xfb => error.ProtocolViolation,
        else => first,
    };
}

fn takeInt(comptime T: type, data: []const u8, at: *usize) Error!T {
    const size = @sizeOf(T);
    if (at.* + size > data.len) return error.ProtocolViolation;
    const value = std.mem.readInt(T, data[at.*..][0..size], .little);
    at.* += size;
    return value;
}

fn readLenBytes(data: []const u8, at: *usize) Error![]const u8 {
    const len: usize = @intCast(try readLenInt(data, at));
    if (at.* + len > data.len) return error.ProtocolViolation;
    defer at.* += len;
    return data[at.* .. at.* + len];
}

test "mysql_native_password vector is stable" {
    var out: [20]u8 = undefined;
    const scramble: [20]u8 = @splat(0);
    auth.nativePassword("secret", &scramble, &out);
    try std.testing.expectEqualSlices(u8, &.{ 0x8e, 0x7e, 0x67, 0x8b, 0x27, 0xf7, 0x07, 0x47, 0xe6, 0x5f, 0xb2, 0xb3, 0x81, 0x21, 0x44, 0x27, 0xb0, 0xfc, 0xed, 0x48 }, &out);
}

test "caching_sha2_password vector is stable" {
    var out: [32]u8 = undefined;
    const scramble: [20]u8 = @splat(0);
    auth.cachingSha2Password("secret", &scramble, &out);
    try std.testing.expectEqualSlices(u8, &.{
        0x43, 0xf3, 0x10, 0xe1, 0x0b, 0xb5, 0xdc, 0x03,
        0xa3, 0xd7, 0x0f, 0x91, 0x2b, 0xa6, 0x2b, 0x06,
        0x47, 0xa3, 0xbe, 0x1d, 0x05, 0x62, 0xcb, 0x82,
        0xa9, 0xba, 0x3a, 0xcb, 0xde, 0x2d, 0xc8, 0x25,
    }, &out);
}

test "parameter rendering is injection safe and quote aware" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try renderSql(&aw.writer, "SELECT '?', $1 -- ?\n", &.{.{
        .kind = .text,
        .data = "x' OR 1=1 --",
    }});
    try std.testing.expectEqualStrings(
        "SELECT '?', CONVERT(X'7827204f5220313d31202d2d' USING utf8mb4) -- ?\n",
        aw.writer.buffered(),
    );
}
