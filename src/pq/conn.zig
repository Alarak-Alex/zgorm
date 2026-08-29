//! PostgreSQL client connection: wire protocol, authentication and query
//! execution. Pure Zig implementation of protocol version 3.0 — no libpq.

const std = @import("std");
const proto = @import("proto.zig");
const scram_mod = @import("scram.zig");

const net = std.Io.net;
const Io = std.Io;

pub const scram = scram_mod;

/// Driver-level errors. `QueryFailed` and friends carry details in
/// `Conn.last_error` (also mirrored on `zorm.Db.last_error`).
pub const Error = error{
    /// Could not establish a TCP/unix connection.
    ConnectionFailed,
    /// The connection was lost or is unusable.
    ConnectionClosed,
    /// The server rejected the credentials or the auth method is unsupported.
    AuthenticationFailed,
    /// Server demanded SSL but it could not be established.
    TlsUnsupported,
    /// Violation of the frontend/backend protocol.
    ProtocolViolation,
    /// The DSN could not be parsed.
    InvalidDsn,
    /// A NULL was returned for a non-optional destination field.
    NullValue,
    /// A value could not be decoded into the requested Zig type.
    TypeMismatch,
    /// The server reported an error; see `last_error`.
    QueryFailed,
    /// A model hook aborted the operation.
    HookAborted,
    OutOfMemory,

    // Mapped SQLSTATE classes:
    UniqueViolation,
    ForeignKeyViolation,
    NotNullViolation,
    CheckViolation,
    SerializationFailure,
    DeadlockDetected,
    UndefinedTable,
    UndefinedColumn,
    SyntaxError,
    InsufficientPrivilege,
    NumericValueOutOfRange,
    InvalidTextRepresentation,
};

/// Parsed ErrorResponse / NoticeResponse payload.
pub const PgError = struct {
    severity: []const u8 = "",
    code: []const u8 = "", // SQLSTATE, e.g. "23505"
    message: []const u8 = "",
    detail: []const u8 = "",
    hint: []const u8 = "",
    position: []const u8 = "",
    schema: []const u8 = "",
    table: []const u8 = "",
    column: []const u8 = "",
    constraint: []const u8 = "",
};

pub const SslMode = enum {
    /// Plaintext only. Default.
    disable,
    /// TLS, but certificate and hostname are not verified.
    require,
    /// TLS, verify the server certificate chain.
    verify_ca,
    /// TLS, verify certificate chain and hostname.
    verify_full,
};

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
};

/// A query parameter in its driver-level form. The ORM layer converts
/// comptime-typed values into this struct, pre-encoding binary formats and
/// declaring the parameter type OID through Parse so the server never has to
/// infer (or mis-infer) it.
pub const Param = struct {
    /// PostgreSQL type OID declared in the Parse message.
    oid: u32 = proto.Oid.text,
    /// 0 = text format, 1 = binary format.
    format: u16 = 0,
    is_null: bool = false,
    /// Encoded value: raw bytes for binary format, server-parseable text for
    /// text format.
    data: []const u8 = "",

    pub fn nullParam(oid: u32) Param {
        return .{ .oid = oid, .format = 1, .is_null = true };
    }
};

pub const Result = struct {
    arena: *std.heap.ArenaAllocator,
    columns: []Column = &.{},
    rows: []Row = &.{},
    cmd_tag: []const u8 = "",
    /// Row count for SELECT, affected rows for INSERT/UPDATE/DELETE.
    affected: i64 = 0,

    pub const Column = struct {
        name: []const u8,
        type_oid: u32,
        /// 0 = text format, 1 = binary format (mirrors RowDescription).
        format: u16 = 0,
    };

    pub const Row = []const ?[]const u8;

    pub fn deinit(r: *Result) void {
        const child = r.arena.child_allocator;
        r.arena.deinit();
        child.destroy(r.arena);
    }

    pub fn colIndex(r: *const Result, name: []const u8) ?usize {
        for (r.columns, 0..) |col, i| {
            if (std.mem.eql(u8, col.name, name)) return i;
        }
        return null;
    }
};

pub const TxnStatus = enum { idle, in_transaction, in_failed_transaction };

