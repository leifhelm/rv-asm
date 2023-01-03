const std = @import("std");
const assert = std.debug.assert;
const colors = @import("colors.zig");

pub const IllegalArgumentError = error{ SliceNotInContext, CursorNotInSlice };

pub const Error = struct {
    message: [*:0]const u8,
    context: ?ErrorContext = null,
};

pub const ErrorContext = struct {
    input: [*:0]const u8,
    input_name: [*:0]const u8,
    location: []const u8,
    cursor: usize = 0,
    cursor_message: ?[*:0]const u8 = null,
};

pub fn printError(err: Error) !void {
    try std.io.getStdErr().writer().print(colors.error_fmt ++ " {s}\n", .{err.message});
    if (err.context) |context| {
        try printContext(context);
    }
}
pub const error_code = enum {
    OK,
    LEXER,
    PARSER,
};
fn printLength(arg_integer: usize) usize {
    var integer = arg_integer;
    var size: usize = 1;
    while ((blk: {
        integer /= 10;
        break :blk integer;
    }) != 0) {
        size += 1;
    }
    return size;
}
const Lengths = struct {
    before: []const u8,
    inbetween: []const u8,
    after: []const u8,
    after_cursor: usize,
};
fn lengths(err: *const ErrorContext, line_start: [*:0]const u8, line_end: [*:0]const u8) Lengths {
    const line_length: usize = @ptrToInt(line_end) - @ptrToInt(line_start);
    var l: Lengths = undefined;
    l.inbetween = err.location;
    if(l.inbetween.len == 0){
        l.inbetween.len = 1;
    }
    if(@ptrToInt(line_end) < @ptrToInt(l.inbetween.ptr + l.inbetween.len)){
        l.inbetween.len -= 1;
    }
    assert(@ptrToInt(line_end) >= @ptrToInt(l.inbetween.ptr + l.inbetween.len));
    l.before = line_start[0 .. @ptrToInt(err.location.ptr) - @ptrToInt(line_start)];
    const after_start = l.inbetween.ptr + l.inbetween.len;
    l.after = after_start[0..@ptrToInt(line_end) - @ptrToInt(after_start)];
    assert(line_length == l.before.len + l.inbetween.len + l.after.len);
    l.after_cursor = if(err.location.len == 0) 0 else err.location.len - err.cursor - 1;
    assert(err.location.len == 0 or err.cursor + l.after_cursor + 1 == err.location.len);
    return l;
}
fn printCursorMessage(err: ErrorContext, linenumber_print_length: usize) !void {
    _ = linenumber_print_length;
    if(err.cursor_message) |_| {
        unreachable;
    }
}
fn printContext(err: ErrorContext) !void {
    var linenumber: usize = 1;
    if(err.location.len != 0 and err.cursor >= err.location.len ){
        return IllegalArgumentError.CursorNotInSlice;
    }
    if(err.location.len == 0 and err.cursor != 0){
        return IllegalArgumentError.CursorNotInSlice;
    }
    var line_start: [*:0]const u8 = err.input;
    {
        var i: usize = 0;
        while (@ptrToInt(err.input + i) < @ptrToInt(err.location.ptr)) : (i += 1) {
            var c: u8 = err.input[i];
            if (c == 0) {
                return IllegalArgumentError.SliceNotInContext;
            }
            if (c == '\n') {
                linenumber += 1;
                line_start = err.input + i + 1;
            }
        }
    }
    var line_end = line_start;
    while (line_end[0] != 0 and line_end[0] != '\n') {
        line_end += 1;
    }
    var l: Lengths = lengths(&err, line_start, line_end);
    const column: usize = @ptrToInt(err.location.ptr + err.cursor) - @ptrToInt(line_start) + 1;
    const linenumber_print_length = printLength(linenumber);
    const writer = std.io.getStdErr().writer();
    try printSpaces(writer, linenumber_print_length);
    try writer.print("  " ++ colors.gray ++ "╭╴" ++ colors.clear ++ "{s}:{}:{}\n", .{ err.input_name, linenumber, column });
    try writer.print(" " ++ colors.gray ++ "{}" ++ colors.clear ++ " " ++ colors.gray ++ "│" ++ colors.clear ++ " {s}" ++ colors.red ++ "{s}" ++ colors.clear ++ "{s}\n", .{ linenumber, l.before, l.inbetween, l.after });
    try printSpaces(writer, linenumber_print_length);
    try writer.writeAll("  " ++ colors.gray ++ "│" ++ colors.clear ++ " ");
    try printSpaces(writer, l.before.len);
    try writer.writeAll(colors.red);
    {
        var i: usize = 0;
        while (i < err.cursor) : (i += 1) {
            try writer.writeAll("~");
        }
    }
    try writer.writeAll("^");
    {
        var i: usize = 0;
        while (i < l.after_cursor) : (i += 1) {
            try writer.writeAll("~");
        }
    }
    try writer.writeAll(colors.clear ++ "\n");
    try printCursorMessage(err, linenumber_print_length);
}

