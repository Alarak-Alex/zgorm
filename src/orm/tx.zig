//! A pinned-connection transaction. A Tx created with `begin()` on another
//! Tx represents a SAVEPOINT: `commit()` releases it, `rollback()` rolls back
//! to it (and releases). Every Session operation is available on the Tx.

const std = @import("std");
const pq = @import("../drivers/postgres/root.zig");
const session_mod = @import("session.zig");
const assoc_mod = @import("association.zig");

pub const Error = pq.Error;

pub const Tx = struct {
    sess: *session_mod.Session,
    /// True when the Tx owns its (heap) session — `Db.begin`.
    owns_session: bool = false,
    /// True when this Tx is a savepoint inside an outer transaction.
    is_savepoint: bool = false,
    sp_name_buf: [24]u8 = undefined,
    sp_name_len: usize = 0,
    finished: bool = false,

    fn spName(t: *const Tx) []const u8 {
        return t.sp_name_buf[0..t.sp_name_len];
    }

    /// Starts a nested transaction (SAVEPOINT) inside this transaction.
    pub fn begin(t: *Tx) Error!Tx {
        if (t.sess.pinned == null) return error.ProtocolViolation;
        t.sess.savepoint_depth += 1;
        errdefer t.sess.savepoint_depth -= 1;

        var sp = Tx{ .sess = t.sess, .is_savepoint = true };
        const name = std.fmt.bufPrint(&sp.sp_name_buf, "zgorm_sp_{d}", .{t.sess.savepoint_depth}) catch
            unreachable;
        sp.sp_name_len = name.len;

        const sql = std.fmt.allocPrint(t.sess.gpa, "SAVEPOINT {s}", .{sp.spName()}) catch
            return error.OutOfMemory;
        defer t.sess.gpa.free(sql);
        var res = try t.sess.execRaw(sql);
        res.deinit();
        return sp;
    }

    fn releaseSavepoint(t: *Tx, comptime action: []const u8) Error!void {
        const sql = std.fmt.allocPrint(t.sess.gpa, "{s} SAVEPOINT {s}", .{ action, t.spName() }) catch
            return error.OutOfMemory;
        defer t.sess.gpa.free(sql);
        var res = try t.sess.execRaw(sql);
        res.deinit();
    }

    fn finish(t: *Tx) void {
        if (t.owns_session) t.sess.gpa.destroy(t.sess);
    }

    pub fn commit(t: *Tx) Error!void {
        if (t.finished) return error.ConnectionClosed;
        _ = t.sess.transactionTimeout(0) catch |err| {
            t.rollback();
            return err;
        };
        t.finished = true;
        if (t.is_savepoint) {
            t.releaseSavepoint("RELEASE") catch |e| {
                t.sess.savepoint_depth -= 1;
                t.finish();
                return e;
            };
            t.sess.savepoint_depth -= 1;
            t.finish();
            return;
        }
        const conn = t.sess.pinned.?;
        var res = conn.execSimple("COMMIT") catch |e| {
            t.sess.captureError(conn);
            t.sess.transaction_deadline = null;
            t.sess.pinned = null;
            t.sess.pool.release(conn);
            t.finish();
            return e;
        };
        t.sess.transaction_deadline = null;
        res.deinit();
        t.sess.pinned = null;
        t.sess.pool.release(conn);
        t.finish();
    }

    /// Rolls back. Safe to call from `defer`; safe on an already-finished tx.
    pub fn rollback(t: *Tx) void {
        if (t.finished) return;
        t.finished = true;
        if (t.is_savepoint) {
            // Roll back to the savepoint, then release it so the name can be
            // reused later in the same transaction.
            t.releaseSavepoint("ROLLBACK TO") catch {
                t.sess.savepoint_depth -= 1;
                t.finish();
                return;
            };
            t.releaseSavepoint("RELEASE") catch {};
            t.sess.savepoint_depth -= 1;
            t.finish();
            return;
        }
        const conn = t.sess.pinned.?;
        t.sess.transaction_deadline = null;
        var res = conn.execSimple("ROLLBACK") catch {
            t.sess.pinned = null;
            t.sess.pool.release(conn);
            t.finish();
            return;
        };
        res.deinit();
        t.sess.pinned = null;
        t.sess.pool.release(conn);
        t.finish();
    }

    // All Session operations are available on the transaction.
    pub fn insert(t: *Tx, m: anytype) Error!void {
        return t.sess.insert(m);
    }
    pub fn insertBatch(t: *Tx, models: anytype) Error!void {
        return t.sess.insertBatch(models);
    }
    pub fn insertReturning(t: *Tx, m: anytype, comptime R: type, comptime fields: []const []const u8) Error!R {
        return t.sess.insertReturning(m, R, fields);
    }
    pub fn insertBatchReturning(t: *Tx, models: anytype, comptime R: type, comptime fields: []const []const u8) Error![]R {
        return t.sess.insertBatchReturning(models, R, fields);
    }
    pub fn upsert(t: *Tx, m: anytype, comptime conflict: session_mod.OnConflict) Error!bool {
        return t.sess.upsert(m, conflict);
    }
    pub fn upsertBatch(t: *Tx, models: anytype, comptime conflict: session_mod.OnConflict) Error!usize {
        return t.sess.upsertBatch(models, conflict);
    }
    pub fn update(t: *Tx, m: anytype) Error!i64 {
        return t.sess.update(m);
    }
    pub fn updateBatch(t: *Tx, models: anytype) Error!usize {
        return t.sess.updateBatch(models);
    }
    pub fn save(t: *Tx, m: anytype) Error!void {
        return t.sess.save(m);
    }
    pub fn delete(t: *Tx, m: anytype) Error!i64 {
        return t.sess.delete(m);
    }
    pub fn deleteWhere(t: *Tx, comptime T: type, frag: []const u8, args: anytype) Error!i64 {
        return t.sess.deleteWhere(T, frag, args);
    }
    pub fn deleteHard(t: *Tx, m: anytype) Error!i64 {
        return t.sess.deleteHard(m);
    }
    pub fn deleteWhereHard(t: *Tx, comptime T: type, frag: []const u8, args: anytype) Error!i64 {
        return t.sess.deleteWhereHard(T, frag, args);
    }
    pub fn restore(t: *Tx, m: anytype) Error!i64 {
        return t.sess.restore(m);
    }
    pub fn updateWhere(t: *Tx, comptime T: type, sets: anytype, frag: []const u8, args: anytype) Error!i64 {
        return t.sess.updateWhere(T, sets, frag, args);
    }
    pub fn find(t: *Tx, comptime T: type, pk: anytype) Error!?T {
        return t.sess.find(T, pk);
    }
    pub fn findUnscoped(t: *Tx, comptime T: type, pk: anytype) Error!?T {
        return t.sess.findUnscoped(T, pk);
    }
    pub fn updateUnscoped(t: *Tx, m: anytype) Error!i64 {
        return t.sess.updateUnscoped(m);
    }
    pub fn association(t: *Tx, parent: anytype, comptime field_name: []const u8) assoc_mod.Association(@typeInfo(@TypeOf(parent)).pointer.child, field_name) {
        return t.sess.association(parent, field_name);
    }
    pub fn query(t: *Tx, comptime T: type) *session_mod.Query(T) {
        const gpa = t.sess.gpa;
        const q = gpa.create(session_mod.Query(T)) catch @panic("zgorm: out of memory");
        q.* = .{
            .sess = t.sess,
            .owns_session = false,
            .arena = std.heap.ArenaAllocator.init(gpa),
        };
        return q;
    }
    pub fn execTimeout(t: *Tx, sql: []const u8, args: anytype, timeout_ms: u64) Error!pq.Result {
        return t.sess.execTimeout(sql, args, timeout_ms);
    }
    pub fn exec(t: *Tx, sql: []const u8, args: anytype) Error!pq.Result {
        return t.sess.exec(sql, args);
    }
    pub fn execRawTimeout(t: *Tx, sql: []const u8, timeout_ms: u64) Error!pq.Result {
        return t.sess.execRawTimeout(sql, timeout_ms);
    }
    pub fn execRaw(t: *Tx, sql: []const u8) Error!pq.Result {
        return t.sess.execRaw(sql);
    }
};
