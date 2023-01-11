const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const ArenaAllocator = std.heap.ArenaAllocator;
const BoundedArray = std.BoundedArray;

const NodeIndex = usize;
const Node = struct {
    bfs_number: usize = std.math.maxInt(usize),
    successors: BoundedArray(NodeIndex, 2),
    predecessors: ArrayList(NodeIndex),
    immediate_dominator: NodeIndex = undefined,
};

pub const Cfg = struct {
    const Self = @This();
    nodes: ArrayList(Node),
    gpa: Allocator,
    pub fn init(gpa: Allocator, nodes: usize) !Self {
        return Self{
            .nodes = try ArrayList(Node).initCapacity(gpa, nodes),
            .gpa = gpa,
        };
    }
    pub fn deinit(self: Self) void {
        for (self.nodes.items) |node| {
            node.predecessors.deinit();
        }
        self.nodes.deinit();
    }
    pub fn createNode(self: *Self, successors: []const NodeIndex) !void {
        try self.nodes.append(Node{
            .successors = try BoundedArray(NodeIndex, 2).fromSlice(successors),
            .predecessors = ArrayList(NodeIndex).init(self.gpa),
        });
    }
    fn findPredecessors(self: *Self) !void {
        for (self.nodes.items) |node, node_index| {
            for (node.successors.constSlice()) |successor_index| {
                if (node.bfs_number != std.math.maxInt(usize)) {
                    try self.nodes.items[successor_index].predecessors.append(node_index);
                }
            }
        }
    }
    fn findBfsSpanningTree(self: *Self) !ArrayList(NodeIndex) {
        var list = ArrayList(NodeIndex).init(self.gpa);
        defer list.deinit();
        const root = &self.nodes.items[0];
        try list.append(0); // append root
        var bfs_order = try ArrayList(NodeIndex).initCapacity(self.gpa, self.nodes.items.len);
        try bfs_order.append(0); // append root
        root.bfs_number = 0;
        while (getLastOrNull(list.items)) |node_index| {
            const node = self.nodes.items[node_index];
            // std.debug.print("findBfsSpanningTree {}\n", .{node_index});
            // std.debug.print("successors: {any}\n", .{node.successors.slice()});
            var successor_not_in_tree = false;
            for (node.successors.constSlice()) |successor_index| {
                const successor = &self.nodes.items[successor_index];
                if (successor.bfs_number == std.math.maxInt(usize)) {
                    successor_not_in_tree = true;
                    successor.immediate_dominator = node_index;
                    try list.append(successor_index);
                    successor.bfs_number = bfs_order.items.len;
                    try bfs_order.append(successor_index);
                }
            }
            if (!successor_not_in_tree) {
                _ = list.pop();
            }
        }
        return bfs_order;
    }
    // The algorithm is described the following papers:
    // A Simple, Fast Dominance Algorithm
    // Keith D. Cooper, Timothy J. Harvey, and Ken Kennedy
    // http://www.hipersoft.rice.edu/grads/publications/dom14.pdf
    //
    // Finding Dominators in Practice
    // Loukas Georgiadis, Robert E. Tarjan, Renato F. Werneck
    // https://jgaa.info/accepted/2006/GeorgiadisTarjanWerneck2006.10.1.pdf
    pub fn findImmediateDominators(self: *Self) !void {
        const bfs_order = try self.findBfsSpanningTree();
        defer bfs_order.deinit();
        // for (bfs_order.items) |node_index| {
        //     std.debug.print("{} ", .{node_index});
        // }
        // std.debug.print("\n", .{});
        try self.findPredecessors();
        const start_node = &self.nodes.items[0];
        start_node.immediate_dominator = 0;
        var changed = true;
        while (changed) {
            changed = false;
            // for (self.nodes.items) |node, node_index| {
            //     std.debug.print("{} -> {}\n", .{ node.immediate_dominator, node_index });
            // }
            // std.debug.print("\n", .{});
            for (bfs_order.items[1..]) |b_index| {
                const b = &self.nodes.items[b_index];
                var new_immediate_dominator = b.predecessors.items[0];
                // std.debug.print("b: {}\n", .{b_index});
                // std.debug.print("new_idom: {}\n", .{new_immediate_dominator});
                for (b.predecessors.items[1..]) |p_index| {
                    new_immediate_dominator = self.intersect(p_index, new_immediate_dominator);
                    // std.debug.print("new_idom: {}\n", .{new_immediate_dominator});
                }
                if (b.immediate_dominator != new_immediate_dominator) {
                    b.immediate_dominator = new_immediate_dominator;
                    changed = true;
                }
            }
        }
    }
    fn intersect(self: Self, b1: NodeIndex, b2: NodeIndex) NodeIndex {
        // std.debug.print("intersection({}, {})\n", .{ b1, b2 });
        var finger1_index = b1;
        var finger1 = self.nodes.items[finger1_index];
        var finger2_index = b2;
        var finger2 = self.nodes.items[finger2_index];
        while (finger1_index != finger2_index) {
            // std.debug.print("finger1: {} {}, finger2: {} {}\n", .{ finger1_index, finger1.bfs_number, finger2_index, finger2.bfs_number });
            while (finger1.bfs_number < finger2.bfs_number) {
                // std.debug.print("finger1: {} {}, finger2: {} {}\n", .{ finger1_index, finger1.bfs_number, finger2_index, finger2.bfs_number });
                finger2_index = finger2.immediate_dominator;
                finger2 = self.nodes.items[finger2_index];
            }
            while (finger2.bfs_number < finger1.bfs_number) {
                // std.debug.print("finger1: {} {}, finger2: {} {}\n", .{ finger1_index, finger1.bfs_number, finger2_index, finger2.bfs_number });
                finger1_index = finger1.immediate_dominator;
                finger1 = self.nodes.items[finger1_index];
            }
        }
        return finger1_index;
    }
    pub fn getImmediateDominator(self: Self, node_index: NodeIndex) NodeIndex {
        return self.nodes.items[node_index].immediate_dominator;
    }
    pub fn getPrdecessors(self: Self, node_index: NodeIndex) []const NodeIndex {
        return self.nodes.items[node_index].predecessors.items;
    }
};

