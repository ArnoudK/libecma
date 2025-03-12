const std = @import("std");
const Token = @import("token.zig").Token;
const TokenType = @import("tokentypes.zig").TokenType;
const ast = @import("ast.zig");

// Define parser errors
pub const ParserError = error{
    ExpectedToken,
    UnexpectedToken,
    ConstantWithoutInitializer,
    InvalidAssignmentTarget,
    OutOfMemory,
    InvalidNumber,
    InvalidEscapeSequence,
    Overflow,
    CodepointTooLarge,
    InvalidCharacter,
    Utf8CannotEncodeSurrogateHalf,
};

// Define operator precedence levels
const Precedence = enum(u8) {
    None = 0,
    Assignment = 1, // =
    Conditional = 2, // ?:
    LogicalOr = 3, // ||
    LogicalAnd = 4, // &&
    BitwiseOr = 5, // |
    BitwiseXor = 6, // ^
    BitwiseAnd = 7, // &
    Equality = 8, // == !=
    Comparison = 9, // < > <= >=
    Shift = 10, // << >> >>>
    Term = 11, // + -
    Factor = 12, // * / %
    Unary = 13, // ! ~ + - typeof void delete
    Update = 14, // ++ --
    Call = 15, // . [] ()
    Primary = 16,
};

pub const Parser = struct {
    allocator: std.mem.Allocator,
    tokens: []Token,
    index: usize,
    program: ?ast.Program, // Track the allocated program

    pub fn init(allocator: std.mem.Allocator, tokens: []Token) Parser {
        return Parser{
            .allocator = allocator,
            .tokens = tokens,
            .index = 0,
            .program = null, // Initialize to null
        };
    }

    pub fn deinit(self: *Parser) void {
        // Clean up the allocated program if it exists
        if (self.program) |*program| {
            program.deinit();
        }
    }

    pub fn parse(self: *Parser) ParserError!ast.Program {
        var program = ast.Program.init(self.allocator);
        errdefer program.deinit(); // Clean up on error

        while (!self.isAtEnd()) {
            const stmt = try self.parseStatement();
            try program.statements.append(stmt);
        }

        return program;
    }

    fn parseStatement(self: *Parser) ParserError!ast.Statement {
        const current = self.peek();

        return switch (current.type) {
            .Let, .Const, .Var => try self.parseVariableDeclaration(),
            .Function => try self.parseFunctionDeclaration(),
            .If => try self.parseIfStatement(),
            .For => try self.parseForStatement(),
            .While => try self.parseWhileStatement(),
            .Return => try self.parseReturnStatement(),
            .CurlyOpen => try self.parseBlockStatement(),
            else => try self.parseExpressionStatement(),
        };
    }

    fn parseExpressionStatement(self: *Parser) ParserError!ast.Statement {
        const expr = try self.parseExpression();
        _ = try self.consume(.Semicolon);

        return ast.Statement{ .Expression = expr };
    }

    fn parseVariableDeclaration(self: *Parser) ParserError!ast.Statement {
        // Determine variable kind (var, let, or const)
        const token = self.advance();
        const kind = switch (token.type) {
            .Var => ast.VariableKind.Var,
            .Let => ast.VariableKind.Let,
            .Const => ast.VariableKind.Const,
            else => unreachable, // This should never happen due to the caller's check
        };

        // Expect identifier
        const identifier_token = try self.consume(.Identifier);
        const name = identifier_token.value.?;

        // Check for initializer
        var initializer: ?*ast.Expression = null;
        if (self.match(.Equals)) {
            const expr = try self.parseExpression();
            const expr_ptr = try self.allocator.create(ast.Expression);
            expr_ptr.* = expr;
            initializer = expr_ptr;
        } else if (kind == .Const) {
            return ParserError.ConstantWithoutInitializer;
        }

        _ = try self.consume(.Semicolon);

        return ast.Statement{
            .VariableDeclaration = .{
                .name = name,
                .initializer = initializer,
                .kind = kind,
            },
        };
    }

    fn parseFunctionDeclaration(self: *Parser) ParserError!ast.Statement {
        _ = try self.consume(.Function);

        // Parse the function name
        const name_token = try self.consume(.Identifier);
        const name = name_token.value.?;

        // Parse parameter list
        _ = try self.consume(.ParenOpen);
        var params = std.ArrayList([]const u8).init(self.allocator);
        defer params.deinit();

        if (!self.check(.ParenClose)) {
            while (true) {
                const param_token = try self.consume(.Identifier);
                try params.append(param_token.value.?);

                if (!self.match(.Comma)) {
                    break;
                }
            }
        }

        _ = try self.consume(.ParenClose);

        // Parse function body
        const body = try self.parseBlockStatement();

        return ast.Statement{
            .FunctionDeclaration = .{
                .name = name,
                .params = try params.toOwnedSlice(),
                .body = body.Block,
            },
        };
    }

    fn parseBlockStatement(self: *Parser) ParserError!ast.Statement {
        _ = try self.consume(.CurlyOpen);

        var statements = std.ArrayList(ast.Statement).init(self.allocator);
        defer statements.deinit();

        while (!self.check(.CurlyClose) and !self.isAtEnd()) {
            const stmt = try self.parseStatement();
            try statements.append(stmt);
        }

        _ = try self.consume(.CurlyClose);

        return ast.Statement{
            .Block = .{
                .statements = try statements.toOwnedSlice(),
            },
        };
    }

    fn parseIfStatement(self: *Parser) ParserError!ast.Statement {
        _ = try self.consume(.If);
        _ = try self.consume(.ParenOpen);

        const condition = try self.parseExpression();
        const condition_ptr = try self.allocator.create(ast.Expression);
        condition_ptr.* = condition;

        _ = try self.consume(.ParenClose);

        const then_branch = try self.parseStatement();
        const then_branch_ptr = try self.allocator.create(ast.Statement);
        then_branch_ptr.* = then_branch;

        var else_branch: ?*ast.Statement = null;
        if (self.match(.Else)) {
            const else_stmt = try self.parseStatement();
            const else_ptr = try self.allocator.create(ast.Statement);
            else_ptr.* = else_stmt;
            else_branch = else_ptr;
        }

        return ast.Statement{
            .IfStatement = .{
                .condition = condition_ptr,
                .then_branch = then_branch_ptr,
                .else_branch = else_branch,
            },
        };
    }

    fn parseWhileStatement(self: *Parser) ParserError!ast.Statement {
        _ = try self.consume(.While);
        _ = try self.consume(.ParenOpen);

        const condition = try self.parseExpression();
        const condition_ptr = try self.allocator.create(ast.Expression);
        condition_ptr.* = condition;

        _ = try self.consume(.ParenClose);

        const body = try self.parseStatement();
        const body_ptr = try self.allocator.create(ast.Statement);
        body_ptr.* = body;

        return ast.Statement{
            .WhileStatement = .{
                .condition = condition_ptr,
                .body = body_ptr,
            },
        };
    }

    fn parseForStatement(self: *Parser) ParserError!ast.Statement {
        _ = try self.consume(.For);
        _ = try self.consume(.ParenOpen);

        // Parse initializer
        var initializer: ?*ast.Statement = null;
        if (!self.check(.Semicolon)) {
            const init_statement = try if (self.check(.Var) or self.check(.Let) or self.check(.Const))
                self.parseVariableDeclaration()
            else
                self.parseExpressionStatement();

            const init_ptr = try self.allocator.create(ast.Statement);
            init_ptr.* = init_statement;
            initializer = init_ptr;
        } else {
            _ = try self.consume(.Semicolon);
        }

        // Parse condition
        var condition: ?*ast.Expression = null;
        if (!self.check(.Semicolon)) {
            const cond_expr = try self.parseExpression();
            const cond_ptr = try self.allocator.create(ast.Expression);
            cond_ptr.* = cond_expr;
            condition = cond_ptr;
        }
        _ = try self.consume(.Semicolon);

        // Parse increment
        var increment: ?*ast.Expression = null;
        if (!self.check(.ParenClose)) {
            const inc_expr = try self.parseExpression();
            const inc_ptr = try self.allocator.create(ast.Expression);
            inc_ptr.* = inc_expr;
            increment = inc_ptr;
        }
        _ = try self.consume(.ParenClose);

        // Parse body
        const body = try self.parseStatement();
        const body_ptr = try self.allocator.create(ast.Statement);
        body_ptr.* = body;

        return ast.Statement{
            .ForStatement = .{
                .initializer = initializer,
                .condition = condition,
                .increment = increment,
                .body = body_ptr,
            },
        };
    }

    fn parseReturnStatement(self: *Parser) ParserError!ast.Statement {
        _ = try self.consume(.Return);

        var value: ?*ast.Expression = null;
        if (!self.check(.Semicolon)) {
            const expr = try self.parseExpression();
            const expr_ptr = try self.allocator.create(ast.Expression);
            expr_ptr.* = expr;
            value = expr_ptr;
        }

        _ = try self.consume(.Semicolon);

        return ast.Statement{
            .ReturnStatement = .{
                .value = value,
            },
        };
    }

    fn parseExpression(self: *Parser) ParserError!ast.Expression {
        return try self.parsePrecedence(.Assignment);
    }

    fn parsePrecedence(self: *Parser, precedence: Precedence) ParserError!ast.Expression {
        var expr = try self.parsePrefix();

        while (!self.isAtEnd() and @intFromEnum(precedence) <= @intFromEnum(self.getNextPrecedence())) {
            expr = try self.parseInfix(expr);
        }

        return expr;
    }

    fn parsePrefix(self: *Parser) ParserError!ast.Expression {
        const token = self.peek();

        return switch (token.type) {
            .NumericLiteral => self.parseNumberLiteral(),
            .StringLiteral, .TemplateLiteralString => self.parseStringLiteral(),
            .BracketOpen => self.parseArrayLiteral(),
            .CurlyOpen => self.parseObjectLiteral(),
            .BoolLiteral => self.parseBooleanLiteral(),
            .NullLiteral => self.parseNullLiteral(),
            .Identifier => self.parseIdentifier(),
            .ParenOpen => self.parseGrouping(),
            .ExclamationMark, .Tilde, .Plus, .Minus, .Typeof, .Void, .Delete => self.parseUnary(),
            else => ParserError.UnexpectedToken,
        };
    }

    fn parseObjectLiteral(self: *Parser) ParserError!ast.Expression {
        _ = self.advance(); // Consume '{'

        var properties = std.ArrayList(ast.ObjectProperty).init(self.allocator);
        defer properties.deinit();

        if (!self.check(.CurlyClose)) {
            while (true) {
                // Parse property key
                var key: []const u8 = undefined;

                if (self.check(.Identifier)) {
                    const id_token = self.advance();
                    key = id_token.value.?;
                } else if (self.check(.StringLiteral)) {
                    const str_token = self.advance();
                    const str_value = try str_token.parseStringValue(self.allocator);
                    key = str_value;
                } else {
                    return ParserError.UnexpectedToken;
                }

                // Parse property value
                _ = try self.consume(.Colon);
                const value_expr = try self.parseExpression();

                const value_ptr = try self.allocator.create(ast.Expression);
                value_ptr.* = value_expr;

                try properties.append(.{
                    .key = key,
                    .value = value_ptr,
                });

                if (!self.match(.Comma)) {
                    break;
                }

                // Allow trailing comma
                if (self.check(.CurlyClose)) {
                    break;
                }
            }
        }

        _ = try self.consume(.CurlyClose);
        const slice = try properties.toOwnedSlice();
        return ast.Expression{ .Object = slice };
    }

    fn parseArrayLiteral(self: *Parser) ParserError!ast.Expression {
        _ = self.advance(); // Consume '['

        var elements = std.ArrayList(ast.Expression).init(self.allocator);
        defer elements.deinit();

        if (!self.check(.BracketClose)) {
            while (true) {
                const element = try self.parseExpression();
                try elements.append(element);

                if (!self.match(.Comma)) {
                    break;
                }
            }
        }

        _ = try self.consume(.BracketClose);
        const slice = try elements.toOwnedSlice();
        return ast.Expression{ .Array = slice };
    }

    fn parseInfix(self: *Parser, left: ast.Expression) ParserError!ast.Expression {
        const token = self.peek();

        return switch (token.type) {
            .Plus, .Minus, .Asterisk, .Slash, .Percent, .DoubleAsterisk, .EqualsEquals, .ExclamationMarkEquals, .EqualsEqualsEquals, .ExclamationMarkEqualsEquals, .LessThan, .LessThanEquals, .GreaterThan, .GreaterThanEquals, .DoubleAmpersand, .DoublePipe, .Ampersand, .Pipe, .Caret, .ShiftLeft, .ShiftRight, .UnsignedShiftRight, .In, .Instanceof => try self.parseBinary(left),

            .Equals => try self.parseAssignment(left),

            .QuestionMark => try self.parseTernary(left),

            .ParenOpen => try self.parseCall(left),

            .Period => try self.parseMemberAccess(left),
            .BracketOpen => try self.parseIndexAccess(left),

            else => ParserError.UnexpectedToken,
        };
    }

    fn parseNumberLiteral(self: *Parser) ParserError!ast.Expression {
        const token = self.advance();
        const value = try token.parseDoubleValue();
        return ast.Expression{ .Number = value };
    }

    fn parseStringLiteral(self: *Parser) ParserError!ast.Expression {
        const token = self.advance();
        const value = try token.parseStringValue(self.allocator);

        return ast.Expression{ .String = value };
    }

    fn parseBooleanLiteral(self: *Parser) ParserError!ast.Expression {
        const token = self.advance();
        const value = try token.parseBoolValue();
        return ast.Expression{ .Boolean = value };
    }

    fn parseNullLiteral(self: *Parser) ParserError!ast.Expression {
        _ = self.advance(); // Consume 'null'
        return ast.Expression{ .Null = {} };
    }

    fn parseIdentifier(self: *Parser) ParserError!ast.Expression {
        const token = self.advance();
        return ast.Expression{ .Identifier = token.value.? };
    }

    fn parseGrouping(self: *Parser) ParserError!ast.Expression {
        _ = self.advance(); // Consume '('
        const expr = try self.parseExpression();
        _ = try self.consume(.ParenClose);
        return expr;
    }

    fn parseUnary(self: *Parser) ParserError!ast.Expression {
        const operator = self.advance();
        const right = try self.parsePrecedence(.Unary);

        const right_ptr = try self.allocator.create(ast.Expression);
        right_ptr.* = right;

        return ast.Expression{ .Unary = .{
            .operator = operator,
            .right = right_ptr,
        } };
    }

    fn parseBinary(self: *Parser, left: ast.Expression) ParserError!ast.Expression {
        const operator = self.advance();
        const precedence = getTokenPrecedence(operator.type);

        // Parse right side with precedence one level higher to ensure left-associativity
        const right = try self.parsePrecedence(@as(Precedence, @enumFromInt(@intFromEnum(precedence) + 1)));

        const left_ptr = try self.allocator.create(ast.Expression);
        left_ptr.* = left;

        const right_ptr = try self.allocator.create(ast.Expression);
        right_ptr.* = right;

        return ast.Expression{ .Binary = .{
            .left = left_ptr,
            .operator = operator,
            .right = right_ptr,
        } };
    }

    fn parseAssignment(self: *Parser, left: ast.Expression) ParserError!ast.Expression {
        _ = self.advance(); // Consume '='
        const value = try self.parsePrecedence(.Assignment);

        const value_ptr = try self.allocator.create(ast.Expression);
        value_ptr.* = value;

        if (left == .Identifier) {
            return ast.Expression{ .Assignment = .{
                .name = left.Identifier,
                .value = value_ptr,
            } };
        }

        // Clean up allocated expression on error
        self.allocator.destroy(value_ptr);
        return ParserError.InvalidAssignmentTarget;
    }

    fn parseTernary(self: *Parser, condition: ast.Expression) ParserError!ast.Expression {
        _ = self.advance(); // Consume '?'

        const then_expr = try self.parseExpression();

        _ = try self.consume(.Colon);

        const else_expr = try self.parsePrecedence(.Conditional);

        const condition_ptr = try self.allocator.create(ast.Expression);
        condition_ptr.* = condition;

        const then_ptr = try self.allocator.create(ast.Expression);
        then_ptr.* = then_expr;

        const else_ptr = try self.allocator.create(ast.Expression);
        else_ptr.* = else_expr;

        return ast.Expression{ .Ternary = .{
            .condition = condition_ptr,
            .then_branch = then_ptr,
            .else_branch = else_ptr,
        } };
    }

    fn parseCall(self: *Parser, callee: ast.Expression) ParserError!ast.Expression {
        _ = self.advance(); // Consume '('

        var arguments = std.ArrayList(ast.Expression).init(self.allocator);
        defer arguments.deinit();

        if (!self.check(.ParenClose)) {
            while (true) {
                const arg = try self.parseExpression();
                try arguments.append(arg);

                if (!self.match(.Comma)) {
                    break;
                }
            }
        }

        _ = try self.consume(.ParenClose);

        const callee_ptr = try self.allocator.create(ast.Expression);
        callee_ptr.* = callee;

        return ast.Expression{ .Call = .{
            .callee = callee_ptr,
            .arguments = try arguments.toOwnedSlice(),
        } };
    }

    fn parseMemberAccess(self: *Parser, object: ast.Expression) ParserError!ast.Expression {
        _ = self.advance(); // Consume '.'

        const property = try self.consume(.Identifier);

        const object_ptr = try self.allocator.create(ast.Expression);
        object_ptr.* = object;

        return ast.Expression{ .MemberAccess = .{
            .object = object_ptr,
            .property = property.value.?,
        } };
    }

    fn parseIndexAccess(self: *Parser, object: ast.Expression) ParserError!ast.Expression {
        _ = self.advance(); // Consume '['

        const index = try self.parseExpression();

        _ = try self.consume(.BracketClose);

        const object_ptr = try self.allocator.create(ast.Expression);
        object_ptr.* = object;

        const index_ptr = try self.allocator.create(ast.Expression);
        index_ptr.* = index;

        return ast.Expression{ .IndexAccess = .{
            .object = object_ptr,
            .index = index_ptr,
        } };
    }

    fn getNextPrecedence(self: *Parser) Precedence {
        if (self.isAtEnd()) return .None;
        return getTokenPrecedence(self.peek().type);
    }

    fn match(self: *Parser, token_type: TokenType) bool {
        if (self.check(token_type)) {
            _ = self.advance();
            return true;
        }
        return false;
    }

    fn check(self: *Parser, token_type: TokenType) bool {
        if (self.isAtEnd()) return false;
        return self.peek().type == token_type;
    }

    fn advance(self: *Parser) Token {
        if (!self.isAtEnd()) self.index += 1;
        return self.previous();
    }

    fn consume(self: *Parser, token_type: TokenType) ParserError!Token {
        if (self.check(token_type)) return self.advance();
        return ParserError.ExpectedToken;
    }

    fn previous(self: *Parser) Token {
        return self.tokens[self.index - 1];
    }

    fn peek(self: *Parser) Token {
        return self.tokens[self.index];
    }

    fn isAtEnd(self: *Parser) bool {
        return self.peek().type == .Eof or self.index >= self.tokens.len;
    }
};

