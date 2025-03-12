const std = @import("std");
const testing = std.testing;

const Lexer = @import("lexer.zig").Lexer;
const Token = @import("token.zig").Token;
const TokenType = @import("tokentypes.zig").TokenType;

test "skipShebang" {
    const file_contents = "#!/usr/bin/env node\nconsole.log('Hello, world!');";
    const index = @import("lexer.zig").skipShebang(file_contents);
    const expected = 20;
    try testing.expectEqual(expected, index);
}

test "skipShebang_no_shebang" {
    const file_contents = "console.log('Hello, world!');";
    const index = @import("lexer.zig").skipShebang(file_contents);
    const expected = 0;
    try testing.expectEqual(expected, index);
}

test "simple js program" {
    const file_name = "test.js";
    const file_contents = "console.log('Hello, world!');";
    const allocator = std.testing.allocator;

    var lexer = Lexer.init(allocator, allocator, file_name, file_contents);
    defer lexer.deinit();
    try lexer.startLexing();

    const expectedTokens = [_]Token{
        .{ .type = .Identifier, .start = 0, .end = 7, .value = "console" },
        .{ .type = .Period, .start = 7, .end = 8, .value = null },
        .{ .type = .Identifier, .start = 8, .end = 11, .value = "log" },
        .{ .type = .ParenOpen, .start = 11, .end = 12, .value = null },
        .{ .type = .StringLiteral, .start = 12, .end = 27, .value = "'Hello, world!'" },
        .{ .type = .ParenClose, .start = 27, .end = 28, .value = null },
        .{ .type = .Semicolon, .start = 28, .end = 29, .value = null },
        .{ .type = .Eof, .start = 29, .end = 29, .value = null },
    };

    try testing.expectEqual(@as(usize, expectedTokens.len), lexer.tokens.items.len);
    for (expectedTokens, 0..) |expectedToken, i| {
        const actualToken = lexer.tokens.items[i];
        try testing.expectEqualDeep(expectedToken, actualToken);
    }
}
