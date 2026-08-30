//! PostgreSQL client connection: wire protocol, authentication and query
//! execution. Pure Zig implementation of protocol version 3.0 — no libpq.

const std = @import("std");
const proto = @import("proto.zig");
const scram_mod = @import("scram.zig");
const types = @import("../shared/types.zig");

const net = std.Io.net;
const Io = std.Io;

pub const scram = scram_mod;

pub const Error = types.Error;
pub const PgError = types.ServerError;

pub const SslMode = types.SslMode;

pub const Config = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 5432,
    user: []const u8 = "",
    password: []const u8 = "",
    database: []const u8 = "",
    ssl_mode: SslMode = .disable,
    application_name: []const u8 = "zorm",
    /// Request results in binary format and decode them (default). Set to
    /// false for exotic column types that lack binary output functions.
    binary_results: bool = true,
    /// CA certificate file (PEM) used by `verify_ca`/`verify_full`. When
    /// null, the system trust store is scanned instead.
    ca_file: ?[]const u8 = null,
    /// Maximum named prepared statements cached per connection. Zero disables
    /// caching and keeps using PostgreSQL's unnamed statement.
    prepared_statement_cache_size: usize = 64,
    /// Per-query deadline. Zero disables it.
    query_timeout_ms: u64 = 0,
    /// Maximum time allowed for one network read. Zero disables it.
    read_timeout_ms: u64 = 0,
    /// Maximum time allowed for one network write/flush. Zero disables it.
    write_timeout_ms: u64 = 0,
};

pub const Param = types.Param;
pub const Result = types.Result;

pub const TxnStatus = enum { idle, in_transaction, in_failed_transaction };

const read_buffer_len = 64 * 1024;
const write_buffer_len = 16 * 1024;

pub const PreparedStats = struct {
    hits: u64,
    misses: u64,
    evictions: u64,

    pub fn hitRate(s: PreparedStats) f64 {
        const total = s.hits + s.misses;
        return if (total == 0) 0 else @as(f64, @floatFromInt(s.hits)) / @as(f64, @floatFromInt(total));
    }
};

const PreparedStatement = struct {
    sql: []u8,
    oids: []u32,
    name: [32]u8,
    name_len: u8,
    last_used: u64,

    fn statementName(s: *const PreparedStatement) []const u8 {
        return s.name[0..s.name_len];
    }
};

