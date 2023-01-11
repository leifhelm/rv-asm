const std = @import("std");
const math = std.math;
const sort = std.sort;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const assert = std.debug.assert;

const ptrLen = @import("util.zig").ptrLen;
const sliceIter = @import("iter.zig").sliceIter;
const iterType = @import("iter.zig").iterType;
const meta = @import("meta.zig");

pub fn IntSet(comptime T: type) type {
    return struct {
        const Self = @This();

        elements: ArrayList(T),

        pub fn init(allocator: Allocator) Self {
            return Self{
                .elements = ArrayList(T).init(allocator),
            };
        }

        pub fn deinit(self: Self) void {
            self.elements.deinit();
        }

        pub fn clone(self: Self) !Self {
            return self.cloneAllocator(self.elements.allocator);
        }

        pub fn cloneAllocator(self: Self, allocator: Allocator) !Self {
            var elements = try ArrayList(T).initCapacity(allocator, self.elements.items.len);
            elements.appendSliceAssumeCapacity(self.elements.items);
            return Self{
                .elements = elements,
            };
        }

        pub fn fromOrderedSlice(allocator: Allocator, slice: []const T) !Self {
            assert(isOrderedSet(slice));
            var elements = try ArrayList(T).initCapacity(allocator, slice.len);
            elements.appendSliceAssumeCapacity(slice);
            return Self{
                .elements = elements,
            };
        }

        pub fn isElementOf(self: Self, e: T) bool {
            return sort.binarySearch(T, e, self.elements.items, {}, compAsc) != null;
        }

        pub fn intersection(self: Self, other: Self) !Self {
            var elements = ArrayList(T).init(self.elements.allocator);

            const self_end = self.elements.items.ptr + self.elements.items.len;
            var self_iter = self.elements.items.ptr;
            const other_end = other.elements.items.ptr + other.elements.items.len;
            var other_iter = other.elements.items.ptr;

            while (self_iter != self_end and other_iter != other_end) {
                switch (math.order(self_iter[0], other_iter[0])) {
                    .eq => {
                        try elements.append(self_iter[0]);
                        self_iter += 1;
                        other_iter += 1;
                    },
                    .lt => self_iter += 1,
                    .gt => other_iter += 1,
                }
            }

            return Self{
                .elements = elements,
            };
        }
        pub fn intersectionInplace(self: *Self, other: Self) void {
            const self_end = self.elements.items.ptr + self.elements.items.len;
            var self_iter = self.elements.items.ptr;
            var insertion_iter = self.elements.items.ptr;
            const other_end = other.elements.items.ptr + other.elements.items.len;
            var other_iter = other.elements.items.ptr;

            while (self_iter != self_end and other_iter != other_end) {
                switch (math.order(self_iter[0], other_iter[0])) {
                    .eq => {
                        insertion_iter[0] = self_iter[0];
                        insertion_iter += 1;
                        self_iter += 1;
                        other_iter += 1;
                    },
                    .lt => self_iter += 1,
                    .gt => other_iter += 1,
                }
            }
            self.elements.shrinkAndFree(ptrLen(T, self.elements.items.ptr, insertion_iter));
        }

        pub fn intersections(allocator: Allocator, sets: []const Self) !Self {
            var iter = sliceIter(sets);
            return intersectionsIter(allocator, &iter);
            // if (sets.len == 0) {
            //     return Self.init(allocator);
            // } else {
            //     var result = try sets[0].cloneAllocator(allocator);
            //     for (sets[1..]) |set| {
            //         result.intersectionInplace(set);
            //     }
            //     return result;
            // }
        }

        pub fn intersectionsIter(allocator: Allocator, iter: anytype) !Self {
            const iter_type = meta.singelItemPtrType(@TypeOf(iter));
            const iter_element_type = iterType(iter_type);
            if (iter_element_type != Self) {
                @compileError("expecting iter type to be " ++ @typeName(Self) ++ ", found " ++ @typeName(iter_element_type));
            }

            var result = if (iter.next()) |set|
                try set.cloneAllocator(allocator)
            else
                return Self.init(allocator);
            while (iter.next()) |set| {
                result.intersectionInplace(set);
            }
            return result;
        }

        pub fn add(self: *Self, e: T) !void {
            if (findInsertionIndex(self.elements.items, e)) |index| {
                try self.elements.insert(index, e);
            }
        }

        pub fn orderedSlice(self: Self) []const T {
            return self.elements.items;
        }

        fn findInsertionIndex(slice: []const T, e: T) ?usize {
            var left: usize = 0;
            var right: usize = slice.len;
            while (left < right) {
                const mid = left + (right - left) / 2;
                switch (math.order(e, slice[mid])) {
                    .eq => return null,
                    .gt => left = mid + 1,
                    .lt => right = mid,
                }
            }
            return left;
        }

        fn isOrderedSet(slice: []const T) bool {
            if (slice.len >= 1) {
                var last = slice[0];
                for (slice[1..]) |element| {
                    if (last >= element) {
                        return false;
                    }
                    last = element;
                }
            }
            return true;
        }

        fn compAsc(context: void, lhs: T, rhs: T) math.Order {
            _ = context;
            return math.order(lhs, rhs);
        }
    };
}

