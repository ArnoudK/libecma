const std = @import("std");
const ast = @import("./ast.zig");
const gc = @import("./garbage_collector.zig");
const stdlib = @import("stdlib.zig");
const InterpreterError = @import("interp_errors.zig").InterpreterError;
const stderr = std.io.getStdErr().writer();

const arrayToString = @import("stdlib_array.zig").arrayToString;

/// Represents a JavaScript value the interpreter can produce
pub const Value = union(enum) {
    Array: *gc.JSArray,
    Number: f64,
    String: []const u8,
    Boolean: bool,
    Null: void,
    Undefined: void,
    Object: *gc.JSObject,
    Function: struct {
        params: [][]const u8,
        name: []const u8,
        body: ast.BlockStatement,
        closure: *gc.JSEnv,
    },
    NativeFunction: struct {
        name: []const u8,
        function: *const fn (interp: *Interpreter, args: []Value) InterpreterError!Value,
        closure: ?*gc.JSEnv = null, // Optional closure for native functions
    },

    pub fn truthy(self: Value) bool {
        return switch (self) {
            .Number => |n| n != 0,
            .String => |s| s.len > 0, // Check string length directly
            .Boolean => |b| b,
            .Null, .Undefined => false,
            .Object => true,
            .Array => |a| a.values.len > 0, // Arrays with elements are truthy
            .Function => true,
            .NativeFunction => true,
        };
    }

    pub fn toString(self: Value, interp: *Interpreter) InterpreterError!Value {
        return switch (self) {
            .Number => |n| interp.createString(std.fmt.fmt("{f}", .{n})),
            .String => self,
            .Boolean => |b| interp.createString(if (b) "true" else "false"),
            .Null => interp.createString("null"),
            .Undefined => interp.createString("undefined"),
            .Object => interp.createString("[object Object]"),
            .Array => |a| interp.createString(try arrayToString(interp, a)),

            .Function => |f| {
                // @TODO when it's called from accessor it should
                // return the whole function body as well...

                var strBuilder = std.ArrayList(u8).init(interp.allocator);
                var writer: std.ArrayList(u8).Writer = strBuilder.writer();
                writer.writeAll("[Function: ");
                writer.writeSlice(f.name);
                writer.writeByte(']');

                return interp.createString(strBuilder.toOwnedSlice());
            },
            .NativeFunction => |f| {
                var strBuilder = std.ArrayList(u8).init(interp.allocator);
                var writer: std.ArrayList(u8).Writer = strBuilder.writer();
                writer.writeAll("function ");
                writer.writeSlice(f.name);
                writer.writeByte(']');

                return interp.createString(strBuilder.toOwnedSlice());
            },
        };
    }
};

