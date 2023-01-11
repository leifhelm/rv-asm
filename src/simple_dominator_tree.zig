const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const BoundedArray = std.BoundedArray;
const eql = std.mem.eql;

const IntSet = @import("int_set.zig").IntSet;
const sliceIter = @import("iter.zig").sliceIter;
const mapIter = @import("iter.zig").mapIter;

const NodeIndex = usize;
const Node = struct {
    const Self = @This();

    dominators: IntSet(NodeIndex),
    successors: BoundedArray(NodeIndex, 2),
    predecessors: ArrayList(NodeIndex),
    in_cfg: bool,
    fn init(allocator: Allocator, successors: []const NodeIndex) !Self {
        return Self{
            .dominators = IntSet(NodeIndex).init(allocator),
            .predecessors = ArrayList(NodeIndex).init(allocator),
            .successors = try BoundedArray(NodeIndex, 2).fromSlice(successors),
            .in_cfg = false,
        };
    }
    fn deinit(self: Self) void {
        self.dominators.deinit();
        self.predecessors.deinit();
    }
};

pub const Cfg = struct {
    const Self = @This();

    allocator: Allocator,
    nodes: ArrayList(Node),
    pub fn init(allocator: Allocator, nodes: usize) !Self {
        return Self{
            .allocator = allocator,
            .nodes = try ArrayList(Node).initCapacity(allocator, nodes),
        };
    }
    pub fn deinit(self: Self) void {
        for (self.nodes.items) |node| {
            node.deinit();
        }
        self.nodes.deinit();
    }
    pub fn addNode(self: *Self, successors: []const NodeIndex) !void {
        try self.nodes.append(try Node.init(self.allocator, successors));
    }
    fn calculateInCfg(self: *Self, node_index: NodeIndex) void {
        const node = &self.nodes.items[node_index];
        if (node.in_cfg) {
            return;
        }
        node.in_cfg = true;
        for (node.successors.constSlice()) |successor_index| {
            self.calculateInCfg(successor_index);
        }
    }
    fn findPredecessors(self: *Self) !void {
        for (self.nodes.items) |node, node_index| {
            for (node.successors.constSlice()) |successor_index| {
                if (successor_index != node_index) {
                    const successor = &self.nodes.items[successor_index];
                    if (node.in_cfg) {
                        try successor.predecessors.append(node_index);
                    }
                }
            }
        }
    }
    // Graph-theoretic constructs for program flow analysis
    // F. E. Allen, J. Cocke
    // RC 3923
    // https://dominoweb.draco.res.ibm.com/reports/rc3923.pdf
    pub fn findDominators(self: *Self) !void {
        self.calculateInCfg(0);
        try self.findPredecessors();
        try self.nodes.items[0].dominators.add(0);
        for (self.nodes.items[1..]) |*node| {
            try node.dominators.elements.ensureTotalCapacity(self.nodes.items.len - 1);
            for (self.nodes.items[0..]) |_, other_node_index| {
                try node.dominators.add(other_node_index);
            }
        }
        var changed = true;
        while (changed) {
            changed = false;
            for (self.nodes.items[1..]) |*node, list_index| {
                const node_index = list_index + 1;
                const lambda = struct {
                    fn dominators(s: *const Self, index: NodeIndex) IntSet(NodeIndex) {
                        return s.nodes.items[index].dominators;
                    }
                };
                var iter = mapIter(IntSet(NodeIndex), sliceIter(node.predecessors.items), self, lambda.dominators);
                const old_set = node.dominators;
                defer old_set.deinit();
                node.dominators = try IntSet(NodeIndex).intersectionsIter(self.allocator, &iter);
                try node.dominators.add(node_index);
                if (!changed and !eql(NodeIndex, old_set.orderedSlice(), node.dominators.orderedSlice())) {
                    changed = true;
                }
            }
        }
    }
    fn intersectionOfPredecessors(self: Self, node_index: NodeIndex, changed: *bool) !void {
        const node = &self.nodes.items[node_index];
        const dominators = &node.dominators;
        const previous_dominators = if (!changed.*) dominators.clone() else null;
        defer {
            if (previous_dominators) |prev_doms| {
                prev_doms.deinit();
            }
        }
        dominators.clearRetainingCapacity();
        if (node.predecessors.items.len == 0) {
            try dominators.append(node_index);
        } else {
            const first_dominators = self.nodes.items[node.predecessors.items[0]].dominators.items;
            try appendSliceAndValue(node_index, dominators, first_dominators);
            for (node.predecessors.items[1..]) |predecessor_index| {
                try intersectionUnion(dominators, self.nodes.items[predecessor_index].dominators.items, node_index);
            }
        }
        if (previous_dominators) |prev_doms| {
            changed.* = !eql(NodeIndex, prev_doms, dominators.items);
        }
    }

    fn appendSliceAndValue(value: anytype, array: *ArrayList(@TypeOf(value)), slice: []const @TypeOf(value)) !void {
        for (slice) |slice_value, index| {
            if (slice_value > value and (index == 0 or slice[index - 1] < value)) {
                try array.append(value);
            }
            try array.append(slice_value);
        }
        if (slice.len == 0 or value > slice[slice.len - 1]) {
            try array.append(value);
        }
    }
    fn intersectionUnion(array: *ArrayList(NodeIndex), slice: []const NodeIndex, union_value: NodeIndex) !void {
        const array_copy = array.toOwnedSlice();
        defer array.allocator.free(array_copy);
        var array_iter = array_copy;
        var slice_iter = slice;
        while (array_iter.len != 0 and slice_iter.len != 0) {
            if (array_iter[0] == union_value) {
                try array.append(union_value);
                array_iter = array_iter[1..];
            } else if (array_iter[0] == slice_iter[0]) {
                try array.append(array_iter[0]);
                array_iter = array_iter[1..];
                slice_iter = slice_iter[1..];
            } else if (array_iter[0] < slice_iter[0]) {
                array_iter = array_iter[1..];
            } else {
                slice_iter = slice_iter[1..];
            }
        }
        if (array_iter.len != 0 and array_iter[0] <= union_value) {
            try array.append(union_value);
        }
    }
    pub fn getDominators(self: Self, node_index: NodeIndex) *const IntSet(NodeIndex) {
        return &self.nodes.items[node_index].dominators;
    }
    pub fn inCfg(self: Self, node_index: NodeIndex) bool {
        return self.nodes.items[node_index].in_cfg;
    }
};

