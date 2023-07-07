const std = @import("std");
const meta = std.meta;
const mem = std.mem;
const math = std.math;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const BoundedArray = std.BoundedArray;
const assert = std.debug.assert;

const Reg = @import("types.zig").Reg;
const regs = @import("types.zig").regs;
const Cfg = @import("dominator_tree.zig").Cfg;
const boundedArrayFromTuple = @import("util.zig").boundedArrayFromTuple;
const typedId = @import("util.zig").typedId;

const BlockId = usize;
const Block = struct {
    const Self = @This();

    id: BlockId,
    statements: ArrayList(Statement),
    successor_blocks: BoundedArray(BlockId, 2),

    register_file: [32]?StatementRef = [1]?StatementRef{null} ** 32,
    spill: Spill,

    fn init(allocator: Allocator, id: usize) Self {
        return Self{
            .id = id,
            .statements = ArrayList(Statement).init(allocator),
            .successor_blocks = BoundedArray(BlockId, 2).init(0) catch unreachable,
            .spill = Spill.init(allocator),
        };
    }
    fn deinit(self: Self) void {
        self.statements.deinit();
        self.spill.deinit();
    }
    fn addStatement(
        self: *Self,
        statement_meta: StatementMeta,
        input_values: []const Value,
    ) !StatementRef {
        const statement_id = self.statements.items.len;
        var input_value_array = BoundedArray(ReadAllocation, 2).init(0) catch unreachable;
        for (input_values) |statement| {
            try input_value_array.append(.{ .statement = statement });
        }
        try self.statements.append(.{
            .id = statement_id,
            .meta = statement_meta,
            .input_values = input_value_array,
        });
        return StatementRef{
            .block_id = self.id,
            .statement_id = statement_id,
        };
    }
    pub fn format(
        self: Self,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("Block {} -> {any}\n", .{ self.id, self.successor_blocks.constSlice() });
        for (self.statements.items) |statement| {
            try writer.print("{}\n", .{statement});
        }
        // if (mem.eql(u8, fmt, "c")) {
        //     if (self.before_constraints.items.len > 0) {
        //         try writer.writeAll("Constraints before:\n");
        //         for (self.before_constraints.items) |constraint, index| {
        //             try writer.print("{}: x{}\n", .{ index, constraint.register });
        //         }
        //     }
        //     if (self.after_constraints.items.len > 0) {
        //         try writer.writeAll("Constraints after:\n");
        //         for (self.after_constraints.items) |constraint, index| {
        //             try writer.print("{}: x{} <- {}\n", .{ index, constraint.register, constraint.statement });
        //         }
        //     }
        // }
    }
};

const Value = union(enum) {
    const Self = @This();

    Register: Reg,
    Statement: StatementRef,

    fn from(value: anytype) Self {
        const value_type = @TypeOf(value);
        if (value_type == Reg) {
            return .{ .Register = value };
        } else if (value_type == StatementRef) {
            return .{ .Statement = value };
        } else if (value_type == Self) {
            return value;
        }
        {
            @compileError("expected either " ++
                @typeName(Reg) ++
                " or " ++
                @typeName(StatementRef) ++
                ", found " ++
                @typeName(value_type));
        }
    }
    pub fn format(
        self: Self,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        switch (self) {
            .Register => |reg| try writer.print("x{}", .{reg}),
            .Statement => |statement| try writer.print("{}", .{statement}),
        }
    }
};
const StatementId = usize;
const StatementRef = struct {
    const Self = @This();

    block_id: BlockId,
    statement_id: StatementId,

    pub fn format(
        self: Self,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("{}.{}", .{ self.block_id, self.statement_id });
    }
};
const Statement = struct {
    const Self = @This();

    id: StatementId,
    input_values: BoundedArray(ReadAllocation, 2),
    meta: StatementMeta,
    fixed_register: ?Reg = null,

    allocation: ?Allocation = null,

    pub fn format(
        self: Self,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("{}: ", .{self.id});
        if (self.meta.has_result) {
            if (self.allocation) |allocation| {
                try writer.print("{} <- ", .{allocation});
            } else {
                try writer.writeAll("? <- ");
            }
        }
        if (self.meta.is_phi) {
            try writer.writeAll("phi");
        } else {
            try writer.print("{any}", .{self.input_values.constSlice()});
        }
        if (self.meta.phi_at) |phi_statement| {
            try writer.print(" phi@{}", .{phi_statement});
        }
        // if (self.before_constraint) |constraint_id| {
        //     try writer.print(" before {}", .{constraint_id});
        // }
        // if (self.after_constraint) |constraint_id| {
        //     try writer.print(" after {}", .{constraint_id});
        // }
    }
};
const StatementMeta = struct {
    has_result: bool,
    requires_register: bool,
    is_phi: bool = false,
    phi_at: ?StatementRef = null,
};

const BeforeConstraint = struct {
    register: Reg,
    statement: ?StatementRef,
};
const AfterConstraint = struct {
    register: Reg,
    statement: StatementRef,
};

const SpillPos = u64;

