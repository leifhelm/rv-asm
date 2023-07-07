const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const BoundedArray = std.BoundedArray;

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

pub fn boundedArrayFromTuple(
    comptime T: type,
    comptime len: comptime_int,
    tuple: anytype,
    comptime f: fn (anytype) T,
) BoundedArray(T, len) {
    const tuple_type = @TypeOf(tuple);
    const tuple_info = @typeInfo(tuple_type);
    if (tuple_info != .Struct or tuple_info.Struct.is_tuple == false) {
        @compileError("expected tuple, found " ++ @typeName(tuple_type));
    }
    const fields = tuple_info.Struct.fields;
    if (fields.len > 2) {
        @compileError("no more than 2 input values are supported");
    }
    var array = [1]T{undefined} ** len;
    inline for (fields) |field_type, i| {
        const field = @field(tuple, field_type.name);
        array[i] = f(field);
    }
    return .{
        .buffer = array,
        .len = fields.len,
    };
}

pub fn typedId(comptime T: type) fn (anytype) T {
    const Closure = struct {
        fn f(value: anytype) T {
            return value;
        }
    };
    return Closure.f;
}


const test_allocator = std.testing.allocator;
const expectEqualSlices = std.testing.expectEqualSlices;

test "dupe" {
    var arena = std.heap.ArenaAllocator.init(test_allocator);
    defer arena.deinit();
    _ = try dupeOption(arena.allocator(), u8, "hi");
}

test "tuple to array id" {
    const array = boundedArrayFromTuple(u8, 4, .{ 3, 4 }, typedId(u8));
    try expectEqualSlices(u8, &[_]u8{ 3, 4 }, array.constSlice());
}

test "tuple to array function" {
    const Closure = struct {
        fn add4(value: anytype) u8{
            return value + 4;
        }
    };
    const array = boundedArrayFromTuple(u8, 4, .{ 3, 4}, Closure.add4);
    try expectEqualSlices(u8, &[_]u8{ 7, 8 }, array.constSlice());
}
