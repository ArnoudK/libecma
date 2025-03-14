const std = @import("std");
const testing = std.testing;
const Token = @import("token.zig").Token;
const TokenType = @import("tokentypes.zig").TokenType;
const Parser = @import("./parser.zig").Parser;
const Lexer = @import("lexer.zig").Lexer;
const ast = @import("./ast.zig");

fn testParse(source: []const u8) !ast.Program {
    // Set up allocator
    var gpa = std.heap.GeneralPurposeAllocator().init();
    defer _ = gpa.deinit();
    const allocator = &gpa.allocator();

    // Tokenize the input
    var lexer = try Lexer.init(allocator, source);
    defer lexer.deinit();

    var tokens = std.ArrayList(Token).init(allocator.*);
    defer tokens.deinit();

    // Collect all tokens
    while (true) {
        const token = try lexer.nextToken();
        try tokens.append(token);
        if (token.kind == .Eof) break;
    }

    // Parse the tokens
    var parser = Parser.createParser(allocator, tokens.items);
    return parser.parse();
}

test "Parse variable declaration" {
    const source = "const x = 5;";
    var program = try testParse(source);
    defer program.deinit();

    try testing.expectEqual(@as(usize, 1), program.statements.items.len);

    const stmt = program.statements.items[0];
    try testing.expect(stmt == .VariableDeclaration);

    const varDecl = stmt.VariableDeclaration;
    try testing.expectEqualStrings("x", varDecl.name);
    try testing.expect(varDecl.kind == .Const);

    try testing.expect(varDecl.initializer.?.* == .Number);
    try testing.expectEqual(@as(f64, 5), varDecl.initializer.?.*.Number);
}

test "Parse function declaration" {
    const source =
        \\function add(a, b) {
        \\  return a + b;
        \\}
    ;

    var program = try testParse(source);
    defer program.deinit();

    try testing.expectEqual(@as(usize, 1), program.statements.items.len);

    const stmt = program.statements.items[0];
    try testing.expect(stmt == .FunctionDeclaration);

    const funcDecl = stmt.FunctionDeclaration;
    try testing.expectEqualStrings("add", funcDecl.name);
    try testing.expectEqual(@as(usize, 2), funcDecl.params.len);
    try testing.expectEqualStrings("a", funcDecl.params[0]);
    try testing.expectEqualStrings("b", funcDecl.params[1]);

    // Check function body
    try testing.expectEqual(@as(usize, 1), funcDecl.body.statements.len);

    const returnStmt = funcDecl.body.statements[0];
    try testing.expect(returnStmt == .ReturnStatement);

    // Check return expression (a + b)
    try testing.expect(returnStmt.ReturnStatement.value.?.* == .Binary);
}

test "Parse if statement" {
    const source =
        \\if (x > 5) {
        \\  return true;
        \\} else {
        \\  return false;
        \\}
    ;

    var program = try testParse(source);
    defer program.deinit();

    try testing.expectEqual(@as(usize, 1), program.statements.items.len);

    const stmt = program.statements.items[0];
    try testing.expect(stmt == .IfStatement);

    const ifStmt = stmt.IfStatement;
    try testing.expect(ifStmt.condition.* == .Binary);
    try testing.expect(ifStmt.then_branch.* == .Block);
    try testing.expect(ifStmt.else_branch.?.* == .Block);
}

test "Parse complex expression" {
    const source = "x = a + b * (c - d);";

    var program = try testParse(source);
    defer program.deinit();

    try testing.expectEqual(@as(usize, 1), program.statements.items.len);

    const stmt = program.statements.items[0];
    try testing.expect(stmt == .Expression);

    const expr = stmt.Expression;
    try testing.expect(expr == .Assignment);

    const assignment = expr.Assignment;
    try testing.expectEqualStrings("x", assignment.name);
}

test "Parse object property access" {
    const source = "console.log(obj.property);";

    var program = try testParse(source);
    defer program.deinit();

    try testing.expectEqual(@as(usize, 1), program.statements.items.len);

    const stmt = program.statements.items[0];
    try testing.expect(stmt == .Expression);

    const expr = stmt.Expression;
    try testing.expect(expr == .Call);

    const call = expr.Call;
    try testing.expect(call.callee.* == .MemberAccess);
    try testing.expectEqual(@as(usize, 1), call.arguments.len);
    try testing.expect(call.arguments[0] == .MemberAccess);
}