pub const Conn = struct {
    /// Optional hook for server notices (e.g. advisory messages).
    pub var on_notice: ?*const fn (err: PgError) void = null;

    gpa: std.mem.Allocator,
    io: Io,
    cfg: Config,

    stream: net.Stream,
    sock_rd: net.Stream.Reader,
    sock_wr: net.Stream.Writer,
    tls: ?*std.crypto.tls.Client = null,
    tls_mem: []u8 = &.{}, // combined read+write buffers of the tls client
    ca_bundle: ?*std.crypto.Certificate.Bundle = null,
    ca_lock: std.Io.RwLock = .init,

    /// Active endpoints (socket or TLS).
    rd: *Io.Reader,
    wr: *Io.Writer,

    wbuf: std.ArrayList(u8) = .empty,
    msg: std.ArrayList(u8) = .empty, // payload scratch of the message being read
    err_arena_state: std.heap.ArenaAllocator,
    last_error: ?PgError = null,
    scram_state: scram.Client = .{},

    txn_status: TxnStatus = .idle,
    broken: bool = false,
    closed: bool = false,
    backend_pid: u32 = 0,
    backend_secret: u32 = 0,
    opened_at: Io.Timestamp,
    last_used_at: Io.Timestamp,
    prepared: std.ArrayList(PreparedStatement) = .empty,
    prepared_clock: u64 = 0,
    prepared_next_id: u64 = 0,
    prepared_hits: u64 = 0,
    prepared_misses: u64 = 0,
    prepared_evictions: u64 = 0,

    // ------------------------------------------------------------------ open

    pub fn connect(gpa: std.mem.Allocator, io: Io, cfg: Config) Error!*Conn {
        try validateConfig(cfg);
        const stream = try openSocket(gpa, io, cfg);
        errdefer stream.close(io);

        const c = try gpa.create(Conn);
        errdefer gpa.destroy(c);

        const rd_buf = try gpa.alloc(u8, read_buffer_len);
        errdefer gpa.free(rd_buf);
        const wr_buf = try gpa.alloc(u8, write_buffer_len);
        errdefer gpa.free(wr_buf);
        // If anything below fails before the Conn takes ownership, these two
        // buffers are freed by the errdefers above.

        const now = Io.Clock.awake.now(io);
        c.* = .{
            .gpa = gpa,
            .io = io,
            .cfg = cfg,
            .stream = stream,
            .sock_rd = net.Stream.Reader.init(stream, io, rd_buf),
            .sock_wr = net.Stream.Writer.init(stream, io, wr_buf),
            .err_arena_state = std.heap.ArenaAllocator.init(gpa),
            .opened_at = now,
            .last_used_at = now,
            .rd = undefined,
            .wr = undefined,
        };
        c.rd = &c.sock_rd.interface;
        c.wr = &c.sock_wr.interface;
        // From here on the handshake may allocate scratch state (wbuf/msg/
        // TLS); on failure it is cleaned here while stream/buffers/the Conn
        // itself are handled by the errdefers above (issue #5).
        errdefer c.deinitScratch();

        if (cfg.ssl_mode != .disable) try c.startTls();

        try c.startup();
        try c.authenticate();
        try c.awaitReady();
        return c;
    }

    fn validateConfig(cfg: Config) Error!void {
        const fields = [_][]const u8{
            cfg.host,
            cfg.user,
            cfg.password,
            cfg.database,
            cfg.application_name,
        };
        for (fields) |field| {
            if (std.mem.indexOfScalar(u8, field, 0) != null)
                return error.InvalidDsn;
        }
        if (cfg.ca_file) |file| {
            if (std.mem.indexOfScalar(u8, file, 0) != null)
                return error.InvalidDsn;
        }
    }

    fn openSocket(gpa: std.mem.Allocator, io: Io, cfg: Config) Error!net.Stream {
        _ = gpa;
        // A host starting with '/' selects the unix socket in that directory:
        // <dir>/.s.PGSQL.<port>
        if (cfg.host.len > 0 and cfg.host[0] == '/') {
            var path_buf: [104]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "{s}/.s.PGSQL.{d}", .{ cfg.host, cfg.port }) catch
                return error.InvalidDsn;
            const ua = net.UnixAddress.init(path) catch return error.InvalidDsn;
            return ua.connect(io) catch return error.ConnectionFailed;
        }
        const addr = net.IpAddress.parse(cfg.host, cfg.port) catch {
            // Not a literal address: resolve the hostname.
            const hn = net.HostName.init(cfg.host) catch return error.InvalidDsn;
            return hn.connect(io, cfg.port, .{ .mode = .stream }) catch return error.ConnectionFailed;
        };
        return net.IpAddress.connect(&addr, io, .{ .mode = .stream }) catch return error.ConnectionFailed;
    }

    fn startTls(c: *Conn) Error!void {
        // SSLRequest: length + magic code.
        var req: [8]u8 = undefined;
        std.mem.writeInt(u32, req[0..4], 8, .big);
        std.mem.writeInt(u32, req[4..8], @intCast(proto.ssl_request_code), .big);
        c.rawWrite(&req) catch return error.ConnectionClosed;

        const answer = c.rd.takeByte() catch return error.ConnectionClosed;
        if (answer != 'S') return error.TlsUnsupported;

        const tls_client = try c.gpa.create(std.crypto.tls.Client);
        errdefer c.gpa.destroy(tls_client);

        const tls_mem = try c.gpa.alloc(u8, 2 * write_buffer_len);
        errdefer c.gpa.free(tls_mem);

        var entropy: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
        c.io.random(&entropy);

        // verify_ca / verify_full must verify a real CA chain; fail closed
        // when no trusted root can be loaded.
        const CaOpt = @TypeOf(@as(std.crypto.tls.Client.Options, undefined).ca);
        var ca_opt: ?CaOpt = null;
        var ca_bundle: ?*std.crypto.Certificate.Bundle = null;
        errdefer if (ca_bundle) |bundle| {
            bundle.deinit(c.gpa);
            c.gpa.destroy(bundle);
        };
        if (c.cfg.ssl_mode == .verify_ca or c.cfg.ssl_mode == .verify_full) {
            const bundle = c.gpa.create(std.crypto.Certificate.Bundle) catch
                return error.OutOfMemory;
            bundle.* = .empty;
            ca_bundle = bundle;
            if (c.cfg.ca_file) |file| {
                bundle.addCertsFromFilePath(c.gpa, c.io, std.Io.Timestamp.now(c.io, .real), Io.Dir.cwd(), file) catch {
                    c.broken = true;
                    return error.TlsUnsupported;
                };
            } else {
                bundle.rescan(c.gpa, c.io, std.Io.Timestamp.now(c.io, .real)) catch {
                    c.broken = true;
                    return error.TlsUnsupported;
                };
            }
            if (bundle.map.count() == 0) {
                // Fail closed: no trusted roots available.
                c.broken = true;
                return error.TlsUnsupported;
            }
            ca_opt = .{ .bundle = .{
                .gpa = c.gpa,
                .io = c.io,
                .lock = &c.ca_lock,
                .bundle = bundle,
            } };
        }

        tls_client.* = std.crypto.tls.Client.init(
            &c.sock_rd.interface,
            &c.sock_wr.interface,
            .{
                .host = if (c.cfg.ssl_mode == .verify_full)
                    .{ .explicit = c.cfg.host }
                else
                    .no_verification,
                .ca = ca_opt orelse .no_verification,
                .write_buffer = tls_mem[0..write_buffer_len],
                .read_buffer = tls_mem[write_buffer_len..],
                .entropy = &entropy,
                .realtime_now = std.Io.Clock.real.now(c.io),
            },
        ) catch {
            c.broken = true;
            return error.TlsUnsupported;
        };
        c.ca_bundle = ca_bundle;
        c.tls = tls_client;
        c.tls_mem = tls_mem;
        c.rd = &tls_client.reader;
        c.wr = &tls_client.writer;
    }

    fn startup(c: *Conn) Error!void {
        c.wbuf.clearRetainingCapacity();
        const pos = c.wbuf.items.len;
        try c.wbuf.appendNTimes(c.gpa, 0, 4); // length placeholder
        try c.wbuf.appendSlice(c.gpa, &std.mem.toBytes(std.mem.nativeToBig(u32, @bitCast(@as(i32, proto.protocol_version)))));
        try c.writeStartupParam("user", c.cfg.user);
        if (c.cfg.database.len > 0) try c.writeStartupParam("database", c.cfg.database);
        try c.writeStartupParam("application_name", c.cfg.application_name);
        try c.writeStartupParam("client_encoding", "UTF8");
        try c.wbuf.append(c.gpa, 0);
        // The startup message has no tag byte: the length field covers itself
        // plus everything after it.
        const total: u32 = @intCast(c.wbuf.items.len - pos);
        std.mem.writeInt(u32, c.wbuf.items[pos..][0..4], total, .big);
        try c.send();
    }

    fn writeStartupParam(c: *Conn, key: []const u8, value: []const u8) Error!void {
        try c.wbuf.appendSlice(c.gpa, key);
        try c.wbuf.append(c.gpa, 0);
        try c.wbuf.appendSlice(c.gpa, value);
        try c.wbuf.append(c.gpa, 0);
    }

    // ------------------------------------------------------------- auth flow

    fn authenticate(c: *Conn) Error!void {
        while (true) {
            const m = try c.readMessage();
            switch (m.tag) {
                proto.Tag.authentication => {
                    if (m.data.len < 4) return error.ProtocolViolation;
                    const code = std.mem.readInt(i32, m.data[0..4], .big);
                    const auth_type: proto.AuthType = @enumFromInt(code);
                    switch (auth_type) {
                        .ok => return,
                        .cleartext_password => try c.sendPassword(c.cfg.password),
                        .md5_password => {
                            if (m.data.len < 8) return error.ProtocolViolation;
                            try c.sendMd5Password(m.data[4..8]);
                        },
                        .sasl => try c.saslStart(m.data[4..]),
                        .sasl_continue => try c.saslContinue(m.data[4..]),
                        .sasl_final => try c.scram_state.verifyServerFinal(m.data[4..]),
                        _ => return error.AuthenticationFailed,
                    }
                },
                proto.Tag.error_response => {
                    try c.storeError(m.data);
                    return error.AuthenticationFailed;
                },
                else => return error.ProtocolViolation,
            }
        }
    }

    fn sendPassword(c: *Conn, password: []const u8) Error!void {
        const pos = try c.frameStart('p');
        try c.writeCStr(password);
        try c.frameEndAt(pos);
        try c.send();
    }

    fn sendMd5Password(c: *Conn, salt: []const u8) Error!void {
        // md5(md5(password + user) + salt)
        var d1: [16]u8 = undefined;
        var h1 = std.crypto.hash.Md5.init(.{});
        h1.update(c.cfg.password);
        h1.update(c.cfg.user);
        h1.final(&d1);

        var h2 = std.crypto.hash.Md5.init(.{});
        const hex1 = hex(&d1);
        h2.update(hex1[0..32]);
        h2.update(salt);
        var d2: [16]u8 = undefined;
        h2.final(&d2);

        var buf: [3 + 32]u8 = undefined;
        @memcpy(buf[0..3], "md5");
        const hex2 = hex(&d2);
        @memcpy(buf[3..], hex2[0..32]);
        try c.sendPassword(&buf);
    }

    fn saslStart(c: *Conn, payload: []const u8) Error!void {
        // Payload: cstring list of mechanism names, NUL terminated.
        var found = false;
        var it = std.mem.splitScalar(u8, payload, 0);
        while (it.next()) |mech| {
            if (mech.len == 0) break;
            if (std.mem.eql(u8, mech, proto.sasl_mechanism_scram_sha256)) {
                found = true;
                break;
            }
        }
        if (!found) return error.AuthenticationFailed;

        const initial = c.scram_state.clientFirstMessage(c.io);
        var init_buf: [4 + scram_mod.Client.client_final_max_len]u8 = undefined;
        const initial_response = std.fmt.bufPrint(&init_buf, "{s}{s}", .{ initial, c.scram_state.client_first_bare }) catch
            return error.ProtocolViolation;

        c.wbuf.clearRetainingCapacity();
        const pos = c.wbuf.items.len;
        try c.wbuf.append(c.gpa, 'p'); // SASLInitialResponse
        try c.wbuf.appendNTimes(c.gpa, 0, 4);
        try c.writeCStr(proto.sasl_mechanism_scram_sha256);
        try c.writeU32(@intCast(initial_response.len));
        try c.wbuf.appendSlice(c.gpa, initial_response);
        try c.frameEndAt(pos);
        try c.send();
    }

    fn saslContinue(c: *Conn, payload: []const u8) Error!void {
        try c.scram_state.receiveServerFirst(payload);
        var buf: [scram_mod.Client.client_final_max_len]u8 = undefined;
        const final = try c.scram_state.clientFinalMessage(c.cfg.password, &buf);
        c.wbuf.clearRetainingCapacity();
        const pos = c.wbuf.items.len;
        try c.wbuf.append(c.gpa, 'p'); // SASLResponse
        try c.wbuf.appendNTimes(c.gpa, 0, 4);
        try c.wbuf.appendSlice(c.gpa, final);
        try c.frameEndAt(pos);
        try c.send();
    }

    fn awaitReady(c: *Conn) Error!void {
        while (true) {
            const m = try c.readMessage();
            switch (m.tag) {
                proto.Tag.ready_for_query => {
                    c.setTxnStatus(m.data);
                    return;
                },
                proto.Tag.parameter_status, proto.Tag.notice_response => {},
                proto.Tag.backend_key_data => {
                    if (m.data.len < 8) return error.ProtocolViolation;
                    c.backend_pid = std.mem.readInt(u32, m.data[0..4], .big);
                    c.backend_secret = std.mem.readInt(u32, m.data[4..8], .big);
                },
                proto.Tag.error_response => {
                    try c.storeError(m.data);
                    return error.QueryFailed;
                },
                else => {},
            }
        }
    }

    // ------------------------------------------------------- message writing

    /// Starts a tagged frame: appends `tag` and a 4-byte length placeholder.
    /// Returns the position of the length field for `frameEndAt`.
    fn frameStart(c: *Conn, tag: u8) Error!usize {
        const pos = c.wbuf.items.len;
        try c.wbuf.append(c.gpa, tag);
        try c.wbuf.appendNTimes(c.gpa, 0, 4);
        return pos;
    }

    /// Seals the frame whose tag sits at position `pos`: writes the payload
    /// length (tag excluded) into the 4 bytes following the tag.
    fn frameEndAt(c: *Conn, pos: usize) Error!void {
        const total: u32 = @intCast(c.wbuf.items.len - pos - 1);
        std.mem.writeInt(u32, c.wbuf.items[pos + 1 ..][0..4], total, .big);
    }

    fn writeCStr(c: *Conn, s: []const u8) Error!void {
        if (std.mem.indexOfScalar(u8, s, 0) != null)
            return error.ProtocolViolation;
        try c.wbuf.appendSlice(c.gpa, s);
        try c.wbuf.append(c.gpa, 0);
    }

    fn writeU16(c: *Conn, v: u16) Error!void {
        try c.wbuf.appendSlice(c.gpa, &std.mem.toBytes(std.mem.nativeToBig(u16, v)));
    }

    fn writeU32(c: *Conn, v: u32) Error!void {
        try c.wbuf.appendSlice(c.gpa, &std.mem.toBytes(std.mem.nativeToBig(u32, v)));
    }

    fn writeI32(c: *Conn, v: i32) Error!void {
        try c.writeU32(@bitCast(v));
    }
    const TransportGuard = struct {
        conn: *Conn,
        timeout_ms: u64,
        done: std.atomic.Value(bool) = .init(false),
        expired: std.atomic.Value(bool) = .init(false),
        group: Io.Group = .init,

        fn start(g: *TransportGuard) void {
            if (g.timeout_ms > 0) g.group.async(g.conn.io, expire, .{g});
        }

        fn expire(g: *TransportGuard) Io.Cancelable!void {
            try g.conn.io.sleep(.fromMilliseconds(@intCast(g.timeout_ms)), .awake);
            if (g.done.swap(true, .acq_rel)) return;
            g.expired.store(true, .release);
            g.conn.stream.shutdown(g.conn.io, .both) catch {};
        }

        fn finish(g: *TransportGuard) bool {
            _ = g.done.swap(true, .acq_rel);
            g.group.cancel(g.conn.io);
            return g.expired.load(.acquire);
        }
    };

    const QueryGuard = struct {
        conn: *Conn,
        timeout_ms: u64,
        done: std.atomic.Value(bool) = .init(false),
        expired: std.atomic.Value(bool) = .init(false),
        group: Io.Group = .init,

        fn start(g: *QueryGuard) void {
            if (g.timeout_ms > 0) g.group.async(g.conn.io, expire, .{g});
        }

        fn expire(g: *QueryGuard) Io.Cancelable!void {
            try g.conn.io.sleep(.fromMilliseconds(@intCast(g.timeout_ms)), .awake);
            if (g.done.swap(true, .acq_rel)) return;
            g.expired.store(true, .release);
            g.conn.sendCancelRequest() catch {};
        }

        fn finish(g: *QueryGuard) bool {
            _ = g.done.swap(true, .acq_rel);
            g.group.cancel(g.conn.io);
            return g.expired.load(.acquire);
        }
    };

    /// Sends PostgreSQL's out-of-band CancelRequest over a separate socket.
    pub fn sendCancelRequest(c: *Conn) Error!void {
        if (c.backend_pid == 0 or c.backend_secret == 0) return error.ProtocolViolation;
        const stream = try openSocket(c.gpa, c.io, c.cfg);
        defer stream.close(c.io);
        var request: [16]u8 = undefined;
        std.mem.writeInt(u32, request[0..4], 16, .big);
        std.mem.writeInt(u32, request[4..8], 80877102, .big);
        std.mem.writeInt(u32, request[8..12], c.backend_pid, .big);
        std.mem.writeInt(u32, request[12..16], c.backend_secret, .big);
        var buffer: [16]u8 = undefined;
        var writer = net.Stream.Writer.init(stream, c.io, &buffer);
        writer.interface.writeAll(&request) catch return error.ConnectionClosed;
        writer.interface.flush() catch return error.ConnectionClosed;
    }

    fn send(c: *Conn) Error!void {
        var guard = TransportGuard{ .conn = c, .timeout_ms = c.cfg.write_timeout_ms };
        guard.start();
        c.wr.writeAll(c.wbuf.items) catch {
            const expired = guard.finish();
            c.broken = true;
            return if (expired) error.NetworkWriteTimeout else error.ConnectionClosed;
        };
        c.wr.flush() catch {
            const expired = guard.finish();
            c.broken = true;
            return if (expired) error.NetworkWriteTimeout else error.ConnectionClosed;
        };
        if (guard.finish()) {
            c.broken = true;
            return error.NetworkWriteTimeout;
        }
        c.wbuf.clearRetainingCapacity();
    }

    fn rawWrite(c: *Conn, bytes: []const u8) Error!void {
        var guard = TransportGuard{ .conn = c, .timeout_ms = c.cfg.write_timeout_ms };
        guard.start();
        c.wr.writeAll(bytes) catch {
            const expired = guard.finish();
            c.broken = true;
            return if (expired) error.NetworkWriteTimeout else error.ConnectionClosed;
        };
        c.wr.flush() catch {
            const expired = guard.finish();
            c.broken = true;
            return if (expired) error.NetworkWriteTimeout else error.ConnectionClosed;
        };
        if (guard.finish()) {
            c.broken = true;
            return error.NetworkWriteTimeout;
        }
    }

    // -------------------------------------------------------- message reading

    const Message = struct {
        tag: u8,
        data: []const u8,
    };

    fn ensureRead(c: *Conn, n: usize) Error!void {
        var guard = TransportGuard{ .conn = c, .timeout_ms = c.cfg.read_timeout_ms };
        guard.start();
        c.rd.fill(n) catch {
            const expired = guard.finish();
            c.broken = true;
            if (!expired) c.sendCancelRequest() catch {};
            return if (expired) error.NetworkReadTimeout else error.ConnectionClosed;
        };
        if (guard.finish()) {
            c.broken = true;
            return error.NetworkReadTimeout;
        }
    }

    pub var debug_traffic: bool = false;

    fn readMessage(c: *Conn) Error!Message {
        try c.ensureRead(5);
        const head = c.rd.buffered()[0..5];
        const tag = head[0];
        const total = std.mem.readInt(u32, head[1..5], .big);
        if (debug_traffic) std.debug.print("<< tag={c} len={d}\n", .{ tag, total });
        c.rd.seek += 5;
        if (total < 4) {
            c.broken = true;
            return error.ProtocolViolation;
        }
        const payload_len = total - 4;
        c.msg.clearRetainingCapacity();
        try c.msg.resize(c.gpa, payload_len);
        var off: usize = 0;
        while (off < payload_len) {
            try c.ensureRead(1);
            const avail = c.rd.buffered();
            const n = @min(avail.len, payload_len - off);
            @memcpy(c.msg.items[off .. off + n], avail[0..n]);
            c.rd.seek += n;
            off += n;
        }
        return .{ .tag = tag, .data = c.msg.items };
    }

    fn setTxnStatus(c: *Conn, data: []const u8) void {
        c.txn_status = switch (data.len) {
            0 => .idle,
            else => switch (data[0]) {
                'T' => .in_transaction,
                'E' => .in_failed_transaction,
                else => .idle,
            },
        };
    }

    // ------------------------------------------------------- error reporting

    fn parseError(payload: []const u8) PgError {
        var e: PgError = .{};
        var it = std.mem.splitScalar(u8, payload, 0);
        while (it.next()) |field| {
            if (field.len < 2) break;
            const value = field[1..];
            switch (field[0]) {
                proto.ErrField.severity => e.severity = value,
                proto.ErrField.code => e.code = value,
                proto.ErrField.message => e.message = value,
                proto.ErrField.detail => e.detail = value,
                proto.ErrField.hint => e.hint = value,
                proto.ErrField.position => e.position = value,
                proto.ErrField.schema_name => e.schema = value,
                proto.ErrField.table_name => e.table = value,
                proto.ErrField.column_name => e.column = value,
                proto.ErrField.constraint_name => e.constraint = value,
                else => {},
            }
        }
        return e;
    }

    fn storeError(c: *Conn, payload: []const u8) Error!void {
        _ = c.err_arena_state.reset(.retain_capacity);
        const arena = c.err_arena_state.allocator();
        const src = parseError(payload);
        c.last_error = .{
            .severity = arena.dupe(u8, src.severity) catch return error.OutOfMemory,
            .code = arena.dupe(u8, src.code) catch return error.OutOfMemory,
            .message = arena.dupe(u8, src.message) catch return error.OutOfMemory,
            .detail = arena.dupe(u8, src.detail) catch return error.OutOfMemory,
            .hint = arena.dupe(u8, src.hint) catch return error.OutOfMemory,
            .position = arena.dupe(u8, src.position) catch return error.OutOfMemory,
            .schema = arena.dupe(u8, src.schema) catch return error.OutOfMemory,
            .table = arena.dupe(u8, src.table) catch return error.OutOfMemory,
            .column = arena.dupe(u8, src.column) catch return error.OutOfMemory,
            .constraint = arena.dupe(u8, src.constraint) catch return error.OutOfMemory,
        };
    }

    pub fn lastError(c: *const Conn) ?PgError {
        return c.last_error;
    }

    fn errorForLastError(c: *Conn) Error {
        const e = c.last_error orelse return error.QueryFailed;
        const code = e.code;
        if (std.mem.eql(u8, code, "23505")) return error.UniqueViolation;
        if (std.mem.eql(u8, code, "23503")) return error.ForeignKeyViolation;
        if (std.mem.eql(u8, code, "23502")) return error.NotNullViolation;
        if (std.mem.eql(u8, code, "23514")) return error.CheckViolation;
        if (std.mem.eql(u8, code, "40001")) return error.SerializationFailure;
        if (std.mem.eql(u8, code, "57014")) return error.QueryCanceled;
        if (std.mem.eql(u8, code, "40P01")) return error.DeadlockDetected;
        if (std.mem.eql(u8, code, "42P01")) return error.UndefinedTable;
        if (std.mem.eql(u8, code, "42703")) return error.UndefinedColumn;
        if (std.mem.eql(u8, code, "42601")) return error.SyntaxError;
        if (std.mem.eql(u8, code, "42501")) return error.InsufficientPrivilege;
        if (std.mem.eql(u8, code, "22003")) return error.NumericValueOutOfRange;
        if (std.mem.eql(u8, code, "22P02")) return error.InvalidTextRepresentation;
        return error.QueryFailed;
    }

    pub fn preparedStats(c: *const Conn) PreparedStats {
        return .{
            .hits = c.prepared_hits,
            .misses = c.prepared_misses,
            .evictions = c.prepared_evictions,
        };
    }

    fn findPrepared(c: *Conn, sql: []const u8, params: []const Param) ?usize {
        for (c.prepared.items, 0..) |entry, i| {
            if (!std.mem.eql(u8, entry.sql, sql) or entry.oids.len != params.len) continue;
            for (params, entry.oids) |param, oid| {
                if (param.oid != oid) break;
            } else return i;
        }
        return null;
    }

    fn freePrepared(c: *Conn, entry: PreparedStatement) void {
        c.gpa.free(entry.sql);
        c.gpa.free(entry.oids);
    }

    fn removePrepared(c: *Conn, index: usize) void {
        c.freePrepared(c.prepared.orderedRemove(index));
    }

    fn queueCloseStatement(c: *Conn, name: []const u8) Error!void {
        const pos = try c.frameStart('C');
        try c.wbuf.append(c.gpa, 'S');
        try c.writeCStr(name);
        try c.frameEndAt(pos);
    }

    fn planInvalidated(c: *const Conn) bool {
        const code = if (c.last_error) |e| e.code else return false;
        return std.mem.eql(u8, code, "0A000") or std.mem.eql(u8, code, "26000");
    }

    fn sendParams(
        c: *Conn,
        sql: []const u8,
        params: []const Param,
        result_format: u16,
        close_first: ?[]const u8,
    ) Error!?PreparedStatement {
        c.last_error = null;
        c.wbuf.clearRetainingCapacity();
        if (close_first) |name| try c.queueCloseStatement(name);

        const cache_enabled = c.cfg.prepared_statement_cache_size > 0;
        var statement_name: []const u8 = "";
        var parse = true;
        var pending: ?PreparedStatement = null;
        errdefer if (pending) |entry| c.freePrepared(entry);

        if (cache_enabled) {
            c.prepared_clock +%= 1;
            if (c.findPrepared(sql, params)) |index| {
                c.prepared_hits +%= 1;
                c.prepared.items[index].last_used = c.prepared_clock;
                statement_name = c.prepared.items[index].statementName();
                parse = false;
            } else {
                c.prepared_misses +%= 1;
                if (c.prepared.items.len >= c.cfg.prepared_statement_cache_size) {
                    var oldest: usize = 0;
                    for (c.prepared.items[1..], 1..) |entry, i| {
                        if (entry.last_used < c.prepared.items[oldest].last_used) oldest = i;
                    }
                    try c.queueCloseStatement(c.prepared.items[oldest].statementName());
                    c.removePrepared(oldest);
                    c.prepared_evictions +%= 1;
                }
                try c.prepared.ensureUnusedCapacity(c.gpa, 1);
                const sql_copy = try c.gpa.dupe(u8, sql);
                const oids = c.gpa.alloc(u32, params.len) catch {
                    c.gpa.free(sql_copy);
                    return error.OutOfMemory;
                };
                for (params, oids) |param, *oid| oid.* = param.oid;
                c.prepared_next_id +%= 1;
                pending = .{
                    .sql = sql_copy,
                    .oids = oids,
                    .name = undefined,
                    .name_len = 0,
                    .last_used = c.prepared_clock,
                };
                const name = std.fmt.bufPrint(&pending.?.name, "zorm_{x}", .{c.prepared_next_id}) catch
                    return error.OutOfMemory;
                pending.?.name_len = @intCast(name.len);
                statement_name = pending.?.statementName();
            }
        }

        if (parse) {
            const pos = try c.frameStart('P');
            try c.writeCStr(statement_name);
            try c.writeCStr(sql);
            try c.writeU16(@intCast(params.len));
            for (params) |p| try c.writeU32(p.oid);
            try c.frameEndAt(pos);
        }

        var pos = try c.frameStart('B');
        try c.writeCStr("");
        try c.writeCStr(statement_name);
        try c.writeU16(@intCast(params.len));
        for (params) |p| try c.writeU16(p.format);
        try c.writeU16(@intCast(params.len));
        for (params) |p| try c.writeParam(p);
        if (result_format == 0) {
            try c.writeU16(0);
        } else {
            try c.writeU16(1);
            try c.writeU16(result_format);
        }
        try c.frameEndAt(pos);

        pos = try c.frameStart('D');
        try c.wbuf.append(c.gpa, 'P');
        try c.writeCStr("");
        try c.frameEndAt(pos);

        pos = try c.frameStart('E');
        try c.writeCStr("");
        try c.writeU32(0);
        try c.frameEndAt(pos);

        pos = try c.frameStart('S');
        try c.frameEndAt(pos);
        try c.send();
        return pending;
    }

    fn execParamsOnce(c: *Conn, sql: []const u8, params: []const Param, close_first: ?[]const u8) Error!Result {
        var pending = try c.sendParams(sql, params, if (c.cfg.binary_results) 1 else 0, close_first);
        errdefer if (pending) |entry| c.freePrepared(entry);
        const result = try c.collectResults();
        if (pending) |entry| {
            c.prepared.appendAssumeCapacity(entry);
            pending = null;
        }
        return result;
    }

    // ---------------------------------------------------------- query paths

    /// Runs SQL via the simple query protocol (multiple statements allowed,
    /// no parameters). Best for DDL and transactions.
    fn execSimpleOnce(c: *Conn, sql: []const u8) Error!Result {
        c.last_error = null;
        c.wbuf.clearRetainingCapacity();
        const pos = c.wbuf.items.len;
        try c.wbuf.append(c.gpa, 'Q');
        try c.wbuf.appendNTimes(c.gpa, 0, 4);
        try c.writeCStr(sql);
        try c.frameEndAt(pos);
        if (debug_traffic) {
            std.debug.print(">> Q '{s}' hex:", .{sql});
            for (c.wbuf.items) |b| std.debug.print(" {x:0>2}", .{b});
            std.debug.print("\n", .{});
        }
        try c.send();
        return c.collectResults();
    }

    pub fn execSimple(c: *Conn, sql: []const u8) Error!Result {
        return c.execSimpleTimeout(sql, c.cfg.query_timeout_ms);
    }

    /// Runs a simple query and cancels it through PostgreSQL's CancelRequest
    /// protocol if the deadline expires.
    pub fn execSimpleTimeout(c: *Conn, sql: []const u8, timeout_ms: u64) Error!Result {
        const effective = if (c.cfg.query_timeout_ms == 0) timeout_ms else if (timeout_ms == 0) c.cfg.query_timeout_ms else @min(timeout_ms, c.cfg.query_timeout_ms);
        if (effective == 0) return c.execSimpleOnce(sql);
        var guard = QueryGuard{ .conn = c, .timeout_ms = effective };
        guard.start();
        const result = c.execSimpleOnce(sql) catch |err| {
            return if (guard.finish()) error.QueryTimeout else err;
        };
        if (guard.finish()) {
            var owned = result;
            owned.deinit();
            return error.QueryTimeout;
        }
        return result;
    }

    /// Runs one parameterized statement via the extended query protocol.
    /// Named statements are cached per connection by SQL and parameter OIDs.
    fn execParamsCached(c: *Conn, sql: []const u8, params: []const Param) Error!Result {
        return c.execParamsOnce(sql, params, null) catch |err| {
            if (!c.planInvalidated()) return err;
            const index = c.findPrepared(sql, params) orelse return err;
            var old_name: [32]u8 = undefined;
            const name = c.prepared.items[index].statementName();
            @memcpy(old_name[0..name.len], name);
            c.removePrepared(index);
            return c.execParamsOnce(sql, params, old_name[0..name.len]);
        };
    }

    pub fn execParams(c: *Conn, sql: []const u8, params: []const Param) Error!Result {
        return c.execParamsTimeout(sql, params, c.cfg.query_timeout_ms);
    }

    /// Runs one extended-protocol query with an out-of-band cancel deadline.
    pub fn execParamsTimeout(c: *Conn, sql: []const u8, params: []const Param, timeout_ms: u64) Error!Result {
        const effective = if (c.cfg.query_timeout_ms == 0) timeout_ms else if (timeout_ms == 0) c.cfg.query_timeout_ms else @min(timeout_ms, c.cfg.query_timeout_ms);
        if (effective == 0) return c.execParamsCached(sql, params);
        var guard = QueryGuard{ .conn = c, .timeout_ms = effective };
        guard.start();
        const result = c.execParamsCached(sql, params) catch |err| {
            return if (guard.finish()) error.QueryTimeout else err;
        };
        if (guard.finish()) {
            var owned = result;
            owned.deinit();
            return error.QueryTimeout;
        }
        return result;
    }

    fn queryParamsRowsOnce(
        c: *Conn,
        sql: []const u8,
        params: []const Param,
        result_format: u16,
        close_first: ?[]const u8,
    ) Error!*Rows {
        const rows = c.gpa.create(Rows) catch return error.OutOfMemory;
        rows.* = Rows.init(c) catch |err| {
            c.gpa.destroy(rows);
            return err;
        };
        var sent = false;
        errdefer {
            if (!sent) rows.done = true;
            rows.deinit();
        }
        var pending = try c.sendParams(sql, params, result_format, close_first);
        sent = true;
        errdefer if (pending) |entry| c.freePrepared(entry);
        try rows.readDescription();
        if (pending) |entry| {
            c.prepared.appendAssumeCapacity(entry);
            pending = null;
        }
        return rows;
    }

    fn queryParamsRowsCached(c: *Conn, sql: []const u8, params: []const Param, result_format: u16) Error!*Rows {
        return c.queryParamsRowsOnce(sql, params, result_format, null) catch |err| {
            if (!c.planInvalidated()) return err;
            const index = c.findPrepared(sql, params) orelse return err;
            var old_name: [32]u8 = undefined;
            const name = c.prepared.items[index].statementName();
            @memcpy(old_name[0..name.len], name);
            c.removePrepared(index);
            return c.queryParamsRowsOnce(sql, params, result_format, old_name[0..name.len]);
        };
    }

    /// Starts an extended-protocol query whose rows are pulled one at a time.
    /// Result values use text format so they can also be exported directly.
    pub fn queryParamsStream(c: *Conn, sql: []const u8, params: []const Param) Error!*Rows {
        return c.queryParamsRowsCached(sql, params, 0);
    }

    /// Starts a cached binary-result cursor for typed ORM decoding.
    pub fn queryParamsBinary(c: *Conn, sql: []const u8, params: []const Param) Error!*Rows {
        return c.queryParamsRowsCached(sql, params, 1);
    }

    fn writeParam(c: *Conn, p: Param) Error!void {
        if (p.is_null) {
            try c.writeI32(-1);
            return;
        }
        try c.writeI32(@intCast(p.data.len));
        try c.wbuf.appendSlice(c.gpa, p.data);
    }

    fn collectResults(c: *Conn) Error!Result {
        var synchronized = false;
        errdefer {
            if (!synchronized) c.broken = true;
        }

        const arena = try c.gpa.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(c.gpa);
        errdefer {
            arena.deinit();
            c.gpa.destroy(arena);
        }
        const a = arena.allocator();

        var result: Result = .{ .arena = arena };
        var columns: std.ArrayList(Result.Column) = .empty;
        var rows: std.ArrayList(Result.Row) = .empty;
        var row_cells: std.ArrayList(?[]const u8) = .empty;
        var got_error = false;
        var has_row_description = false;

        while (true) {
            const m = try c.readMessage();
            switch (m.tag) {
                proto.Tag.row_description => {
                    columns.clearRetainingCapacity();
                    rows.clearRetainingCapacity();
                    has_row_description = true;
                    if (m.data.len < 2) return error.ProtocolViolation;
                    const nfields = std.mem.readInt(i16, m.data[0..2], .big);
                    if (nfields < 0) return error.ProtocolViolation;
                    var i: usize = 2;
                    var f: i16 = 0;
                    while (f < nfields) : (f += 1) {
                        const name_end = std.mem.indexOfScalarPos(u8, m.data, i, 0) orelse
                            return error.ProtocolViolation;
                        const name = try a.dupe(u8, m.data[i..name_end]);
                        if (m.data.len - name_end < 19) return error.ProtocolViolation;
                        const type_oid = std.mem.readInt(u32, m.data[name_end + 7 ..][0..4], .big);
                        const col_format = std.mem.readInt(u16, m.data[name_end + 17 ..][0..2], .big);
                        try columns.append(a, .{ .name = name, .type_oid = type_oid, .format = col_format });
                        i = name_end + 19; // NUL + table oid(4) + attr(2) + oid(4) + len(2) + mod(4) + format(2)
                    }
                    if (i != m.data.len) return error.ProtocolViolation;
                    result.columns = columns.items;
                },
                proto.Tag.data_row => {
                    if (m.data.len < 2) return error.ProtocolViolation;
                    const ncols = std.mem.readInt(i16, m.data[0..2], .big);
                    if (ncols < 0) return error.ProtocolViolation;
                    if (!has_row_description or @as(usize, @intCast(ncols)) != columns.items.len)
                        return error.ProtocolViolation;
                    row_cells.clearRetainingCapacity();
                    var i: usize = 2;
                    var n: i16 = 0;
                    while (n < ncols) : (n += 1) {
                        if (i + 4 > m.data.len) return error.ProtocolViolation;
                        const len = std.mem.readInt(i32, m.data[i..][0..4], .big);
                        i += 4;
                        if (len < -1) return error.ProtocolViolation;
                        if (len == -1) {
                            try row_cells.append(a, null);
                        } else {
                            const ulen: usize = @intCast(len);
                            if (i + ulen > m.data.len) return error.ProtocolViolation;
                            try row_cells.append(a, try a.dupe(u8, m.data[i..][0..ulen]));
                            i += ulen;
                        }
                    }
                    if (i != m.data.len) return error.ProtocolViolation;
                    const row = try a.alloc(?[]const u8, row_cells.items.len);
                    @memcpy(row, row_cells.items);
                    try rows.append(a, row);
                },
                proto.Tag.command_complete => {
                    if (!has_row_description) {
                        columns.clearRetainingCapacity();
                        rows.clearRetainingCapacity();
                        result.columns = columns.items;
                    }
                    if (m.data.len == 0 or m.data[m.data.len - 1] != 0)
                        return error.ProtocolViolation;
                    const tag = std.mem.sliceTo(m.data, 0);
                    result.cmd_tag = try a.dupe(u8, tag);
                    result.affected = parseAffected(tag);
                    has_row_description = false;
                },
                proto.Tag.error_response => {
                    try c.storeError(m.data);
                    if (debug_traffic) {
                        if (c.last_error) |e| {
                            std.debug.print("<< PG ERROR {s}: {s} | {s}\n", .{ e.code, e.message, e.detail });
                        }
                    }
                    got_error = true;
                },
                proto.Tag.notice_response => {
                    if (Conn.on_notice) |hook| hook(parseError(m.data));
                },
                proto.Tag.ready_for_query => {
                    if (m.data.len != 1) return error.ProtocolViolation;
                    c.setTxnStatus(m.data);
                    synchronized = true;
                    break;
                },
                else => {},
            }
        }

        result.rows = rows.items;
        if (got_error) return c.errorForLastError();
        return result;
    }

    fn parseAffected(tag: []const u8) i64 {
        // "INSERT 0 5" -> 5, "UPDATE 3" / "DELETE 3" / "SELECT 7" -> last token,
        // DDL tags ("CREATE TABLE") -> 0.
        var last: ?[]const u8 = null;
        var it = std.mem.tokenizeScalar(u8, tag, ' ');
        while (it.next()) |tok| last = tok;
        if (last) |l| return std.fmt.parseInt(i64, l, 10) catch 0;
        return 0;
    }

    // ---------------------------------------------------------------- close

    /// Frees handshake/query scratch state (wbuf, msg, TLS). Used by both
    /// `close` and the `connect` error path; leaves stream/buffers alone.
    fn deinitScratch(c: *Conn) void {
        if (c.tls) |t| {
            t.end() catch {};
            c.gpa.destroy(t);
            c.gpa.free(c.tls_mem);
            c.tls = null;
        }
        if (c.ca_bundle) |b| {
            b.deinit(c.gpa);
            c.gpa.destroy(b);
            c.ca_bundle = null;
        }
        for (c.prepared.items) |entry| c.freePrepared(entry);
        c.prepared.deinit(c.gpa);
        c.msg.deinit(c.gpa);
        c.wbuf.deinit(c.gpa);
        c.err_arena_state.deinit();
    }

    pub fn close(c: *Conn) void {
        if (c.closed) return;
        c.closed = true;
        // Best effort Terminate message.
        if (!c.broken) {
            c.wbuf.clearRetainingCapacity();
            if (c.frameStart('X')) |pos| {
                c.frameEndAt(pos) catch {};
                c.send() catch {};
            } else |_| {}
        }
        c.deinitScratch();
        c.gpa.free(c.sock_rd.interface.buffer);
        c.gpa.free(c.sock_wr.interface.buffer);
        c.stream.close(c.io);
        c.gpa.destroy(c);
    }

    /// True when the connection can be reused by a pool.
    pub fn ping(c: *Conn) Error!void {
        var result = try c.execSimple("SELECT 1");
        result.deinit();
    }

    pub fn touch(c: *Conn) void {
        c.last_used_at = Io.Clock.awake.now(c.io);
    }

    pub fn ageMilliseconds(c: *const Conn) u64 {
        const ns = c.opened_at.durationTo(Io.Clock.awake.now(c.io)).nanoseconds;
        return if (ns <= 0) 0 else @intCast(@as(u128, @intCast(ns)) / std.time.ns_per_ms);
    }

    pub fn idleMilliseconds(c: *const Conn) u64 {
        const ns = c.last_used_at.durationTo(Io.Clock.awake.now(c.io)).nanoseconds;
        return if (ns <= 0) 0 else @intCast(@as(u128, @intCast(ns)) / std.time.ns_per_ms);
    }

    pub fn healthy(c: *const Conn) bool {
        return !c.broken and !c.closed and c.txn_status == .idle;
    }
};