const Spill = struct {
    const Self = @This();
    spill: ArrayList(?StatementRef),
    lowest_free_index: usize,
    fn init(allocator: Allocator) Self {
        return Self{
            .spill = ArrayList(?StatementRef).init(allocator),
            .lowest_free_index = 0,
        };
    }
    fn deinit(self: Self) void {
        self.spill.deinit();
    }
    fn put(spill1: *Self, spill2: *Self, statement: StatementRef) !SpillPos {
        var spill_pos = spill1.lowest_free_index;
        while (spill1.get(spill_pos) != null or spill2.get(spill_pos) != null) {
            spill_pos += 1;
        }
        try spill1.set(spill_pos, statement);
        try spill2.set(spill_pos, statement);

        if (spill1.lowest_free_index == spill_pos) {
            spill1.lowest_free_index += 1;
            while (spill1.lowest_free_index < spill1.spill.items.len and spill1.spill.items[spill1.lowest_free_index] != null) : (spill1.lowest_free_index += 1) {}
        }
        return spill_pos;
    }
    fn set(self: *Self, spill_pos: SpillPos, statement: ?StatementRef) !void {
        if (spill_pos < self.spill.items.len) {
            self.spill.items[spill_pos] = statement;
        } else {
            try self.spill.ensureTotalCapacity(spill_pos + 1);
            self.spill.appendNTimesAssumeCapacity(null, spill_pos - self.spill.items.len);
            self.spill.appendAssumeCapacity(statement);
            assert(self.spill.items.len == spill_pos + 1);
        }
    }
    fn get(self: Self, spill_pos: SpillPos) ?StatementRef {
        if (spill_pos < self.spill.items.len) {
            return self.spill.items[spill_pos];
        } else {
            return null;
        }
    }
    fn delete(self: *Self, spill_pos: SpillPos) void {
        self.spill.items[spill_pos] = null;
        self.lowest_free_index = std.math.min(self.lowest_free_index, spill_pos);
    }
    fn merge(self: *Self, other: Self) AllocationError!void {
        if (self.spill.items.len < other.spill.items.len) {
            return AllocationError.InvalidMerge;
        }
        for (self.spill.items) |*spill, i| {
            const other_spill = other.spill.items[i];
            if (!meta.eql(spill.*, other_spill)) {
                if (spill.* == null) {
                    spill.* = other_spill;
                } else return AllocationError.InvalidMerge;
            }
        }
    }
};
const ReadAllocation = struct {
    const Self = @This();

    value: Value,
    allocation: ?Allocation = null,
    after: ?MemoryAction = null,
    before: ?MemoryAction = null,
    requires_register: bool = true,

    fn init(value: Value, requires_register: bool) Self {
        const allocation = switch (value) {
            .Register => |reg| Allocation{ .Register = reg },
            .Statement => null,
        };
        return .{
            .value = value,
            .allocation = allocation,
            .requires_register = requires_register,
        };
    }

    fn from(allocation: anytype) Self {
        const allocation_type = @TypeOf(allocation);
        if (allocation_type == Self) {
            return allocation;
        } else {
            return Self.init(Value.from(allocation), true);
        }
    }

    pub fn format(
        self: Self,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("{}", .{self.value});
        if (self.value == .Statement) {
            if (self.allocation) |allocation| {
                try writer.print("@{}", .{allocation});
            }
        }
        if (self.before) |before| {
            try writer.print(" before {}", .{before});
        }
        if (self.after) |after| {
            try writer.print(" after {}", .{after});
        }
    }
};

const Allocation = union(enum) {
    const Self = @This();

    Register: Reg,
    Spill: SpillPos,

    fn getRegister(self: Self) ?Reg {
        return switch (self) {
            .Register => |reg| reg,
            else => null,
        };
    }

    pub fn format(
        self: Self,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        switch (self) {
            .Register => |reg| try writer.print("x{}", .{reg}),
            .Spill => |spill_pos| try writer.print("s{}", .{spill_pos}),
        }
    }
};
const MemoryAction = union(enum) {
    const Self = @This();

    LoadFromSpill: SpillPos,
    StoreToSpill: SpillPos,

    pub fn format(
        self: Self,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        switch (self) {
            .LoadFromSpill => |spill_pos| try writer.print("load s{}", .{spill_pos}),
            .StoreToSpill => |spill_pos| try writer.print("store s{}", .{spill_pos}),
        }
    }
};

