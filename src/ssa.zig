const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const BoundedArray = std.BoundedArray;
const FormatOptions = std.fmt.FormatOptions;
const Tuple = std.meta.Tuple;
const Formatter = std.fmt.Formatter;
const eql = std.meta.eql;
const assert = std.debug.assert;
const maxInt = std.math.maxInt;
const minInt = std.math.minInt;

const types = @import("types.zig");
const Reg = types.Reg;
const regs = types.regs;
const getArgumentRegister = types.getArgumentRegister;

const appendAndGetIndex = @import("util.zig").appendAndGetIndex;
const getId = @import("util.zig").getId;
const dupeOption = @import("util.zig").dupeOption;

const Assembler = @import("asm.zig").Assembler;
const Cfg = @import("dominator_tree.zig").Cfg;

// ██████╗  ██╗       ██████╗   ██████╗ ██╗  ██╗
// ██╔══██╗ ██║      ██╔═══██╗ ██╔════╝ ██║ ██╔╝
// ██████╔╝ ██║      ██║   ██║ ██║      █████╔╝
// ██╔══██╗ ██║      ██║   ██║ ██║      ██╔═██╗
// ██████╔╝ ███████╗ ╚██████╔╝ ╚██████╗ ██║  ██╗
// ╚═════╝  ╚══════╝  ╚═════╝   ╚═════╝ ╚═╝  ╚═╝

pub const Value = union(enum) {
    const Self = @This();
    Constant: u64,
    Result: Result,
    pub fn format(self: Self, comptime fmt: []const u8, options: FormatOptions, writer: anytype) !void {
        return formatValue(.{ .block = null, .value = self }, fmt, options, writer);
    }
    pub fn getConstant(self: Self) ?u64 {
        return switch (self) {
            .Constant => |constant| constant,
            else => null,
        };
    }
    pub fn getResult(self: Self) ?Result {
        return switch (self) {
            .Result => |result| result,
            else => null,
        };
    }
};

pub const Result = struct {
    block: *const Block,
    index: StatementIndex,
};

pub fn constant(value: u64) Value {
    return .{ .Constant = value };
}

pub fn signedConstant(value: i64) Value {
    return .{ .Constant = @bitCast(u64, value) };
}

