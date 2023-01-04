const std = @import("std");
const process = std.process;
const Allocator = std.mem.Allocator;

const colors = @import("colors.zig");
const Assembler = @import("asm.zig").Assembler;

const ApplicationError = error{FatalError};

const stderr = std.io.getStdErr().writer();

const ExitCode = enum(u8) {
    Ok = 0,
    CliUsageError = 64,
    CannotOpenInput = 66,
    LeakedMemory = 199,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked) {
            _ = stderr.write("\nLEAKED MEMORY\n") catch {};
            exit(.LeakedMemory);
        }
    }
    const allocator = gpa.allocator();
    const args = try process.argsAlloc(allocator);
    defer allocator.free(args);
    if (args.len != 2) {
        stderr.writeAll("usage: rv-asm <FILE>\n") catch {};
        exit(.CliUsageError);
    }
    var file_name = args[1];

    var input: []u8 = try loadFile(allocator, file_name);
    defer allocator.free(input);
    _ = input;

    var assembler = try Assembler.init(allocator);
    defer assembler.deinit();
    var text = Assembler.textSection;
    _ = try assembler.addSymbolAtEnd(text, "loop");
    try assembler.instrAdd(4, 1, 1);
    _ = try assembler.addSymbolAtEnd(text, null);
    try assembler.instrAdd(7, 8, 9);
    try assembler.writeToFile("a.o");
}

pub fn loadFile(allocator: Allocator, file_name: []const u8) ![]u8 {
    return std.fs.cwd().readFileAlloc(allocator, file_name, std.math.maxInt(usize)) catch |err| {
        switch (err) {
            error.OutOfMemory => return err,
            else => {
                stderr.print(colors.error_fmt ++ " the file " ++ colors.blue_underline ++ "{s}" ++ colors.clear ++ " could not be opened.\n", .{file_name}) catch {};
                exit(.CannotOpenInput);
            },
        }
    };
}

fn exit(exit_code: ExitCode) noreturn {
    process.exit(@enumToInt(exit_code));
}