const Function = struct {
    const Self = @This();

    allocator: Allocator,

    blocks: ArrayList(Block),
    cfg: ?Cfg = null,

    pub fn init(allocator: Allocator) Self {
        return Self{
            .blocks = ArrayList(Block).init(allocator),
            .allocator = allocator,
        };
    }
    pub fn deinit(self: Self) void {
        for (self.blocks.items) |block| {
            block.deinit();
        }
        self.blocks.deinit();
        if (self.cfg) |cfg| {
            cfg.deinit();
        }
    }

    pub fn addBlock(self: *Self) !BlockId {
        const block_id = self.blocks.items.len;
        try self.blocks.append(Block.init(self.blocks.allocator, block_id));
        return block_id;
    }

    pub fn addStatement(
        self: *Self,
        block_id: BlockId,
        statement_meta: StatementMeta,
        input_value: anytype,
    ) !StatementRef {
        const input_value_array = boundedArrayFromInputValues(input_value);
        const block = self.getBlock(block_id);
        const statement_id = block.statements.items.len;
        try block.statements.append(.{
            .id = statement_id,
            .meta = statement_meta,
            .input_values = input_value_array,
        });
        return StatementRef{
            .block_id = block_id,
            .statement_id = statement_id,
        };
    }

    // pub fn addBeforeConstraint(self: *Self, reg: Reg, statement_ref: StatementRef) !void {
    //     const block = self.getBlock(statement_ref.block_id);
    //     const before_constraint_index = block.before_constraints.items.len;
    //     try block.before_constraints.append(.{
    //         .register = reg,
    //         .statement = statement_ref,
    //     });
    //     const statement = self.getStatement(statement_ref);
    //     assert(statement.before_constraint == null);
    //     statement.before_constraint = before_constraint_index;
    // }

    // pub fn invalidateRegister(self: *Self, block_id: BlockId, reg: Reg) !void {
    //     try self.getBlock(block_id).before_constraints.append(.{
    //         .register = reg,
    //         .statement = null,
    //     });
    // }

    pub fn readRegister(self: *Self, block_id: BlockId, register: Reg) !StatementRef {
        const read_statement_ref = try self.addStatement(block_id, result, .{register});
        const read_statement = self.getStatement(read_statement_ref);
        read_statement.allocation = .{ .Register = register };
    }

    pub fn writeRegister(self: *Self, block_id: BlockId, register: Reg, statement: StatementRef) !void {
        const allocation = Allocation{.Register = register};
        const read_allocation = ReadAllocation{
            .value = .{ .Statement = statement },
            .requires_register = false,
            .allocation = allocation,
        };
        const input_values = boundedArrayFromInputValues(.{read_allocation});
        const write_statement_ref = try self.addStatementInternal(
            block_id,
            .{ .id = undefined, .meta = result, .input_values = input_values },
        );
        const write_statement = self.getStatement(write_statement_ref);
        write_statement.allocation = .{ .Register = register };
        write_statement.fixed_register = register;
    }

    fn addStatementInternal(self: *Self, block_id: BlockId, statement: Statement) !StatementRef {
        const block = self.getBlock(block_id);
        const statement_id = block.statements.items.len;
        var statement_with_id = statement;
        statement_with_id.id = statement_id;
        try block.statements.append(statement_with_id);
        return StatementRef{
            .block_id = block_id,
            .statement_id = statement_id,
        };
    }

    pub fn addBlockSuccessor(self: *Self, block_id: BlockId, successor_id: BlockId) !void {
        try self.getBlock(block_id).successor_blocks.append(successor_id);
    }

    pub fn allocateRegisters(self: *Self) (AllocationError || error{OutOfMemory})!void {
        try self.analyzeCfg();
        for(self.cfg.?.post_order.items) |block_id|{
            try self.allocateRegistersForBlock(block_id);
        }
    }

    fn allocateRegistersForBlock(self: *Self, block_id: BlockId) (AllocationError || error{OutOfMemory})!void {
        std.debug.print("Block: {}\n", .{block_id});
        const block = self.getBlock(block_id);
        for (block.successor_blocks.constSlice()) |successor_id| {
            try self.mergeRegisterFileAndSpill(block, successor_id);
        }
        // for (block.after_constraints.items) |after_constraint| {
        //     const register_value = &block.register_file[after_constraint.register];
        //     if (register_value.*) |statement_ref| {
        //         const statement = self.getStatement(statement_ref);
        //         const statement_block = self.getBlock(statement_ref.block_id);
        //         statement.allocation = .{ .Spill = try Spill.put(&block.spill, &statement_block.spill, statement_ref) };
        //     }
        //     register_value.* = after_constraint.statement;
        //     const statement = self.getStatement(after_constraint.statement);
        //     statement.allocation = .{ .Register = after_constraint.register };
        // }
        var i: usize = block.statements.items.len;
        while (i > 0) {
            i -= 1;
            const statement = &block.statements.items[i];
            if (statement.meta.has_result) {
                const allocation = if (statement.meta.phi_at) |phi_statement|
                    self.getStatementConst(phi_statement).allocation.?
                else
                    statement.allocation.?;
                switch (allocation) {
                    .Register => |reg| block.register_file[reg] = null,
                    .Spill => |spill_pos| block.spill.delete(spill_pos),
                }
                statement.allocation = allocation;
            }
            for (statement.input_values.slice()) |*read_allocation| {
                switch (read_allocation.value){
                    .Statement => try self.findReadRegister(block, read_allocation),
                    .Register => {},
                }
            }
        }
        // for(block.before_constraints.items) |constraint| {
        //     const register_value = &block.register_file[constraint.register];
        //     if(!(register_value.* == null)){
        //         return AllocationError.InvalidConstraint;
        //     }
        //     register_value.* = null;
        // }
        // const immediate_dominator = self.blocks.items[self.cfg.?.getImmediateDominator(block_id)];

    }
    fn findReadRegister(self: *Self, block: *Block, read_allocation: *ReadAllocation) !void {
        std.debug.print("{}\n", .{self});
        const statement_ref = read_allocation.value.Statement;
        const statement: *Statement = self.getStatement(statement_ref);
        if (self.findExistingAllocation(block, read_allocation)) {
            return;
        }
        var reg: ?Reg = if (self.findFreeRegister(block, statement, read_allocation)) |reg|
            reg
        else
            try self.spillValue(block, read_allocation);
        const statement_block = self.getBlock(statement_ref.block_id);
        if (reg) |r| {
            read_allocation.allocation = .{ .Register = r };
            block.register_file[r] = statement_ref;
            statement_block.register_file[r] = statement_ref;
            statement.allocation = .{ .Register = r };
        } else {
            const spill_pos = try Spill.put(&block.spill, &statement_block.spill, statement_ref);
            read_allocation.allocation = .{ .Spill = spill_pos };
            statement.allocation = .{ .Spill = spill_pos };
        }
    }
    fn findExistingAllocation(self: *const Self, block: *const Block, read_allocation: *ReadAllocation) bool {
        const statement_ref = read_allocation.value.Statement;
        const statement = self.getStatementConst(statement_ref);
        assert(statement.meta.has_result);
        if (statement.allocation) |allocation| {
            if (allocation.getRegister()) |reg| {
                const register = block.register_file[reg].?;
                read_allocation.allocation = .{ .Register = reg };
                assert(meta.eql(register, statement_ref));
            }
            return true;
        } else {
            return false;
        }
    }
    fn findFreeRegister(self: *const Self, block: *Block, statement: *const Statement, read_allocation: *const ReadAllocation) ?Reg {
        const statement_ref = read_allocation.value.Statement;
        const statement_block = self.getBlockConst(statement_ref.block_id);
        _ = statement;
        // if (statement.after_constraint) |constraint_id| {
        //     const constraint = statement_block.after_constraints.items[constraint_id];
        //     assert(block.register_file[constraint.register] == null);
        //     return constraint.register;
        // }
        // if (statement.before_constraint) |constraint_id| {
        //     const constraint = statement_block.before_constraints.items[constraint_id];
        //     assert(meta.eql(constraint.statement, statement_ref));
        //     if (block.register_file[constraint.register] == null) {
        //         return constraint.register;
        //     }
        // }
        var j: Reg = 31;
        while (j > 0) : (j -= 1) {
            if (j == regs.fp) {
                continue;
            }
            if (block.register_file[j] == null) {
                if (statement_block.register_file[j] == null) {
                    return j;
                }
            }
        }
        return null;
    }
    fn spillValue(self: *Self, block: *Block, read_allocation: *ReadAllocation) !Reg {
        var reg: Reg = 31;
        var best_reg: Reg = 31;
        var best_index: StatementId = math.maxInt(StatementId);
        var best_depth: usize = math.maxInt(usize);
        var best_block: BlockId = undefined;
        while (reg > 0) : (reg -= 1) {
            if (reg == regs.fp) {
                continue;
            }
            const statement = block.register_file[reg].?;
            const depth = self.cfg.?.getDominatorTreeDepth(statement.block_id);
            // TODO: make compatible with constants
            if (depth < best_depth or statement.statement_id < best_index) {
                best_reg = reg;
                best_index = statement.statement_id;
                best_block = statement.block_id;
                best_depth = depth;
            }
        }
        const statement_block = self.getBlock(read_allocation.value.Statement.block_id);
        const spill_pos = try Spill.put(&block.spill, &statement_block.spill, block.register_file[best_reg].?);
        const spilled_statement = self.getStatement(.{ .block_id = best_block, .statement_id = best_index });
        spilled_statement.allocation = .{ .Spill = spill_pos };
        read_allocation.after = .{ .LoadFromSpill = spill_pos };
        return best_reg;
    }

    fn mergeRegisterFileAndSpill(self: *Self, block: *Block, other_block_id: BlockId) AllocationError!void {
        const other_block = self.getBlock(other_block_id);
        const other_register_file = &other_block.register_file;
        for (block.register_file) |*register, i| {
            const other_register = other_register_file[i];
            if (!meta.eql(register.*, other_register)) {
                if (register.* != null and other_register != null) {
                    return AllocationError.InvalidMerge;
                }
                if (register.* == null) {
                    register.* = other_register;
                }
            }
        }
        const other_spill = other_block.spill;
        try block.spill.merge(other_spill);
    }

    fn analyzeCfg(self: *Self) !void {
        self.cfg = try Cfg.init(self.allocator, self.blocks.items.len);
        for (self.blocks.items) |block| {
            self.cfg.?.createNode(block.successor_blocks.constSlice()) catch |err| switch (err) {
                error.Overflow => unreachable,
                error.OutOfMemory => return error.OutOfMemory,
            };
        }
        try self.cfg.?.analyze();
    }

    fn verifyRegisterAllocation(self: Self) (VerificationError || error{OutOfMemory})!void {
        var verification_stack = ArrayList(Verification).init(self.allocator);
        defer verification_stack.deinit();
        try verification_stack.append(.{
            .function = &self,
            .block_id = 0,
            .spill = ArrayList(?StatementRef).init(self.allocator),
        });

        var visited_edges = ArrayList(bool).init(self.allocator);
        defer visited_edges.deinit();
        try visited_edges.appendNTimes(false, self.blocks.items.len * 2);

        while (verification_stack.popOrNull()) |*v| {
            try v.verify(&verification_stack, visited_edges.items);
        }
    }

    fn verify(self: Self) VerificationError!void {
        for (self.blocks.items) |block| {
            for (block.statements.items) |statement| {
                const input_registers = statement.input_values.constSlice();
                assert(input_registers.len <= 2);
                if (input_registers.len == 2) {
                    if (meta.eql(input_registers[0], input_registers[1])) {
                        return VerificationError.InvalidInputRegister;
                    }
                }
            }
        }
    }

    fn getBlock(self: *Self, block_id: BlockId) *Block {
        return &self.blocks.items[block_id];
    }

    fn getBlockConst(self: *const Self, block_id: BlockId) *const Block {
        return &self.blocks.items[block_id];
    }

    fn getStatement(self: *Self, statement: StatementRef) *Statement {
        const block = self.getBlock(statement.block_id);
        return &block.statements.items[statement.statement_id];
    }

    fn getStatementConst(self: *const Self, statement: StatementRef) *const Statement {
        const block = self.getBlockConst(statement.block_id);
        return &block.statements.items[statement.statement_id];
    }

    pub fn format(
        self: Self,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.writeAll("Function:\n");
        for (self.blocks.items) |block| {
            try writer.print("{" ++ fmt ++ "}\n", .{block});
        }
    }
};

