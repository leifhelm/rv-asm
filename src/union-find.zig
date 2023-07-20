const std = @import("std");
const Allocator = std.mem.Allocator;

pub const SetId = usize;

pub const SetElement = union(enum) {
    const Self = @This();

    set: Set, // the root of the tree
    parent: *SetElement,

    pub fn init(id: SetId) Self {
        return .{ .set = .{ .id = id, .size = 1 } };
    }

    // tail recursive
    fn findSet_(self: *Self) *Self {
        return switch (self.*) {
            .set => self,
            .parent => |parent| parent.findSet_(),
        };
    }

    // tail recursive
    fn shortenPath(self: *Self, set: *Self) void {
        switch (self.*) {
            .set => {},
            .parent => |parent| {
                self.parent = set;
                parent.shortenPath(set);
            },
        }
    }

    pub fn findSet(self: *Self) *Self {
        return switch (self.*) {
            .set => self,
            .parent => |parent| blk: {
                const set = parent.findSet_();
                parent.shortenPath(set);
                break :blk set;
            },
        };
    }

    pub fn unionWith(self: *Self, other: *Self) void {
        const self_set = self.findSet();
        const other_set = other.findSet();

        if (self_set == other_set) return; // already in the same set

        const self_size = self_set.set.size;
        const other_size = other_set.set.size;
        if (self_set.set.size < other_set.set.size) {
            self_set.* = SetElement{ .parent = other_set };
            other_set.set.size += self_size;
        } else {
            other_set.* = SetElement{ .parent = self_set };
            self_set.set.size += other_size;
        }
    }

    pub fn inSameSet(self: *SetElement, other: *SetElement) bool {
        return self.findSet() == other.findSet();
    }
};

pub const Set = struct {
    id: SetId,
    size: usize,
};

const expectEqual = std.testing.expectEqual;
const expect = std.testing.expect;
const testAllocator = std.testing.allocator;

test "union all" {
    var sets = [_]SetElement{
        SetElement.init(0),
        SetElement.init(1),
        SetElement.init(2),
        SetElement.init(3),
        SetElement.init(4),
        SetElement.init(5),
        SetElement.init(6),
        SetElement.init(7),
        SetElement.init(8),
        SetElement.init(9),
    };
    for (sets) |*set_i, i| {
        for (sets) |*set_j, j| {
            try expectEqual(i == j, set_i.inSameSet(set_j));
        }
    }
    for (sets) |*set| {
        set.unionWith(&sets[0]);
    }
    for (sets) |*set_i| {
        for (sets) |*set_j| {
            try expect(set_i.inSameSet(set_j));
        }
    }
}

test "union once" {
    var sets = [_]SetElement{
        SetElement.init(0),
        SetElement.init(1),
        SetElement.init(2),
        SetElement.init(3),
    };
    sets[0].unionWith(&sets[2]);

    try expect(sets[0].inSameSet(&sets[2]));
    try expect(sets[2].inSameSet(&sets[0]));
}
