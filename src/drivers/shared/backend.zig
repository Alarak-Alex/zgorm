const std = @import("std");
const types = @import("types.zig");

/// Compile-time contract consumed by the shared ORM/query/migration layers.
pub fn assertBackend(comptime Backend: type) void {
    if (!@hasField(Backend, "gpa") or @FieldType(Backend, "gpa") != std.mem.Allocator)
        @compileError("zorm driver backend requires `gpa: std.mem.Allocator`");
    inline for (.{ "exec", "execParamsTimeout", "beginTransaction", "commit", "rollback" }) |name| {
        if (!@hasDecl(Backend, name))
            @compileError("zorm driver backend requires `" ++ name ++ "`");
    }
    assertResultMethod(Backend, "exec");
    assertResultMethod(Backend, "execParamsTimeout");
}

fn assertResultMethod(comptime Backend: type, comptime name: []const u8) void {
    const function = @field(Backend, name);
    const return_type = @typeInfo(@TypeOf(function)).@"fn".return_type orelse
        @compileError("zorm driver method `" ++ name ++ "` requires a return type");
    const info = @typeInfo(return_type);
    if (info != .error_union or info.error_union.payload != types.Result)
        @compileError("zorm driver method `" ++ name ++ "` must return Error!Result");
}