/// Pull-based PostgreSQL row cursor. Cell slices remain valid until the next
/// call to `next`. `deinit` drains the protocol and keeps the connection
/// reusable; a drain failure marks it broken for pool retirement.
pub const Rows = struct {
    conn: *Conn,
    arena: *std.heap.ArenaAllocator,
    columns: []Result.Column = &.{},
    cells: std.ArrayList(?[]const u8) = .empty,
    affected: i64 = 0,
    done: bool = false,
    got_error: bool = false,

    fn init(conn: *Conn) Error!Rows {
        const arena = conn.gpa.create(std.heap.ArenaAllocator) catch return error.OutOfMemory;
        arena.* = std.heap.ArenaAllocator.init(conn.gpa);
        return .{ .conn = conn, .arena = arena };
    }

    fn parseDescription(r: *Rows, data: []const u8) Error!void {
        if (data.len < 2) return error.ProtocolViolation;
        const count = std.mem.readInt(i16, data[0..2], .big);
        if (count < 0) return error.ProtocolViolation;
        const allocator = r.arena.allocator();
        const columns = allocator.alloc(Result.Column, @intCast(count)) catch return error.OutOfMemory;
        var offset: usize = 2;
        for (columns) |*column| {
            const name_end = std.mem.indexOfScalarPos(u8, data, offset, 0) orelse return error.ProtocolViolation;
            if (data.len - name_end < 19) return error.ProtocolViolation;
            column.* = .{
                .name = allocator.dupe(u8, data[offset..name_end]) catch return error.OutOfMemory,
                .type_oid = std.mem.readInt(u32, data[name_end + 7 ..][0..4], .big),
                .format = std.mem.readInt(u16, data[name_end + 17 ..][0..2], .big),
            };
            offset = name_end + 19;
        }
        if (offset != data.len) return error.ProtocolViolation;
        r.columns = columns;
        r.cells.ensureTotalCapacity(r.conn.gpa, columns.len) catch return error.OutOfMemory;
    }

    fn readDescription(r: *Rows) Error!void {
        while (true) {
            const message = try r.conn.readMessage();
            switch (message.tag) {
                proto.Tag.row_description => return r.parseDescription(message.data),
                proto.Tag.error_response => {
                    try r.conn.storeError(message.data);
                    r.got_error = true;
                },
                proto.Tag.ready_for_query => {
                    if (message.data.len != 1) return error.ProtocolViolation;
                    r.conn.setTxnStatus(message.data);
                    r.done = true;
                    return if (r.got_error) r.conn.errorForLastError() else {};
                },
                proto.Tag.notice_response => if (Conn.on_notice) |hook| hook(Conn.parseError(message.data)),
                else => {},
            }
        }
    }

    fn parseRow(r: *Rows, data: []const u8) Error!Result.Row {
        if (data.len < 2) return error.ProtocolViolation;
        const count = std.mem.readInt(i16, data[0..2], .big);
        if (count < 0 or @as(usize, @intCast(count)) != r.columns.len) return error.ProtocolViolation;
        r.cells.clearRetainingCapacity();
        var offset: usize = 2;
        for (0..@as(usize, @intCast(count))) |_| {
            if (offset + 4 > data.len) return error.ProtocolViolation;
            const len = std.mem.readInt(i32, data[offset..][0..4], .big);
            offset += 4;
            if (len < -1) return error.ProtocolViolation;
            if (len == -1) {
                r.cells.appendAssumeCapacity(null);
            } else {
                const value_len: usize = @intCast(len);
                if (offset + value_len > data.len) return error.ProtocolViolation;
                r.cells.appendAssumeCapacity(data[offset..][0..value_len]);
                offset += value_len;
            }
        }
        if (offset != data.len) return error.ProtocolViolation;
        return r.cells.items;
    }

    /// Returns the next row, or null after ReadyForQuery. Protocol and server
    /// errors are returned from the iteration point where they are observed.
    pub fn next(r: *Rows) Error!?Result.Row {
        if (r.done) return null;
        while (true) {
            const message = r.conn.readMessage() catch |err| {
                r.conn.broken = true;
                return err;
            };
            switch (message.tag) {
                proto.Tag.data_row => return try r.parseRow(message.data),
                proto.Tag.command_complete => {
                    if (message.data.len == 0 or message.data[message.data.len - 1] != 0)
                        return error.ProtocolViolation;
                    r.affected = Conn.parseAffected(std.mem.sliceTo(message.data, 0));
                },
                proto.Tag.error_response => {
                    try r.conn.storeError(message.data);
                    r.got_error = true;
                },
                proto.Tag.notice_response => if (Conn.on_notice) |hook| hook(Conn.parseError(message.data)),
                proto.Tag.ready_for_query => {
                    if (message.data.len != 1) return error.ProtocolViolation;
                    r.conn.setTxnStatus(message.data);
                    r.done = true;
                    if (r.got_error) return r.conn.errorForLastError();
                    return null;
                },
                else => {},
            }
        }
    }

    fn writeCsvField(writer: *Io.Writer, value: []const u8) !void {
        const quote = std.mem.indexOfAny(u8, value, ",\"\r\n") != null;
        if (!quote) return writer.writeAll(value);
        try writer.writeByte('\"');
        for (value) |byte| {
            if (byte == '\"') try writer.writeByte('\"');
            try writer.writeByte(byte);
        }
        try writer.writeByte('\"');
    }

    /// Streams the remaining rows as RFC 4180-style CSV without buffering the
    /// complete result set.
    pub fn writeCsv(r: *Rows, writer: *Io.Writer) !void {
        for (r.columns, 0..) |column, i| {
            if (i > 0) try writer.writeByte(',');
            try writeCsvField(writer, column.name);
        }
        try writer.writeAll("\r\n");
        while (try r.next()) |row| {
            for (row, 0..) |cell, i| {
                if (i > 0) try writer.writeByte(',');
                if (cell) |value_| try writeCsvField(writer, value_);
            }
            try writer.writeAll("\r\n");
        }
    }

    pub fn deinit(r: *Rows) void {
        while (!r.done) {
            _ = r.next() catch {
                r.conn.broken = true;
                break;
            };
        }
        const gpa = r.conn.gpa;
        r.cells.deinit(gpa);
        r.arena.deinit();
        gpa.destroy(r.arena);
        gpa.destroy(r);
    }
};