fn printSpaces(writer: anytype, n: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        try writer.writeAll(" ");
    }
}

test "simple test" {
    const input: [*:0]const u8 = "hello\nworld\n";
    const err = Error{
        .context = .{
            .input = input,
            .input_name = "test.txt",
            .location = input[7..9],
        },
        .message = "some error",
    };
    try printError(err);
}

test "zero size" {
    const input: [*:0]const u8 = "hello\nworld\n";
    const err = Error{
        .context = .{
            .input = input,
            .input_name = "test.txt",
            .location = input[7..7],
        },
        .message = "some error",
    };
    try printError(err);
}

test "zero size at end of line" {
    const input: [*:0]const u8 = "hello\nworld\n";
    const err = Error{
        .context = .{
            .input = input,
            .input_name = "test.txt",
            .location = input[11..11],
        },
        .message = "some error",
    };
    try printError(err);
}

test "empty line" {
    const input: [*:0]const u8 = "\n\n";
    const err = Error{
        .context = .{
            .input = input,
            .input_name = "test.txt",
            .location = input[1..1],
        },
        .message = "some error",
    };
    try printError(err);
}

test "whole line" {
    const input: [*:0]const u8 = "hello\nworld\n";
    const err = Error{
        .context = .{
            .input = input,
            .input_name = "test.txt",
            .location = input[0..6],
        },
        .message = "some error",
    };
    try printError(err);
}

test "slice at 0" {
    const input: [*:0]const u8 = "hello\nworld\n";
    const err = Error{
        .context = .{
            .input = input,
            .input_name = "test.txt",
            .location = input[12..12],
        },
        .message = "some error",
    };
    try printError(err);
}

test "cursor" {
    const input: [*:0]const u8 = "hello\nworld\n";
    const err = Error{
        .context = .{
            .input = input,
            .input_name = "test.txt",
            .location = input[7..10],
            .cursor = 2,
        },
        .message = "some error",
    };
    try printError(err);
}

test "cursor at end of line" {
    const input: [*:0]const u8 = "hello\nworld\n";
    const err = Error{
        .context = .{
            .input = input,
            .input_name = "test.txt",
            .location = input[7..12],
            .cursor = 4,
        },
        .message = "some error",
    };
    try printError(err);
}

test "cursor centered" {
    const input: [*:0]const u8 = "hello\nworld\n";
    const err = Error{
        .context = .{
            .input = input,
            .input_name = "test.txt",
            .location = input[7..12],
            .cursor = 2,
        },
        .message = "some error",
    };
    try printError(err);
}

test "slice not in context" {
    const expectError = std.testing.expectError;
    const input: [*:0]const u8 = "hello\nworld\n";
    const err = Error{
        .context = .{
            .input = input,
            .input_name = "test.txt",
            .location = "not in input",
        },
        .message = "some error",
    };
    try expectError(IllegalArgumentError.SliceNotInContext, printError(err));
}

test "cursor not in slice" {
    const expectError = std.testing.expectError;
    const input: [*:0]const u8 = "hello\nworld\n";
    const err = Error{
        .context = .{
            .input = input,
            .input_name = "test.txt",
            .location = input[7..10],
            .cursor = 3,
        },
        .message = "some error",
    };
    try expectError(IllegalArgumentError.CursorNotInSlice, printError(err));
}

test "cursor not in zero sized slice" {
    const expectError = std.testing.expectError;
    const input: [*:0]const u8 = "hello\nworld\n";
    const err = Error{
        .context = .{
            .input = input,
            .input_name = "test.txt",
            .location = input[7..7],
            .cursor = 1,
        },
        .message = "some error",
    };
    try expectError(IllegalArgumentError.CursorNotInSlice, printError(err));
}