// const RegisterAllocator = struct {
//     const Self = @This();

//     register_file: [32]?StatementRef = [1]?StatementRef{null} ** 32,
//     spill: Spill,
//     function: *Function,
//     block_id: BlockId,

//     fn allocate(self: Self, register_allocator_stack: *ArrayList(Self), ) !void{

//     }

// };

const Verification = struct {
    const Self = @This();

    register_file: [32]?StatementRef = [1]?StatementRef{null} ** 32,
    spill: ArrayList(?StatementRef),
    function: *const Function,
    block_id: BlockId,

    fn verify(
        self: *Self,
        verification_stack: *ArrayList(Self),
        visited_edges: []bool,
    ) (VerificationError || error{OutOfMemory})!void {
        const block = self.function.getBlockConst(self.block_id);
        // for (block.before_constraints.items) |constraint| {
        //     self.register_file[constraint.register] = constraint.statement;
        // }
        for (block.statements.items) |statement, statement_id| {
            const statement_ref = StatementRef{
                .block_id = self.block_id,
                .statement_id = statement_id,
            };
            if (statement.meta.has_result and statement.allocation == null) {
                return VerificationError.MissingAllocation;
            }
            if (!statement.meta.has_result and statement.allocation != null) {
                return VerificationError.InvalidAllocation;
            }
            const read_allocs = statement.input_values.constSlice();
            for (read_allocs) |read_allocation| {
                if (read_allocation.allocation) |allocation| {
                    if ((read_allocation.requires_register or read_allocation.before != null or read_allocation.after != null) and allocation != .Register) {
                        return VerificationError.RequiresRegister;
                    }
                } else {
                    return VerificationError.MissingAllocation;
                }
            }
            // before
            for (read_allocs) |read_allocation| {
                const allocation = read_allocation.allocation.?;
                if (read_allocation.before) |before| {
                    switch (before) {
                        .LoadFromSpill => |spill_pos| self.register_file[allocation.Register] = self.spill.items[spill_pos],
                        .StoreToSpill => return VerificationError.InvalidMemoryAction,
                    }
                }
            }
            // instruction
            for (read_allocs) |read_allocation| {
                const allocation = read_allocation.allocation.?;
                if (read_allocation.value == .Statement and !meta.eql(self.register_file[allocation.Register], read_allocation.value.Statement)) {
                    return VerificationError.InvalidRegisterFile;
                }
                if(read_allocation.value == .Register){
                    self.register_file[read_allocation.value.Register] = null;
                }
            }
            if (statement.meta.has_result) {
                if (statement.meta.is_phi) {
                    const phi_at_statement = self.function.getStatementConst(switch (statement.allocation.?) {
                        .Register => |reg| if (self.register_file[reg]) |phi_at_statement| phi_at_statement else return VerificationError.MissingPhiAt,
                        .Spill => |spill_pos| if (self.spill.items[spill_pos]) |phi_at_statement| phi_at_statement else return VerificationError.MissingPhiAt,
                    });
                    if (phi_at_statement.meta.phi_at) |phi_at| {
                        if (!meta.eql(phi_at, statement_ref)) {
                            return VerificationError.InvalidRegisterFile;
                        }
                    } else {
                        return VerificationError.InvalidRegisterFile;
                    }
                }
                switch (statement.allocation.?) {
                    .Register => |reg| self.register_file[reg] = statement_ref,
                    .Spill => |spill_pos| try setList(spill_pos, @as(?StatementRef, statement_ref), &self.spill),
                }
            }
            // after
            for (read_allocs) |read_allocation| {
                const allocation = read_allocation.allocation.?;
                if (read_allocation.after) |after| {
                    const register_value = &self.register_file[allocation.Register];
                    switch (after) {
                        .LoadFromSpill => |spill_pos| register_value.* = self.spill.items[spill_pos],
                        .StoreToSpill => |spill_pos| try setList(spill_pos, @as(?StatementRef, register_value.*), &self.spill),
                    }
                }
            }
        }

        // for (block.after_constraints.items) |constraint| {
        //     if (!meta.eql(self.register_file[constraint.register], constraint.statement)) {
        //         std.debug.print("{}\n", .{constraint});
        //         std.debug.print("{any}\n", .{self.register_file});
        //         return VerificationError.InvalidRegisterFile;
        //     }
        // }

        for (block.successor_blocks.constSlice()) |successor_id, index| {
            const edge_index = self.block_id * 2 + index;
            if (visited_edges[edge_index] == false) {
                visited_edges[edge_index] = true;
                var spill = try ArrayList(?StatementRef).initCapacity(self.spill.allocator, self.spill.items.len);
                spill.appendSliceAssumeCapacity(self.spill.items);
                try verification_stack.append(.{
                    .register_file = self.register_file,
                    .function = self.function,
                    .block_id = successor_id,
                    .spill = spill,
                });
            }
        }
    }
};

