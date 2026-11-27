//! Typed CRUD on a Session: insert / upsert / update / delete / restore /
//! find, batch variants, hooks, optimistic locking and association saving.
//! Comptime statement templates come from `crud_sql.zig`.

const std = @import("std");
const pq = @import("../../drivers/postgres/root.zig");
const qb_mod = @import("../qb.zig");
const schema = @import("../schema.zig");
const value = @import("../value.zig");
const time_mod = @import("../time.zig");
const crud_sql = @import("crud_sql.zig");
const crud_helpers = @import("crud_helpers.zig");
const session_mod = @import("../session.zig");
const assoc_mod = @import("../association.zig");

const Session = session_mod.Session;
const Time = time_mod.Time;
pub const Error = pq.Error;
pub const OnConflict = crud_sql.OnConflict;
const callHook = Session.callHook;

/// Inserts one model. Auto-increment primary keys are filled back in.
/// `created_at` / `updated_at` columns are auto-stamped when empty.
/// When the model saves associations and no transaction is active, the
/// insert and its association writes run in one internal transaction so a
/// mid-way failure cannot leave a committed parent with orphaned children.
pub fn insert(s: *Session, m: anytype) Error!void {
    const MP = @typeInfo(@TypeOf(m));
    if (MP != .pointer or MP.pointer.size != .one or MP.pointer.attrs.@"const")
        @compileError("zgorm: insert expects a mutable pointer to a model, e.g. db.insert(&user)");
    const T = MP.pointer.child;
    const table = comptime schema.tableOf(T);
    const needs_tx = comptime blk: {
        for (table.assocs) |a| {
            if (a.kind != .belongs_to) break :blk true;
        }
        break :blk false;
    };
    if (!needs_tx or s.pinned != null) return insertImpl(s, m);
    var tx = try s.begin();
    errdefer tx.rollback();
    try insertImpl(s, m);
    try tx.commit();
}

