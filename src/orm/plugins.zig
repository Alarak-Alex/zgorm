//! Global query/CRUD callbacks and small production plugins.

const std = @import("std");
const observability = @import("observability.zig");

pub const Operation = enum { select, insert, update, delete, other };
pub const Phase = enum { before, after };

pub const QueryContext = struct {
    sql: []const u8,
    operation: Operation,
    phase: Phase,
    event: ?observability.QueryEvent = null,
};

pub const CrudContext = struct {
    sql: []const u8,
    operation: Operation,
    phase: Phase,
    affected_rows: i64 = 0,
};

pub const BeforeQuery = *const fn (?*anyopaque, QueryContext) bool;
pub const AfterQuery = *const fn (?*anyopaque, QueryContext) void;
pub const BeforeCrud = *const fn (?*anyopaque, CrudContext) bool;
pub const AfterCrud = *const fn (?*anyopaque, CrudContext) void;

pub const Plugin = struct {
    context: ?*anyopaque = null,
    before_query: ?BeforeQuery = null,
    after_query: ?AfterQuery = null,
    before_crud: ?BeforeCrud = null,
    after_crud: ?AfterCrud = null,
};

pub const Registry = struct {
    entries: [16]Plugin = undefined,
    len: usize = 0,

    pub fn add(r: *Registry, plugin: Plugin) bool {
        if (r.len == r.entries.len) return false;
        r.entries[r.len] = plugin;
        r.len += 1;
        return true;
    }

    pub fn runBeforeQuery(r: *const Registry, sql: []const u8) bool {
        const context = QueryContext{ .sql = sql, .operation = operation(sql), .phase = .before };
        for (r.entries[0..r.len]) |plugin| {
            if (plugin.before_query) |callback| if (!callback(plugin.context, context)) return false;
        }
        return true;
    }

    pub fn runAfterQuery(r: *const Registry, event: observability.QueryEvent) void {
        const context = QueryContext{ .sql = event.sql, .operation = operation(event.sql), .phase = .after, .event = event };
        for (r.entries[0..r.len]) |plugin| if (plugin.after_query) |callback| callback(plugin.context, context);
    }

    pub fn runBeforeCrud(r: *const Registry, sql: []const u8) bool {
        const op = operation(sql);
        if (op == .select or op == .other) return true;
        const context = CrudContext{ .sql = sql, .operation = op, .phase = .before };
        for (r.entries[0..r.len]) |plugin| {
            if (plugin.before_crud) |callback| if (!callback(plugin.context, context)) return false;
        }
        return true;
    }

    pub fn runAfterCrud(r: *const Registry, sql: []const u8, affected_rows: i64) void {
        const op = operation(sql);
        if (op == .select or op == .other) return;
        const context = CrudContext{ .sql = sql, .operation = op, .phase = .after, .affected_rows = affected_rows };
        for (r.entries[0..r.len]) |plugin| if (plugin.after_crud) |callback| callback(plugin.context, context);
    }
};

pub fn operation(sql: []const u8) Operation {
    const trimmed = std.mem.trim(u8, sql, " \t\r\n");
    const end = std.mem.indexOfAny(u8, trimmed, " \t\r\n") orelse trimmed.len;
    const word = trimmed[0..end];
    if (std.ascii.eqlIgnoreCase(word, "select") or std.ascii.eqlIgnoreCase(word, "with")) return .select;
    if (std.ascii.eqlIgnoreCase(word, "insert")) return .insert;
    if (std.ascii.eqlIgnoreCase(word, "update")) return .update;
    if (std.ascii.eqlIgnoreCase(word, "delete")) return .delete;
    return .other;
}

pub const Metrics = struct {
    queries: std.atomic.Value(u64) = .init(0),
    failures: std.atomic.Value(u64) = .init(0),
    mutations: std.atomic.Value(u64) = .init(0),

    pub fn plugin(metrics: *Metrics) Plugin {
        return .{ .context = metrics, .after_query = afterQuery, .after_crud = afterCrud };
    }

    fn afterQuery(raw: ?*anyopaque, context: QueryContext) void {
        const metrics: *Metrics = @ptrCast(@alignCast(raw.?));
        _ = metrics.queries.fetchAdd(1, .monotonic);
        if (context.event.?.error_class != .none) _ = metrics.failures.fetchAdd(1, .monotonic);
    }

    fn afterCrud(raw: ?*anyopaque, _: CrudContext) void {
        const metrics: *Metrics = @ptrCast(@alignCast(raw.?));
        _ = metrics.mutations.fetchAdd(1, .monotonic);
    }
};