fn boundedArrayFromInputValues(input_value: anytype) BoundedArray(ReadAllocation, 2) {
    return boundedArrayFromTuple(ReadAllocation, 2, input_value, ReadAllocation.from);
}

const AllocationError = error{
    InvalidValue,
    InvalidMerge,
    ValueIsNotUsedByBothSuccessors,
    InvalidConstraint,
};
const VerificationError = error{
    InvalidInputRegister,
    MissingAllocation,
    InvalidAllocation,
    RequiresRegister,
    InvalidRegisterFile,
    InvalidMemoryAction,
    MissingPhiAt,
};

fn setList(index: usize, value: anytype, list: *ArrayList(@TypeOf(value))) !void {
    if (index >= list.items.len) {
        try list.resize(index + 1);
    }
    list.items[index] = value;
}

const result = StatementMeta{
    .has_result = true,
    .requires_register = true,
};
const read_register = StatementMeta{
    .has_result = true,
    .requires_register = false,
};
const no_result = StatementMeta{
    .has_result = false,
    .requires_register = false,
};
const phi = StatementMeta{
    .has_result = true,
    .requires_register = false,
    .is_phi = true,
};
fn phiAt(statement: StatementRef) StatementMeta {
    return .{
        .has_result = true,
        .requires_register = false,
        .phi_at = statement,
    };
}

