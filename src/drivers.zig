pub const postgres = @import("drivers/postgres/root.zig");
pub const mysql = @import("drivers/mysql/root.zig");
pub const sqlite = @import("drivers/sqlite/root.zig");
pub const backend = @import("drivers/shared/backend.zig");
pub const plugins = @import("drivers/shared/plugins.zig");
pub const RetryOptions = @import("drivers/shared/orm.zig").RetryOptions;
pub const Dialect = @import("drivers/shared/dialect.zig").Dialect;
pub const Error = @import("drivers/shared/types.zig").Error;
pub const Result = @import("drivers/shared/types.zig").Result;
pub const Migration = @import("drivers/shared/migrator.zig").Migration;
pub const QueryEvent = @import("drivers/shared/types.zig").QueryEvent;
pub const Observer = @import("drivers/shared/types.zig").Observer;

pub fn Migrator(comptime Db: type) type {
    return @import("drivers/shared/migrator.zig").Migrator(Db);
}

pub fn Router(comptime Orm: type) type {
    return @import("drivers/shared/router.zig").Router(Orm);
}
