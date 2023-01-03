const std = @import("std");
const builtin = std.builtin;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const File = std.fs.File;

const elf = @import("elf.h.zig");
const Elf32_Ehdr = elf.Elf32_Ehdr;
const Elf32_Phdr = elf.Elf32_Phdr;
const Elf32_Shdr = elf.Elf32_Shdr;
const Elf32_Sym = elf.Elf32_Sym;
const Elf32_Rela = elf.Elf32_Rela;

pub const Section = struct { section: u16 };
pub const Symbol = struct { symbol: u32 };
pub const Reg = u5;

pub const InvalidArgumentError = error{ InvalidSection, InvalidSymbol };

pub const Assembler = struct {
    const Self = @This();

    text: ArrayList(u8),
    rela_table: ArrayList(Elf32_Rela),
    data: ArrayList(u8),
    string_table: ArrayList(u8),
    symbol_table: ArrayList(Elf32_Sym),
    pub fn init(allocator: Allocator) !Self {
        return Self{
            .text = ArrayList(u8).init(allocator),
            .rela_table = ArrayList(Elf32_Rela).init(allocator),
            .data = ArrayList(u8).init(allocator),
            .string_table = try stringTableInit(allocator),
            .symbol_table = try symbolTableInit(allocator),
        };
    }
    pub fn deinit(self: Self) void {
        self.text.deinit();
        self.rela_table.deinit();
        self.data.deinit();
        self.string_table.deinit();
        self.symbol_table.deinit();
    }
    pub fn writeToFile(self: *Self, arg_file_name: []const u8) !void {
        var file_name = arg_file_name;
        var header = defaultElfHeader();
        var section_headers = defaultSections();
        var file = try std.fs.cwd().createFile(file_name, .{});
        defer file.close();
        try file.seekTo(@sizeOf(Elf32_Ehdr));
        try writeSection(&file, &section_headers[1], u8, &self.string_table);
        try writeSection(&file, &section_headers[2], u8, &self.text);
        try writeSection(&file, &section_headers[3], Elf32_Rela, &self.rela_table);
        try writeSection(&file, &section_headers[4], u8, &self.data);
        try writeSection(&file, &section_headers[5], Elf32_Sym, &self.symbol_table);
        header.e_shoff = @truncate(u32, try file.getPos());
        header.e_shnum = section_headers.len;
        try writeSectionHeaders(&file, section_headers[0..]);
        try file.seekTo(0);
        try file.writeAll(toBytes(&header));
    }
    const textSection = Section{ .section = 2 };
    const dataSection = Section{ .section = 3 };
    fn addString(self: *Self, string: []const u8) !usize {
        return addCString(&self.string_table, string);
    }
    pub fn addSymbolAtEnd(self: *Self, section: Section, name: ?[]const u8) !Symbol {
        const array_list = switch (section.section) {
            2 => self.text,
            3 => self.data,
            else => return InvalidArgumentError.InvalidSection,
        };
        var buffer: [32]u8 = undefined;
        const symbol_name = if (name) |n| n else blk: {
            const unnamed_counter = struct {
                var static: usize = 0;
            };
            const number = @atomicRmw(usize, &unnamed_counter.static, .Add, 1, .Monotonic);
            break :blk std.fmt.bufPrint(buffer[0..], "__unnamed-{}", .{number}) catch unreachable;
        };
        const symbol_index = self.symbol_table.items.len;
        try self.symbol_table.append(.{
            .st_name = @truncate(u32, try self.addString(symbol_name)),
            .st_value = @truncate(u32, array_list.items.len),
            .st_size = 0,
            .st_info = ELF32_ST_INFO(elf.STB_LOCAL, elf.STT_NOTYPE),
            .st_other = 0,
            .st_shndx = @truncate(u16, section.section),
        });
        return Symbol{ .symbol = @truncate(u32, symbol_index) };
    }
    pub fn instrAdd(self: *Self, rd: Reg, rs1: Reg, rs2: Reg) !void {
        try encodeRInstr(&self.*.text, 0x33, 0, 0, rd, rs1, rs2);
    }
    pub fn instrJump(self: *Self, symbol: Symbol) !void {
        _ = self;
        _ = symbol;
        unreachable;
    }
};
fn stringTableInit(allocator: Allocator) !ArrayList(u8) {
    var string_table = ArrayList(u8).init(allocator);
    _ = try addCString(&string_table, "");
    _ = try addCString(&string_table, ".strtab");
    _ = try addCString(&string_table, ".rela.text");
    _ = try addCString(&string_table, ".data");
    _ = try addCString(&string_table, ".symtab");
    return string_table;
}
fn symbolTableInit(allocator: Allocator) !ArrayList(Elf32_Sym) {
    var symbol_table = ArrayList(Elf32_Sym).init(allocator);
    try symbol_table.append(.{
        .st_name = 0,
        .st_value = 0,
        .st_size = 0,
        .st_info = 0,
        .st_other = 0,
        .st_shndx = elf.SHN_UNDEF,
    });
    return symbol_table;
}

