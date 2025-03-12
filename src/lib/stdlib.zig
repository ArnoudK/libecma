const std = @import("std");
const Interpreter = @import("interpreter.zig").Interpreter;
const Value = @import("interpreter.zig").Value;
const initJSON = @import("stdlib_json.zig").initJSON;
const stdout = std.io.getStdOut().writer();

/// Initialize the standard library in the interpreter
pub fn initStdLib(interp: *Interpreter) !void {
    try initConsole(interp);
    try initMath(interp);
    try initJSON(interp);
}

pub var rnd: std.Random = undefined;

/// Initialize the console object and its methods
fn initConsole(interp: *Interpreter) !void {
    // Create console object
    const console = try interp.createObject();

    // Create native function with owned string
    const log_func = try interp.createNativeFunction("log", consoleLog);

    // Set console.log
    try interp.setProperty(console, "log", log_func);

    // Add console to global environment
    try interp.envDefine(interp.global_env, "console", console);
}

/// Implementation of console.log
fn consoleLog(interp: *Interpreter, args: []Value) !Value {
    _ = interp;
    for (args, 0..) |arg, i| {
        if (i > 0) {
            std.debug.print(" ", .{});
        }
        try printValue(arg);
    }
    try stdout.print("\n", .{});
    return Value{ .Undefined = {} };
}

/// Helper function to print a Value
fn printValue(value: Value) !void {
    switch (value) {
        .Number => |n| try stdout.print("{d}", .{n}),
        .String => |s| try stdout.print("{s}", .{s}),
        .Boolean => |b| try stdout.print("{}", .{b}),
        .Null => try stdout.print("null", .{}),
        .Undefined => try stdout.print("undefined", .{}),
        .Object => try stdout.print("[object Object]", .{}),
        .Function => try stdout.print("[Function]", .{}),
        .NativeFunction => try stdout.print("[Native Function]", .{}),
        .Array => |a| {
            try stdout.print("[", .{});
            for (a.values, 0..) |v, i| {
                if (i > 0) {
                    try stdout.print(", ", .{});
                }
                try printValue(v);
            }
            try stdout.print("]", .{});
        },
    }
}

pub fn initMath(interp: *Interpreter) !void {
    const math = try interp.createObject();

    const random_func = try interp.createNativeFunction("random", mathRandom);
    rnd = @constCast(&std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp()))).random();
    try interp.setProperty(math, "random", random_func);

    try interp.envDefine(interp.global_env, "Math", math);
}

fn mathRandom(interp: *Interpreter, args: []Value) !Value {
    _ = interp;
    _ = args;
    return Value{ .Number = rnd.float(f64) };
}