const read_buffer_len = 64 * 1024;
const write_buffer_len = 16 * 1024;

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

    // ------------------------------------------------------------------ open

    pub fn connect(gpa: std.mem.Allocator, io: Io, cfg: Config) Error!*Conn {
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

        c.* = .{
            .gpa = gpa,
            .io = io,
            .cfg = cfg,
            .stream = stream,
            .sock_rd = net.Stream.Reader.init(stream, io, rd_buf),
            .sock_wr = net.Stream.Writer.init(stream, io, wr_buf),
            .err_arena_state = std.heap.ArenaAllocator.init(gpa),
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
        if (c.cfg.ssl_mode == .verify_ca or c.cfg.ssl_mode == .verify_full) {
            const bundle = c.gpa.create(std.crypto.Certificate.Bundle) catch
                return error.OutOfMemory;
            errdefer c.gpa.destroy(bundle);
            bundle.* = .empty;
            if (c.cfg.ca_file) |file| {
                bundle.addCertsFromFilePath(c.gpa, c.io, std.Io.Timestamp.now(c.io, .real), Io.Dir.cwd(), file) catch {
                    bundle.deinit(c.gpa);
                    c.gpa.destroy(bundle);
                    c.broken = true;
                    return error.TlsUnsupported;
                };
            } else {
                bundle.rescan(c.gpa, c.io, std.Io.Timestamp.now(c.io, .real)) catch {
                    bundle.deinit(c.gpa);
                    c.gpa.destroy(bundle);
                    c.broken = true;
                    return error.TlsUnsupported;
                };
            }
            if (bundle.map.count() == 0) {
                // Fail closed: no trusted roots available.
                bundle.deinit(c.gpa);
                c.gpa.destroy(bundle);
                c.broken = true;
                return error.TlsUnsupported;
            }
            c.ca_bundle = bundle;
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

    fn send(c: *Conn) Error!void {
        c.wr.writeAll(c.wbuf.items) catch {
            c.broken = true;
            return error.ConnectionClosed;
        };
        c.wr.flush() catch {
            c.broken = true;
            return error.ConnectionClosed;
        };
        c.wbuf.clearRetainingCapacity();
    }

    fn rawWrite(c: *Conn, bytes: []const u8) !void {
        c.wr.writeAll(bytes) catch {
            c.broken = true;
            return error.ConnectionClosed;
        };
        c.wr.flush() catch {
            c.broken = true;
            return error.ConnectionClosed;
        };
    }

    // -------------------------------------------------------- message reading

    const Message = struct {
        tag: u8,
        data: []const u8,
    };

    fn ensureRead(c: *Conn, n: usize) Error!void {
        c.rd.fill(n) catch {
            c.broken = true;
            return error.ConnectionClosed;
        };
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

    fn storeError(c: *Conn, payload: []const u8) Error!void {
        _ = c.err_arena_state.reset(.retain_capacity);
        const arena = c.err_arena_state.allocator();
        var e: PgError = .{};
        var it = std.mem.splitScalar(u8, payload, 0);
        while (it.next()) |field| {
            if (field.len < 2) break;
            const value = field[1..];
            const dup = arena.dupe(u8, value) catch return error.OutOfMemory;
            switch (field[0]) {
                proto.ErrField.severity => e.severity = dup,
                proto.ErrField.code => e.code = dup,
                proto.ErrField.message => e.message = dup,
                proto.ErrField.detail => e.detail = dup,
                proto.ErrField.hint => e.hint = dup,
                proto.ErrField.position => e.position = dup,
                proto.ErrField.schema_name => e.schema = dup,
                proto.ErrField.table_name => e.table = dup,
                proto.ErrField.column_name => e.column = dup,
                proto.ErrField.constraint_name => e.constraint = dup,
                else => {},
            }
        }
        c.last_error = e;
    }

    fn errorForLastError(c: *Conn) Error {
        const e = c.last_error orelse return error.QueryFailed;
        const code = e.code;
        if (std.mem.eql(u8, code, "23505")) return error.UniqueViolation;
        if (std.mem.eql(u8, code, "23503")) return error.ForeignKeyViolation;
        if (std.mem.eql(u8, code, "23502")) return error.NotNullViolation;
        if (std.mem.eql(u8, code, "23514")) return error.CheckViolation;
        if (std.mem.eql(u8, code, "40001")) return error.SerializationFailure;
        if (std.mem.eql(u8, code, "40P01")) return error.DeadlockDetected;
        if (std.mem.eql(u8, code, "42P01")) return error.UndefinedTable;
        if (std.mem.eql(u8, code, "42703")) return error.UndefinedColumn;
        if (std.mem.eql(u8, code, "42601")) return error.SyntaxError;
        if (std.mem.eql(u8, code, "42501")) return error.InsufficientPrivilege;
        if (std.mem.eql(u8, code, "22003")) return error.NumericValueOutOfRange;
        if (std.mem.eql(u8, code, "22P02")) return error.InvalidTextRepresentation;
        return error.QueryFailed;
    }

    // ---------------------------------------------------------- query paths

    /// Runs SQL via the simple query protocol (multiple statements allowed,
    /// no parameters). Best for DDL and transactions.
    pub fn execSimple(c: *Conn, sql: []const u8) Error!Result {
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

    /// Runs one parameterized statement via the extended query protocol.
    /// Parameters are sent in text format; results come back in text format.
    pub fn execParams(c: *Conn, sql: []const u8, params: []const Param) Error!Result {
        c.last_error = null;
        c.wbuf.clearRetainingCapacity();

        // Parse (unnamed statement) with explicit parameter type OIDs.
        // Layout: statement-name \0 query \0 i16 count ++ i32 oid per param.
        var pos = try c.frameStart('P');
        try c.writeCStr(""); // statement name: unnamed
        try c.writeCStr(sql);
        try c.writeU16(@intCast(params.len));
        for (params) |p| try c.writeU32(p.oid);
        try c.frameEndAt(pos);

        // Bind with per-parameter format codes (binary for scalars, text for
        // complex types); results stay in text format.
        pos = try c.frameStart('B');
        try c.writeCStr(""); // portal
        try c.writeCStr(""); // statement
        try c.writeU16(@intCast(params.len));
        for (params) |p| try c.writeU16(p.format);
        try c.writeU16(@intCast(params.len));
        for (params) |p| try c.writeParam(p);
        // Result format: all-binary when enabled, all-text otherwise.
        if (c.cfg.binary_results) {
            try c.writeU16(1);
            try c.writeU16(1);
        } else {
            try c.writeU16(0);
        }
        try c.frameEndAt(pos);

        // Describe portal
        pos = try c.frameStart('D');
        try c.wbuf.append(c.gpa, 'P');
        try c.writeCStr("");
        try c.frameEndAt(pos);

        // Execute (no row limit)
        pos = try c.frameStart('E');
        try c.writeCStr("");
        try c.writeU32(0);
        try c.frameEndAt(pos);

        // Sync
        pos = try c.frameStart('S');
        try c.frameEndAt(pos);

        if (debug_traffic) {
            for (c.wbuf.items) |b| std.debug.print("{x:0>2} ", .{b});
            std.debug.print("\n", .{});
        }
        try c.send();
        return c.collectResults();
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

        while (true) {
            const m = try c.readMessage();
            switch (m.tag) {
                proto.Tag.row_description => {
                    columns.clearRetainingCapacity();
                    if (m.data.len < 2) return error.ProtocolViolation;
                    const nfields = std.mem.readInt(i16, m.data[0..2], .big);
                    var i: usize = 2;
                    var f: i16 = 0;
                    while (f < nfields) : (f += 1) {
                        const name_end = std.mem.indexOfScalarPos(u8, m.data, i, 0) orelse
                            return error.ProtocolViolation;
                        const name = try a.dupe(u8, m.data[i..name_end]);
                        if (name_end + 18 > m.data.len) return error.ProtocolViolation;
                        const type_oid = std.mem.readInt(u32, m.data[name_end + 7 ..][0..4], .big);
                        const col_format = std.mem.readInt(u16, m.data[name_end + 17 ..][0..2], .big);
                        try columns.append(a, .{ .name = name, .type_oid = type_oid, .format = col_format });
                        i = name_end + 19; // NUL + table oid(4) + attr(2) + oid(4) + len(2) + mod(4) + format(2)
                    }
                    result.columns = columns.items;
                },
                proto.Tag.data_row => {
                    if (m.data.len < 2) return error.ProtocolViolation;
                    const ncols = std.mem.readInt(i16, m.data[0..2], .big);
                    row_cells.clearRetainingCapacity();
                    var i: usize = 2;
                    var n: i16 = 0;
                    while (n < ncols) : (n += 1) {
                        if (i + 4 > m.data.len) return error.ProtocolViolation;
                        const len = std.mem.readInt(i32, m.data[i..][0..4], .big);
                        i += 4;
                        if (len < 0) {
                            try row_cells.append(a, null);
                        } else {
                            const ulen: usize = @intCast(len);
                            if (i + ulen > m.data.len) return error.ProtocolViolation;
                            try row_cells.append(a, try a.dupe(u8, m.data[i..][0..ulen]));
                            i += ulen;
                        }
                    }
                    const row = try a.alloc(?[]const u8, row_cells.items.len);
                    @memcpy(row, row_cells.items);
                    try rows.append(a, row);
                },
                proto.Tag.command_complete => {
                    const tag = std.mem.sliceTo(m.data, 0);
                    result.cmd_tag = try a.dupe(u8, tag);
                    result.affected = parseAffected(tag);
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
                    if (Conn.on_notice) |hook| {
                        try c.storeError(m.data);
                        if (c.last_error) |e| hook(e);
                        c.last_error = null;
                    }
                },
                proto.Tag.ready_for_query => {
                    c.setTxnStatus(m.data);
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
        if (c.ca_bundle) |b| {
            b.deinit(c.gpa);
            c.gpa.destroy(b);
            c.ca_bundle = null;
        }
        if (c.tls) |t| {
            t.end() catch {};
            c.gpa.destroy(t);
            c.gpa.free(c.tls_mem);
            c.tls = null;
        }
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
    pub fn healthy(c: *const Conn) bool {
        return !c.broken and !c.closed and c.txn_status == .idle;
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