pub const Block = struct {
    const Self = @This();

    // general purpose allocator
    gpa: Allocator,
    arena: Allocator,

    function_id: usize,
    id: usize,
    statement_list: ArrayList(Statement),
    exit: ?Exit = null,

    fn init(gpa: Allocator, arena: Allocator, function_id: usize, id: usize) Self {
        var block = Self{
            .statement_list = ArrayList(Statement).init(gpa),
            .arena = arena,
            .gpa = gpa,
            .function_id = function_id,
            .id = id,
        };
        return block;
    }
    pub fn deinit(self: Self) void {
        for (self.statement_list.items) |statement| {
            statement.deinit();
        }
        self.statement_list.deinit();
    }
    fn appendReadRegister(self: *Self, reg: Reg) !Value {
        if (reg == 0) {
            return Value{ .Constant = 0 };
        }
        var buffer: [3]u8 = undefined;
        const name = std.fmt.bufPrint(buffer[0..], "x{}", .{reg}) catch unreachable;
        const statement_index = try self.appendStatement(.{ .ReadRegister = reg }, name);
        return Value{ .Result = .{
            .block = self,
            .index = statement_index,
        } };
    }
    fn appendWriteRegister(self: *Self, reg: Reg, value: Value) !void {
        if (reg == 0) {
            return;
        }
        _ = try self.appendStatement(.{
            .WriteRegister = .{
                .reg = reg,
                .value_info = .{ .value = value, .immediate = .Unlimited },
            },
        }, null);
    }
    pub fn appendAdd(self: *Self, arg_a: Value, arg_b: Value, name: ?[]const u8) !Value {
        try self.checkValue(arg_a);
        try self.checkValue(arg_b);
        var a = arg_a;
        var b = arg_b;
        if (a.getConstant()) |a_const| {
            if (b.getConstant()) |b_const| {
                // Allow subtraction
                return Value{ .Constant = a_const +% b_const };
            }
        }
        if (a.getConstant() != null) {
            const tmp = a;
            a = b;
            b = tmp;
        }
        const statement_index = try self.appendStatement(.{
            .Add = .{
                .a = .{ .value = a, .immediate = .None },
                .b = .{ .value = b, .immediate = imm12 },
            },
        }, name);
        return Value{ .Result = .{
            .block = self,
            .index = statement_index,
        } };
    }
    fn appendStatement(self: *Self, statement: StatementType, name: ?[]const u8) !StatementIndex {
        const duped_name: ?[]const u8 = try dupeOption(self.arena, u8, name);
        return appendAndGetIndex(
            Statement.init(statement, duped_name),
            &self.statement_list,
        );
    }
    pub fn jump(self: *Self, target: *Self) void {
        self.exit = .{ .Jump = target };
    }
    pub fn allocateRegisters(self: *Self, registers: *RegisterFile, spill: *Spill) (RegisterAllocationError || error{OutOfMemory})!void {
        var i: usize = self.statement_list.items.len;
        while (i > 0) {
            i -= 1;
            const statement = &self.statement_list.items[i];
            if (statement.statement.isValue()) {
                if (statement.register_allocation == null) {
                    std.debug.print("{}\n", .{i});
                }
                switch (statement.register_allocation.?) {
                    .Register => |reg| registers[reg] = null,
                    .Spill => |spill_pos| spill.delete(spill_pos),
                }
            }
            switch (statement.statement) {
                .WriteRegister => |*write| {
                    try self.findAndSetRegister(registers, spill, &write.value_info, write.reg);
                },
                else => {
                    const input_values = statement.statement.inputValues();
                    for (input_values.constSlice()) |value_info| {
                        if (value_info.needsRegister()) {
                            try self.findAndSetRegister(registers, spill, value_info, null);
                        }
                    }
                },
            }
        }
    }
    fn findAndSetRegister(self: *Self, registers: *RegisterFile, spill: *Spill, value_info: *ValueInfo, prefered_reg: ?Reg) !void {
        const statement: ?*Statement = switch (value_info.value) {
            .Result => |result| blk: {
                const statement = &result.block.statement_list.items[result.index];
                assert(statement.statement.isValue());
                if (statement.register_allocation) |register_allocation| {
                    if (register_allocation.getRegister()) |reg| {
                        if (registers[reg]) |register_value| {
                            value_info.register = reg;
                            assert(eql(register_value.Result, result));
                        } else {
                            registers[reg] = value_info.value;
                        }
                    }
                    return;
                } else {
                    break :blk statement;
                }
            },
            .Constant => null,
        };
        const reg = findRegister: {
            if (prefered_reg) |reg| {
                if (registers[reg] == null) {
                    break :findRegister reg;
                }
            }
            if (statement) |stmt| {
                if (stmt.statement.getPreferedRegister()) |reg| {
                    if (registers[reg] == null) {
                        break :findRegister reg;
                    }
                }
            }
            var j: Reg = 31;
            while (j > 0) : (j -= 1) {
                if (registers[j] == null) {
                    break :findRegister j;
                }
            }
            if (value_info.needsRegister()) {
                var reg: Reg = 31;
                var best_reg: Reg = 31;
                var best_index: StatementIndex = maxInt(StatementIndex);
                while (reg > 0) : (reg -= 1) {
                    if (reg == regs.fp) {
                        continue;
                    }
                    const index = registers[reg].?.Result.index;
                    if (index < best_index) { // TODO: make compatible with constants
                        best_reg = reg;
                        best_index = index;
                    }
                }
                const spill_pos = try spill.put(registers[best_reg].?);
                self.statement_list.items[best_index].register_allocation = .{ .Spill = spill_pos };
                value_info.after = .{ .LoadFromSpill = spill_pos };
                break :findRegister best_reg;
            } else {
                break :findRegister null;
            }
        };
        if (reg) |r| {
            value_info.register = r;
            switch (value_info.value) {
                .Result => {
                    registers[r] = value_info.value;
                },
                .Constant => |c| {
                    value_info.before = .{ .LoadImmediate = c };
                },
            }
            if (statement) |stmt| {
                stmt.register_allocation = .{ .Register = r };
            }
        } else {
            if (statement) |stmt| {
                stmt.register_allocation = .{ .Spill = try spill.put(value_info.value) };
            }
        }
    }
    fn spillRegister(self: *Self, registers: *RegisterFile, value_info: *ValueInfo) void {
        _ = self;
        _ = registers;
        _ = value_info;
    }
    fn verifyRegisterAllocation(self: *const Self) (VerificationError || error{OutOfMemory})!void {
        var registers = [1]?Value{null} ** 32;
        var spill = ArrayList(?Value).init(self.gpa);
        defer spill.deinit();
        for (self.statement_list.items) |statement, index| {
            if (statement.statement.isValue() and statement.register_allocation == null) {
                return VerificationError.MissingAllocation;
            }
            if (!statement.statement.isValue() and statement.register_allocation != null) {
                return VerificationError.AllocationForNonValue;
            }
            // before
            const inputValues = statement.statement.constInputValues();
            for (inputValues.constSlice()) |value_info| {
                if (value_info.needsRegister()) {
                    if (value_info.register == null) {
                        return VerificationError.MissingAllocation;
                    }
                    const reg = value_info.register.?;
                    if (value_info.before) |before| {
                        switch (before) {
                            .LoadImmediate => |immediate| registers[reg] = constant(immediate),
                            .LoadFromSpill => |spill_pos| registers[reg] = spill.items[spill_pos],
                            .StoreToSpill => return VerificationError.InvalidMemoryAction,
                        }
                    }
                } else {
                    if (value_info.before != null) {
                        return VerificationError.InvalidMemoryAction;
                    }
                }
            }
            // instruction
            // inputValues = statement.statement.constInputValues();
            for (inputValues.constSlice()) |value_info| {
                if (value_info.needsRegister()) {
                    const reg = value_info.register.?;
                    if (reg == 0) {
                        return VerificationError.InvalidRegister;
                    }
                    if (!eql(registers[reg], value_info.value)) {
                        return VerificationError.RegisterHoldsDifferentValue;
                    }
                }
            }
            if (statement.register_allocation) |register_allocation| {
                const value = Value{ .Result = .{
                    .block = self,
                    .index = index,
                } };
                switch (register_allocation) {
                    .Register => |reg| registers[reg] = value,
                    .Spill => |spill_pos| {
                        if (statement.statement.needsRegister()) {
                            return VerificationError.MissingAllocation;
                        }
                        try setList(spill_pos, @as(?Value, value), &spill);
                    },
                }
            }
            // after
            // inputValues = statement.statement.constInputValues();
            for (inputValues.constSlice()) |value_info| {
                if (value_info.needsRegister()) {
                    const reg = value_info.register.?;
                    if (value_info.after) |after| {
                        switch (after) {
                            .LoadImmediate => return VerificationError.InvalidMemoryAction,
                            .LoadFromSpill => |spill_pos| registers[reg] = spill.items[spill_pos],
                            .StoreToSpill => unreachable, // TODO: stack
                        }
                    }
                } else {
                    if (value_info.after != null) {
                        return VerificationError.InvalidMemoryAction;
                    }
                }
            }
        }
    }
    pub fn materialize(self: *const Self, spill_size: u64, assembler: *Assembler) !void {
        const stack_frame_size: u64 =
            if (spill_size == 0) @as(u64, 0) else @as(u64, 8);
        if (stack_frame_size != 0) {
            try assembler.instrSd(regs.fp, regs.sp, -8);
            try assembler.instrMv(regs.fp, regs.sp);
        }
        for (self.statement_list.items) |statement| {
            const inputValues = statement.statement.constInputValues();
            for (inputValues.constSlice()) |value_info| {
                if (value_info.before) |before| {
                    const reg_dest = value_info.register.?;
                    switch (before) {
                        .LoadImmediate => |immediate| try assembler.instrLi(reg_dest, immediate),
                        .LoadFromSpill => unreachable, // TODO
                        .StoreToSpill => unreachable,
                    }
                }
            }
            switch (statement.statement) {
                .ReadRegister => |reg| {
                    switch (statement.register_allocation.?) {
                        .Register => |alloc_reg| {
                            if (reg != alloc_reg) {
                                try assembler.instrMv(alloc_reg, reg);
                            }
                        },
                        .Spill => |spill_pos| {
                            try assembler.instrSd(reg, regs.fp, -8 * @intCast(i12, spill_pos) - @intCast(i12, stack_frame_size) - 8);
                        },
                    }
                },
                .WriteRegister => |write| {
                    if (write.value_info.needsRegister()) {
                        const alloc_reg = write.value_info.register.?;
                        if (write.reg != alloc_reg) {
                            try assembler.instrMv(write.reg, alloc_reg);
                        }
                    } else {
                        try assembler.instrLi(write.reg, write.value_info.value.Constant);
                    }
                },
                .Add => |add| {
                    const reg_dest = statement.register_allocation.?.getRegister().?;
                    if (add.b.needsRegister()) {
                        try assembler.instrAdd(reg_dest, add.a.register.?, add.b.register.?);
                    } else {
                        const immediate = @intCast(i12, @bitCast(i64, add.b.value.Constant));
                        try assembler.instrAddi(reg_dest, add.a.register.?, immediate);
                    }
                },
            }
            // inputValues = statement.statement.constInputValues();
            for (inputValues.constSlice()) |value_info| {
                if (value_info.after) |after| {
                    const reg_dest = value_info.register.?;
                    switch (after) {
                        .LoadImmediate => unreachable,
                        .LoadFromSpill => |spill_pos| try assembler.instrLd(reg_dest, regs.fp, -8 * @intCast(i12, spill_pos) - @intCast(i12, stack_frame_size) - 8),
                        .StoreToSpill => |spill_pos| try assembler.instrSd(reg_dest, regs.fp, -8 * @intCast(i12, spill_pos) - @intCast(i12, stack_frame_size) - 8),
                    }
                }
            }
        }
        if (stack_frame_size != 0) {
            try assembler.instrLd(regs.fp, regs.fp, -8);
        }
    }
    pub fn format(self: Self, comptime fmt: []const u8, options: FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        for (self.statement_list.items) |statement, index| {
            try writer.print("{}\n", .{self.fmtStatement(statement, index)});
        }
    }
    fn fmtStatement(self: *const Self, statement: Statement, index: usize) Formatter(formatStatement) {
        return .{ .data = .{ .block = self, .statement = statement, .index = index } };
    }
    fn fmtValue(self: *const Self, value: Value) Formatter(formatValue) {
        return .{ .data = .{ .block = self, .value = value } };
    }
    fn fmtValueInfo(self: *const Self, value_info: ValueInfo) Formatter(formatValueInfo) {
        return .{ .data = .{ .block = self, .value_info = value_info } };
    }
    fn checkValue(self: *const Self, value: Value) ValueError!void {
        if (value.getResult()) |result| {
            if (self.function_id != result.block.function_id) {
                return ValueError.InvalidValue;
            }
        }
    }
};

