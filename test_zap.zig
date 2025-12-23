const std = @import("std");
const zap = @import("zap");

test "check zap json" {
    @compileLog(@typeInfo(zap).@"struct".decls);
}
