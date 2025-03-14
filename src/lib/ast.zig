const std = @import("std");
const Token = @import("./token.zig").Token;

pub const Program = struct {
    statements: std.ArrayList(Statement),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Program {
        return Program{
            .statements = std.ArrayList(Statement).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Program) void {
        // Free all statements in the program
        for (self.statements.items) |*stmt| {
            self.freeStatement(stmt);
        }
        self.statements.deinit();
    }

    fn freeStatement(self: *Program, stmt: *Statement) void {
        switch (stmt.*) {
            .Expression => |expr| self.freeExpression(@constCast(&expr)),
            .Block => |*block| {
                for (block.statements) |*block_stmt| {
                    self.freeStatement(block_stmt);
                }
                self.allocator.free(block.statements);
            },
            .VariableDeclaration => |*var_decl| {
                if (var_decl.initializer) |init_expr| {
                    self.freeExpression(init_expr);
                    self.allocator.destroy(init_expr);
                }
            },
            .FunctionDeclaration => |*func_decl| {
                // self.allocator.free(func_decl.name);

                // for (func_decl.params) |param| {
                //     std.debug.print("TRYING TO FREE: {s}\n", .{param});
                //     self.allocator.free(param);
                // }

                self.allocator.free(func_decl.params);

                for (func_decl.body.statements) |*body_stmt| {
                    self.freeStatement(body_stmt);
                }
                self.allocator.free(func_decl.body.statements);
            },
            .IfStatement => |*if_stmt| {
                self.freeExpression(if_stmt.condition);
                self.allocator.destroy(if_stmt.condition);

                self.freeStatement(if_stmt.then_branch);
                self.allocator.destroy(if_stmt.then_branch);

                if (if_stmt.else_branch) |else_stmt| {
                    self.freeStatement(else_stmt);
                    self.allocator.destroy(else_stmt);
                }
            },
            .WhileStatement => |*while_stmt| {
                self.freeExpression(while_stmt.condition);
                self.allocator.destroy(while_stmt.condition);

                self.freeStatement(while_stmt.body);
                self.allocator.destroy(while_stmt.body);
            },
            .ForStatement => |*for_stmt| {
                if (for_stmt.initializer) |init_stmt| {
                    self.freeStatement(init_stmt);
                    self.allocator.destroy(init_stmt);
                }

                if (for_stmt.condition) |cond_expr| {
                    self.freeExpression(cond_expr);
                    self.allocator.destroy(cond_expr);
                }

                if (for_stmt.increment) |inc_expr| {
                    self.freeExpression(inc_expr);
                    self.allocator.destroy(inc_expr);
                }

                self.freeStatement(for_stmt.body);
                self.allocator.destroy(for_stmt.body);
            },
            .ReturnStatement => |*ret_stmt| {
                if (ret_stmt.value) |val_expr| {
                    self.freeExpression(val_expr);
                    self.allocator.destroy(val_expr);
                }
            },
        }
    }

    pub fn freeExpression(self: *Program, expr: *Expression) void {
        switch (expr.*) {
            .Assignment => |*assignment| {
                self.freeExpression(assignment.value);
                self.allocator.destroy(assignment.value);
            },
            .Binary => |*binary| {
                self.freeExpression(binary.left);
                self.allocator.destroy(binary.left);

                self.freeExpression(binary.right);
                self.allocator.destroy(binary.right);
            },
            .Unary => |*unary| {
                self.freeExpression(unary.right);
                self.allocator.destroy(unary.right);
            },
            .Call => |*call| {
                self.freeExpression(call.callee);
                self.allocator.destroy(call.callee);

                for (call.arguments) |*arg| {
                    self.freeExpression(arg);
                }
                self.allocator.free(call.arguments);
            },
            .MemberAccess => |*member| {
                self.freeExpression(member.object);
                self.allocator.destroy(member.object);
            },
            .IndexAccess => |*index| {
                self.freeExpression(index.object);
                self.allocator.destroy(index.object);

                self.freeExpression(index.index);
                self.allocator.destroy(index.index);
            },
            .Ternary => |*ternary| {
                self.freeExpression(ternary.condition);
                self.allocator.destroy(ternary.condition);

                self.freeExpression(ternary.then_branch);
                self.allocator.destroy(ternary.then_branch);

                self.freeExpression(ternary.else_branch);
                self.allocator.destroy(ternary.else_branch);
            },
            .String => |str| {
                self.allocator.free(str);
            },
            .Number, .Boolean, .Null, .Identifier => {
                // These types don't own memory that needs to be freed
                // Note: We assume Identifier strings are owned elsewhere
                // it should be the lexer / file_contents
            },
            .Object => |object| {
                for (object) |*property| {
                    // Free key if it's dynamically allocated (optional, depends on your implementation)
                    self.freeExpression(property.value);
                    self.allocator.destroy(property.value);
                }
                self.allocator.free(object);
            },
            .Array => |array| {
                for (array) |*val| {
                    self.freeExpression(val);
                }
                self.allocator.free(array);
            },
        }
    }
};

pub const Statement = union(enum) {
    Expression: Expression,
    Block: BlockStatement,
    VariableDeclaration: VariableDeclaration,
    FunctionDeclaration: FunctionDeclaration,
    IfStatement: IfStatement,
    WhileStatement: WhileStatement,
    ForStatement: ForStatement,
    ReturnStatement: ReturnStatement,
};

pub const BlockStatement = struct {
    statements: []Statement,
};

pub const VariableDeclaration = struct {
    name: []const u8,
    initializer: ?*Expression,
    kind: VariableKind,
};

pub const VariableKind = enum {
    Var,
    Let,
    Const,
};

pub const FunctionDeclaration = struct {
    name: []const u8,
    params: [][]const u8,
    body: BlockStatement,
};

pub const IfStatement = struct {
    condition: *Expression,
    then_branch: *Statement,
    else_branch: ?*Statement,
};

pub const WhileStatement = struct {
    condition: *Expression,
    body: *Statement,
};

pub const ForStatement = struct {
    initializer: ?*Statement,
    condition: ?*Expression,
    increment: ?*Expression,
    body: *Statement,
};

pub const ReturnStatement = struct {
    value: ?*Expression,
};

pub const Expression = union(enum) {
    Assignment: AssignmentExpression,
    Binary: BinaryExpression,
    Unary: UnaryExpression,
    Call: CallExpression,
    MemberAccess: MemberAccessExpression,
    IndexAccess: IndexAccessExpression,
    Ternary: TernaryExpression,
    Number: f64,
    String: []u8,
    Boolean: bool,
    Null: void,
    Identifier: []const u8,
    Array: []Expression,
    Object: []ObjectProperty,
};

pub const AssignmentExpression = struct {
    name: []const u8,
    value: *Expression,
};

pub const BinaryExpression = struct {
    left: *Expression,
    operator: Token,
    right: *Expression,
};

pub const UnaryExpression = struct {
    operator: Token,
    right: *Expression,
};

pub const CallExpression = struct {
    callee: *Expression,
    arguments: []Expression,
};

pub const MemberAccessExpression = struct {
    object: *Expression,
    property: []const u8,
};

pub const IndexAccessExpression = struct {
    object: *Expression,
    index: *Expression,
};

pub const TernaryExpression = struct {
    condition: *Expression,
    then_branch: *Expression,
    else_branch: *Expression,
};

pub const ObjectProperty = struct {
    key: []const u8,
    value: *Expression,
};