const SavedRegisters = struct {
    ra: Value,
    sp: Value,
    gp: Value,
    tp: Value,
    fp: Value,
    s1: Value,
    s2: Value,
    s3: Value,
    s4: Value,
    s5: Value,
    s6: Value,
    s7: Value,
    s8: Value,
    s9: Value,
    s10: Value,
    s11: Value,
};

pub fn addRiscvAbiPrologue(block: *Block) !SavedRegisters {
    return SavedRegisters{
        .ra = try block.appendReadRegister(regs.ra),
        .sp = try block.appendReadRegister(regs.sp),
        .gp = try block.appendReadRegister(regs.gp),
        .tp = try block.appendReadRegister(regs.tp),
        .fp = try block.appendReadRegister(regs.fp),
        .s1 = try block.appendReadRegister(regs.s1),
        .s2 = try block.appendReadRegister(regs.s2),
        .s3 = try block.appendReadRegister(regs.s3),
        .s4 = try block.appendReadRegister(regs.s4),
        .s5 = try block.appendReadRegister(regs.s5),
        .s6 = try block.appendReadRegister(regs.s6),
        .s7 = try block.appendReadRegister(regs.s7),
        .s8 = try block.appendReadRegister(regs.s8),
        .s9 = try block.appendReadRegister(regs.s9),
        .s10 = try block.appendReadRegister(regs.s10),
        .s11 = try block.appendReadRegister(regs.s11),
    };
}

pub fn addRiscvAbiEpilogue(block: *Block, saved_registers: SavedRegisters) !void {
    try block.appendWriteRegister(regs.ra, saved_registers.ra);
    try block.appendWriteRegister(regs.sp, saved_registers.sp);
    try block.appendWriteRegister(regs.gp, saved_registers.gp);
    try block.appendWriteRegister(regs.tp, saved_registers.tp);
    try block.appendWriteRegister(regs.fp, saved_registers.fp);
    try block.appendWriteRegister(regs.s1, saved_registers.s1);
    try block.appendWriteRegister(regs.s2, saved_registers.s2);
    try block.appendWriteRegister(regs.s3, saved_registers.s3);
    try block.appendWriteRegister(regs.s4, saved_registers.s4);
    try block.appendWriteRegister(regs.s5, saved_registers.s5);
    try block.appendWriteRegister(regs.s6, saved_registers.s6);
    try block.appendWriteRegister(regs.s7, saved_registers.s7);
    try block.appendWriteRegister(regs.s8, saved_registers.s8);
    try block.appendWriteRegister(regs.s9, saved_registers.s9);
    try block.appendWriteRegister(regs.s10, saved_registers.s10);
    try block.appendWriteRegister(regs.s11, saved_registers.s11);
}

const FormatStatement = struct {
    block: *const Block,
    statement: Statement,
    index: StatementIndex,
};

fn formatStatement(data: FormatStatement, comptime fmt: []const u8, options: FormatOptions, writer: anytype) !void {
    _ = fmt;
    _ = options;
    const indexFmt = data.block.fmtValue(.{ .Result = .{
        .block = data.block,
        .index = data.index,
    } });
    if (data.statement.register_allocation) |register_allocation| {
        switch (register_allocation) {
            .Register => |reg| try writer.print("x{}| ", .{reg}),
            .Spill => |spill_pos| try writer.print("s{}| ", .{spill_pos}),
        }
    }
    switch (data.statement.statement) {
        .ReadRegister => |reg| try writer.print("{} <- x{}", .{ indexFmt, reg }),
        .WriteRegister => |write| try writer.print(
            "x{} <- {}",
            .{ write.reg, data.block.fmtValueInfo(write.value_info) },
        ),
        .Add => |add| {
            try writer.print(
                "{} <- add({}, {})",
                .{ indexFmt, data.block.fmtValueInfo(add.a), data.block.fmtValueInfo(add.b) },
            );
        },
    }
}

const FormatValue = struct {
    block: ?*const Block,
    value: Value,
};

fn formatValue(data: FormatValue, comptime fmt: []const u8, options: FormatOptions, writer: anytype) !void {
    _ = fmt;
    _ = options;
    switch (data.value) {
        .Constant => |c| try writer.print("{}", .{c}),
        .Result => |result| blk: {
            try writer.print("#{}.{}", .{ result.block.id, result.index });
            if (result.block.statement_list.items[result.index].name) |name| {
                try writer.print(":{s}", .{name});
                break :blk;
            }
        },
    }
}

const FormatValueInfo = struct {
    block: *const Block,
    value_info: ValueInfo,
};

fn formatValueInfo(data: FormatValueInfo, comptime fmt: []const u8, options: FormatOptions, writer: anytype) !void {
    _ = fmt;
    _ = options;
    if (data.value_info.register) |reg| {
        try writer.print("x{}", .{reg});
        if (data.value_info.before) |before| {
            switch (before) {
                .LoadImmediate => |immediate| try writer.print(" = {}", .{immediate}),
                .LoadFromSpill => |spill_pos| try writer.print(" = s{}", .{spill_pos}),
                else => {},
            }
        }
        if (data.value_info.after) |after| {
            switch (after) {
                .LoadImmediate => |immediate| try writer.print(", <- {}", .{immediate}),
                .LoadFromSpill => |spill_pos| try writer.print(", <- s{}", .{spill_pos}),
                .StoreToSpill => |spill_pos| try writer.print(", -> s{}", .{spill_pos}),
            }
        }
        try writer.writeAll("| ");
    }
    try writer.print("{}", .{data.block.fmtValue(data.value_info.value)});
}