fn addCString(list: *ArrayList(u8), string: []const u8) !usize {
    const start = list.items.len;
    try list.appendSlice(string);
    try list.append(0);
    return start;
}


fn encodeRInstr(vec: *ArrayList(u8), op_code: u7, funct3: u3, funct7: u7, rd: Reg, rs1: Reg, rs2: Reg) !void {
    try listAppendInstr(vec, op_code | encodeRd(rd) | encodeRs1(rs1) | encodeRs2(rs2) | encodeFunct3(funct3) | encodeFunct7(funct7));
}
fn encodeRd(rd: Reg) u32 {
    return @as(u32, rd) << 7;
}
fn encodeRs1(rs1: Reg) u32 {
    return @as(u32, rs1) << 15;
}
fn encodeRs2(rs2: Reg) u32 {
    return @as(u32, rs2) << 20;
}
fn encodeFunct3(funct3: u3) u32 {
    return @as(u32, funct3) << 12;
}
fn encodeFunct7(funct7: u7) u32 {
    return @as(u32, funct7) << 25;
}
fn listAppendInstr(vec: *ArrayList(u8), instr: u32) !void {
    try vec.appendSlice(instrAsBytes(instr)[0..]);
}
fn instrAsBytes(instr: u32) [4]u8 {
    // TODO: Endianess
    return @bitCast([4]u8, instr);
}
fn writeSectionHeaders(file: *File, sections: []Elf32_Shdr) !void {
    try file.writeAll(sliceCast(u8, sections));
}
fn writeSection(file: *File, section_header: *Elf32_Shdr, comptime T: type, elements: *const ArrayList(T)) !void {
    const data = sliceCast(u8, elements.items);
    section_header.*.sh_offset = @truncate(u32, try file.getPos());
    section_header.*.sh_size = @truncate(u32, data.len);
    try file.writeAll(data);
}

fn sliceCast(comptime T: type, slice: anytype) []T {
    if (slice.len == 0) {
        return &[_]T{};
    }
    return @ptrCast([*]T, slice.ptr)[0..@divExact(slice.len * @sizeOf(@TypeOf(slice[0])), @sizeOf(T))];
}

fn toBytes(x: anytype) []u8 {
    return @ptrCast([*]u8, x)[0..@sizeOf(@TypeOf(x.*))];
}

inline fn ELF32_ST_INFO(bind: c_int, @"type": c_int) u8 {
    return @bitCast(u8, @truncate(i8, elf.ELF32_ST_INFO(bind, @"type")));
}