const test_allocator = std.testing.allocator;
const expect = std.testing.expect;
const expectEqualSlices = std.testing.expectEqualSlices;

test "add" {
    var intSet = IntSet(usize).init(test_allocator);
    defer intSet.deinit();
    try expectEqualSlices(usize, &[_]usize{}, intSet.elements.items);
    try intSet.add(2);
    try expectEqualSlices(usize, &[_]usize{2}, intSet.elements.items);
    try intSet.add(2);
    try expectEqualSlices(usize, &[_]usize{2}, intSet.elements.items);
    try intSet.add(1);
    try expectEqualSlices(usize, &[_]usize{ 1, 2 }, intSet.elements.items);
    try intSet.add(3);
    try expectEqualSlices(usize, &[_]usize{ 1, 2, 3 }, intSet.elements.items);
}

test "intersection" {
    var intSet = IntSet(usize).init(test_allocator);
    defer intSet.deinit();
    try intSet.add(2);
    try intSet.add(1);
    try intSet.add(3);
    const otherSet = try IntSet(usize).fromOrderedSlice(test_allocator, &[_]usize{ 1, 3 });
    defer otherSet.deinit();
    const intersection = try intSet.intersection(otherSet);
    defer intersection.deinit();
    try expectEqualSlices(usize, &[_]usize{ 1, 3 }, intersection.elements.items);
}

test "intersection subset" {
    const setA = try IntSet(usize).fromOrderedSlice(test_allocator, &[_]usize{ 1, 2, 3, 4, 5 });
    defer setA.deinit();
    const setB = try IntSet(usize).fromOrderedSlice(test_allocator, &[_]usize{ 1, 3 });
    defer setB.deinit();
    const intersection = try setA.intersection(setB);
    defer intersection.deinit();
    try expectEqualSlices(usize, &[_]usize{ 1, 3 }, intersection.elements.items);
}
test "intersection empty set" {
    const setA = try IntSet(usize).fromOrderedSlice(test_allocator, &[_]usize{});
    defer setA.deinit();
    const setB = try IntSet(usize).fromOrderedSlice(test_allocator, &[_]usize{ 1, 3 });
    defer setB.deinit();
    const intersection = try setA.intersection(setB);
    defer intersection.deinit();
    try expectEqualSlices(usize, &[_]usize{}, intersection.elements.items);
}
test "intersection disjuct sets" {
    const setA = try IntSet(usize).fromOrderedSlice(test_allocator, &[_]usize{ 2, 4, 6, 8 });
    defer setA.deinit();
    const setB = try IntSet(usize).fromOrderedSlice(test_allocator, &[_]usize{ 1, 3 });
    defer setB.deinit();
    const intersection = try setA.intersection(setB);
    defer intersection.deinit();
    try expectEqualSlices(usize, &[_]usize{}, intersection.elements.items);
}
test "intersections none" {
    const intersection = try IntSet(usize).intersections(test_allocator, &[_]IntSet(usize){});
    defer intersection.deinit();
    try expectEqualSlices(usize, &[_]usize{}, intersection.elements.items);
}
test "intersections one" {
    const setA = try IntSet(usize).fromOrderedSlice(test_allocator, &[_]usize{ 2, 4, 6, 8 });
    defer setA.deinit();
    const intersection = try IntSet(usize).intersections(test_allocator, &[_]IntSet(usize){setA});
    defer intersection.deinit();
    try expectEqualSlices(usize, &[_]usize{ 2, 4, 6, 8 }, intersection.elements.items);
}
test "intersections two" {
    const setA = try IntSet(usize).fromOrderedSlice(test_allocator, &[_]usize{ 2, 4, 6, 8 });
    defer setA.deinit();
    const setB = try IntSet(usize).fromOrderedSlice(test_allocator, &[_]usize{ 1, 2, 3, 4, 5, 6 });
    defer setB.deinit();
    const intersection = try IntSet(usize).intersections(test_allocator, &[_]IntSet(usize){ setA, setB });
    defer intersection.deinit();
    try expectEqualSlices(usize, &[_]usize{ 2, 4, 6 }, intersection.elements.items);
}
test "intersections three" {
    const setA = try IntSet(usize).fromOrderedSlice(test_allocator, &[_]usize{ 2, 4, 6, 8 });
    defer setA.deinit();
    const setB = try IntSet(usize).fromOrderedSlice(test_allocator, &[_]usize{ 1, 2, 3, 4, 5, 6 });
    defer setB.deinit();
    const setC = try IntSet(usize).fromOrderedSlice(test_allocator, &[_]usize{ 1, 5, 6 });
    defer setC.deinit();
    const intersection = try IntSet(usize).intersections(test_allocator, &[_]IntSet(usize){ setA, setB, setC });
    defer intersection.deinit();
    try expectEqualSlices(usize, &[_]usize{6}, intersection.elements.items);
}
