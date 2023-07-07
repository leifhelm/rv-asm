const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const Block = @import("block.zig").Block;
const getId = @import("util.zig").getId;

pub const Function = struct {
    const Self = @This();

    allocator: Allocator,
    arena: ArenaAllocator,

    id: usize,
    blocks: ArrayList(*Block),
    name: []const u8,

    pub fn init(allocator: Allocator, name: []const u8) !Self {
        var arena = ArenaAllocator.init(allocator);
        const allocated_name = try arena.allocator().dupe(u8, name);
        return Self{
            .arena = arena,
            .allocator = allocator,
            .id = getId(),
            .blocks = ArrayList(*Block).init(allocator),
            .name = allocated_name,
        };
    }
    pub fn deinit(self: Self) void {
        self.blocks.deinit();
        self.arena.deinit();
    }
    pub fn addBlock(self: *Self) !*Block {
        const block = try self.arena.allocator().create(Block);
        try self.blocks.append(block);
        return block;
    }
};

const FunctionError = error{InvalidId};

const expect = std.testing.expect;
const test_allocator = std.testing.allocator;

test "function id" {
    var f1 = try Function.init(test_allocator, "hello_world");
    defer f1.deinit();
    var f2 = try Function.init(test_allocator, "function_2");
    defer f2.deinit();
    try expect(f1.id != f2.id);
}

test "add block" {
    var function = try Function.init(test_allocator, "function");
    defer function.deinit();
    const block = try function.addBlock();
    _ = block;
}
