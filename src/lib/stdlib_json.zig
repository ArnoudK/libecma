const std = @import("std");
const stdout = std.io.getStdOut().writer();
const Value = @import("interpreter.zig").Value;
const Interpreter = @import("interpreter.zig").Interpreter;
const InterpreterError = @import("interp_errors.zig").InterpreterError;

pub fn initJSON(interp: *Interpreter) InterpreterError!void {
    const json = try interp.createObject();

    const stringify = try interp.createNativeFunction("stringify", jsonStringify);
    try interp.setProperty(json, "stringify", stringify);

    try interp.envDefine(interp.global_env, "JSON", json);
}

pub fn jsonStringify(interp: *Interpreter, args: []Value) InterpreterError!Value {
    if (args.len < 1) {
        return interp.createString("undefined");
    }

    var builder = std.ArrayList(u8).init(interp.allocator);
    defer builder.deinit();
    const writer = builder.writer();

    const replacer: ?[][]const u8 = null; // will be done later
    var space: ?[]const u8 = null;

    if (args.len > 1) {
        const arg1 = args[1];
        if (arg1 != .Null) {
            return error.NotImplemented;
        }
    }
    _ = replacer;
    if (args.len > 2) {
        const arg2 = args[2];
        switch (arg2) {
            .String => |s| space = s,
            .Number => |n| {
                if (n < 0) {
                    space = null;
                } else if (n > 10) {
                    space = "          ";
                } else {
                    const spaces = [_]u8{ ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' ' };
                    const space_len: u8 = @truncate(@as(u64, @intCast(@as(i64, (@intFromFloat(n))))));
                    space = spaces[0..space_len];
                }
            },
            else => return error.InvalidArgument,
        }
    }
    try valueToJson(writer, args[0], space, 0); // directly into the writer

    const jsonString = try interp.createString(builder.items);
    return jsonString;
}

fn writeIndent(writer: std.ArrayList(u8).Writer, indent: []const u8, level: usize) InterpreterError!void {
    var i: usize = 0;
    while (i < level) : (i += 1) {
        try writer.writeAll(indent);
    }
}

pub fn valueToJson(writer: std.ArrayList(u8).Writer, value: Value, indent: ?[]const u8, level: usize) InterpreterError!void {
    // Helper function to write indentation

    switch (value) {
        .Number => |n| try writer.print("{d}", .{n}),
        .String => |s| {
            try writer.writeByte('"');
            try writer.writeAll(s);
            try writer.writeByte('"');
        },
        .Boolean => |b| try writer.print("{}", .{b}),
        .Null => try writer.print("null", .{}),
        .Undefined => try writer.print("undefined", .{}),
        .Object => |o| {
            if (o.values.count() == 0) {
                try writer.writeAll("{}");
                return;
            }

            try writer.writeByte('{');

            if (indent) |ind| {
                const next_level = level + 1;

                var first = true;
                var iter = o.values.iterator();
                while (iter.next()) |prop| {
                    if (first) {
                        first = false;
                    } else {
                        try writer.writeByte(',');
                    }
                    try writer.writeByte('\n');
                    try writeIndent(writer, ind, next_level);
                    try writer.print("\"{s}\": ", .{prop.key_ptr.*});
                    try valueToJson(writer, prop.value_ptr.*, ind, next_level);
                }
                try writer.writeByte('\n');
                try writeIndent(writer, ind, level);
            } else {
                var first = true;
                var iter = o.values.iterator();
                while (iter.next()) |prop| {
                    if (first) {
                        first = false;
                    } else {
                        try writer.writeAll(",");
                    }
                    try writer.print("\"{s}\":", .{prop.key_ptr.*});
                    try valueToJson(writer, prop.value_ptr.*, null, 0);
                }
            }

            try writer.writeByte('}');
        },
        .Array => |a| {
            if (a.values.len == 0) {
                try writer.writeAll("[]");
                return;
            }

            try writer.writeByte('[');

            if (indent) |ind| {
                const next_level = level + 1;

                var first = true;
                for (a.values) |v| {
                    if (first) {
                        first = false;
                    } else {
                        try writer.writeByte(',');
                    }
                    try writer.writeByte('\n');
                    try writeIndent(writer, ind, next_level);
                    try valueToJson(writer, v, ind, next_level);
                }
                try writer.writeByte('\n');
                try writeIndent(writer, ind, level);
            } else {
                var first = true;
                for (a.values) |v| {
                    if (first) {
                        first = false;
                    } else {
                        try writer.writeAll(",");
                    }
                    try valueToJson(writer, v, null, 0);
                }
            }

            try writer.writeByte(']');
        },
        .Function => try writer.writeAll("[Function]"),
        .NativeFunction => try writer.writeAll("[Native Function]"),
    }
}