/// The interpreter state
pub const Interpreter = struct {
    gc: gc.GarbageCollector,
    global_env: *gc.JSEnv,
    current_env: *gc.JSEnv,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        var gc_instance = gc.GarbageCollector.init(allocator);
        const global_env_ptr = try gc_instance.allocEnv(null);

        var interpreter = Self{
            .gc = gc_instance,
            .global_env = global_env_ptr,
            .current_env = global_env_ptr,
            .allocator = allocator,
        };

        // Initialize the standard library
        try stdlib.initStdLib(&interpreter);

        return interpreter;
    }

    pub fn deinit(self: *Self) void {
        self.gc.deinit();
    }

    pub fn interpret(self: *Self, program: ast.Program) InterpreterError!void {
        // Evaluate each statement in the program
        for (program.statements.items) |stmt| {
            _ = self.evaluateStatement(stmt) catch |err| {
                switch (err) {
                    InterpreterError.UndefinedVariable => {
                        try stderr.print("Undefined variable\n", .{});
                    },
                    InterpreterError.NotCallable => {
                        try stderr.print("Not callable\n", .{});
                    },
                    InterpreterError.NotAnObject => {
                        try stderr.print("Not an object\n", .{});
                    },
                    InterpreterError.NotAnArray => {
                        try stderr.print("Not an array\n", .{});
                    },
                    InterpreterError.IndexOutOfBounds => {
                        try stderr.print("Index out of bounds\n", .{});
                    },
                    InterpreterError.TooManyArguments => {
                        try stderr.print("Too many arguments\n", .{});
                    },
                    InterpreterError.NotImplemented => {
                        try stderr.print("Not implemented\n", .{});
                    },
                    else => {
                        try stderr.print("Other not handled error: {!}\n", .{err});
                    },
                }
                std.debug.dumpCurrentStackTrace(null);
            };
        }
    }

    pub fn evaluateStatement(self: *Self, stmt: ast.Statement) InterpreterError!Value {
        return switch (stmt) {
            .Expression => |expr| self.evaluateExpression(expr),
            .Block => |block| self.evaluateBlockStatement(block),
            .VariableDeclaration => |decl| self.evaluateVariableDeclaration(decl),
            .FunctionDeclaration => |func| try self.evaluateFunctionDeclaration(func),
            .IfStatement => |if_stmt| try self.evaluateIfStatement(if_stmt),
            .WhileStatement => |while_stmt| try self.evaluateWhileStatement(while_stmt),
            .ForStatement => |for_stmt| self.evaluateForStatement(for_stmt),
            .ReturnStatement => |return_stmt| self.evaluateReturnStatement(return_stmt),
        };
    }

    fn evaluateExpression(self: *Self, expr: ast.Expression) InterpreterError!Value {
        return switch (expr) {
            .Number => |n| Value{ .Number = n },
            .String => |s| try self.createString(s), // Use new GC string creation
            .Boolean => |b| Value{ .Boolean = b },
            .Null => Value{ .Null = {} },
            .Identifier => |name| self.envGet(self.current_env, name),
            .Binary => |bin| self.evaluateBinaryExpression(bin),
            .Unary => |unary| self.evaluateUnaryExpression(unary),
            .Assignment => |assign| self.evaluateAssignmentExpression(assign),
            .Call => |call| try self.evaluateCallExpression(call),
            .MemberAccess => |access| self.evaluateMemberAccessExpression(access),
            .Array => |elements| try self.evaluateArrayLiteral(elements),
            .Object => |properties| try self.evaluateObjectLiteral(properties),
            .IndexAccess => |access| try self.evaluateIndexAccessExpression(access),
            .Ternary => |ternary| try self.evaluateTernaryExpression(ternary),
        };
    }

    fn evaluateBlockStatement(self: *Self, block: ast.BlockStatement) InterpreterError!Value {
        var result = Value{ .Undefined = {} };
        for (block.statements) |stmt| {
            result = try self.evaluateStatement(stmt);
        }
        return result;
    }

    fn evaluateVariableDeclaration(self: *Self, decl: ast.VariableDeclaration) InterpreterError!Value {
        var value = Value{ .Undefined = {} };
        if (decl.initializer) |initializer| {
            value = try self.evaluateExpression(initializer.*);
        }

        // Define the variable in the current environment
        try self.envDefine(self.current_env, decl.name, value);
        return value;
    }

    fn evaluateFunctionDeclaration(self: *Self, func: ast.FunctionDeclaration) InterpreterError!Value {
        // Duplicate the function parameters using GC allocator

        const function_value = Value{ .Function = .{
            .params = func.params,
            .body = func.body,
            .closure = self.current_env,
            .name = func.name,
        } };

        try self.envDefine(self.current_env, func.name, function_value);
        return function_value;
    }

    fn evaluateIfStatement(self: *Self, if_stmt: ast.IfStatement) InterpreterError!Value {
        const condition = try self.evaluateExpression(if_stmt.condition.*);
        if (condition.truthy()) {
            return self.evaluateStatement(if_stmt.then_branch.*);
        } else if (if_stmt.else_branch) |else_branch| {
            return self.evaluateStatement(else_branch.*);
        }
        return Value{ .Undefined = {} };
    }

    fn evaluateWhileStatement(self: *Self, while_stmt: ast.WhileStatement) InterpreterError!Value {
        var result = Value{ .Undefined = {} };
        while (true) {
            const condition = try self.evaluateExpression(while_stmt.condition.*);
            if (!condition.truthy()) break;
            result = try self.evaluateStatement(while_stmt.body.*);
        }
        return result;
    }

    fn evaluateForStatement(self: *Self, for_stmt: ast.ForStatement) InterpreterError!Value {
        var result = Value{ .Undefined = {} };
        if (for_stmt.initializer) |init_statement| {
            _ = try self.evaluateStatement(init_statement.*);
        }
        while (true) {
            if (for_stmt.condition) |cond| {
                const condition = try self.evaluateExpression(cond.*);
                if (!condition.truthy()) break;
            }
            result = try self.evaluateStatement(for_stmt.body.*);
            if (for_stmt.increment) |inc| {
                _ = try self.evaluateExpression(inc.*);
            }
        }
        return result;
    }

    fn evaluateReturnStatement(self: *Self, return_stmt: ast.ReturnStatement) InterpreterError!Value {
        if (return_stmt.value) |value| {
            return self.evaluateExpression(value.*);
        }
        return Value{ .Undefined = {} };
    }

    fn evaluateBinaryExpression(self: *Self, bin: ast.BinaryExpression) InterpreterError!Value {
        const left = try self.evaluateExpression(bin.left.*);
        const right = try self.evaluateExpression(bin.right.*);
        // Simplified for brevity - would need to handle all operators and type coercion
        if (left == .Number and right == .Number) {
            const l = left.Number;
            const r = right.Number;
            return switch (bin.operator.kind) {
                .Plus => Value{ .Number = l + r },
                .Minus => Value{ .Number = l - r },
                .Asterisk => Value{ .Number = l * r },
                .Slash => Value{ .Number = l / r },
                .EqualsEquals => Value{ .Boolean = l == r },
                .ExclamationMarkEquals => Value{ .Boolean = l != r },
                .GreaterThan => Value{ .Boolean = l > r },
                .GreaterThanEquals => Value{ .Boolean = l >= r },
                .LessThan => Value{ .Boolean = l < r },
                .LessThanEquals => Value{ .Boolean = l <= r },
                .Percent => Value{ .Number = @mod(l, r) },
                else => Value{ .Undefined = {} },
            };
        }

        // String concatenation with +
        if (bin.operator.kind == .Plus and left == .String and right == .String) {
            return self.concatStrings(left, right);
        }

        return Value{ .Undefined = {} };
    }

    fn evaluateUnaryExpression(self: *Self, unary: ast.UnaryExpression) InterpreterError!Value {
        const right = try self.evaluateExpression(unary.right.*);
        return switch (unary.operator.kind) {
            .Minus => if (right == .Number) Value{ .Number = -right.Number } else Value{ .Undefined = {} },
            .ExclamationMark => Value{ .Boolean = !right.truthy() },
            else => Value{ .Undefined = {} },
        };
    }

    fn evaluateAssignmentExpression(self: *Self, assign: ast.AssignmentExpression) InterpreterError!Value {
        const value = try self.evaluateExpression(assign.value.*);
        try self.envSet(self.current_env, assign.name, value);
        return value;
    }

    fn evaluateCallExpression(self: *Self, call: ast.CallExpression) InterpreterError!Value {
        const callee = try self.evaluateExpression(call.callee.*);

        // Prepare arguments using GC allocator
        var args = try self.gc.allocator.alloc(Value, call.arguments.len);
        defer self.gc.allocator.free(args);
        for (call.arguments, 0..) |arg, i| {
            args[i] = try self.evaluateExpression(arg);
        }

        // Handle different callable types
        switch (callee) {
            .Function => {
                if (args.len > callee.Function.params.len) {
                    return InterpreterError.TooManyArguments;
                }

                // Create a new environment with the function's closure as parent
                const func_env = try self.gc.allocEnv(callee.Function.closure);
                for (callee.Function.params, 0..) |param_name, i| {
                    const arg_value = if (i < args.len) args[i] else Value{ .Undefined = {} };
                    try self.envDefine(func_env, param_name, arg_value);
                }

                // Save and update environment
                const previous_env = self.current_env;
                self.current_env = func_env;
                defer self.current_env = previous_env;

                // Execute function body
                const result = try self.evaluateBlockStatement(callee.Function.body);
                return result;
            },
            .NativeFunction => |native| {
                return native.function(self, args);
            },
            else => return InterpreterError.NotCallable,
        }
    }

    fn evaluateMemberAccessExpression(self: *Self, access: ast.MemberAccessExpression) InterpreterError!Value {
        const object = try self.evaluateExpression(access.object.*);
        return try self.getProperty(object, access.property);
    }

    // Add new function to evaluate array literals
    fn evaluateArrayLiteral(self: *Self, elements: []ast.Expression) InterpreterError!Value {
        // Create a new array with the correct size
        const array_value = try self.createArray(elements.len);

        // Evaluate each element and add it to the array
        for (elements, 0..) |element, i| {
            const value = try self.evaluateExpression(element);
            try self.setArrayElement(array_value, i, value);
        }
        return array_value;
    }

    fn evaluateObjectLiteral(self: *Self, properties: []ast.ObjectProperty) InterpreterError!Value {
        // Create a new empty object
        const object_value = try self.createObject();

        // Evaluate each property and set it in the object
        for (properties) |property| {
            const value = try self.evaluateExpression(property.value.*);
            try self.setProperty(object_value, property.key, value);
        }

        return object_value;
    }

    fn evaluateIndexAccessExpression(self: *Self, access: ast.IndexAccessExpression) InterpreterError!Value {
        const object = try self.evaluateExpression(access.object.*);
        const index = try self.evaluateExpression(access.index.*);

        // Handle different index types
        if (index == .String) {
            const property = index.String;
            return self.getProperty(object, property);
        } else if (index == .Number and object == .Array) {
            const idx: usize = @intFromFloat(index.Number);
            return self.getArrayElement(object, idx) catch |err| {
                switch (err) {
                    else => return err,
                }
            };
        }

        return Value{ .Undefined = {} };
    }

    fn evaluateTernaryExpression(self: *Self, ternary: ast.TernaryExpression) InterpreterError!Value {
        const condition = try self.evaluateExpression(ternary.condition.*);
        if (condition.truthy()) {
            return self.evaluateExpression(ternary.then_branch.*);
        } else {
            return self.evaluateExpression(ternary.else_branch.*);
        }
    }

    pub fn createObject(self: *Self) InterpreterError!Value {
        const js_object = try self.gc.allocObject();
        return Value{ .Object = js_object };
    }

    pub fn setProperty(self: *Self, object: Value, name: []const u8, value: Value) InterpreterError!void {
        if (object != .Object) {
            return InterpreterError.NotAnObject;
        }

        // Store the name as a GC-managed string if it's not already
        const key = try self.gc.allocString(name);
        try object.Object.values.put(key, value);
    }

    pub fn getProperty(self: *Self, object: Value, name: []const u8) InterpreterError!Value {
        _ = self;
        if (object != .Object) {
            return Value{ .Undefined = {} };
        }

        // Use our input name directly for lookup
        return object.Object.values.get(name) orelse Value{ .Undefined = {} };
    }

    // Create a new array
    pub fn createArray(self: *Self, size: usize) InterpreterError!Value {
        const array = try self.gc.allocArray(size);

        // Initialize array with undefined values
        for (array.values) |*val| {
            val.* = Value{ .Undefined = {} };
        }

        return Value{ .Array = array };
    }

    // Get value from array at index
    pub fn getArrayElement(self: *Self, array: Value, index: usize) InterpreterError!Value {
        _ = self;
        if (array != .Array) {
            return InterpreterError.NotAnArray;
        }

        if (index >= array.Array.values.len) {
            return Value{ .Undefined = {} };
        }

        return array.Array.values[index];
    }

    // Set value in array at index
    pub fn setArrayElement(self: *Self, array: Value, index: usize, value: Value) InterpreterError!void {
        _ = self;
        if (array != .Array) {
            return InterpreterError.NotAnArray;
        }

        if (index >= array.Array.values.len) {
            return InterpreterError.IndexOutOfBounds;
        }

        array.Array.values[index] = value;
    }

    // Get array length
    pub fn getArrayLength(self: *Self, array: Value) InterpreterError!usize {
        _ = self;
        if (array != .Array) {
            return InterpreterError.NotAnArray;
        }

        return array.Array.values.len;
    }

    pub fn collectGarbage(self: *Self) void {
        // Build roots array from environment values
        var roots = std.ArrayList(Value).init(self.allocator);
        defer roots.deinit();

        // Add all values from the global environment
        var it = self.global_env.values.valueIterator();
        while (it.next()) |value| {
            roots.append(value.*) catch continue;
        }

        // Add all values from the current environment if it's not the global
        if (self.current_env != self.global_env) {
            it = self.current_env.values.valueIterator();
            while (it.next()) |value| {
                roots.append(value.*) catch continue;
            }
        }

        // Now collect with the roots
        self.gc.markRoots(roots.items);
        self.gc.collectGarbage() catch {}; // Ignore any collection errors
    }

    // Create a GC-managed string
    pub fn createString(self: *Self, str: []const u8) InterpreterError!Value {
        const string = try self.gc.allocString(str);
        return Value{ .String = string };
    }

    // Helper function to concatenate two strings
    pub fn concatStrings(self: *Self, a: Value, b: Value) InterpreterError!Value {
        if (a != .String or b != .String) return Value{ .Undefined = {} };

        const a_content = a.String;
        const b_content = b.String;

        // Allocate a new buffer
        var buffer = try self.allocator.alloc(u8, a_content.len + b_content.len);
        defer self.allocator.free(buffer);

        @memcpy(buffer[0..a_content.len], a_content);
        @memcpy(buffer[a_content.len..], b_content);

        // Create a GC-managed string
        return self.createString(buffer);
    }

    // Helper function to create a native function
    pub fn createNativeFunction(self: *Self, name: []const u8, func: *const fn (interp: *Interpreter, args: []Value) InterpreterError!Value) InterpreterError!Value {
        const name_copy = try self.gc.allocString(name);

        return Value{ .NativeFunction = .{
            .name = name_copy,
            .function = func,
        } };
    }

    // Helper function to get string content (now simpler, just returns the string)
    pub fn getStringContent(self: *Self, value: Value) InterpreterError![]const u8 {
        _ = self;
        if (value != .String) return InterpreterError.NotAString;
        return value.String;
    }

    // Environment access methods
    pub fn envDefine(self: *Self, env: *gc.JSEnv, name: []const u8, value: Value) InterpreterError!void {
        const key = try self.gc.allocString(name);
        try env.values.put(key, value);
    }

    pub fn envGet(self: *Self, env: *gc.JSEnv, name: []const u8) InterpreterError!Value {
        _ = self;
        var current_env = env;

        while (true) {
            if (current_env.values.get(name)) |value| {
                return value;
            }

            if (current_env.parent) |parent| {
                current_env = parent;
            } else {
                return InterpreterError.UndefinedVariable;
            }
        }
    }

    pub fn envSet(self: *Self, env: *gc.JSEnv, name: []const u8, value: Value) InterpreterError!void {
        _ = self;
        var current_env = env;

        while (true) {
            if (current_env.values.contains(name)) {
                try current_env.values.put(name, value);
                return;
            }

            if (current_env.parent) |parent| {
                current_env = parent;
            } else {
                return InterpreterError.UndefinedVariable;
            }
        }
    }

    // Create a new environment managed by the GC
    pub fn createEnvironment(self: *Self, parent: ?*gc.JSEnv) InterpreterError!*gc.JSEnv {
        return self.gc.allocEnv(parent);
    }

    // Create a JSVariable and track it with GC
    pub fn createVariable(self: *Self, name: []const u8, value: Value) InterpreterError!Value {
        const variable = try self.gc.allocVariable(name, value);
        return Value{ .Variable = variable };
    }

    // Get an existing JSVariable by name
    pub fn getVariable(self: *Self, name: []const u8) ?*gc.JSVariable {
        // Try to get from current environment
        if (self.current_env.values.get(name)) |val| {
            if (val == .Variable) return val.Variable;
        }

        // Try parent environments if it wasn't in the current one
        var env = self.current_env.parent;
        while (env) |parent| {
            if (parent.values.get(name)) |val| {
                if (val == .Variable) return val.Variable;
            }
            env = parent.parent;
        }

        return null;
    }

    // Get the value of a variable
    pub fn getVariableValue(self: *Self, variable: *gc.JSVariable) Value {
        _ = self;
        return variable.value;
    }

    // Set the value of a variable
    pub fn setVariableValue(self: *Self, variable: *gc.JSVariable, value: Value) void {
        _ = self;
        variable.value = value;
    }
};
