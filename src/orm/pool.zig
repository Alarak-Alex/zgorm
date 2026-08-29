//! Thread-safe connection pool.

const std = @import("std");
const pq = @import("../pq.zig");

pub const Error = pq.Error;

pub const Pool = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    cfg: pq.Config,
    max_size: usize,

    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    free: std.ArrayList(*pq.Conn) = .empty,
    /// Connections currently existing (free + checked out).
    total: usize = 0,
    closed: bool = false,
    /// Details of the most recent server error (diagnostic; not synchronized).
    err_buf: [1024]u8 = undefined,
    last_error: ?pq.PgError = null,

    /// Copies the connection's server error into pool-owned storage so it
    /// outlives the session that observed it.
    pub fn captureError(p: *Pool, c: *pq.Conn) void {
        const src = c.last_error orelse return;
        var fbs: std.Io.Writer = .fixed(&p.err_buf);
        var e: pq.PgError = .{};
        e.severity = store(&fbs, src.severity);
        e.code = store(&fbs, src.code);
        e.message = store(&fbs, src.message);
        e.detail = store(&fbs, src.detail);
        e.hint = store(&fbs, src.hint);
        e.position = store(&fbs, src.position);
        e.schema = store(&fbs, src.schema);
        e.table = store(&fbs, src.table);
        e.column = store(&fbs, src.column);
        e.constraint = store(&fbs, src.constraint);
        p.last_error = e;
    }

    fn store(fbs: *std.Io.Writer, src: []const u8) []const u8 {
        if (src.len == 0) return "";
        const start = fbs.end;
        fbs.writeAll(src) catch return "";
        return fbs.buffered()[start..];
    }

    pub fn init(gpa: std.mem.Allocator, io: std.Io, cfg: pq.Config, max_size: usize) Pool {
        return .{
            .gpa = gpa,
            .io = io,
            .cfg = cfg,
            .max_size = @max(max_size, 1),
        };
    }

    /// Closes pooled connections. Connections still checked out are closed
    /// when they are released afterwards.
    pub fn deinit(p: *Pool) void {
        p.mutex.lockUncancelable(p.io);
        p.closed = true;
        for (p.free.items) |c| c.close();
        p.free.clearRetainingCapacity();
        p.mutex.unlock(p.io);
        p.free.deinit(p.gpa);
        p.cond.broadcast(p.io);
    }

    /// Returns a live connection. Blocks while `max_size` are checked out.
    pub fn acquire(p: *Pool) Error!*pq.Conn {
        p.mutex.lockUncancelable(p.io);
        while (true) {
            if (p.closed) {
                p.mutex.unlock(p.io);
                return error.ConnectionClosed;
            }
            if (p.free.items.len > 0) {
                const c = p.free.pop().?;
                p.mutex.unlock(p.io);
                return c;
            }
            if (p.total < p.max_size) {
                // Reserve the slot, then connect without holding the lock.
                p.total += 1;
                p.mutex.unlock(p.io);
                const c = pq.Conn.connect(p.gpa, p.io, p.cfg) catch |err| {
                    p.mutex.lockUncancelable(p.io);
                    p.total -= 1;
                    p.mutex.unlock(p.io);
                    p.cond.signal(p.io);
                    return err;
                };
                return c;
            }
            p.cond.waitUncancelable(p.io, &p.mutex);
        }
    }

    /// Returns a connection to the pool. Broken connections are closed.
    pub fn release(p: *Pool, c: *pq.Conn) void {
        p.mutex.lockUncancelable(p.io);
        if (!p.closed and c.healthy()) {
            p.free.append(p.gpa, c) catch {
                p.total -= 1;
                p.mutex.unlock(p.io);
                c.close();
                p.cond.signal(p.io);
                return;
            };
            p.mutex.unlock(p.io);
        } else {
            p.total -= 1;
            p.mutex.unlock(p.io);
            c.close();
        }
        p.cond.signal(p.io);
    }
};

test "pool basics against a dead endpoint" {
    // Acquire fails with ConnectionFailed and the slot is returned; pool can
    // be deinit'ed cleanly.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();

    var p = Pool.init(std.testing.allocator, threaded.io(), .{
        .user = "x",
        .host = "127.0.0.1",
        .port = 1, // nothing listens here
    }, 2);
    defer p.deinit();
    try std.testing.expectError(error.ConnectionFailed, p.acquire());
}
