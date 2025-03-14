const std = @import("std");
const Value = @import("interpreter.zig").Value;
const Interpreter = @import("interpreter.zig").Interpreter;
const InterpreterError = @import("interpreter.zig").InterpreterError;

pub fn arrayToString(interp: *Interpreter, value: Value) InterpreterError![]u8 {
    std.debug.assert(value.type == Value.Type.Array);

    var strBuilder = std.ArrayList(u8).init(interp.allocator);
    var writer: std.ArrayList(u8).Writer = strBuilder.writer();
    writer.writeByte('[');

    const array = value.data.array;
    var first = true;
    for (array) |element| {
        if (first) {
            first = false;
        } else {
            writer.writeByte(',');
        }
        const err = interp.valueToString(element);
        if (err != null) return err;
        const str = element.data.string;
        writer.writeSlice(str);
        interp.allocator.free(str);
    }

    writer.writeByte(']');

    return strBuilder.toOwnedSlice();
}
