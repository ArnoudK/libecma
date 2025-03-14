const std = @import("std");
const Token = @import("token.zig").Token;
const TokenType = @import("tokentypes.zig").TokenType;
const Lexer = @import("lexer.zig").Lexer;

pub fn parseTemplateString(lexer: *Lexer) !bool {
    const start = lexer.index;
    var isTemplateString = false;
    var areWeInTemplateString = false;

    var i: usize = 1;

    while (i < lexer.file_contents.len) : (i += 1) {
        if (start + i >= lexer.file_contents.len) {
            break;
        }

        const c = lexer.file_contents[start + i];

        switch (c) {
            '`' => {
                if (areWeInTemplateString) {
                    const end = start + i + 1;
                    const token = Token{ .kind = TokenType.TemplateLiteralEnd, .start = end - 1, .end = end, .value = null };
                    try lexer.tokens.append(token);
                    lexer.index = end;
                    areWeInTemplateString = false;
                    return true;
                } else {
                    const end = start + i;
                    const value = lexer.file_contents[start..end];
                    const token = Token{ .kind = TokenType.TemplateLiteralString, .start = start, .end = end, .value = value };
                    try lexer.tokens.append(token);
                    lexer.index = end + 1;
                    return true;
                }
            },

            '$' => {
                if (i + 1 < lexer.file_contents.len and start + i + 1 < lexer.file_contents.len and lexer.file_contents[start + i + 1] == '{') {
                    const end = start + i;

                    if (!isTemplateString) {
                        const token = Token{ .kind = TokenType.TemplateLiteralStart, .start = start - 1, .end = start, .value = null };
                        try lexer.tokens.append(token);
                    }
                    if (end > start + 1 and !areWeInTemplateString) {
                        const literal_value = lexer.file_contents[start..end];
                        const literal_token = Token{ .kind = TokenType.TemplateLiteralString, .start = start, .end = end, .value = literal_value };
                        try lexer.tokens.append(literal_token);
                    }

                    // Add the interpolation start token for ${
                    const expr_start_token = Token{ .kind = TokenType.TemplateLiteralExprStart, .start = end, .end = end + 2, .value = null };
                    try lexer.tokens.append(expr_start_token);

                    // Move past ${
                    lexer.index = end + 2;
                    i += 1;

                    // Find the matching closing brace for this interpolation
                    const expr_start = end + 2;
                    var expr_end = expr_start;
                    var brace_count: usize = 1;

                    while (expr_end < lexer.file_contents.len and brace_count > 0) {
                        if (lexer.file_contents[expr_end] == '{') {
                            brace_count += 1;
                        } else if (lexer.file_contents[expr_end] == '}') {
                            brace_count -= 1;
                        } else if (lexer.file_contents[expr_end] == '`') {
                            // Unterminated expression in template
                            const error_token = Token{ .kind = TokenType.UnterminatedTemplateLiteral, .start = start, .end = expr_end, .value = lexer.file_contents[start..expr_end] };
                            try lexer.tokens.append(error_token);
                            lexer.index = expr_end;
                            return false;
                        }
                        if (brace_count > 0) expr_end += 1;
                    }

                    if (brace_count > 0) {
                        // Unterminated expression
                        const error_token = Token{ .kind = TokenType.UnterminatedTemplateLiteral, .start = start, .end = lexer.file_contents.len, .value = lexer.file_contents[start..lexer.file_contents.len] };
                        try lexer.tokens.append(error_token);
                        lexer.index = lexer.file_contents.len;
                        return false;
                    }

                    // Now parse the expression content with a temporary lexer
                    const expr_text = lexer.file_contents[expr_start..expr_end];
                    var temp_lexer = Lexer.init(lexer.temp_allocator, lexer.temp_allocator, "temp", expr_text);
                    defer temp_lexer.deinit();
                    // we need to handle errors... @TODO @BUG
                    try temp_lexer.startLexing();

                    // Add tokens from the temp lexer with adjusted positions
                    for (temp_lexer.tokens.items) |token| {
                        if (token.kind == TokenType.Eof) continue;

                        var adjusted_token = token;
                        adjusted_token.start += expr_start;
                        adjusted_token.end += expr_start;

                        try lexer.tokens.append(adjusted_token);
                    }

                    // Add the closing expression token
                    const expr_end_token = Token{ .kind = TokenType.TemplateLiteralExprEnd, .start = expr_end, .end = expr_end + 1, .value = null };
                    try lexer.tokens.append(expr_end_token);

                    // Update position and continue parsing the rest of the template
                    lexer.index = expr_end + 1;
                    i = expr_end - start;
                    isTemplateString = true;
                    areWeInTemplateString = true;
                    continue;
                }
            },

            '{' => {
                // Just handle as a regular character in the template string
            },

            '}' => {
                // Just handle as a regular character in the template string
            },

            '\\' => {
                if (i + 1 < lexer.file_contents.len) {
                    i += 1; // Skip the escaped character
                } else {
                    const value = lexer.file_contents[start..lexer.file_contents.len];
                    const token = Token{ .kind = TokenType.UnterminatedTemplateLiteral, .start = start, .end = lexer.file_contents.len, .value = value };
                    try lexer.tokens.append(token);
                    lexer.index = lexer.file_contents.len;
                    return false;
                }
            },

            else => {},
        }
    }

    const value = lexer.file_contents[start..lexer.file_contents.len];
    const token = Token{ .kind = TokenType.UnterminatedTemplateLiteral, .start = start, .end = lexer.file_contents.len, .value = value };
    try lexer.tokens.append(token);
    lexer.index = lexer.file_contents.len;
    return false;
}