pub const Trace = struct {
    context: ?*anyopaque = null,
    emit: *const fn (?*anyopaque, observability.QueryEvent) void,

    pub fn plugin(trace: *Trace) Plugin {
        return .{ .context = trace, .after_query = afterQuery };
    }

    fn afterQuery(raw: ?*anyopaque, context: QueryContext) void {
        const trace: *Trace = @ptrCast(@alignCast(raw.?));
        trace.emit(trace.context, context.event.?);
    }
};

pub const Audit = struct {
    context: ?*anyopaque = null,
    record: *const fn (?*anyopaque, CrudContext) void,

    pub fn plugin(audit: *Audit) Plugin {
        return .{ .context = audit, .after_crud = afterCrud };
    }

    fn afterCrud(raw: ?*anyopaque, context: CrudContext) void {
        const audit: *Audit = @ptrCast(@alignCast(raw.?));
        audit.record(audit.context, context);
    }
};

pub const CacheInvalidation = struct {
    context: ?*anyopaque = null,
    invalidate: *const fn (?*anyopaque, Operation) void,

    pub fn plugin(cache: *CacheInvalidation) Plugin {
        return .{ .context = cache, .after_crud = afterCrud };
    }

    fn afterCrud(raw: ?*anyopaque, context: CrudContext) void {
        const cache: *CacheInvalidation = @ptrCast(@alignCast(raw.?));
        cache.invalidate(cache.context, context.operation);
    }
};

pub const TenantFilter = struct {
    column: []const u8 = "tenant_id",

    pub fn apply(filter: TenantFilter, query: anytype, tenant_id: anytype) @TypeOf(query) {
        return query.whereEq(filter.column, tenant_id);
    }
};

pub const Pagination = struct {
    page: u64,
    per_page: u64,

    pub fn apply(p: Pagination, query: anytype) @TypeOf(query) {
        const size = @min(p.per_page, 10_000);
        return query.limit(@intCast(size)).offset(@intCast(p.page *| size));
    }
};

pub const Encryption = struct {
    key: [32]u8,

    pub fn encrypt(e: Encryption, io: std.Io, gpa: std.mem.Allocator, plaintext: []const u8, associated_data: []const u8) ![]u8 {
        const Aes = std.crypto.aead.aes_gcm.Aes256Gcm;
        const output = try gpa.alloc(u8, Aes.nonce_length + plaintext.len + Aes.tag_length);
        errdefer gpa.free(output);
        const nonce: *[Aes.nonce_length]u8 = output[0..Aes.nonce_length];
        io.random(nonce);
        const ciphertext = output[Aes.nonce_length .. Aes.nonce_length + plaintext.len];
        const tag: *[Aes.tag_length]u8 = output[output.len - Aes.tag_length ..][0..Aes.tag_length];
        Aes.encrypt(ciphertext, tag, plaintext, associated_data, nonce.*, e.key);
        return output;
    }

    pub fn decrypt(e: Encryption, gpa: std.mem.Allocator, encoded: []const u8, associated_data: []const u8) ![]u8 {
        const Aes = std.crypto.aead.aes_gcm.Aes256Gcm;
        if (encoded.len < Aes.nonce_length + Aes.tag_length) return error.AuthenticationFailed;
        const plaintext = try gpa.alloc(u8, encoded.len - Aes.nonce_length - Aes.tag_length);
        errdefer gpa.free(plaintext);
        const nonce: *const [Aes.nonce_length]u8 = encoded[0..Aes.nonce_length];
        const ciphertext = encoded[Aes.nonce_length .. encoded.len - Aes.tag_length];
        const tag: *const [Aes.tag_length]u8 = encoded[encoded.len - Aes.tag_length ..][0..Aes.tag_length];
        try Aes.decrypt(plaintext, ciphertext, tag.*, associated_data, nonce.*, e.key);
        return plaintext;
    }
};

test "operation classification and encryption" {
    try std.testing.expectEqual(Operation.insert, operation("  INSERT INTO t VALUES (1)"));
    try std.testing.expectEqual(Operation.select, operation("WITH x AS (SELECT 1) SELECT * FROM x"));
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const encryption = Encryption{ .key = [_]u8{7} ** 32 };
    const encrypted = try encryption.encrypt(threaded.io(), std.testing.allocator, "secret", "users.email");
    defer std.testing.allocator.free(encrypted);
    const decrypted = try encryption.decrypt(std.testing.allocator, encrypted, "users.email");
    defer std.testing.allocator.free(decrypted);
    try std.testing.expectEqualStrings("secret", decrypted);
}