fn hex(bytes: []const u8) [64]u8 {
    // Returns a fixed buffer; callers only use the first 32 bytes for MD5.
    var out: [64]u8 = undefined;
    hexInto(&out, bytes);
    return out;
}

fn hexInto(out: []u8, bytes: []const u8) void {
    const digits = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[i * 2] = digits[b >> 4];
        out[i * 2 + 1] = digits[b & 0xF];
    }
}

test "parse affected rows" {
    try std.testing.expectEqual(@as(i64, 5), Conn.parseAffected("INSERT 0 5"));
    try std.testing.expectEqual(@as(i64, 3), Conn.parseAffected("UPDATE 3"));
    try std.testing.expectEqual(@as(i64, 7), Conn.parseAffected("SELECT 7"));
    try std.testing.expectEqual(@as(i64, 0), Conn.parseAffected("CREATE TABLE"));
}

test "hex encode" {
    var out: [4]u8 = undefined;
    hexInto(&out, "\xde\xad");
    try std.testing.expectEqualStrings("dead", &out);
}

test "config rejects embedded NUL bytes" {
    try std.testing.expectError(error.InvalidDsn, Conn.validateConfig(.{
        .user = "user\x00database",
    }));
}

test "notice parsing does not require owned storage" {
    const e = Conn.parseError("SERROR\x00C23505\x00Mduplicate\x00\x00");
    try std.testing.expectEqualStrings("ERROR", e.severity);
    try std.testing.expectEqualStrings("23505", e.code);
    try std.testing.expectEqualStrings("duplicate", e.message);
}
