const std = @import("std");
const ast = @import("./ast.zig");
const gc = @import("./garbage_collector.zig");
const stdlib = @import("stdlib.zig");

/// Represents a JavaScript value
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
        body: ast.BlockStatement,
        closure: *gc.JSEnv, // Updated to use JSEnv
    },
    NativeFunction: struct {
        name: []const u8,
        function: *const fn (interp: *Interpreter, args: []Value) anyerror!Value,
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
};

// Remove the Environment struct as we're using JSEnv instead

/// The interpreter state
pub const Interpreter = struct {
    gc: gc.GarbageCollector,
    global_env: *gc.JSEnv, // Changed to JSEnv
    current_env: *gc.JSEnv, // Changed to JSEnv
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        var gc_instance = gc.GarbageCollector.init(allocator);

        // Create the global environment using the GC
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
        // No need to manually free environments as they're handled by the GC
        self.gc.deinit();
    }

    pub fn interpret(self: *Self, program: ast.Program) !void {
        // Evaluate each statement in the program
        for (program.statements.items) |stmt| {
            _ = try self.evaluateStatement(stmt);
        }
    }

    pub fn evaluateStatement(self: *Self, stmt: ast.Statement) !Value {
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

    fn evaluateExpression(self: *Self, expr: ast.Expression) !Value {
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
            // Other expression types would be implemented here
            else => Value{ .Undefined = {} },
        };
    }

    fn evaluateBlockStatement(self: *Self, block: ast.BlockStatement) !Value {
        var result = Value{ .Undefined = {} };
        for (block.statements) |stmt| {
            result = try self.evaluateStatement(stmt);
        }
        return result;
    }

    fn evaluateVariableDeclaration(self: *Self, decl: ast.VariableDeclaration) !Value {
        var value = Value{ .Undefined = {} };
        if (decl.initializer) |initializer| {
            value = try self.evaluateExpression(initializer.*);
        }

        // Define the variable in the current environment
        try self.envDefine(self.current_env, decl.name, value);
        return value;
    }

    fn evaluateFunctionDeclaration(self: *Self, func: ast.FunctionDeclaration) !Value {
        // Duplicate the function parameters using GC allocator
        var params = try self.gc.allocator.alloc([]const u8, func.params.len);

        for (func.params, 0..) |param, i| {
            params[i] = try self.gc.allocator.dupe(u8, param);
        }

        const function_value = Value{ .Function = .{
            .params = params,
            .body = func.body,
            .closure = self.current_env,
        } };

        try self.envDefine(self.current_env, func.name, function_value);
        return function_value;
    }

    fn evaluateIfStatement(self: *Self, if_stmt: ast.IfStatement) !Value {
        const condition = try self.evaluateExpression(if_stmt.condition.*);
        if (condition.truthy()) {
            return self.evaluateStatement(if_stmt.then_branch.*);
        } else if (if_stmt.else_branch) |else_branch| {
            return self.evaluateStatement(else_branch.*);
        }
        return Value{ .Undefined = {} };
    }

    fn evaluateWhileStatement(self: *Self, while_stmt: ast.WhileStatement) anyerror!Value {
        var result = Value{ .Undefined = {} };
        while (true) {
            const condition = try self.evaluateExpression(while_stmt.condition.*);
            if (!condition.truthy()) break;
            result = try self.evaluateStatement(while_stmt.body.*);
        }
        return result;
    }

    fn evaluateForStatement(self: *Self, for_stmt: ast.ForStatement) !Value {
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

    fn evaluateReturnStatement(self: *Self, return_stmt: ast.ReturnStatement) !Value {
        if (return_stmt.value) |value| {
            return self.evaluateExpression(value.*);
        }
        return Value{ .Undefined = {} };
    }

    fn evaluateBinaryExpression(self: *Self, bin: ast.BinaryExpression) !Value {
        const left = try self.evaluateExpression(bin.left.*);
        const right = try self.evaluateExpression(bin.right.*);

        // Simplified for brevity - would need to handle all operators and type coercion
        if (left == .Number and right == .Number) {
            const l = left.Number;
            const r = right.Number;

            return switch (bin.operator.type) {
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
                else => Value{ .Undefined = {} },
            };
        }

        // String concatenation with +
        if (bin.operator.type == .Plus and left == .String and right == .String) {
            return self.concatStrings(left, right);
        }

        return Value{ .Undefined = {} };
    }

    fn evaluateUnaryExpression(self: *Self, unary: ast.UnaryExpression) !Value {
        const right = try self.evaluateExpression(unary.right.*);

        return switch (unary.operator.type) {
            .Minus => if (right == .Number) Value{ .Number = -right.Number } else Value{ .Undefined = {} },
            .ExclamationMark => Value{ .Boolean = !right.truthy() },
            else => Value{ .Undefined = {} },
        };
    }

    fn evaluateAssignmentExpression(self: *Self, assign: ast.AssignmentExpression) !Value {
        const value = try self.evaluateExpression(assign.value.*);
        try self.envSet(self.current_env, assign.name, value);
        return value;
    }

    fn evaluateCallExpression(self: *Self, call: ast.CallExpression) anyerror!Value {
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
                    return error.TooManyArguments;
                }

                // Create a new environment with the function's closure as parent
                const func_env = try self.gc.allocEnv(callee.Function.closure);

                // Set arguments
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
            else => return error.NotCallable,
        }
    }

    fn evaluateMemberAccessExpression(self: *Self, access: ast.MemberAccessExpression) anyerror!Value {
        const object = try self.evaluateExpression(access.object.*);
        return try self.getProperty(object, access.property);
    }

    // Add new function to evaluate array literals
    fn evaluateArrayLiteral(self: *Self, elements: []ast.Expression) anyerror!Value {
        // Create a new array with the correct size
        const array_value = try self.createArray(elements.len);

        // Evaluate each element and add it to the array
        for (elements, 0..) |element, i| {
            const value = try self.evaluateExpression(element);
            try self.setArrayElement(array_value, i, value);
        }

        return array_value;
    }

    pub fn createObject(self: *Self) !Value {
        const js_object = try self.gc.allocObject();
        return Value{ .Object = js_object };
    }

    pub fn setProperty(self: *Self, object: Value, name: []const u8, value: Value) !void {
        if (object != .Object) {
            return error.NotAnObject;
        }

        // Store the name as a GC-managed string if it's not already
        const key = try self.gc.allocString(name);
        try object.Object.values.put(key, value);
    }

    pub fn getProperty(self: *Self, object: Value, name: []const u8) !Value {
        _ = self;
        if (object != .Object) {
            return Value{ .Undefined = {} };
        }

        // Use our input name directly for lookup
        return object.Object.values.get(name) orelse Value{ .Undefined = {} };
    }

    // Create a new array
    pub fn createArray(self: *Self, size: usize) !Value {
        const array = try self.gc.allocArray(size);

        // Initialize array with undefined values
        for (array.values) |*val| {
            val.* = Value{ .Undefined = {} };
        }

        return Value{ .Array = array };
    }

    // Get value from array at index
    pub fn getArrayElement(self: *Self, array: Value, index: usize) !Value {
        _ = self;
        if (array != .Array) {
            return error.NotAnArray;
        }

        if (index >= array.Array.values.len) {
            return Value{ .Undefined = {} };
        }

        return array.Array.values[index];
    }

    // Set value in array at index
    pub fn setArrayElement(self: *Self, array: Value, index: usize, value: Value) !void {
        _ = self;
        if (array != .Array) {
            return error.NotAnArray;
        }

        if (index >= array.Array.values.len) {
            return error.IndexOutOfBounds;
        }

        array.Array.values[index] = value;
    }

    // Get array length
    pub fn getArrayLength(self: *Self, array: Value) !usize {
        _ = self;
        if (array != .Array) {
            return error.NotAnArray;
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
    pub fn createString(self: *Self, str: []const u8) !Value {
        const string = try self.gc.allocString(str);
        return Value{ .String = string };
    }

    // Helper function to concatenate two strings
    pub fn concatStrings(self: *Self, a: Value, b: Value) !Value {
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
    pub fn createNativeFunction(self: *Self, name: []const u8, func: *const fn (interp: *Interpreter, args: []Value) anyerror!Value) !Value {
        const name_copy = try self.gc.allocString(name);

        return Value{ .NativeFunction = .{
            .name = name_copy,
            .function = func,
        } };
    }

    // Helper function to get string content (now simpler, just returns the string)
    pub fn getStringContent(self: *Self, value: Value) ![]const u8 {
        _ = self; // Not needed but kept for consistency
        if (value != .String) return error.NotAString;
        return value.String;
    }

    // Environment access methods
    pub fn envDefine(self: *Self, env: *gc.JSEnv, name: []const u8, value: Value) !void {
        const key = try self.gc.allocString(name);
        try env.values.put(key, value);
    }

    pub fn envGet(self: *Self, env: *gc.JSEnv, name: []const u8) !Value {
        _ = self;
        var current_env = env;

        while (true) {
            if (current_env.values.get(name)) |value| {
                return value;
            }

            if (current_env.parent) |parent| {
                current_env = parent;
            } else {
                return error.UndefinedVariable;
            }
        }
    }

    pub fn envSet(self: *Self, env: *gc.JSEnv, name: []const u8, value: Value) !void {
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
                return error.UndefinedVariable;
            }
        }
    }

    // Create a new environment managed by the GC
    pub fn createEnvironment(self: *Self, parent: ?*gc.JSEnv) !*gc.JSEnv {
        return self.gc.allocEnv(parent);
    }

    // Create a JSVariable and track it with GC
    pub fn createVariable(self: *Self, name: []const u8, value: Value) !Value {
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
        _ = self; // Not needed but kept for consistency
        return variable.value;
    }

    // Set the value of a variable
    pub fn setVariableValue(self: *Self, variable: *gc.JSVariable, value: Value) void {
        _ = self; // Not needed but kept for consistency
        variable.value = value;
    }
};