pub fn getTokenPrecedence(token_type: TokenType) Precedence {
    return switch (token_type) {
        .Equals, .PlusEquals, .MinusEquals, .AsteriskEquals, .SlashEquals, .PercentEquals, .ShiftLeftEquals, .ShiftRightEquals, .UnsignedShiftRightEquals, .AmpersandEquals, .CaretEquals, .PipeEquals, .DoubleAsteriskEquals, .DoubleAmpersandEquals, .DoublePipeEquals, .DoubleQuestionMarkEquals => .Assignment,

        .QuestionMark => .Conditional,

        .DoublePipe => .LogicalOr,
        .DoubleAmpersand => .LogicalAnd,

        .Pipe => .BitwiseOr,
        .Caret => .BitwiseXor,
        .Ampersand => .BitwiseAnd,

        .EqualsEquals, .EqualsEqualsEquals, .ExclamationMarkEquals, .ExclamationMarkEqualsEquals => .Equality,

        .LessThan, .LessThanEquals, .GreaterThan, .GreaterThanEquals, .Instanceof, .In => .Comparison,

        .ShiftLeft, .ShiftRight, .UnsignedShiftRight => .Shift,

        .Plus, .Minus => .Term,

        .Asterisk, .Slash, .Percent, .DoubleAsterisk => .Factor,

        .Period, .BracketOpen, .ParenOpen => .Call,

        else => .None,
    };
}
