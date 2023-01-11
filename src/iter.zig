const std = @import("std");
const assert = std.debug.assert;

pub fn SliceIter(comptime T: type) type {
    return struct {
        const Self = @This();

        slice_iter: [*]const T,
        slice_end: [*]const T,

        pub fn init(slice: []const T) Self {
            return Self{
                .slice_iter = slice.ptr,
                .slice_end = slice.ptr + slice.len,
            };
        }

        pub fn next(self: *Self) ?T {
            if (self.slice_iter != self.slice_end) {
                const element = self.slice_iter[0];
                self.slice_iter += 1;
                return element;
            } else {
                return null;
            }
        }
    };
}
pub fn sliceIter(slice: anytype) SliceIter(sliceChild(@TypeOf(slice))) {
    return SliceIter(sliceChild(@TypeOf(slice))){
        .slice_iter = slice.ptr,
        .slice_end = slice.ptr + slice.len,
    };
}

fn sliceChild(comptime T: type) type {
    const type_info = @typeInfo(T);
    if (!std.meta.trait.isSlice(T)) {
        @compileError("expected slice, found " ++ @typeName(T));
    }
    return type_info.Pointer.child;
}

pub fn MapIter(
    comptime Context: type,
    comptime InnerIter: type,
    comptime T: type,
    comptime R: type,
    comptime f: fn (Context, T) R,
) type {
    return struct {
        const Self = @This();

        context: Context,
        inner_iter: InnerIter,

        pub fn init(context: Context, inner_iter: InnerIter) Self {
            return Self{
                .context = context,
                .inner_iter = inner_iter,
            };
        }

        pub fn next(self: *Self) ?R {
            return if (self.inner_iter.next()) |x| f(self.context, x) else null;
        }
    };
}

pub fn mapIter(
    comptime R: type,
    inner_iter: anytype,
    context: anytype,
    comptime f: fn (@TypeOf(context), iterType(@TypeOf(inner_iter))) R,
) MapIter(
    @TypeOf(context),
    @TypeOf(inner_iter),
    iterType(@TypeOf(inner_iter)),
    R,
    f,
) {
    return MapIter(
        @TypeOf(context),
        @TypeOf(inner_iter),
        iterType(@TypeOf(inner_iter)),
        R,
        f,
    ).init(context, inner_iter);
}
pub fn isIter(comptime T: type) bool {
    if (!@hasDecl(T, "next")) {
        return false;
    }
    const next_info = @typeInfo(@TypeOf(@field(T, "next")));
    if (next_info != .Fn) {
        return false;
    }
    return @typeInfo(next_info.Fn.return_type.?) == .Optional;
}
pub fn iterType(comptime T: type) type {
    if (!isIter(T)) {
        @compileError("expected iterator, found " ++ @typeName(T));
    }
    return @typeInfo(@typeInfo(@TypeOf(@field(T, "next"))).Fn.return_type.?).Optional.child;
}
fn functionReturnType(T: type) type {
    return @typeInfo(T).Fn.returnType.?;
}

const expectEqual = std.testing.expectEqual;

test "map" {
    const lambda = struct {
        fn square(context: void, x: usize) usize {
            _ = context;
            return x * x;
        }
    };
    const array = [_]usize{ 1, 2, 3 };
    var iter = mapIter(usize, sliceIter(@as([]const usize, &array)), {}, lambda.square);
    try expectEqual(@as(?usize, 1), iter.next());
    try expectEqual(@as(?usize, 4), iter.next());
    try expectEqual(@as(?usize, 9), iter.next());
    try expectEqual(@as(?usize, null), iter.next());
}
test "map type change" {
    const lambda = struct {
        fn odd(context: void, x: usize) bool {
            _ = context;
            return x % 2 == 1;
        }
    };
    const array = [_]usize{ 1, 2, 3 };
    var iter = mapIter(bool, sliceIter(@as([]const usize, &array)), {}, lambda.odd);
    try expectEqual(@as(?bool, true), iter.next());
    try expectEqual(@as(?bool, false), iter.next());
    try expectEqual(@as(?bool, true), iter.next());
    try expectEqual(@as(?bool, null), iter.next());
}