const StatementIndex = usize;
const Statement = struct {
    const Self = @This();
    name: ?[]const u8 = null,
    statement: StatementType,
    register_allocation: ?RegisterAllocation = null,
    fn init(statement: StatementType, name: ?[]const u8) Self {
        return Self{
            .name = name,
            .statement = statement,
        };
    }
    fn deinit(self: Self) void {
        _ = self;
    }
};

const StatementType = union(enum) {
    const Self = @This();
    ReadRegister: Reg,
    WriteRegister: struct { reg: Reg, value_info: ValueInfo },
    Add: struct { a: ValueInfo, b: ValueInfo },
    fn isValue(self: Self) bool {
        return switch (self) {
            .ReadRegister => true,
            .WriteRegister => false,
            .Add => true,
        };
    }
    fn inputValues(self: *Self) BoundedArray(*ValueInfo, 2) {
        return genericInputValues(self, *ValueInfo);
    }
    fn constInputValues(self: *const Self) BoundedArray(*const ValueInfo, 2) {
        return genericInputValues(self, *const ValueInfo);
    }
    fn genericInputValues(self: anytype, comptime T: type) BoundedArray(T, 2) {
        const Array = BoundedArray(T, 2);
        return switch (self.*) {
            .ReadRegister => Array.fromSlice(&[_]T{}) catch unreachable,
            .WriteRegister => |*write| Array.fromSlice(&[_]T{&write.value_info}) catch unreachable,
            .Add => |*add| Array.fromSlice(&[_]T{ &add.a, &add.b }) catch unreachable,
        };
    }
    fn getPreferedRegister(self: Self) ?Reg {
        return switch (self) {
            .ReadRegister => |reg| reg,
            .WriteRegister => null,
            .Add => null,
        };
    }
    fn needsRegister(self: Self) bool {
        return switch (self) {
            .ReadRegister => false,
            .WriteRegister => false,
            .Add => true,
        };
    }
};

const ValueInfo = struct {
    const Self = @This();
    value: Value,
    register: ?Reg = null,
    before: ?MemoryAction = null,
    after: ?MemoryAction = null,
    immediate: Immediate,
    fn needsRegister(self: Self) bool {
        return switch (self.value) {
            .Constant => |c| self.immediate.needsRegister(c),
            .Result => true,
        };
    }
};
const imm12 = Immediate{ .Sized = .{ .bits = 12, .signed = .Signed } };
const Immediate = union(enum) {
    const Self = @This();
    None,
    Unlimited,
    Sized: struct {
        bits: u5,
        signed: Signed,
    },
    fn needsRegister(self: Self, value: u64) bool {
        return switch (self) {
            .None => true,
            .Unlimited => false,
            .Sized => |size| !switch (size.signed) {
                .Signed => blk: {
                    const min = @as(i64, -1) << size.bits - 1;
                    const max = @bitCast(i64, (@as(u64, 1) << size.bits - 1) - 1);
                    const signedValue = @bitCast(i64, value);
                    break :blk min <= signedValue and signedValue <= max;
                },
                .Unsigned => value < (@as(u64, 1) << size.bits),
            },
        };
    }
};
const Signed = enum { Signed, Unsigned };

const RegisterAllocation = union(enum) {
    const Self = @This();
    Register: Reg,
    Spill: SpillPos,
    fn getRegister(self: Self) ?Reg {
        return switch (self) {
            .Register => |reg| reg,
            else => null,
        };
    }
};

const RegisterFile = [32]?Value;

const SpillPos = u64;
const MemoryAction = union(enum) {
    LoadImmediate: u64,
    LoadFromSpill: SpillPos,
    StoreToSpill: SpillPos,
};

const Spill = struct {
    const Self = @This();
    spill: ArrayList(?Value),
    lowest_free_index: usize,
    fn init(allocator: Allocator) Self {
        return Self{
            .spill = ArrayList(?Value).init(allocator),
            .lowest_free_index = 0,
        };
    }
    fn deinit(self: Self) void {
        self.spill.deinit();
    }
    fn put(self: *Self, value: Value) !SpillPos {
        const spill_pos = self.lowest_free_index;
        if (spill_pos == self.spill.items.len) {
            try self.spill.append(value);
            self.lowest_free_index += 1;
        } else {
            self.spill.items[spill_pos] = value;
            self.lowest_free_index += 1;
            while (self.lowest_free_index < self.spill.items.len and self.spill.items[self.lowest_free_index] != null) : (self.lowest_free_index += 1) {}
        }
        return spill_pos;
    }
    fn delete(self: *Self, spill_pos: SpillPos) void {
        self.spill.items[spill_pos] = null;
        self.lowest_free_index = std.math.min(self.lowest_free_index, spill_pos);
    }
};

const Exit = union(enum) {
    const Self = @This();

    Jump: *Block,
    FunctionExit,

    fn getSuccessorBlocks(self: Self) BoundedArray(usize, 2) {
        const Array = BoundedArray(usize, 2);
        return switch (self) {
            .Jump => |block| Array.fromSlice(&[_]usize{block.id}) catch unreachable,
            .FunctionExit => Array.init(0) catch unreachable,
        };
    }
};

const ValueError = error{InvalidValue};
const RegisterAllocationError = error{RegisterAlreadyAllocated};
const VerificationError = error{
    RegisterHoldsDifferentValue,
    MissingAllocation,
    AllocationForNonValue,
    InvalidMemoryAction,
    InvalidRegister,
};
const MaterializationError = error{NoRegisterAllocation};