pub fn insertImpl(s: *Session, m: anytype) Error!void {
    const MP = @typeInfo(@TypeOf(m));
    if (MP != .pointer or MP.pointer.size != .one or MP.pointer.attrs.@"const")
        @compileError("zgorm: insert expects a mutable pointer to a model, e.g. db.insert(&user)");
    const T = MP.pointer.child;
    const table = comptime schema.tableOf(T);

    try callHook(T, "beforeSave", m, s);
    try callHook(T, "beforeCreate", m, s);
    try crud_helpers.autoStamp(s, T, m, true);

    var arena_state = std.heap.ArenaAllocator.init(s.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const params = arena.alloc(pq.Param, table.columns.len) catch return error.OutOfMemory;

    const pk_col = comptime table.pk();
    const single_auto = comptime crud_sql.autoColumnCount(table) == 1 and pk_col != null and pk_col.?.is_auto;

    var b = crud_sql.SqlBuf.init(arena);
    var sql: []const u8 = undefined;
    var returning = false;
    if (single_auto) {
        // SQL is fully determined by whether the auto pk is zero; reuse a
        // comptime template instead of rebuilding it per insert.
        const pk_zero = crud_helpers.isZeroValue(value.getColumn(m, pk_col.?));
        returning = pk_zero;
        sql = if (pk_zero) crud_sql.InsertSql(T, false, true).value else crud_sql.InsertSql(T, true, false).value;
    } else {
        const w = b.w();
        w.print("INSERT INTO {s} (", .{qb_mod.quoted(table.name)}) catch return error.OutOfMemory;
        var first = true;
        inline for (table.columns) |col| {
            if (!(col.is_auto and crud_helpers.isZeroValue(value.getColumn(m, col)))) {
                if (!first) w.writeAll(", ") catch return error.OutOfMemory;
                w.writeAll(qb_mod.quoted(col.name)) catch return error.OutOfMemory;
                first = false;
            }
        }
        w.writeAll(") VALUES (") catch return error.OutOfMemory;
        var nparams: usize = 0;
        inline for (table.columns) |col| {
            if (!(col.is_auto and crud_helpers.isZeroValue(value.getColumn(m, col)))) {
                if (nparams > 0) w.writeAll(", ") catch return error.OutOfMemory;
                w.print("${d}", .{nparams + 1}) catch return error.OutOfMemory;
                nparams += 1;
            }
        }
        w.writeAll(")") catch return error.OutOfMemory;
        if (comptime (pk_col != null and pk_col.?.is_auto)) {
            if (crud_helpers.isZeroValue(value.getColumn(m, pk_col.?))) {
                returning = true;
                w.print(" RETURNING {s}", .{qb_mod.quoted(pk_col.?.name)}) catch return error.OutOfMemory;
            }
        }
        sql = b.slice();
    }

    var np: usize = 0;
    inline for (table.columns) |col| {
        if (!(col.is_auto and crud_helpers.isZeroValue(value.getColumn(m, col)))) {
            params[np] = try value.toParam(value.getColumn(m, col), arena);
            np += 1;
        }
    }

    var res = try s.runExec(sql, params[0..np]);
    defer res.deinit();

    if (returning and res.rows.len > 0 and table.pk_index != null) {
        const pkc = table.columns[table.pk_index.?];
        const FType = value.columnFieldType(T, pkc);
        value.setColumn(m, pkc, try value.decodeCell(
            FType,
            res.rows[0][0],
            res.columns[0].type_oid,
            res.columns[0].format,
            s.gpa,
        ));
    }

    try crud_helpers.saveAssociations(s, T, m);
    try callHook(T, "afterCreate", m, s);
    try callHook(T, "afterSave", m, s);
}

/// Inserts one model and decodes arbitrary RETURNING columns into `R`.
/// Returned heap fields are owned by `s.gpa`.
pub fn insertReturning(
    s: *Session,
    m: anytype,
    comptime R: type,
    comptime fields: []const []const u8,
) Error!R {
    if (fields.len == 0) @compileError("zgorm: insertReturning requires at least one field");
    const MP = @typeInfo(@TypeOf(m));
    if (MP != .pointer or MP.pointer.size != .one or MP.pointer.attrs.@"const")
        @compileError("zgorm: insertReturning expects a mutable model pointer");
    const T = MP.pointer.child;
    const table = comptime schema.tableOf(T);
    inline for (fields) |name| {
        if (comptime !table.hasColumn(name)) @compileError("zgorm: unknown RETURNING column " ++ name);
    }

    try callHook(T, "beforeSave", m, s);
    try callHook(T, "beforeCreate", m, s);
    try crud_helpers.autoStamp(s, T, m, true);

    var arena_state = std.heap.ArenaAllocator.init(s.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var params: std.ArrayList(pq.Param) = .empty;
    var b = crud_sql.SqlBuf.init(arena);
    const w = b.w();
    const pk_col = comptime table.pk();
    const return_pk = comptime pk_col != null and pk_col.?.is_auto and !crud_sql.containsName(fields, pk_col.?.name);

    w.print("INSERT INTO {s} (", .{qb_mod.quoted(table.name)}) catch return error.OutOfMemory;
    var first = true;
    inline for (table.columns) |col| {
        if (!(col.is_auto and crud_helpers.isZeroValue(value.getColumn(m, col)))) {
            if (!first) w.writeAll(", ") catch return error.OutOfMemory;
            w.writeAll(qb_mod.quoted(col.name)) catch return error.OutOfMemory;
            first = false;
        }
    }
    w.writeAll(") VALUES (") catch return error.OutOfMemory;
    var np: usize = 0;
    inline for (table.columns) |col| {
        if (!(col.is_auto and crud_helpers.isZeroValue(value.getColumn(m, col)))) {
            if (np > 0) w.writeAll(", ") catch return error.OutOfMemory;
            w.print("${d}", .{np + 1}) catch return error.OutOfMemory;
            params.append(arena, try value.toParam(value.getColumn(m, col), arena)) catch return error.OutOfMemory;
            np += 1;
        }
    }
    w.writeAll(") RETURNING ") catch return error.OutOfMemory;
    inline for (fields, 0..) |name, i| {
        if (i > 0) w.writeAll(", ") catch return error.OutOfMemory;
        w.writeAll(try qb_mod.quoteIdent(arena, name)) catch return error.OutOfMemory;
    }
    if (return_pk) {
        w.print(", {s}", .{qb_mod.quoted(pk_col.?.name)}) catch return error.OutOfMemory;
    }

    var res = try s.runExec(b.slice(), params.items);
    defer res.deinit();
    if (res.rows.len != 1) return error.ProtocolViolation;
    if (comptime pk_col != null and pk_col.?.is_auto) {
        if (crud_helpers.isZeroValue(value.getColumn(m, pk_col.?))) {
            const ci = res.colIndex(pk_col.?.name) orelse return error.ProtocolViolation;
            value.setColumn(m, pk_col.?, try value.decodeCell(
                value.columnFieldType(T, pk_col.?),
                res.rows[0][ci],
                res.columns[ci].type_oid,
                res.columns[ci].format,
                s.gpa,
            ));
        }
    }
    const returned = try value.scanRow(R, comptime schema.tableOf(R), &res, res.rows[0], s.gpa);
    try callHook(T, "afterCreate", m, s);
    try callHook(T, "afterSave", m, s);
    return returned;
}

/// Inserts a mutable slice atomically and returns one projection per row.
pub fn insertBatchReturning(
    s: *Session,
    models: anytype,
    comptime R: type,
    comptime fields: []const []const u8,
) Error![]R {
    const P = @typeInfo(@TypeOf(models));
    const Items: type = blk: {
        if (P == .pointer and P.pointer.size == .slice and !P.pointer.attrs.@"const") break :blk @TypeOf(models);
        if (P == .pointer and P.pointer.size == .one and @typeInfo(P.pointer.child) == .array and !P.pointer.attrs.@"const")
            break :blk []@typeInfo(P.pointer.child).array.child;
        @compileError("zgorm: insertBatchReturning expects a mutable slice");
    };
    const list: Items = models;
    const out = s.gpa.alloc(R, list.len) catch return error.OutOfMemory;
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |item| value.freeValue(R, item, s.gpa);
        s.gpa.free(out);
    }
    if (s.pinned != null) {
        for (list, 0..) |*model, i| {
            out[i] = try s.insertReturning(model, R, fields);
            initialized += 1;
        }
        return out;
    }
    var tx = try s.begin();
    errdefer tx.rollback();
    for (list, 0..) |*model, i| {
        out[i] = try tx.insertReturning(model, R, fields);
        initialized += 1;
    }
    try tx.commit();
    return out;
}

/// Inserts a model with a compile-time PostgreSQL ON CONFLICT policy.
/// Returns false only when DO NOTHING skipped a conflicting row.
pub fn upsert(s: *Session, m: anytype, comptime conflict: OnConflict) Error!bool {
    const MP = @typeInfo(@TypeOf(m));
    if (MP != .pointer or MP.pointer.size != .one)
        @compileError("zgorm: upsert expects a pointer to a model");
    const T = MP.pointer.child;
    const table = comptime schema.tableOf(T);
    inline for (conflict.columns) |name| {
        if (comptime !table.hasColumn(name)) @compileError("zgorm: unknown conflict column " ++ name);
    }
    inline for (conflict.update) |name| {
        if (comptime !table.hasColumn(name)) @compileError("zgorm: unknown upsert update column " ++ name);
    }
    if (conflict.update.len > 0 and conflict.columns.len == 0 and table.pk_indexes.len == 0)
        @compileError("zgorm: ON CONFLICT DO UPDATE requires conflict columns or a primary key");

    try callHook(T, "beforeSave", m, s);
    try callHook(T, "beforeCreate", m, s);
    try crud_helpers.autoStamp(s, T, m, true);

    var arena_state = std.heap.ArenaAllocator.init(s.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var params: std.ArrayList(pq.Param) = .empty;
    var b = crud_sql.SqlBuf.init(arena);
    const w = b.w();
    const pk_col = comptime table.pk();

    w.print("INSERT INTO {s} (", .{qb_mod.quoted(table.name)}) catch return error.OutOfMemory;
    var first = true;
    inline for (table.columns) |col| {
        if (!(col.is_auto and crud_helpers.isZeroValue(value.getColumn(m, col)))) {
            if (!first) w.writeAll(", ") catch return error.OutOfMemory;
            w.writeAll(qb_mod.quoted(col.name)) catch return error.OutOfMemory;
            first = false;
        }
    }
    w.writeAll(") VALUES (") catch return error.OutOfMemory;
    var np: usize = 0;
    inline for (table.columns) |col| {
        if (!(col.is_auto and crud_helpers.isZeroValue(value.getColumn(m, col)))) {
            if (np > 0) w.writeAll(", ") catch return error.OutOfMemory;
            w.print("${d}", .{np + 1}) catch return error.OutOfMemory;
            params.append(arena, try value.toParam(value.getColumn(m, col), arena)) catch return error.OutOfMemory;
            np += 1;
        }
    }
    w.writeAll(") ON CONFLICT") catch return error.OutOfMemory;
    if (conflict.columns.len > 0) {
        w.writeAll(" (") catch return error.OutOfMemory;
        inline for (conflict.columns, 0..) |name, i| {
            if (i > 0) w.writeAll(", ") catch return error.OutOfMemory;
            w.writeAll(qb_mod.quoted(name)) catch return error.OutOfMemory;
        }
        w.writeByte(')') catch return error.OutOfMemory;
    }
    if (conflict.columns.len == 0 and conflict.update.len > 0) {
        w.writeAll(" (") catch return error.OutOfMemory;
        inline for (table.pk_indexes, 0..) |pk_index, i| {
            if (i > 0) w.writeAll(", ") catch return error.OutOfMemory;
            w.writeAll(qb_mod.quoted(table.columns[pk_index].name)) catch return error.OutOfMemory;
        }
        w.writeByte(')') catch return error.OutOfMemory;
    }
    if (conflict.update.len == 0) {
        w.writeAll(" DO NOTHING") catch return error.OutOfMemory;
    } else {
        w.writeAll(" DO UPDATE SET ") catch return error.OutOfMemory;
        inline for (conflict.update, 0..) |name, i| {
            if (i > 0) w.writeAll(", ") catch return error.OutOfMemory;
            const quoted = qb_mod.quoted(name);
            w.print("{s} = EXCLUDED.{s}", .{ quoted, quoted }) catch return error.OutOfMemory;
        }
    }

    var returning = false;
    if (comptime (pk_col != null and pk_col.?.is_auto)) {
        if (crud_helpers.isZeroValue(value.getColumn(m, pk_col.?))) {
            returning = true;
            w.print(" RETURNING {s}", .{qb_mod.quoted(pk_col.?.name)}) catch return error.OutOfMemory;
        }
    }
    var res = try s.runExec(b.slice(), params.items);
    defer res.deinit();
    const affected = res.affected > 0;
    if (affected and returning and res.rows.len > 0) {
        const pkc = pk_col.?;
        value.setColumn(m, pkc, try value.decodeCell(
            value.columnFieldType(T, pkc),
            res.rows[0][0],
            res.columns[0].type_oid,
            res.columns[0].format,
            s.gpa,
        ));
    }
    if (affected) {
        try callHook(T, "afterCreate", m, s);
        try callHook(T, "afterSave", m, s);
    }
    return affected;
}

/// Applies the same upsert policy to a mutable slice atomically.
pub fn upsertBatch(s: *Session, models: anytype, comptime conflict: OnConflict) Error!usize {
    const P = @typeInfo(@TypeOf(models));
    const Items: type = blk: {
        if (P == .pointer and P.pointer.size == .slice and !P.pointer.attrs.@"const") break :blk @TypeOf(models);
        if (P == .pointer and P.pointer.size == .one and @typeInfo(P.pointer.child) == .array and !P.pointer.attrs.@"const")
            break :blk []@typeInfo(P.pointer.child).array.child;
        @compileError("zgorm: upsertBatch expects a mutable slice");
    };
    const list: Items = models;
    if (s.pinned != null) {
        var affected: usize = 0;
        for (list) |*model| affected += @intFromBool(try s.upsert(model, conflict));
        return affected;
    }
    var tx = try s.begin();
    errdefer tx.rollback();
    var affected: usize = 0;
    for (list) |*model| affected += @intFromBool(try tx.upsert(model, conflict));
    try tx.commit();
    return affected;
}

/// Inserts many models in chunked multi-row statements.
pub fn insertBatch(s: *Session, models: anytype) Error!void {
    const P = @typeInfo(@TypeOf(models));
    const Items: type = blk: {
        if (P == .pointer and P.pointer.size == .slice) break :blk @TypeOf(models);
        if (P == .pointer and P.pointer.size == .one and @typeInfo(P.pointer.child) == .array)
            break :blk []@typeInfo(P.pointer.child).array.child;
        @compileError("zgorm: insertBatch expects a slice, e.g. db.insertBatch(&users)");
    };
    const list: Items = models;
    const T = @typeInfo(Items).pointer.child;
    const table = comptime schema.tableOf(T);
    if (models.len == 0) return;

    var return_auto_pk = false;
    if (comptime table.pk()) |pkc| {
        if (comptime pkc.is_auto) {
            return_auto_pk = true;
            for (list) |*m| {
                if (!crud_helpers.isZeroValue(value.getColumn(m, pkc))) {
                    return_auto_pk = false;
                    break;
                }
            }
            if (!return_auto_pk) {
                for (list) |*m| {
                    if (crud_helpers.isZeroValue(value.getColumn(m, pkc)))
                        return error.NullValue; // mixed manual/auto pk batch
                }
            }
        }
    }

    const denom: usize = @max(table.columns.len, 1);
    const chunk_rows: usize = @max(@as(usize, 1), crud_sql.max_params / denom);
    var i: usize = 0;
    while (i < list.len) {
        const end = @min(i + chunk_rows, list.len);
        try insertChunk(s, T, list[i..end], return_auto_pk);
        i = end;
    }
}

pub fn insertChunk(s: *Session, comptime T: type, models: []T, returning: bool) Error!void {
    const table = comptime schema.tableOf(T);
    for (models) |*m| {
        try callHook(T, "beforeSave", m, s);
        try callHook(T, "beforeCreate", m, s);
        try crud_helpers.autoStamp(s, T, m, true);
    }

    var arena_state = std.heap.ArenaAllocator.init(s.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The exact parameter count is known up front; a fixed slice avoids
    // repeated ArrayList growth (each growth copies and strands the old
    // block in the arena).
    var col_count: usize = 0;
    inline for (table.columns) |col| {
        if (!(returning and col.is_pk)) col_count += 1;
    }
    const params = arena.alloc(pq.Param, models.len * col_count) catch return error.OutOfMemory;

    var b = crud_sql.SqlBuf.init(arena);
    const w = b.w();

    w.print("INSERT INTO {s} (", .{qb_mod.quoted(table.name)}) catch return error.OutOfMemory;
    var first_col = true;
    inline for (table.columns) |col| {
        if (!(returning and col.is_pk)) {
            if (!first_col) w.writeAll(", ") catch return error.OutOfMemory;
            w.writeAll(qb_mod.quoted(col.name)) catch return error.OutOfMemory;
            first_col = false;
        }
    }
    w.writeAll(") VALUES ") catch return error.OutOfMemory;

    var np: usize = 0;
    for (models, 0..) |*m, r| {
        if (r > 0) w.writeAll(", ") catch return error.OutOfMemory;
        w.writeByte('(') catch return error.OutOfMemory;
        var first = true;
        inline for (table.columns) |col| {
            if (!(returning and col.is_pk)) {
                if (!first) w.writeAll(", ") catch return error.OutOfMemory;
                w.print("${d}", .{np + 1}) catch return error.OutOfMemory;
                params[np] = try value.toParam(value.getColumn(m, col), arena);
                np += 1;
                first = false;
            }
        }
        w.writeByte(')') catch return error.OutOfMemory;
    }

    if (returning) {
        const pkc = comptime table.pk().?;
        w.print(" RETURNING {s}", .{qb_mod.quoted(pkc.name)}) catch return error.OutOfMemory;
    }

    var res = try s.runExec(b.slice(), params[0..np]);
    defer res.deinit();
    if (returning and (res.rows.len != models.len or res.columns.len == 0))
        return error.ProtocolViolation;

    if (returning) {
        const pkc = comptime table.pk().?;
        const FType = value.columnFieldType(T, pkc);
        for (models, 0..) |*m, r| {
            if (res.rows[r].len == 0) return error.ProtocolViolation;
            value.setColumn(m, pkc, try value.decodeCell(
                FType,
                res.rows[r][0],
                res.columns[0].type_oid,
                res.columns[0].format,
                s.gpa,
            ));
        }
    }

    for (models) |*m| {
        try callHook(T, "afterCreate", m, s);
        try callHook(T, "afterSave", m, s);
    }
}

/// Updates every column of the model (except the primary key) by primary
/// key. `updated_at` is refreshed. Soft-deleted rows are not updated.
/// Returns affected rows (0 or 1).
pub fn update(s: *Session, m: anytype) Error!i64 {
    return updateTx(s, m, false);
}

/// Like `update`, but also updates soft-deleted rows.
pub fn updateUnscoped(s: *Session, m: anytype) Error!i64 {
    return updateTx(s, m, true);
}

pub fn updateTx(s: *Session, m: anytype, comptime unscoped: bool) Error!i64 {
    const MP = @typeInfo(@TypeOf(m));
    if (MP != .pointer or MP.pointer.size != .one or MP.pointer.attrs.@"const")
        @compileError("zgorm: update expects a mutable pointer to a model, e.g. db.update(&user)");
    const T = MP.pointer.child;
    const table = comptime schema.tableOf(T);
    const needs_tx = comptime blk: {
        for (table.assocs) |a| {
            if (a.kind != .belongs_to) break :blk true;
        }
        break :blk false;
    };
    if (!needs_tx or s.pinned != null) return updateImpl(s, m, unscoped);
    var tx = try s.begin();
    errdefer tx.rollback();
    const affected = try updateImpl(s, m, unscoped);
    try tx.commit();
    return affected;
}

/// Updates a mutable model slice with optimistic-lock all-or-nothing
/// semantics. Outside an existing transaction, any conflict rolls back
/// every earlier update in the batch.
pub fn updateBatch(s: *Session, models: anytype) Error!usize {
    const P = @typeInfo(@TypeOf(models));
    const Items: type = blk: {
        if (P == .pointer and P.pointer.size == .slice and !P.pointer.attrs.@"const") break :blk @TypeOf(models);
        if (P == .pointer and P.pointer.size == .one and @typeInfo(P.pointer.child) == .array and !P.pointer.attrs.@"const")
            break :blk []@typeInfo(P.pointer.child).array.child;
        @compileError("zgorm: updateBatch expects a mutable slice, e.g. db.updateBatch(&users)");
    };
    const list: Items = models;
    if (s.pinned != null) {
        for (list) |*model| _ = try s.update(model);
        return list.len;
    }
    var tx = try s.begin();
    errdefer tx.rollback();
    for (list) |*model| _ = try tx.update(model);
    try tx.commit();
    return list.len;
}

pub fn updateImpl(s: *Session, m: anytype, comptime unscoped: bool) Error!i64 {
    const MP = @typeInfo(@TypeOf(m));
    if (MP != .pointer or MP.pointer.size != .one or MP.pointer.attrs.@"const")
        @compileError("zgorm: update expects a mutable pointer to a model, e.g. db.update(&user)");
    const T = MP.pointer.child;
    const table = comptime schema.tableOf(T);
    if (table.pk_indexes.len == 0)
        @compileError("zgorm: model has no primary key; declare one via `primary_key` or `primary_keys`");
    inline for (table.pk_indexes) |pk_index| {
        if (crud_helpers.isZeroValue(value.getColumn(m, table.columns[pk_index]))) return error.NullValue;
    }
    if (comptime table.version()) |version_col| {
        try crud_helpers.ensureVersionCanIncrement(T, m, version_col);
    }

    try callHook(T, "beforeSave", m, s);
    try callHook(T, "beforeUpdate", m, s);
    try crud_helpers.autoStamp(s, T, m, false);

    var arena_state = std.heap.ArenaAllocator.init(s.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var params: std.ArrayList(pq.Param) = .empty;

    var b = crud_sql.SqlBuf.init(arena);
    b.w().writeAll(crud_sql.UpdateSql(T, unscoped).value) catch return error.OutOfMemory;

    inline for (table.columns, 0..) |col, col_index| {
        if (!col.is_pk and (table.version_index == null or table.version_index.? != col_index)) {
            params.append(arena, try value.toParam(value.getColumn(m, col), arena)) catch return error.OutOfMemory;
        }
    }
    inline for (table.pk_indexes) |pk_index| {
        params.append(arena, try value.toParam(value.getColumn(m, table.columns[pk_index]), arena)) catch return error.OutOfMemory;
    }
    if (comptime table.version()) |version_col| {
        params.append(arena, try value.toParam(value.getColumn(m, version_col), arena)) catch return error.OutOfMemory;
    }

    var res = try s.runExec(b.slice(), params.items);
    defer res.deinit();
    const affected = res.affected;
    if (comptime table.version()) |version_col| {
        if (affected == 0) return error.OptimisticLockConflict;
        crud_helpers.incrementVersion(T, m, version_col);
    }

    try crud_helpers.saveAssociations(s, T, m);
    try callHook(T, "afterUpdate", m, s);
    try callHook(T, "afterSave", m, s);
    return affected;
}

/// Insert when the primary key is empty, update otherwise.
pub fn save(s: *Session, m: anytype) Error!void {
    const T = @typeInfo(@TypeOf(m)).pointer.child;
    const table = comptime schema.tableOf(T);
    if (table.pk_indexes.len == 0) {
        try s.insert(m);
        return;
    }
    inline for (table.pk_indexes) |pk_index| {
        if (crud_helpers.isZeroValue(value.getColumn(m, table.columns[pk_index]))) {
            try s.insert(m);
            return;
        }
    }
    _ = try s.update(m);
}

/// Deletes the model by primary key. Returns affected rows.
/// Cascade deletes and the parent delete run in one internal transaction
/// when no transaction is active, so a failed parent delete cannot leave
/// children already permanently removed.
pub fn delete(s: *Session, m: anytype) Error!i64 {
    const MP = @typeInfo(@TypeOf(m));
    if (MP != .pointer or MP.pointer.size != .one)
        @compileError("zgorm: delete expects a pointer to a model");
    const T = MP.pointer.child;
    const table = comptime schema.tableOf(T);
    const needs_tx = comptime blk: {
        for (table.assocs) |a| {
            if (a.cascade_delete) break :blk true;
        }
        break :blk false;
    };
    if (!needs_tx or s.pinned != null) return deleteImpl(s, m);
    var tx = try s.begin();
    errdefer tx.rollback();
    const affected = try deleteImpl(s, m);
    try tx.commit();
    return affected;
}

pub fn deleteImpl(s: *Session, m: anytype) Error!i64 {
    const MP = @typeInfo(@TypeOf(m));
    if (MP != .pointer or MP.pointer.size != .one)
        @compileError("zgorm: delete expects a pointer to a model");
    const T = MP.pointer.child;
    const table = comptime schema.tableOf(T);
    try crud_helpers.validateModelPrimaryKey(T, m, table);

    try crud_helpers.cascadeAssociations(s, T, m);
    try callHook(T, "beforeDelete", m, s);

    var arena_state = std.heap.ArenaAllocator.init(s.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var b = crud_sql.SqlBuf.init(arena);
    b.w().writeAll(crud_sql.DeleteSql(T, false).value) catch return error.OutOfMemory;
    const soft = comptime table.softDeletable();
    var params: std.ArrayList(pq.Param) = .empty;
    inline for (table.pk_indexes) |pk_index| {
        params.append(arena, try value.toParam(value.getColumn(m, table.columns[pk_index]), arena)) catch return error.OutOfMemory;
    }

    var res = try s.runExec(b.slice(), params.items);
    defer res.deinit();
    const affected = res.affected;

    if (soft) {
        // Reflect the stamp in the in-memory model (GORM behaviour).
        const del_col = table.columns[table.deleted_at_index.?];
        const FType = value.columnFieldType(T, del_col);
        const now = Time.now(s.io);
        switch (FType) {
            Time, ?Time => value.setColumn(m, del_col, now),
            i64, ?i64 => value.setColumn(m, del_col, now.micros),
            else => {},
        }
    }

    try callHook(T, "afterDelete", m, s);
    return affected;
}

/// Hard-deletes the model row even when the model has a `deleted_at`
/// column. Returns affected rows.
pub fn deleteHard(s: *Session, m: anytype) Error!i64 {
    const MP = @typeInfo(@TypeOf(m));
    if (MP != .pointer or MP.pointer.size != .one)
        @compileError("zgorm: deleteHard expects a pointer to a model");
    const T = MP.pointer.child;
    const table = comptime schema.tableOf(T);
    const needs_tx = comptime blk: {
        for (table.assocs) |a| {
            if (a.cascade_delete) break :blk true;
        }
        break :blk false;
    };
    if (!needs_tx or s.pinned != null) return deleteHardImpl(s, m);
    var tx = try s.begin();
    errdefer tx.rollback();
    const affected = try deleteHardImpl(s, m);
    try tx.commit();
    return affected;
}

pub fn deleteHardImpl(s: *Session, m: anytype) Error!i64 {
    const MP = @typeInfo(@TypeOf(m));
    if (MP != .pointer or MP.pointer.size != .one)
        @compileError("zgorm: deleteHard expects a pointer to a model");
    const T = MP.pointer.child;
    const table = comptime schema.tableOf(T);
    try crud_helpers.validateModelPrimaryKey(T, m, table);

    try crud_helpers.cascadeAssociations(s, T, m);
    try callHook(T, "beforeDelete", m, s);

    var arena_state = std.heap.ArenaAllocator.init(s.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var b = crud_sql.SqlBuf.init(arena);
    b.w().writeAll(crud_sql.DeleteSql(T, true).value) catch return error.OutOfMemory;
    var params: std.ArrayList(pq.Param) = .empty;
    inline for (table.pk_indexes) |pk_index| {
        params.append(arena, try value.toParam(value.getColumn(m, table.columns[pk_index]), arena)) catch return error.OutOfMemory;
    }

    var res = try s.runExec(b.slice(), params.items);
    defer res.deinit();
    const affected = res.affected;

    try callHook(T, "afterDelete", m, s);
    return affected;
}

/// Undoes a soft delete by primary key (sets `deleted_at` back to NULL).
pub fn restore(s: *Session, m: anytype) Error!i64 {
    const MP = @typeInfo(@TypeOf(m));
    if (MP != .pointer or MP.pointer.size != .one)
        @compileError("zgorm: restore expects a pointer to a model");
    const T = MP.pointer.child;
    const table = comptime schema.tableOf(T);
    if (table.deleted_at_index == null) @compileError("zgorm: restore requires a deleted_at column");
    if (table.pk_index == null) @compileError("zgorm: model has no primary key");
    const pkc = table.columns[table.pk_index.?];
    const del_col = table.columns[table.deleted_at_index.?];
    if (crud_helpers.isZeroValue(value.getColumn(m, pkc))) return error.NullValue;

    var arena_state = std.heap.ArenaAllocator.init(s.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var b = crud_sql.SqlBuf.init(arena);
    b.w().writeAll(crud_sql.RestoreSql(T).value) catch return error.OutOfMemory;
    const params = try arena.alloc(pq.Param, 1);
    params[0] = try value.toParam(value.getColumn(m, pkc), arena);

    var res = try s.runExec(b.slice(), params);
    defer res.deinit();
    const affected = res.affected;
    if (affected > 0) value.setColumn(m, del_col, null);
    return affected;
}

/// Soft-deletes matching rows when the model has `deleted_at`, otherwise
/// performs a real DELETE. Returns affected rows.
pub fn deleteWhere(s: *Session, comptime T: type, frag: []const u8, args: anytype) Error!i64 {
    return deleteWhereImpl(s, T, frag, args, false);
}

/// Hard variant of `deleteWhere`: always performs a real DELETE.
pub fn deleteWhereHard(s: *Session, comptime T: type, frag: []const u8, args: anytype) Error!i64 {
    return deleteWhereImpl(s, T, frag, args, true);
}

pub fn deleteWhereImpl(s: *Session, comptime T: type, frag: []const u8, args: anytype, comptime force_hard: bool) Error!i64 {
    var arena_state = std.heap.ArenaAllocator.init(s.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const table = comptime schema.tableOf(T);
    const soft = comptime table.softDeletable() and !force_hard;

    var b = crud_sql.SqlBuf.init(arena);
    const w = b.w();
    const params_list = try value.argsToParams(args, arena);

    if (soft) {
        const del_col = table.columns[table.deleted_at_index.?];
        w.print("UPDATE {s} SET {s} = {s} WHERE (", .{
            qb_mod.quoted(table.name),
            qb_mod.quoted(del_col.name),
            qb_mod.softDeleteStampSql(value.columnFieldType(T, del_col)),
        }) catch return error.OutOfMemory;
        qb_mod.writeRenumbered(w, frag, 0) catch return error.OutOfMemory;
        w.print(") AND {s} IS NULL", .{qb_mod.quoted(del_col.name)}) catch return error.OutOfMemory;
    } else {
        w.print("DELETE FROM {s} WHERE (", .{qb_mod.quoted(table.name)}) catch return error.OutOfMemory;
        qb_mod.writeRenumbered(w, frag, 0) catch return error.OutOfMemory;
        w.writeByte(')') catch return error.OutOfMemory;
    }

    var res = try s.runExec(b.slice(), params_list);
    defer res.deinit();
    return res.affected;
}

/// Updates the given fields of matching rows. `sets` is a struct whose
/// fields reference model columns, e.g. `.{ .active = false }`.
/// Returns affected rows.
pub fn updateWhere(s: *Session, comptime T: type, sets: anytype, frag: []const u8, args: anytype) Error!i64 {
    const table = comptime schema.tableOf(T);
    var arena_state = std.heap.ArenaAllocator.init(s.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var b = crud_sql.SqlBuf.init(arena);
    const w = b.w();
    var params: std.ArrayList(pq.Param) = .empty;

    const SetsInfo = @typeInfo(@TypeOf(sets)).@"struct";
    if (SetsInfo.field_names.len == 0) return error.TypeMismatch;

    w.print("UPDATE {s} SET ", .{qb_mod.quoted(table.name)}) catch return error.OutOfMemory;
    inline for (SetsInfo.field_names, 0..) |set_name, i| {
        if (i > 0) w.writeAll(", ") catch return error.OutOfMemory;
        comptime var col_name: ?[]const u8 = null;
        inline for (table.columns) |col| {
            if (comptime std.mem.eql(u8, col.field_name, set_name)) col_name = col.name;
        }
        if (col_name == null) @compileError("zgorm: updateWhere set field '" ++ set_name ++ "' is not a column of " ++ @typeName(T));
        w.print("{s} = ${d}", .{ qb_mod.quoted(col_name.?), i + 1 }) catch return error.OutOfMemory;
        params.append(arena, try value.toParam(@field(sets, set_name), arena)) catch return error.OutOfMemory;
    }
    w.writeAll(" WHERE (") catch return error.OutOfMemory;
    qb_mod.writeRenumbered(w, frag, SetsInfo.field_names.len) catch return error.OutOfMemory;
    w.writeByte(')') catch return error.OutOfMemory;
    if (comptime table.softDeletable()) {
        const del_col = table.columns[table.deleted_at_index.?];
        w.print(" AND {s} IS NULL", .{qb_mod.quoted(del_col.name)}) catch return error.OutOfMemory;
    }

    const cond_params = try value.argsToParams(args, arena);
    params.appendSlice(arena, cond_params) catch return error.OutOfMemory;

    var res = try s.runExec(b.slice(), params.items);
    defer res.deinit();
    return res.affected;
}

/// Fetches one model by primary key, or null.
/// Returned strings are allocated with the session's gpa; release them
/// with `zgorm.free(T, value, gpa)` or decode into an arena of your own.
/// Fetches one model by primary key, excluding soft-deleted rows
/// (models with a `deleted_at` column). Use `findUnscoped` to include them.
pub fn find(s: *Session, comptime T: type, pk: anytype) Error!?T {
    return findImpl(s, T, pk, false);
}

/// Like `find`, but also matches soft-deleted rows.
pub fn findUnscoped(s: *Session, comptime T: type, pk: anytype) Error!?T {
    return findImpl(s, T, pk, true);
}

pub fn findImpl(s: *Session, comptime T: type, pk: anytype, comptime unscoped: bool) Error!?T {
    const table = comptime schema.tableOf(T);
    if (table.pk_indexes.len == 0) @compileError("zgorm: model has no primary key");

    var arena_state = std.heap.ArenaAllocator.init(s.gpa);

    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const params = try value.argsToParams(pk, arena);
    if (params.len != table.pk_indexes.len) return error.InvalidQuery;

    const sql = crud_sql.FindSql(T, unscoped).value[0..];

    const models = try s.runModels(T, sql, params, 0, s.gpa);
    defer s.gpa.free(models);
    if (models.len == 0) return null;
    return models[0];
}
pub fn association(s: *Session, parent: anytype, comptime field_name: []const u8) assoc_mod.Association(@typeInfo(@TypeOf(parent)).pointer.child, field_name) {
    const M = @typeInfo(@TypeOf(parent)).pointer.child;
    return .{ .sess = s.*, .parent = @as(*M, parent) };
}
