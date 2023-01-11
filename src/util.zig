const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

pub fn appendAndGetIndex(value: anytype, list: *ArrayList(@TypeOf(value))) !usize {
    const index = list.items.len;
    try list.append(value);
    return index;
}

var counter: usize = 0;
pub fn getId() usize {
    return @atomicRmw(usize, &counter, .Add, 1, .Monotonic);
}

pub fn dupeOption(allocator: Allocator, comptime T: type, m_opt: ?[]const T) !?[]T {
    return if (m_opt) |m|
        @as(?[]T, try allocator.dupe(T, m))
    else
        null;
}

pub fn ptrLen(comptime T: type, from: [*]const T, to: [*]const T) usize {
    return @divExact((@ptrToInt(to) - @ptrToInt(from)), @sizeOf(T));
}

const test_allocator = std.testing.allocator;

test "dupe" {
    var arena = std.heap.ArenaAllocator.init(test_allocator);
    defer arena.deinit();
    _ = try dupeOption(arena.allocator(), u8, "hi");
}