fn setList(index: usize, value: anytype, list: *ArrayList(@TypeOf(value))) !void {
    if (index >= list.items.len) {
        try list.resize(index + 1);
    }
    list.items[index] = value;
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const test_allocator = std.testing.allocator;

test "append and get index" {
    var list = ArrayList(u8).init(test_allocator);
    defer list.deinit();
    try expect((try appendAndGetIndex(@as(u8, 7), &list)) == 0);
    try expect((try appendAndGetIndex(@as(u8, 8), &list)) == 1);
}

test "read register" {
    var arena = ArenaAllocator.init(test_allocator);
    defer arena.deinit();
    var block = Block.init(test_allocator, arena.allocator(), 0, 0);
    block.id = 0;
    defer block.deinit();
    const val = try block.appendReadRegister(5);
    try expect(val.Result.index == 0);
    try testStatement(&block, val, .{ .ReadRegister = 5 }, null);
}

test "read register x0" {
    var arena = ArenaAllocator.init(test_allocator);
    defer arena.deinit();
    var block = Block.init(test_allocator, arena.allocator(), 0, 0);
    block.id = 0;
    defer block.deinit();
    const val = try block.appendReadRegister(0);
    try expect(val.Constant == 0);
}

test "add" {
    var arena = ArenaAllocator.init(test_allocator);
    defer arena.deinit();
    var block = Block.init(test_allocator, arena.allocator(), 0, 0);
    block.id = 0;
    defer block.deinit();
    const val = try block.appendAdd(constant(1), constant(1), null);
    try expect(val.Constant == 2);
    const reg = try block.appendReadRegister(9);
    const val2 = try block.appendAdd(reg, constant(10), null);
    try testStatement(&block, val2, .{
        .Add = .{
            .a = .{ .value = reg, .immediate = .None },
            .b = .{ .value = constant(10), .immediate = imm12 },
        },
    }, null);
}

test "add with name" {
    var arena = ArenaAllocator.init(test_allocator);
    defer arena.deinit();
    var block = Block.init(test_allocator, arena.allocator(), 0, 0);
    block.id = 0;
    defer block.deinit();
    const reg = try block.appendReadRegister(31);
    const val = try block.appendAdd(constant(3), reg, "hello");
    try testStatement(&block, val, .{
        .Add = .{
            .a = .{ .value = reg, .immediate = .None },
            .b = .{ .value = constant(3), .immediate = imm12 },
        },
    }, "hello");
}

test "add constant negative" {
    var arena = ArenaAllocator.init(test_allocator);
    defer arena.deinit();
    var block = Block.init(test_allocator, arena.allocator(), 0, 0);
    block.id = 0;
    defer block.deinit();
    const val = try block.appendAdd(signedConstant(-1), signedConstant(-2), null);
    try expectEqual(val, signedConstant(-3));
    const val2 = try block.appendAdd(signedConstant(1), signedConstant(-2), null);
    try expectEqual(val2, signedConstant(-1));
}

test "format" {
    var arena = ArenaAllocator.init(test_allocator);
    defer arena.deinit();
    var block = Block.init(test_allocator, arena.allocator(), 0, 0);
    block.id = 0;
    defer block.deinit();
    _ = try block.appendAdd(constant(1), constant(1), "test");
    const reg = try block.appendReadRegister(9);
    const val = try block.appendAdd(reg, constant(10), "hello");
    const result = try block.appendAdd(reg, val, null);
    try block.appendWriteRegister(4, result);
    std.debug.print("\n{}", .{block});
}

test "function body alloc" {
    var arena = ArenaAllocator.init(test_allocator);
    defer arena.deinit();
    var block = Block.init(test_allocator, arena.allocator(), 0, 0);
    block.id = 0;
    defer block.deinit();
    const saved_registers = try addRiscvAbiPrologue(&block);
    const a0 = try block.appendReadRegister(regs.a0);
    const a1 = try block.appendReadRegister(regs.a1);
    const result = try block.appendAdd(a0, a1, "result");
    const tmp = try block.appendAdd(a0, constant(21), "tmp");
    try block.appendWriteRegister(regs.a0, result);
    try block.appendWriteRegister(regs.a1, tmp);
    try addRiscvAbiEpilogue(&block, saved_registers);
    var registers = [1]?Value{null} ** 32;
    var spill = Spill.init(test_allocator);
    defer spill.deinit();
    try block.allocateRegisters(&registers, &spill);
    std.debug.print("\n{}", .{block});
    try block.verifyRegisterAllocation();
    var assembler = try Assembler.init(test_allocator);
    defer assembler.deinit();
    const spill_size = spill.spill.items.len;
    try block.materialize(spill_size, &assembler);
    try assembler.writeToFile("simple_addition.o");
}

test "large constant" {
    var arena = ArenaAllocator.init(test_allocator);
    defer arena.deinit();
    var block = Block.init(test_allocator, arena.allocator(), 0, 0);
    block.id = 0;
    defer block.deinit();
    const saved_registers = try addRiscvAbiPrologue(&block);
    const a0 = try block.appendReadRegister(regs.a0);
    const result = try block.appendAdd(a0, constant(80000000), "result");
    try block.appendWriteRegister(regs.a0, result);
    try addRiscvAbiEpilogue(&block, saved_registers);
    var registers = [1]?Value{null} ** 32;
    var spill = Spill.init(test_allocator);
    defer spill.deinit();
    try block.allocateRegisters(&registers, &spill);
    std.debug.print("\n{}", .{block});
    try block.verifyRegisterAllocation();
    var assembler = try Assembler.init(test_allocator);
    defer assembler.deinit();
    const spill_size = spill.spill.items.len;
    try block.materialize(spill_size, &assembler);
    try assembler.writeToFile("large_constant.o");
}

test "materialize complex addition" {
    var arena = ArenaAllocator.init(test_allocator);
    defer arena.deinit();
    var block = Block.init(test_allocator, arena.allocator(), 0, 0);
    block.id = 0;
    defer block.deinit();
    const saved_registers = try addRiscvAbiPrologue(&block);
    const a0 = try block.appendReadRegister(regs.a0);
    const a1 = try block.appendReadRegister(regs.a1);
    const a2 = try block.appendReadRegister(regs.a2);
    const a3 = try block.appendReadRegister(regs.a3);
    const a4 = try block.appendReadRegister(regs.a4);
    const a5 = try block.appendReadRegister(regs.a5);
    const a6 = try block.appendReadRegister(regs.a6);
    const a7 = try block.appendReadRegister(regs.a7);
    const a0_plus_a1 = try block.appendAdd(a0, a1, "a0 + a1");
    const a2_plus_a3 = try block.appendAdd(a2, a3, "a2 + a3");
    const a4_plus_a5 = try block.appendAdd(a4, a5, "a4 + a5");
    const a6_plus_a7 = try block.appendAdd(a6, a7, "a6 + a7");
    const a0_to_a3 = try block.appendAdd(a0_plus_a1, a2_plus_a3, "a0 + a1 + a2 + a3");
    const a4_to_a7 = try block.appendAdd(a4_plus_a5, a6_plus_a7, "a4 + a5 + a6 + a7");
    const result = try block.appendAdd(a0_to_a3, a4_to_a7, "result");
    try block.appendWriteRegister(regs.a0, result);
    try addRiscvAbiEpilogue(&block, saved_registers);
    var registers = [1]?Value{null} ** 32;
    var spill = Spill.init(test_allocator);
    defer spill.deinit();
    try block.allocateRegisters(&registers, &spill);
    std.debug.print("\n{}", .{block});
    try block.verifyRegisterAllocation();
    var assembler = try Assembler.init(test_allocator);
    defer assembler.deinit();
    const spill_size = spill.spill.items.len;
    try block.materialize(spill_size, &assembler);
    try assembler.writeToFile("complex_addition.o");
}

test "spill" {
    var arena = ArenaAllocator.init(test_allocator);
    defer arena.deinit();
    var block = Block.init(test_allocator, arena.allocator(), 0, 0);
    block.id = 0;
    defer block.deinit();
    const saved_registers = try addRiscvAbiPrologue(&block);
    const a0 = try block.appendReadRegister(regs.a0);
    const a1 = try block.appendReadRegister(regs.a1);
    const a2 = try block.appendReadRegister(regs.a2);
    const a3 = try block.appendReadRegister(regs.a3);
    const a4 = try block.appendReadRegister(regs.a4);
    const a5 = try block.appendReadRegister(regs.a5);
    const a6 = try block.appendReadRegister(regs.a6);
    const a7 = try block.appendReadRegister(regs.a7);
    const a0_plus_a1 = try block.appendAdd(a0, a1, "a0 + a1");
    const a2_plus_a3 = try block.appendAdd(a2, a3, "a2 + a3");
    const a4_plus_a5 = try block.appendAdd(a4, a5, "a4 + a5");
    const a6_plus_a7 = try block.appendAdd(a6, a7, "a6 + a7");
    const a0_to_a3 = try block.appendAdd(a0_plus_a1, a2_plus_a3, "a0 + a1 + a2 + a3");
    const a4_to_a7 = try block.appendAdd(a4_plus_a5, a6_plus_a7, "a4 + a5 + a6 + a7");
    const a0_plus_a7 = try block.appendAdd(a0, a7, "a0 + a7");
    const a1_plus_a6 = try block.appendAdd(a1, a6, "a1 + a6");
    const a2_plus_a5 = try block.appendAdd(a2, a5, "a2 + a5");
    const a3_plus_a4 = try block.appendAdd(a3, a4, "a3 + a4");
    var sum = try block.appendAdd(a0_to_a3, a4_to_a7, "sum");
    const original_sum = sum;
    sum = try block.appendAdd(sum, a0_plus_a1, "sum");
    sum = try block.appendAdd(sum, a2_plus_a3, "sum");
    sum = try block.appendAdd(sum, a4_plus_a5, "sum");
    sum = try block.appendAdd(sum, a6_plus_a7, "sum");
    sum = try block.appendAdd(sum, a0_plus_a7, "sum");
    sum = try block.appendAdd(sum, a1_plus_a6, "sum");
    sum = try block.appendAdd(sum, a2_plus_a5, "sum");
    sum = try block.appendAdd(sum, a3_plus_a4, "sum");
    sum = try block.appendAdd(sum, a0_to_a3, "sum");
    sum = try block.appendAdd(sum, a4_to_a7, "sum");
    sum = try block.appendAdd(sum, original_sum, "sum");
    sum = try block.appendAdd(sum, a0, "sum");
    sum = try block.appendAdd(sum, a1, "sum");
    sum = try block.appendAdd(sum, a2, "sum");
    sum = try block.appendAdd(sum, a3, "sum");
    sum = try block.appendAdd(sum, a4, "sum");
    sum = try block.appendAdd(sum, a5, "sum");
    sum = try block.appendAdd(sum, a6, "sum");
    sum = try block.appendAdd(sum, a7, "sum");
    try block.appendWriteRegister(regs.a0, sum);
    try addRiscvAbiEpilogue(&block, saved_registers);
    var registers = [1]?Value{null} ** 32;
    var spill = Spill.init(test_allocator);
    defer spill.deinit();
    try block.allocateRegisters(&registers, &spill);
    std.debug.print("\n{}", .{block});
    try block.verifyRegisterAllocation();
    var assembler = try Assembler.init(test_allocator);
    defer assembler.deinit();
    const spill_size = spill.spill.items.len;
    try block.materialize(spill_size, &assembler);
    try assembler.writeToFile("spill.o");
}

test "needs register none" {
    const immediate: Immediate = .None;
    try expect(immediate.needsRegister(0) == true);
    try expect(immediate.needsRegister(maxInt(u64)) == true);
    try expect(immediate.needsRegister(@bitCast(u64, @as(i64, maxInt(i64)))) == true);
    try expect(immediate.needsRegister(@bitCast(u64, @as(i64, minInt(i64)))) == true);
}

test "needs register unlimited" {
    const immediate: Immediate = .Unlimited;
    try expect(immediate.needsRegister(0) == false);
    try expect(immediate.needsRegister(maxInt(u64)) == false);
    try expect(immediate.needsRegister(@bitCast(u64, @as(i64, maxInt(i64)))) == false);
    try expect(immediate.needsRegister(@bitCast(u64, @as(i64, minInt(i64)))) == false);
}

test "needs register sized unsigned" {
    const immediate = Immediate{ .Sized = .{ .bits = 8, .signed = .Unsigned } };
    try expect(immediate.needsRegister(0) == false);
    try expect(immediate.needsRegister(maxInt(u64)) == true);
    try expect(immediate.needsRegister(@bitCast(u64, @as(i64, maxInt(i64)))) == true);
    try expect(immediate.needsRegister(@bitCast(u64, @as(i64, minInt(i64)))) == true);
    try expect(immediate.needsRegister(maxInt(u8)) == false);
    try expect(immediate.needsRegister(maxInt(u8) + 1) == true);
}

test "needs register sized signed" {
    const immediate = Immediate{ .Sized = .{ .bits = 8, .signed = .Signed } };
    try expect(immediate.needsRegister(0) == false);
    try expect(immediate.needsRegister(@bitCast(u64, @as(i64, maxInt(i64)))) == true);
    try expect(immediate.needsRegister(@bitCast(u64, @as(i64, minInt(i64)))) == true);
    try expect(immediate.needsRegister(@bitCast(u64, @as(i64, maxInt(i8)))) == false);
    try expect(immediate.needsRegister(@bitCast(u64, @as(i64, maxInt(i8) + 1))) == true);
    try expect(immediate.needsRegister(@bitCast(u64, @as(i64, minInt(i8)))) == false);
    try expect(immediate.needsRegister(@bitCast(u64, @as(i64, minInt(i8) - 1))) == true);
}

fn testStatement(block: *Block, value: Value, expected: StatementType, expected_name: ?[]const u8) !void {
    try expect(value == .Result);
    try expect(block == value.Result.block);
    const actual = block.statement_list.items[value.Result.index];
    try expectEqual(expected, actual.statement);
    if (expected_name) |name| {
        try expectEqualStrings(name, actual.name.?);
    }
}

// ███████╗ ██╗   ██╗ ███╗   ██╗  ██████╗ ████████╗ ██╗  ██████╗  ███╗   ██╗
// ██╔════╝ ██║   ██║ ████╗  ██║ ██╔════╝ ╚══██╔══╝ ██║ ██╔═══██╗ ████╗  ██║
// █████╗   ██║   ██║ ██╔██╗ ██║ ██║         ██║    ██║ ██║   ██║ ██╔██╗ ██║
// ██╔══╝   ██║   ██║ ██║╚██╗██║ ██║         ██║    ██║ ██║   ██║ ██║╚██╗██║
// ██║      ╚██████╔╝ ██║ ╚████║ ╚██████╗    ██║    ██║ ╚██████╔╝ ██║ ╚████║
// ╚═╝       ╚═════╝  ╚═╝  ╚═══╝  ╚═════╝    ╚═╝    ╚═╝  ╚═════╝  ╚═╝  ╚═══╝

pub const Function = struct {
    const Self = @This();

    gpa: Allocator,
    arena: Allocator,

    id: usize,
    blocks: ArrayList(*Block),
    name: []const u8,
    function_parameters: ArrayList(FunctionParameter),
    saved_registers: SavedRegisters = undefined,
    exit_block: ?*Block = null,
    cfg: ?Cfg = null,
    spill_size: ?usize = null,

    pub fn init(gpa: Allocator, arena: Allocator, name: []const u8) !Self {
        const allocated_name = try arena.dupe(u8, name);
        var self = Self{
            .gpa = gpa,
            .arena = arena,
            .id = getId(),
            .blocks = ArrayList(*Block).init(gpa),
            .function_parameters = ArrayList(FunctionParameter).init(gpa),
            .name = allocated_name,
        };
        try self.addInitialBlocks();
        return self;
    }
    pub fn deinit(self: Self) void {
        for (self.blocks.items) |block| {
            block.deinit();
        }
        self.blocks.deinit();
        self.function_parameters.deinit();
        if (self.cfg) |cfg| {
            cfg.deinit();
        }
    }
    pub fn addBlock(self: *Self) !*Block {
        const block = try self.arena.create(Block);
        const block_id = try appendAndGetIndex(block, &self.blocks);
        block.* = Block.init(self.gpa, self.arena, self.id, block_id);
        return block;
    }
    fn addInitialBlocks(self: *Self) !void {
        const prologue = try self.addBlock();
        self.saved_registers = try addRiscvAbiPrologue(prologue);
        const epilogue = try self.addBlock();
        epilogue.exit = .FunctionExit;
        const entry = try self.addBlock();
        prologue.jump(entry);
    }
    pub fn getEntryBlock(self: *const Self) *Block {
        return self.blocks.items[2];
    }
    fn getPrologueBlock(self: *const Self) *Block {
        return self.blocks.items[0];
    }
    fn getEpilogueBlock(self: *const Self) *Block {
        return self.blocks.items[1];
    }
    pub fn addParameter(self: *Self, name: ?[]const u8) !Value {
        const function_parameter = if (getArgumentRegister(self.function_parameters.items.len)) |reg| .{
            .register = reg,
            .value = try self.getPrologueBlock().appendReadRegister(reg),
            .name = try dupeOption(self.arena, u8, name),
        } else unreachable;
        try self.function_parameters.append(function_parameter);
        return function_parameter.value;
    }
    pub fn setFunctionExit(self: *Self, block: *Block, return_value: Value) !void {
        if (self.exit_block == null) {
            self.exit_block = block;
            block.jump(self.getEpilogueBlock());
            try self.getEpilogueBlock().appendWriteRegister(regs.a0, return_value);
        } else {
            return FunctionError.MultipleExits;
        }
    }

    fn calculateDominatorTree(self: *Self) (FunctionError || error{OutOfMemory})!void {
        var cfg = try Cfg.init(self.gpa, self.blocks.items.len);
        for (self.blocks.items) |block| {
            if (block.exit) |exit| {
                cfg.createNode(exit.getSuccessorBlocks().constSlice()) catch |err| switch (err) {
                    error.Overflow => unreachable,
                    error.OutOfMemory => return error.OutOfMemory,
                };
            } else return FunctionError.NoExit;
        }
        try cfg.analyze();
        self.cfg = cfg;
        std.debug.print("\n{}\n", .{cfg});
    }

    fn addPseudoInstructions(self: *Self) !void {
        try addRiscvAbiEpilogue(self.getEpilogueBlock(), self.saved_registers);
    }

    fn allocateRegisters(self: *Self) (FunctionError || RegisterAllocationError || error{OutOfMemory})!void {
        var registers: RegisterFile = [1]?Value{null} ** 32;
        var spill = Spill.init(self.gpa);
        defer spill.deinit();
        try self.calculateDominatorTree();
        var block_index = self.getEpilogueBlock().id;
        var immediate_dominator = self.cfg.?.getImmediateDominator(block_index);
        while (true) {
            const block = self.blocks.items[block_index];
            try self.allocateRegistersInBlock(block, &registers, &spill);
            if (block_index == immediate_dominator) {
                break;
            }
            block_index = immediate_dominator;
            immediate_dominator = self.cfg.?.getImmediateDominator(block_index);
        }
        for (registers) |reg, index| {
            if (reg) |reg_value| {
                std.debug.print("value of register {}: {}\n", .{ index, reg_value });
            }
            assert(reg == null);
        }
        for (spill.spill.items) |value| {
            assert(value == null);
        }
        self.spill_size = spill.spill.items.len;
    }

    fn allocateRegistersInBlock(self: *Self, block: *Block, registers: *RegisterFile, spill: *Spill) (RegisterAllocationError || error{OutOfMemory})!void {
        std.debug.print("allocate regs for block: {}\n", .{block.id});
        var i: usize = block.statement_list.items.len;
        while (i > 0) {
            i -= 1;
            const statement = &block.statement_list.items[i];
            if (statement.statement.isValue()) {
                switch (statement.register_allocation.?) {
                    .Register => |reg| registers[reg] = null,
                    .Spill => |spill_pos| spill.delete(spill_pos),
                }
            }
            switch (statement.statement) {
                .WriteRegister => |*write| {
                    try self.findAndSetRegister(registers, spill, &write.value_info, write.reg);
                },
                else => {
                    const input_values = statement.statement.inputValues();
                    for (input_values.constSlice()) |value_info| {
                        if (value_info.needsRegister()) {
                            try self.findAndSetRegister(registers, spill, value_info, null);
                        }
                    }
                },
            }
        }
    }
    fn findAndSetRegister(self: *Self, registers: *RegisterFile, spill: *Spill, value_info: *ValueInfo, prefered_reg: ?Reg) !void {
        const statement: ?*Statement = switch (value_info.value) {
            .Result => |result| blk: {
                const statement = &result.block.statement_list.items[result.index];
                assert(statement.statement.isValue());
                if (statement.register_allocation) |register_allocation| {
                    if (register_allocation.getRegister()) |reg| {
                        if (registers[reg]) |register_value| {
                            value_info.register = reg;
                            assert(eql(register_value.Result, result));
                        } else {
                            registers[reg] = value_info.value;
                        }
                    }
                    return;
                } else {
                    break :blk statement;
                }
            },
            .Constant => null,
        };
        const reg = findRegister: {
            if (prefered_reg) |reg| {
                if (registers[reg] == null) {
                    break :findRegister reg;
                }
            }
            if (statement) |stmt| {
                if (stmt.statement.getPreferedRegister()) |reg| {
                    if (registers[reg] == null) {
                        break :findRegister reg;
                    }
                }
            }
            var j: Reg = 31;
            while (j > 0) : (j -= 1) {
                if (registers[j] == null) {
                    break :findRegister j;
                }
            }
            if (value_info.needsRegister()) {
                break :findRegister try self.spillValue(registers, spill, value_info);
            } else {
                break :findRegister null;
            }
        };
        if (reg) |r| {
            value_info.register = r;
            switch (value_info.value) {
                .Result => {
                    registers[r] = value_info.value;
                },
                .Constant => |c| {
                    value_info.before = .{ .LoadImmediate = c };
                },
            }
            if (statement) |stmt| {
                stmt.register_allocation = .{ .Register = r };
            }
        } else {
            if (statement) |stmt| {
                stmt.register_allocation = .{ .Spill = try spill.put(value_info.value) };
            }
        }
    }
    fn spillValue(self: *Self, registers: *RegisterFile, spill: *Spill, value_info: *ValueInfo) !Reg {
        var reg: Reg = 31;
        var best_reg: Reg = 31;
        var best_index: StatementIndex = maxInt(StatementIndex);
        var best_depth: usize = maxInt(usize);
        var best_block: *const Block = undefined;
        while (reg > 0) : (reg -= 1) {
            if (reg == regs.fp) {
                continue;
            }
            const result = registers[reg].?.Result;
            const depth = self.cfg.?.getDominatorTreeDepth(result.block.id);
            // TODO: make compatible with constants
            if (depth < best_depth or result.index < best_index) {
                best_reg = reg;
                best_index = result.index;
                best_block = result.block;
                best_depth = depth;
            }
        }
        const spill_pos = try spill.put(registers[best_reg].?);
        best_block.statement_list.items[best_index].register_allocation = .{ .Spill = spill_pos };
        value_info.after = .{ .LoadFromSpill = spill_pos };
        return best_reg;
    }
    fn verifyRegisterAllocation(self: *const Self) (VerificationError || error{OutOfMemory})!void {
        var registers = [1]?Value{null} ** 32;
        var spill = ArrayList(?Value).init(self.gpa);
        defer spill.deinit();
        for (self.statement_list.items) |statement, index| {
            if (statement.statement.isValue() and statement.register_allocation == null) {
                return VerificationError.MissingAllocation;
            }
            if (!statement.statement.isValue() and statement.register_allocation != null) {
                return VerificationError.AllocationForNonValue;
            }
            // before
            const inputValues = statement.statement.constInputValues();
            for (inputValues.constSlice()) |value_info| {
                if (value_info.needsRegister()) {
                    if (value_info.register == null) {
                        return VerificationError.MissingAllocation;
                    }
                    const reg = value_info.register.?;
                    if (value_info.before) |before| {
                        switch (before) {
                            .LoadImmediate => |immediate| registers[reg] = constant(immediate),
                            .LoadFromSpill => |spill_pos| registers[reg] = spill.items[spill_pos],
                            .StoreToSpill => return VerificationError.InvalidMemoryAction,
                        }
                    }
                } else {
                    if (value_info.before != null) {
                        return VerificationError.InvalidMemoryAction;
                    }
                }
            }
            // instruction
            for (inputValues.constSlice()) |value_info| {
                if (value_info.needsRegister()) {
                    const reg = value_info.register.?;
                    if (reg == 0) {
                        return VerificationError.InvalidRegister;
                    }
                    if (!eql(registers[reg], value_info.value)) {
                        return VerificationError.RegisterHoldsDifferentValue;
                    }
                }
            }
            if (statement.register_allocation) |register_allocation| {
                const value = Value{ .Result = .{
                    .block = self,
                    .index = index,
                } };
                switch (register_allocation) {
                    .Register => |reg| registers[reg] = value,
                    .Spill => |spill_pos| {
                        if (statement.statement.needsRegister()) {
                            return VerificationError.MissingAllocation;
                        }
                        try setList(spill_pos, @as(?Value, value), &spill);
                    },
                }
            }
            // after
            for (inputValues.constSlice()) |value_info| {
                if (value_info.needsRegister()) {
                    const reg = value_info.register.?;
                    if (value_info.after) |after| {
                        switch (after) {
                            .LoadImmediate => return VerificationError.InvalidMemoryAction,
                            .LoadFromSpill => |spill_pos| registers[reg] = spill.items[spill_pos],
                            .StoreToSpill => unreachable, // TODO: stack
                        }
                    }
                } else {
                    if (value_info.after != null) {
                        return VerificationError.InvalidMemoryAction;
                    }
                }
            }
        }
    }
    fn materialize(self: *const Self, assembler: *Assembler) !void {
        const spill_size = if (self.spill_size) |spill_size| spill_size else {
            return MaterializationError.NoRegisterAllocation;
        };
        _ =try  assembler.addSymbolAtEnd(Assembler.textSection, self.name);
        var block = self.getPrologueBlock();
        while (true) {
            try block.materialize(spill_size, assembler);
            if(block.exit.? == .FunctionExit){
                try assembler.instrRet();
            }

            const successor_blocks = block.exit.?.getSuccessorBlocks();
            if (successor_blocks.constSlice().len == 0) {
                break;
            }
            assert(successor_blocks.constSlice().len == 1);
            block = self.blocks.items[successor_blocks.constSlice()[0]];
        }
    }
};

const FunctionParameter = struct {
    register: Reg, // TODO: add ability for stack values
    value: Value,
    name: ?[]const u8,
};

const FunctionError = error{ InvalidId, MultipleExits, NoExit };

test "function id" {
    var arena = ArenaAllocator.init(test_allocator);
    defer arena.deinit();
    var f1 = try Function.init(test_allocator, arena.allocator(), "hello_world");
    defer f1.deinit();
    var f2 = try Function.init(test_allocator, arena.allocator(), "function_2");
    defer f2.deinit();
    try expect(f1.id != f2.id);
}

test "add block" {
    var arena = ArenaAllocator.init(test_allocator);
    defer arena.deinit();
    var function = try Function.init(test_allocator, arena.allocator(), "function");
    defer function.deinit();
    const block0 = try function.addBlock();
    try expect(block0.id == 3);
    const block1 = try function.addBlock();
    try expect(block1.id == 4);
}

test "function with one block" {
    var arena = ArenaAllocator.init(test_allocator);
    defer arena.deinit();
    var function = try Function.init(test_allocator, arena.allocator(), "function");
    defer function.deinit();
    var entry = function.getEntryBlock();
    const a = try function.addParameter("a");
    const b = try function.addParameter("b");
    const sum = try entry.appendAdd(a, b, "sum");
    try function.setFunctionExit(entry, sum);
    try function.addPseudoInstructions();
    try function.allocateRegisters();
    std.debug.print("{any}", .{function.blocks.items});
    var assembler = try Assembler.init(test_allocator);
    defer assembler.deinit();
    try function.verifyRegisterAllocation();
    try function.materialize(&assembler);
    try assembler.writeToFile("one_block.o");
}
test "function simple loop" {

}