const test_allocator = std.testing.allocator;
const expectError = std.testing.expectError;

fn addReadRegister(function: *Function, block: BlockId, register: Reg) !StatementRef {
    const value = try function.addStatement(block, read_register, .{register});
    return value;
}

fn invalidateRegister(function: *Function, block: BlockId, register: Reg) !void {
    _ = try function.addStatement(block, no_result, .{register});
}

fn invalidateAfterFunctionCall(function: *Function, block: BlockId) !void {
    try invalidateRegister(function, block, regs.ra);
    try invalidateRegister(function, block, regs.a0);
    try invalidateRegister(function, block, regs.a1);
    try invalidateRegister(function, block, regs.a2);
    try invalidateRegister(function, block, regs.a3);
    try invalidateRegister(function, block, regs.a4);
    try invalidateRegister(function, block, regs.a5);
    try invalidateRegister(function, block, regs.a6);
    try invalidateRegister(function, block, regs.a7);
    try invalidateRegister(function, block, regs.t0);
    try invalidateRegister(function, block, regs.t1);
    try invalidateRegister(function, block, regs.t2);
    try invalidateRegister(function, block, regs.t3);
    try invalidateRegister(function, block, regs.t4);
    try invalidateRegister(function, block, regs.t5);
    try invalidateRegister(function, block, regs.t6);
}
const SavedRegisters = struct {
    ra: StatementRef,
    sp: StatementRef,
    gp: StatementRef,
    tp: StatementRef,
    fp: StatementRef,
    s1: StatementRef,
    s2: StatementRef,
    s3: StatementRef,
    s4: StatementRef,
    s5: StatementRef,
    s6: StatementRef,
    s7: StatementRef,
    s8: StatementRef,
    s9: StatementRef,
    s10: StatementRef,
    s11: StatementRef,
};
pub fn addRiscvAbiPrologue(function: *Function, block: BlockId) !SavedRegisters {
    return SavedRegisters{
        .ra = try addReadRegister(function, block, regs.ra),
        .sp = try addReadRegister(function, block, regs.sp),
        .gp = try addReadRegister(function, block, regs.gp),
        .tp = try addReadRegister(function, block, regs.tp),
        .fp = try addReadRegister(function, block, regs.fp),
        .s1 = try addReadRegister(function, block, regs.s1),
        .s2 = try addReadRegister(function, block, regs.s2),
        .s3 = try addReadRegister(function, block, regs.s3),
        .s4 = try addReadRegister(function, block, regs.s4),
        .s5 = try addReadRegister(function, block, regs.s5),
        .s6 = try addReadRegister(function, block, regs.s6),
        .s7 = try addReadRegister(function, block, regs.s7),
        .s8 = try addReadRegister(function, block, regs.s8),
        .s9 = try addReadRegister(function, block, regs.s9),
        .s10 = try addReadRegister(function, block, regs.s10),
        .s11 = try addReadRegister(function, block, regs.s11),
    };
}