test "template string no interpolation" {
    const testing = std.testing;
    const file_name = "test.js";
    const file_contents = "`hello world`";
    const allocator = std.testing.allocator;

    var lexer = Lexer.init(allocator, allocator, file_name, file_contents);
    defer lexer.deinit();

    try lexer.startLexing();

    const expectedTokens = [_]Token{
        .{ .type = TokenType.TemplateLiteralString, .start = 1, .end = 12, .value = "hello world" },
        .{ .type = TokenType.Eof, .start = 13, .end = 13, .value = null },
    };

    // std.debug.print("\nexp: {}\n\nact: {}\n", .{ expectedTokens[0], lexer.tokens.items[0] });

    try testing.expectEqual(@as(usize, expectedTokens.len), lexer.tokens.items.len);
    for (expectedTokens, 0..) |expectedToken, i| {
        const actualToken = lexer.tokens.items[i];

        try testing.expectEqualDeep(expectedToken, actualToken);
    }
}

test "template string with interpolation" {
    const testing = std.testing;
    const file_name = "test.js";
    const file_contents = "`text${arg}`";
    const allocator = std.testing.allocator;

    var lexer = Lexer.init(allocator, allocator, file_name, file_contents);
    defer lexer.deinit();

    try lexer.startLexing();

    // for (lexer.tokens.items, 0..) |token, i| {
    //     std.debug.print("\n{d}:{}\n", .{ i, token });
    // }

    const expectedTokens = [_]Token{
        .{ .type = TokenType.TemplateLiteralStart, .start = 0, .end = 1, .value = null },
        .{ .type = TokenType.TemplateLiteralString, .start = 1, .end = 5, .value = "text" },
        .{ .type = TokenType.TemplateLiteralExprStart, .start = 5, .end = 7, .value = null },
        .{ .type = TokenType.Identifier, .start = 7, .end = 10, .value = "arg" },
        .{ .type = TokenType.TemplateLiteralExprEnd, .start = 10, .end = 11, .value = null },
        .{ .type = TokenType.TemplateLiteralEnd, .start = 11, .end = 12, .value = null },
        .{ .type = TokenType.Eof, .start = 12, .end = 12, .value = null },
    };

    try testing.expectEqual(@as(usize, expectedTokens.len), lexer.tokens.items.len);
    for (expectedTokens, 0..) |expectedToken, i| {
        const actualToken = lexer.tokens.items[i];

        // std.debug.print("\nactual:\n\t{}\nexp:\n\t{}\n", .{ actualToken, expectedToken });

        try testing.expectEqualDeep(expectedToken, actualToken);
    }
}

test "template advanced interpolation" {
    const testing = std.testing;
    const file_name = "test.js";
    const file_contents = "`text${arg1 + arg2}text${arg2}text`";

    var lexer = Lexer.init(testing.allocator, testing.allocator, file_name, file_contents);
    defer lexer.deinit();
    try lexer.startLexing();
    std.debug.print("\n{any}\n", .{lexer.tokens.items});
}