fn defaultSections() [6]Elf32_Shdr {
    return [_]Elf32_Shdr{
        Elf32_Shdr{
            .sh_name = 0,
            .sh_type = elf.SHT_NULL,
            .sh_flags = 0,
            .sh_addr = 0,
            .sh_offset = 0,
            .sh_size = 0,
            .sh_link = 0,
            .sh_info = 0,
            .sh_addralign = 0,
            .sh_entsize = 0,
        },
        Elf32_Shdr{
            .sh_name = 1,
            .sh_type = elf.SHT_STRTAB,
            .sh_flags = 0,
            .sh_addr = 0,
            .sh_offset = undefined,
            .sh_size = undefined,
            .sh_link = 0,
            .sh_info = 0,
            .sh_addralign = 1,
            .sh_entsize = 0,
        },
        Elf32_Shdr{
            .sh_name = 14,
            .sh_type = elf.SHT_PROGBITS,
            .sh_flags = elf.SHF_ALLOC | elf.SHF_EXECINSTR,
            .sh_addr = 0,
            .sh_offset = undefined,
            .sh_size = undefined,
            .sh_link = 0,
            .sh_info = 0,
            .sh_addralign = 4,
            .sh_entsize = 0,
        },
        Elf32_Shdr{
            .sh_name = 9,
            .sh_type = elf.SHT_RELA,
            .sh_flags = elf.SHF_INFO_LINK,
            .sh_addr = 0,
            .sh_offset = undefined,
            .sh_size = undefined,
            .sh_link = 5,
            .sh_info = 2,
            .sh_addralign = 4,
            .sh_entsize = @sizeOf(Elf32_Rela),
        },
        Elf32_Shdr{
            .sh_name = 20,
            .sh_type = elf.SHT_PROGBITS,
            .sh_flags = elf.SHF_ALLOC | elf.SHF_WRITE,
            .sh_addr = 0,
            .sh_offset = undefined,
            .sh_size = undefined,
            .sh_link = 0,
            .sh_info = 0,
            .sh_addralign = 1,
            .sh_entsize = 0,
        },
        Elf32_Shdr{
            .sh_name = 26,
            .sh_type = elf.SHT_SYMTAB,
            .sh_flags = 0,
            .sh_addr = 0,
            .sh_offset = undefined,
            .sh_size = undefined,
            .sh_link = 1,
            .sh_info = 2,
            .sh_addralign = 4,
            .sh_entsize = @sizeOf(Elf32_Sym),
        },
    };
}

fn defaultElfHeader() Elf32_Ehdr {
    return Elf32_Ehdr{
        .e_ident = [_]u8{
            elf.ELFMAG0,
            elf.ELFMAG1,
            elf.ELFMAG2,
            elf.ELFMAG3,
            elf.ELFCLASS32,
            elf.ELFDATA2LSB,
            elf.EV_CURRENT,
            elf.ELFOSABI_SYSV,
            0,
        } ++ [1]u8{0} ** 7,
        .e_type = elf.ET_REL,
        .e_machine = elf.EM_RISCV,
        .e_version = elf.EV_CURRENT,
        .e_entry = undefined,
        .e_phoff = undefined,
        .e_shoff = undefined,
        .e_flags = 0,
        .e_ehsize = @sizeOf(Elf32_Ehdr),
        .e_phentsize = @sizeOf(Elf32_Phdr),
        .e_phnum = undefined,
        .e_shentsize = @sizeOf(Elf32_Shdr),
        .e_shnum = undefined,
        .e_shstrndx = 1,
    };
}

const test_allocator = std.testing.allocator;
const expect = std.testing.expect;

test "slice cast" {
    var x = [_]u16{ 1, 2, 3 };
    const cast = sliceCast(u8, @as([]u16, x[0..2]));
    try expect(@TypeOf(cast) == []u8);
    try expect(cast.len == 4);
}

test "slice cast" {
    var x = [_][3]u8{ .{ 1, 2, 3 }, .{ 4, 5, 6 }, .{ 7, 8, 9 } };
    const cast = sliceCast([2]u8, @as([][3]u8, x[0..2]));
    try expect(@sizeOf(@TypeOf(x)) == 9);
    try expect(@TypeOf(cast) == [][2]u8);
    try expect(cast.len == 3);
}

test "write file" {
    var assembler = try Assembler.init(test_allocator);
    defer assembler.deinit();
    const text = Assembler.textSection;
    _ = try assembler.addSymbolAtEnd(text, "main");
    try assembler.instrAdd(7, 0, 3);
    try assembler.writeToFile("test.o");
}