pub fn addRiscvAbiEpilogue(function: *Function, block: BlockId, saved_registers: SavedRegisters) !void {
    try function.writeRegister(block, regs.ra, saved_registers.ra);
    try function.writeRegister(block, regs.sp, saved_registers.sp);
    try function.writeRegister(block, regs.gp, saved_registers.gp);
    try function.writeRegister(block, regs.tp, saved_registers.tp);
    try function.writeRegister(block, regs.fp, saved_registers.fp);
    try function.writeRegister(block, regs.s1, saved_registers.s1);
    try function.writeRegister(block, regs.s2, saved_registers.s2);
    try function.writeRegister(block, regs.s3, saved_registers.s3);
    try function.writeRegister(block, regs.s4, saved_registers.s4);
    try function.writeRegister(block, regs.s5, saved_registers.s5);
    try function.writeRegister(block, regs.s6, saved_registers.s6);
    try function.writeRegister(block, regs.s7, saved_registers.s7);
    try function.writeRegister(block, regs.s8, saved_registers.s8);
    try function.writeRegister(block, regs.s9, saved_registers.s9);
    try function.writeRegister(block, regs.s10, saved_registers.s10);
    try function.writeRegister(block, regs.s11, saved_registers.s11);
}

test "one block" {
    var function = Function.init(test_allocator);
    defer function.deinit();
    const block = try function.addBlock();
    const x = try addReadRegister(&function, block, regs.a0);
    const x_squared = try function.addStatement(block, result, .{x});
    _ = try function.writeRegister(block, regs.a0, x_squared);
    std.debug.print("{}", .{function});
    try verifyFunction(&function);
}

test "one block after constraint" {
    var function = Function.init(test_allocator);
    defer function.deinit();
    const block = try function.addBlock();
    const a0 = try addReadRegister(&function, block, regs.a0);
    const a1 = try addReadRegister(&function, block, regs.a1);
    const result_0 = try function.addStatement(block, result, .{ a0, a1 });
    try function.writeRegister(block, regs.a0, result_0);
    const result_1 = try function.addStatement(block, result, .{a0});
    try function.writeRegister(block, regs.a1, result_1);
    try verifyFunction(&function);
}

test "input register twice" {
    var function = Function.init(test_allocator);
    defer function.deinit();
    const block = try function.addBlock();
    const x = try function.addStatement(block, read_register, .{});
    _ = try function.addStatement(block, result, .{ x, x });
    try expectError(VerificationError.InvalidInputRegister, function.verify());
}

test "invalid register allocation" {
    var function = Function.init(test_allocator);
    defer function.deinit();
    const block = try function.addBlock();
    const x = try addReadRegister(&function, block, regs.a0);
    try function.writeRegister(block, regs.a0, x);
    try expectError(VerificationError.MissingAllocation, function.verifyRegisterAllocation());
}

test "if" {
    var function = Function.init(test_allocator);
    defer function.deinit();

    const entry = try function.addBlock();
    // const exit = try function.addBlock();
    const then_block = try function.addBlock();
    const else_block = try function.addBlock();
    try function.addBlockSuccessor(entry, then_block);
    // try function.addBlockSuccessor(then_block, exit);
    try function.addBlockSuccessor(entry, else_block);
    // try function.addBlockSuccessor(else_block, exit);

    const a0 = try addReadRegister(&function, entry, regs.a0);
    _ = try function.addStatement(then_block, no_result, .{a0});
    try verifyFunction(&function);
}

test "if two different used results" {
    var function = Function.init(test_allocator);
    defer function.deinit();

    const entry = try function.addBlock();
    const then_block = try function.addBlock();
    const else_block = try function.addBlock();
    try function.addBlockSuccessor(entry, then_block);
    try function.addBlockSuccessor(entry, else_block);

    const a0 = try addReadRegister(&function, entry, regs.a0);
    const a1 = try addReadRegister(&function, entry, regs.a1);

    _ = try function.addStatement(then_block, no_result, .{a0});
    _ = try function.addStatement(else_block, no_result, .{a1});
    try verifyFunction(&function);
}

