//! Model-side helpers shared by CRUD: timestamp stamping, association
//! cascade/save, primary-key validation and optimistic-lock versioning.

const std = @import("std");
const schema = @import("../schema.zig");
const value = @import("../value.zig");
const time_mod = @import("../time.zig");
const session_mod = @import("../session.zig");

const Session = session_mod.Session;
const Time = time_mod.Time;
pub const Error = session_mod.Error;

pub fn autoStamp(s: *Session, comptime T: type, m: anytype, comptime is_insert: bool) Error!void {
    const table = comptime schema.tableOf(T);
    if (table.created_at_index == null and table.updated_at_index == null) return;

    const now = Time.now(s.io);
    inline for (table.columns, 0..) |col, i| {
        const is_created = table.created_at_index != null and table.created_at_index.? == i;
        const is_updated = table.updated_at_index != null and table.updated_at_index.? == i;
        if ((is_created and is_insert) or is_updated) {
            const FType = value.columnFieldType(T, col);
            const stamp = !is_insert or switch (FType) {
                Time => value.getColumn(m, col).micros == 0,
                i64 => value.getColumn(m, col) == 0,
                ?Time, ?i64 => value.getColumn(m, col) == null,
                else => false,
            };
            if (stamp) switch (FType) {
                Time, ?Time => value.setColumn(m, col, now),
                i64, ?i64 => value.setColumn(m, col, now.micros),
                else => {},
            };
        }
    }
}
pub fn saveAssociations(s: *Session, comptime T: type, model: *T) Error!void {
    const table = comptime schema.tableOf(T);
    inline for (table.assocs) |assoc| {
        if (assoc.kind == .belongs_to) continue;
        var manager = s.association(model, assoc.field_name);
        switch (assoc.kind) {
            .has_one => {
                if (@field(model, assoc.field_name)) |*child| try manager.append(child);
            },
            .has_many, .many_to_many => {
                for (@field(model, assoc.field_name)) |*child| try manager.append(child);
            },
            .belongs_to => unreachable,
        }
    }
}

pub fn cascadeAssociations(s: *Session, comptime T: type, model: *T) Error!void {
    inline for (comptime schema.tableOf(T).assocs) |assoc| {
        if (assoc.cascade_delete) {
            var manager = s.association(model, assoc.field_name);
            try manager.clear();
        }
    }
}

pub fn validateModelPrimaryKey(comptime T: type, m: *T, comptime table: schema.Table) Error!void {
    if (table.pk_indexes.len == 0) @compileError("zgorm: model has no primary key");
    inline for (table.pk_indexes) |pk_index| {
        if (isZeroValue(value.getColumn(m, table.columns[pk_index]))) return error.NullValue;
    }
}

pub fn ensureVersionCanIncrement(comptime T: type, m: *T, comptime col: schema.Column) Error!void {
    const F = value.columnFieldType(T, col);
    const current = value.getColumn(m, col);
    if (current == std.math.maxInt(F)) return error.NumericValueOutOfRange;
}

pub fn incrementVersion(comptime T: type, m: *T, comptime col: schema.Column) void {
    const current = value.getColumn(m, col);
    value.setColumn(m, col, current + 1);
}

pub fn isZeroValue(v: anytype) bool {
    return switch (@typeInfo(@TypeOf(v))) {
        .optional => v == null,
        .int => v == 0,
        .pointer => v.len == 0,
        else => false,
    };
}