const test_allocator = std.testing.allocator;
const expect = std.testing.expect;
const expectEqualSlices = std.testing.expectEqualSlices;

test "intersectionUnion" {
    var array = ArrayList(NodeIndex).init(test_allocator);
    defer array.deinit();
    try array.appendSlice(&[_]NodeIndex{ 1, 2, 3, 4, 5 });
    const slice_array = [_]NodeIndex{ 1, 4 };
    try Cfg.intersectionUnion(&array, &slice_array, 5);
    try expectEqualSlices(NodeIndex, &[_]NodeIndex{ 1, 4, 5 }, array.items);
}
test "intersectionUnion empty slice" {
    var array = ArrayList(NodeIndex).init(test_allocator);
    defer array.deinit();
    try array.appendSlice(&[_]NodeIndex{5});
    try Cfg.intersectionUnion(&array, &[_]NodeIndex{}, 5);
    try expectEqualSlices(NodeIndex, &[_]NodeIndex{5}, array.items);
}
test "intersectionUnion same slice" {
    var array = ArrayList(NodeIndex).init(test_allocator);
    defer array.deinit();
    try array.appendSlice(&[_]NodeIndex{ 0, 1, 2, 4 });
    try Cfg.intersectionUnion(&array, &[_]NodeIndex{ 0, 1, 2, 4 }, 4);
    try expectEqualSlices(NodeIndex, &[_]NodeIndex{ 0, 1, 2, 4 }, array.items);
}
test "appendSliceAndValue" {
    var array = ArrayList(NodeIndex).init(test_allocator);
    defer array.deinit();
    try Cfg.appendSliceAndValue(@as(NodeIndex, 5), &array, &[_]NodeIndex{ 1, 5, 7 });
    try expectEqualSlices(NodeIndex, &[_]NodeIndex{ 1, 5, 7 }, array.items);
}
test "appendSliceAndValue empty slice" {
    var array = ArrayList(NodeIndex).init(test_allocator);
    defer array.deinit();
    try Cfg.appendSliceAndValue(@as(NodeIndex, 5), &array, &[_]NodeIndex{});
    try expectEqualSlices(NodeIndex, &[_]NodeIndex{5}, array.items);
}
test "appendSliceAndValue slice with value" {
    var array = ArrayList(NodeIndex).init(test_allocator);
    defer array.deinit();
    try Cfg.appendSliceAndValue(@as(NodeIndex, 5), &array, &[_]NodeIndex{5});
    try expectEqualSlices(NodeIndex, &[_]NodeIndex{5}, array.items);
}

test "find dominators" {
    var cfg = try Cfg.init(test_allocator, 5);
    defer cfg.deinit();
    try cfg.addNode(&[_]NodeIndex{4});
    try cfg.addNode(&[_]NodeIndex{ 2, 4 });
    try cfg.addNode(&[_]NodeIndex{3});
    try cfg.addNode(&[_]NodeIndex{ 3, 2 });
    try cfg.addNode(&[_]NodeIndex{ 1, 1 });
    try cfg.findDominators();
    try expect(cfg.inCfg(0));
    try expect(cfg.inCfg(1));
    try expect(cfg.inCfg(2));
    try expect(cfg.inCfg(3));
    try expect(cfg.inCfg(4));
    try expectEqualSlices(NodeIndex, &[_]NodeIndex{}, cfg.nodes.items[0].predecessors.items);
    try expectEqualSlices(NodeIndex, &[_]NodeIndex{ 4, 4 }, cfg.nodes.items[1].predecessors.items);
    try expectEqualSlices(NodeIndex, &[_]NodeIndex{ 1, 3 }, cfg.nodes.items[2].predecessors.items);
    try expectEqualSlices(NodeIndex, &[_]NodeIndex{2}, cfg.nodes.items[3].predecessors.items);
    try expectEqualSlices(NodeIndex, &[_]NodeIndex{ 0, 1 }, cfg.nodes.items[4].predecessors.items);
    try expectEqualSlices(NodeIndex, &[_]NodeIndex{0}, cfg.getDominators(0).orderedSlice());
    try expectEqualSlices(NodeIndex, &[_]NodeIndex{ 0, 1, 4 }, cfg.getDominators(1).orderedSlice());
    try expectEqualSlices(NodeIndex, &[_]NodeIndex{ 0, 1, 2, 4 }, cfg.getDominators(2).orderedSlice());
    try expectEqualSlices(NodeIndex, &[_]NodeIndex{ 0, 1, 2, 3, 4 }, cfg.getDominators(3).orderedSlice());
    try expectEqualSlices(NodeIndex, &[_]NodeIndex{ 0, 4 }, cfg.getDominators(4).orderedSlice());
}