fn BfsIter(comptime T: type) type {
    return struct {
        const Self = @This();
        array: []T,
        fn init(array: []T) Self {
            return Self{
                .array = array,
            };
        }
        fn next(self: *Self) ?T {
            _ = self;
            return null;
        }
    };
}

fn getLastOrNull(array: []NodeIndex) ?NodeIndex {
    if (array.len == 0) return null;
    return array[array.len - 1];
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const test_allocator = std.testing.allocator;

test "simple cfg" {
    var cfg = try Cfg.init(test_allocator, 6);
    defer cfg.deinit();
    try cfg.createNode(([_]usize{1})[0..]);
    try cfg.createNode(([_]usize{ 2, 5 })[0..]);
    try cfg.createNode(([_]usize{ 3, 4 })[0..]);
    try cfg.createNode(([_]usize{4})[0..]);
    try cfg.createNode(([_]usize{ 1, 4 })[0..]);
    try cfg.createNode(([_]usize{})[0..]);
    try cfg.findImmediateDominators();
    try expectEqual(@as(usize, 0), cfg.getImmediateDominator(0));
    try expectEqual(@as(usize, 0), cfg.getImmediateDominator(1));
    try expectEqual(@as(usize, 1), cfg.getImmediateDominator(2));
    try expectEqual(@as(usize, 2), cfg.getImmediateDominator(3));
    try expectEqual(@as(usize, 2), cfg.getImmediateDominator(4));
    try expectEqual(@as(usize, 1), cfg.getImmediateDominator(5));
    try verifyImmediateDominators(cfg);
}

test "random 20 node cfg" {
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        try testFindImmediateDominator(20);
    }
}

test "random 200 node cfg" {
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        try testFindImmediateDominator(200);
    }
}

test "random 2000 node cfg" {
    try testFindImmediateDominator(2000);
}

fn testFindImmediateDominator(nodes: usize) !void {
    var cfg = try generateRandomCfg(test_allocator, nodes);
    defer cfg.deinit();
    try cfg.findImmediateDominators();
    try verifyImmediateDominators(cfg);
}

fn generateRandomCfg(allocator: Allocator, nodes: usize) !Cfg {
    var prng = std.rand.DefaultPrng.init(blk: {
        var seed: u64 = undefined;
        try std.os.getrandom(std.mem.asBytes(&seed));
        break :blk seed;
    });
    const rand = prng.random();
    var cfg = try Cfg.init(allocator, nodes);
    var node_index: usize = 0;
    while (node_index < nodes) : (node_index += 1) {
        switch (rand.intRangeLessThan(usize, 0, 100)) {
            0...3 => try cfg.createNode(&[_]usize{}),
            4...50 => try cfg.createNode(&[_]usize{rand.intRangeLessThan(usize, 1, nodes)}),
            else => try cfg.createNode(&[_]usize{ rand.intRangeLessThan(usize, 1, nodes), rand.intRangeLessThan(usize, 1, nodes) }),
        }
    }
    return cfg;
}
fn printCfg(cfg: Cfg) void {
    for (cfg.nodes.items) |node, node_index| {
        for (node.successors.constSlice()) |successor_index| {
            std.debug.print("{} -> {}\n", .{ node_index, successor_index });
        }
    }
}

const simple = @import("simple_dominator_tree.zig");
const IntSet = @import("int_set.zig").IntSet;

fn verifyImmediateDominators(cfg: Cfg) !void {
    var simpleCfg = try simple.Cfg.init(test_allocator, cfg.nodes.items.len);
    defer simpleCfg.deinit();
    for (cfg.nodes.items) |node| {
        try simpleCfg.addNode(node.successors.constSlice());
    }
    try simpleCfg.findDominators();
    for (cfg.nodes.items) |_, node_index| {
        const dominators = simpleCfg.getDominators(node_index);
        if (simpleCfg.inCfg(node_index)) {
            try verifyDominators(cfg, node_index, dominators);
        }
    }
}

fn verifyDominators(cfg: Cfg, node_index: NodeIndex, dominators: *const IntSet(NodeIndex)) !void {
    var index = node_index;
    var immediate_dominator = cfg.getImmediateDominator(index);
    while (index != immediate_dominator) : ({
        index = immediate_dominator;
        immediate_dominator = cfg.getImmediateDominator(index);
    }) {
        try expect(dominators.isElementOf(immediate_dominator));
    }
}

fn nodeIndexOrder(context: void, lhs: NodeIndex, rhs: NodeIndex) std.math.Order {
    _ = context;
    return std.math.order(lhs, rhs);
}

fn inDominatorSet(node_index: NodeIndex, dominators: []const NodeIndex) bool {
    return std.sort.binarySearch(NodeIndex, node_index, dominators, {}, nodeIndexOrder) != null;
}
