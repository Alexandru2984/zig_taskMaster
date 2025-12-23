const std = @import("std");

test "check adaptToNewApi" {
    var list = std.ArrayListUnmanaged(u8){};
    defer list.deinit(std.testing.allocator);
    var w = list.writer(std.testing.allocator);
    var buf: [100]u8 = undefined;
    var adapter = w.adaptToNewApi(&buf);
    try std.json.Stringify.value(.{ .x = 1 }, .{}, &adapter.new_interface);
}