test "decision tree" {
    var function = Function.init(test_allocator);
    defer function.deinit();

    const entry = try function.addBlock();
    const left = try function.addBlock();
    const right = try function.addBlock();
    const left_left = try function.addBlock();
    const left_right = try function.addBlock();
    const left_exit = try function.addBlock();
    const exit = try function.addBlock();
    try function.addBlockSuccessor(entry, left);
    try function.addBlockSuccessor(entry, right);
    try function.addBlockSuccessor(left, left_left);
    try function.addBlockSuccessor(left, left_right);
    try function.addBlockSuccessor(left_left, left_exit);
    try function.addBlockSuccessor(left_right, left_exit);
    try function.addBlockSuccessor(left_exit, exit);
    try function.addBlockSuccessor(right, exit);

    const a0 = try addReadRegister(&function, entry, regs.a0);
    const a1 = try addReadRegister(&function, entry, regs.a1);
    const a2 = try addReadRegister(&function, entry, regs.a2);
    const a3 = try addReadRegister(&function, entry, regs.a3);
    const a4 = try addReadRegister(&function, entry, regs.a4);
    const a5 = try addReadRegister(&function, entry, regs.a5);
    const a6 = try addReadRegister(&function, entry, regs.a6);
    const a7 = try addReadRegister(&function, entry, regs.a7);

    const left_result_1 = try function.addStatement(left, result, .{a0});
    const left_result_2 = try function.addStatement(left, result, .{a0});

    _ = try function.addStatement(left_left, no_result, .{ left_result_1, a1 });
    _ = try function.addStatement(left_right, no_result, .{ left_result_2, a2 });
    _ = try function.addStatement(right, no_result, .{a3});
    _ = try function.addStatement(exit, no_result, .{ a6, a7 });
    _ = try function.addStatement(left_exit, no_result, .{ a4, a5 });

    try verifyFunction(&function);
}

test "if with phi" {
    var function = Function.init(test_allocator);
    defer function.deinit();

    const entry = try function.addBlock();
    const exit = try function.addBlock();
    const left = try function.addBlock();
    const right = try function.addBlock();
    try function.addBlockSuccessor(entry, left);
    try function.addBlockSuccessor(entry, right);
    try function.addBlockSuccessor(left, exit);
    try function.addBlockSuccessor(right, exit);

    const a0 = try addReadRegister(&function, entry, regs.a0);
    const a1 = try addReadRegister(&function, entry, regs.a1);
    const result_phi = try function.addStatement(exit, phi, .{});
    _ = try function.addStatement(left, phiAt(result_phi), .{a0});
    _ = try function.addStatement(right, phiAt(result_phi), .{a1});
    try function.writeRegister(exit, regs.a0, result_phi);

    try verifyFunction(&function);
}

test "missing phi" {
    var function = Function.init(test_allocator);
    defer function.deinit();

    const entry = try function.addBlock();
    const exit = try function.addBlock();
    const left = try function.addBlock();
    const right = try function.addBlock();
    try function.addBlockSuccessor(entry, left);
    try function.addBlockSuccessor(entry, right);
    try function.addBlockSuccessor(left, exit);
    try function.addBlockSuccessor(right, exit);

    const a0 = try addReadRegister(&function, entry, regs.a0);
    const result_phi = try function.addStatement(exit, phi, .{});
    _ = try function.addStatement(left, phiAt(result_phi), .{a0});
    try function.writeRegister(exit, regs.a0, result_phi);

    try function.verify();
    try function.allocateRegisters();
    try expectError(VerificationError.InvalidRegisterFile, function.verifyRegisterAllocation());
}

test "function call" {
    var function = Function.init(test_allocator);
    defer function.deinit();

    const entry = try function.addBlock();
    const function_call = try function.addBlock();
    const after_function_call = try function.addBlock();
    const exit = try function.addBlock();
    try function.addBlockSuccessor(entry, function_call);
    try function.addBlockSuccessor(function_call, after_function_call);
    try function.addBlockSuccessor(after_function_call, exit);

    const saved_regs = try addRiscvAbiPrologue(&function, entry);
    try invalidateAfterFunctionCall(&function, after_function_call);
    const a0 = try addReadRegister(&function, entry, regs.a0);
    const a1 = try addReadRegister(&function, entry, regs.a1);
    const res = try addReadRegister(&function, after_function_call, regs.a0);
    const arg0 = try function.addStatement(function_call, result, .{a1});
    const arg1 = try function.addStatement(function_call, result, .{a0});

    try function.writeRegister(function_call, regs.a0, arg0);
    try function.writeRegister(function_call, regs.a1, arg1);
    try function.writeRegister(exit, regs.a0, res);
    try addRiscvAbiEpilogue(&function, exit, saved_regs);

    try verifyFunction(&function);
}

fn verifyFunction(function: *Function) !void {
    try function.verify();
    try function.allocateRegisters();
    std.debug.print("{}", .{function});
    try function.verifyRegisterAllocation();
}
