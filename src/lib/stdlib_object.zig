const std = @import("std");
const InterpreterError = @import("interpreter.zig").InterpreterError;
const Value = @import("interpreter.zig").Value;
const Interpreter = @import("interpreter.zig").Interpreter;

pub fn initObject(interp: *Interpreter) InterpreterError!void {
    const object = try interp.createObject();

    const objectProto = try interp.createObject();
    try interp.setProperty(object, "prototype", objectProto);

    const objectToString = try interp.createNativeFunction("toString", objectToStringFunc);
    try interp.setProperty(object, "toString", objectToString);

    try interp.envDefine(interp.global_env, "Object", object);
}

pub fn objectToStringFunc(interp: *Interpreter, args: []Value) InterpreterError!Value {
    _ = args;
    return interp.createString("function Object() { [native code] }");
}

pub fn objectKeys(interp: *Interpreter, args: []Value) InterpreterError!Value {
    if (args.len < 1) {
        return InterpreterError.TypeError;
    }

    const obj = args[0];

    if (obj.type != .Object) {
        return try interp.createArray(0);
    }

    const keys = try interp.createArray();
    const objProps = obj.objectProps;
    for (objProps) |prop| {
        const key = prop.key;
        try interp.arrayPush(keys, key);
    }

    return keys;
}
