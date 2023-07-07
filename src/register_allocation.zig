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

    register_file: RegisterFile,

    fn init(allocator: Allocator, id: usize) Self {
        return Self{
            .id = id,
            .statements = ArrayList(Statement).init(allocator),
            .successor_blocks = BoundedArray(BlockId, 2).init(0) catch unreachable,
            .register_file = RegisterFile.init(allocator),
        };
    }
    fn deinit(self: Self) void {
        self.statements.deinit();
        self.register_file.deinit();
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

    allocation: ?Register = null,

    pub fn format(
        self: Self,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("{}: ", .{self.id});
        if (self.fixed_register) |fixed_reg| {
            if (self.input_values.len == 0) {
                try writer.print("x{}", .{fixed_reg});
                return;
            }
        }
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

const Register = struct {
    const Self = @This();

    register: usize,

    fn fromReg(reg: Reg) ?Register {
        return Self{
            .register = switch (reg) {
                5...7 => reg - 5,
                28...29 => reg - 25,
                10...17 => reg - 5,
                9 => 13,
                18...27 => reg - 4,
                else => return null,
            },
        };
    }
    fn toReg(self: Self) ?Reg {
        return switch (self.register) {
            0...2 => @intCast(u5, self.register) + 5,
            3...4 => @intCast(u5, self.register) + 25,
            5...12 => @intCast(u5, self.register) + 5,
            13 => 9,
            14...23 => @intCast(u5, self.register) + 4,
            else => return null,
        };
    }

    pub fn format(
        self: Self,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        var int_options = options;
        if (int_options.width) |width| {
            int_options.width = width - 1;
        }
        if (self.toReg()) |reg| {
            try writer.writeAll("x");
            try std.fmt.formatInt(reg, 10, .lower, int_options, writer);
        } else {
            try writer.writeAll("r");
            try std.fmt.formatInt(self.register, 10, .lower, int_options, writer);
        }
    }
};
const RegisterFile = struct {
    const Self = @This();

    register_file: ArrayList(?StatementRef),

    fn init(allocator: Allocator) Self {
        return Self{
            .register_file = ArrayList(?StatementRef).init(allocator),
        };
    }
    fn deinit(self: Self) void {
        self.register_file.deinit();
    }
    fn clone(self: Self) !Self {
        var register_file = ArrayList(?StatementRef).init(self.register_file.allocator);
        try register_file.appendSlice(self.register_file.items);
        return Self{
            .register_file = register_file,
        };
    }

    // fn put(register_file1: *Self, register_file2: *Self, statement: StatementRef) !Register {
    //     var register = Register{ .register = 0 };
    //     while (register_file1.get(register) != null or register_file2.get(register) != null) {
    //         register.register += 1;
    //     }
    //     try register_file1.set(register, statement);
    //     try register_file2.set(register, statement);
    //     return register;
    // }

    fn set(self: *Self, register: Register, statement: ?StatementRef) !void {
        std.debug.print("set {} to {}\n", .{register ,statement});
        if (register.register < self.register_file.items.len) {
            self.register_file.items[register.register] = statement;
        } else {
            try self.register_file.ensureTotalCapacity(register.register + 1);
            self.register_file.appendNTimesAssumeCapacity(null, register.register - self.register_file.items.len);
            self.register_file.appendAssumeCapacity(statement);
            assert(self.register_file.items.len == register.register + 1);
        }
        std.debug.print("{}", .{self});
    }
    fn get(self: Self, register: Register) ?StatementRef {
        if (register.register < self.register_file.items.len) {
            return self.register_file.items[register.register];
        } else {
            return null;
        }
    }
    fn delete(self: *Self, register: Register) void {
        if (register.register < self.register_file.items.len) {
            self.register_file.items[register.register] = null;
        }
    }
    fn merge(self: *Self, other: Self) AllocationError!void {
        if (self.register_file.items.len < other.register_file.items.len) {
            return AllocationError.InvalidMerge;
        }
        for (self.register_file.items) |*spill, i| {
            const other_spill = other.register_file.items[i];
            if (!meta.eql(spill.*, other_spill)) {
                if (spill.* == null) {
                    spill.* = other_spill;
                } else return AllocationError.InvalidMerge;
            }
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
        for (self.register_file.items) |statement_ref, index| {
            const register = Register{.register = index};
            try writer.print("{: <4} | {}\n", .{ register, statement_ref });
        }
    }
};
const ReadAllocation = struct {
    const Self = @This();

    statement: StatementRef,
    allocation: ?Register = null,
    restore: ?Register = null,

    fn from(allocation: anytype) Self {
        const allocation_type = @TypeOf(allocation);
        if (allocation_type == Self) {
            return allocation;
        } else if (allocation_type == StatementRef) {
            return Self{
                .statement = allocation,
            };
        } else {
            @compileError("expected either " ++
                @typeName(Self) ++
                " or " ++
                @typeName(StatementRef) ++
                ", found " ++
                @typeName(allocation_type));
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
        try writer.print("{}", .{self.statement});
        if (self.allocation) |allocation| {
            try writer.print("@{}", .{allocation});
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

    pub fn readRegister(self: *Self, block_id: BlockId, reg: Reg) !StatementRef {
        const read_statement_ref = try self.addStatement(block_id, result, .{});
        const read_statement = self.getStatement(read_statement_ref);
        // read_statement.allocation = Register.fromReg(reg);
        read_statement.fixed_register = reg;
        return read_statement_ref;
    }

    pub fn writeRegister(self: *Self, block_id: BlockId, reg: Reg, statement: StatementRef) !void {
        const register = Register.fromReg(reg);
        const read_allocation = ReadAllocation{ .statement = statement };
        const input_values = boundedArrayFromInputValues(.{read_allocation});
        const write_statement_ref = try self.addStatementInternal(
            block_id,
            .{ .id = undefined, .meta = result, .input_values = input_values },
        );
        const write_statement = self.getStatement(write_statement_ref);
        write_statement.allocation = register;
        write_statement.fixed_register = reg;
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
        for (self.cfg.?.post_order.items) |block_id| {
            try self.allocateRegistersForBlock(block_id);
        }
    }

    fn allocateRegistersForBlock(self: *Self, block_id: BlockId) (AllocationError || error{OutOfMemory})!void {
        std.debug.print("Block: {}\n", .{block_id});
        const block = self.getBlock(block_id);
        for (block.successor_blocks.constSlice()) |successor_id| {
            const successor = self.getBlockConst(successor_id);
            try block.register_file.merge(successor.register_file);
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
                block.register_file.delete(allocation);
                statement.allocation = allocation;
            }
            for (statement.input_values.slice()) |*read_allocation| {
                std.debug.print("before findReadRegister:\n{}", .{block.register_file});
                try self.findReadRegister(block, read_allocation);
                std.debug.print("after findReadRegister:\n{}", .{block.register_file});
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
        std.debug.print("{}\n", .{block.register_file});
        const statement_ref = read_allocation.statement;
        const statement: *Statement = self.getStatement(statement_ref);
        if (self.findExistingAllocation(block, read_allocation)) {
            return;
        }
        if (statement.fixed_register != null) {
            try self.findFixedRegister(block, read_allocation);
            return;
        }
        const register = try self.findFreeRegister(block, statement_ref);
        read_allocation.allocation = register;
        statement.allocation = register;
    }
    fn findExistingAllocation(self: *const Self, block: *const Block, read_allocation: *ReadAllocation) bool {
        const statement_ref = read_allocation.statement;
        const statement = self.getStatementConst(statement_ref);
        assert(statement.meta.has_result);
        if (statement.allocation) |allocation| {
            const register_value = block.register_file.get(allocation);
            read_allocation.allocation = allocation;
            std.debug.print("{} != {}\n", .{ register_value, statement_ref });
            assert(meta.eql(register_value, statement_ref));
            return true;
        } else {
            return false;
        }
    }
    fn findFreeRegister(self: *Self, block: *Block, statement: StatementRef) !Register {
        var register = Register{ .register = 0 };
        outer: while (true) : (register.register += 1) {
            var dominator_iter = self.cfg.?.dominatorIter(block.id);
            while (dominator_iter.next()) |dominator_id| {
                const dominator = self.getBlockConst(dominator_id);
                if (dominator.register_file.get(register) != null) {
                    continue :outer;
                }
                if (dominator_id == statement.block_id) {
                    break :outer;
                }
            } else {
                return AllocationError.InvalidValue;
            }
        }
        var dominator_iter = self.cfg.?.dominatorIter(block.id);
        while (dominator_iter.next()) |dominator_id| {
            const dominator = self.getBlock(dominator_id);
            try dominator.register_file.set(register, statement);
            if (dominator_id == statement.block_id) {
                break;
            }
        }
        return register;
    }
    fn findFixedRegister(self: *Self, block: *Block, read_allocation: *ReadAllocation) !void {
        const statement_ref = read_allocation.statement;
        const statement = self.getStatement(statement_ref);
        const fixed_reg = statement.fixed_register.?;
        const register = Register.fromReg(fixed_reg).?;
        if (block.register_file.get(register)) |statement_to_move| {
            const new_register = try self.findFreeRegister(block, statement_to_move);
            read_allocation.restore = new_register;
            self.getStatement(statement_to_move).allocation = new_register;
        }
        std.debug.print("set register: {}\n", register);
        try block.register_file.set(register, statement_ref);
        read_allocation.allocation = register;
        statement.allocation = register;
        std.debug.print("{}\n", .{block.register_file});
    }

    // fn mergeRegisterFileAndSpill(self: *Self, block: *Block, other_block_id: BlockId) AllocationError!void {
    //     const other_block = self.getBlock(other_block_id);
    //     const other_register_file = &other_block.register_file;
    //     for (block.register_file) |*register, i| {
    //         const other_register = other_register_file[i];
    //         if (!meta.eql(register.*, other_register)) {
    //             if (register.* != null and other_register != null) {
    //                 return AllocationError.InvalidMerge;
    //             }
    //             if (register.* == null) {
    //                 register.* = other_register;
    //             }
    //         }
    //     }
    //     const other_spill = other_block.spill;
    //     try block.spill.merge(other_spill);
    // }

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
            .register_file = RegisterFile.init(self.allocator),
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

    register_file: RegisterFile,
    function: *const Function,
    block_id: BlockId,

    fn verify(
        self: *Self,
        verification_stack: *ArrayList(Self),
        visited_edges: []bool,
    ) (VerificationError || error{OutOfMemory})!void {
        defer self.register_file.deinit();
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
                if (read_allocation.allocation == null) {
                    return VerificationError.MissingAllocation;
                }
            }
            // instruction
            for (read_allocs) |read_allocation| {
                const allocation = read_allocation.allocation.?;
                if (!meta.eql(self.register_file.get(allocation), read_allocation.statement)) {
                    return VerificationError.InvalidRegisterFile;
                }
            }
            if (statement.meta.has_result) {
                if (statement.meta.is_phi) {
                    const phi_at_statement = if (self.register_file.get(statement.allocation.?)) |phi_at_statement_ref|
                        self.function.getStatementConst(phi_at_statement_ref)
                    else
                        return VerificationError.MissingPhiAt;
                    if (phi_at_statement.meta.phi_at) |phi_at| {
                        if (!meta.eql(phi_at, statement_ref)) {
                            return VerificationError.InvalidRegisterFile;
                        }
                    } else {
                        return VerificationError.InvalidRegisterFile;
                    }
                }
                if (statement.fixed_register != null and !meta.eql(statement.fixed_register, Register.toReg(statement.allocation.?))) {
                    std.debug.print("{} != {}\n", .{ statement.fixed_register, Register.toReg(statement.allocation.?) });
                    return VerificationError.InvalidRegisterFile;
                }
                try self.register_file.set(statement.allocation.?, statement_ref);
            }
            for (read_allocs) |read_allocation| {
                if (read_allocation.restore) |restore| {
                    if (self.register_file.get(restore)) |restore_statement| {
                        try self.register_file.set(read_allocation.allocation.?, restore_statement);
                    } else {
                        return VerificationError.InvalidRestore;
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
                try verification_stack.append(.{
                    .register_file = try self.register_file.clone(),
                    .function = self.function,
                    .block_id = successor_id,
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
    InvalidRestore,
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

fn invalidateRegister(function: *Function, block: BlockId, reg: Reg) !void {
    _ = try function.readRegister(block, reg);
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
        .ra = try function.readRegister(block, regs.ra),
        .sp = try function.readRegister(block, regs.sp),
        .gp = try function.readRegister(block, regs.gp),
        .tp = try function.readRegister(block, regs.tp),
        .fp = try function.readRegister(block, regs.fp),
        .s1 = try function.readRegister(block, regs.s1),
        .s2 = try function.readRegister(block, regs.s2),
        .s3 = try function.readRegister(block, regs.s3),
        .s4 = try function.readRegister(block, regs.s4),
        .s5 = try function.readRegister(block, regs.s5),
        .s6 = try function.readRegister(block, regs.s6),
        .s7 = try function.readRegister(block, regs.s7),
        .s8 = try function.readRegister(block, regs.s8),
        .s9 = try function.readRegister(block, regs.s9),
        .s10 = try function.readRegister(block, regs.s10),
        .s11 = try function.readRegister(block, regs.s11),
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
    const x = try function.readRegister(block, regs.a0);
    const x_squared = try function.addStatement(block, result, .{x});
    _ = try function.writeRegister(block, regs.a0, x_squared);
    std.debug.print("{}", .{function});
    try verifyFunction(&function);
}

test "one block after constraint" {
    var function = Function.init(test_allocator);
    defer function.deinit();
    const block = try function.addBlock();
    const a0 = try function.readRegister(block, regs.a0);
    const a1 = try function.readRegister(block, regs.a1);
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
    const x = try function.readRegister(block, regs.a0);
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

    const a0 = try function.readRegister(entry, regs.a0);
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

    const a0 = try function.readRegister(entry, regs.a0);
    const a1 = try function.readRegister(entry, regs.a1);

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

    const a0 = try function.readRegister(entry, regs.a0);
    const a1 = try function.readRegister(entry, regs.a1);
    const a2 = try function.readRegister(entry, regs.a2);
    const a3 = try function.readRegister(entry, regs.a3);
    const a4 = try function.readRegister(entry, regs.a4);
    const a5 = try function.readRegister(entry, regs.a5);
    const a6 = try function.readRegister(entry, regs.a6);
    const a7 = try function.readRegister(entry, regs.a7);

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

    const a0 = try function.readRegister(entry, regs.a0);
    const a1 = try function.readRegister(entry, regs.a1);
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

    const a0 = try function.readRegister(entry, regs.a0);
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
    const a0 = try function.readRegister(entry, regs.a0);
    const a1 = try function.readRegister(entry, regs.a1);
    const res = try function.readRegister(after_function_call, regs.a0);
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
