const std = @import("std");

const Token = @import("token.zig").Token;
const TokenType = @import("tokentypes.zig").TokenType;

const ArrayListToken = std.ArrayList(Token);
const parseTemplateString = @import("lex_template.zig").parseTemplateString;
const lexNumber = @import("lex_number.zig").lexNumber;

pub const Lexer = struct {
    // lots of short-lived allocations
    temp_allocator: std.mem.Allocator,
    // long-lived allocations (arena reccomended)
    // all tokens are allocated here
    long_allocator: std.mem.Allocator,

    tokens: ArrayListToken,

    file_name: []const u8,
    file_contents: []const u8,

    // index in characters
    index: usize = 0,

    pub fn init(temp_allocator: std.mem.Allocator, long_allocator: std.mem.Allocator, file_name: []const u8, file_contents: []const u8) @This() {
        const start: usize = skipShebang(file_contents);
        const tokens = ArrayListToken.init(long_allocator);
        return .{
            .temp_allocator = temp_allocator,
            .long_allocator = long_allocator,
            .file_name = file_name,
            .file_contents = file_contents,
            .index = start,
            .tokens = tokens,
        };
    }
    pub fn deinit(self: @This()) void {
        self.tokens.deinit();
    }

    pub fn startLexing(self: *@This()) LexerError!void {
        while (try self.continueLexing()) {}
    }

    pub fn skipWhitespace(self: *@This()) void {
        while (self.index < self.file_contents.len) : (self.index += 1) {
            const c = self.file_contents[self.index];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                continue;
            }
            break;
        }
    }

    pub fn peek(self: @This()) u8 {
        if (self.index >= self.file_contents.len) {
            return 0;
        }
        return self.file_contents[self.index];
    }

    pub fn nextChar(self: *@This()) u8 {
        if (self.index >= self.file_contents.len) {
            return 0;
        }
        const c = self.file_contents[self.index];
        self.index += 1;
        return c;
    }

    pub fn secondNextChar(self: @This()) u8 {
        if (self.index + 1 >= self.file_contents.len) {
            return 0;
        }
        return self.file_contents[self.index + 1];
    }

    pub fn continueLexing(self: *@This()) LexerError!bool {
        self.skipWhitespace();
        if (self.index >= self.file_contents.len) {
            const eofToken = Token{ .kind = .Eof, .start = self.index, .end = self.index };
            try self.tokens.append(eofToken);
            return false;
        }

        const c = self.nextChar();
        var token: Token = undefined;

        switch (c) {
            'a'...'z', 'A'...'Z', '_', '$' => {
                token = try self.lexIdentifier(c);
            },
            '0'...'9' => {
                token = try lexNumber(self, c);
            },
            '"', '\'' => {
                token = try self.lexString(.StringLiteral, c);
            },
            '`' => {
                return try parseTemplateString(self);
            },
            '+' => {
                if (self.peek() == '+') {
                    _ = self.nextChar();
                    token = Token{ .kind = .PlusPlus, .start = self.index - 2, .end = self.index };
                } else if (self.peek() == '=') {
                    _ = self.nextChar();
                    token = Token{ .kind = .PlusEquals, .start = self.index - 2, .end = self.index };
                } else {
                    token = Token{ .kind = .Plus, .start = self.index - 1, .end = self.index };
                }
            },
            '-' => {
                if (self.peek() == '-') {
                    _ = self.nextChar();
                    token = Token{ .kind = .MinusMinus, .start = self.index - 2, .end = self.index };
                } else if (self.peek() == '=') {
                    _ = self.nextChar();
                    token = Token{ .kind = .MinusEquals, .start = self.index - 2, .end = self.index };
                } else {
                    token = Token{ .kind = .Minus, .start = self.index - 1, .end = self.index };
                }
            },
            '*' => {
                if (self.peek() == '*') {
                    _ = self.nextChar();
                    if (self.peek() == '=') {
                        _ = self.nextChar();
                        token = Token{ .kind = .DoubleAsteriskEquals, .start = self.index - 3, .end = self.index };
                    } else {
                        token = Token{ .kind = .DoubleAsterisk, .start = self.index - 2, .end = self.index };
                    }
                } else if (self.peek() == '=') {
                    _ = self.nextChar();
                    token = Token{ .kind = .AsteriskEquals, .start = self.index - 2, .end = self.index };
                } else {
                    token = Token{ .kind = .Asterisk, .start = self.index - 1, .end = self.index };
                }
            },
            '/' => {
                if (self.peek() == '=') {
                    _ = self.nextChar();
                    token = Token{ .kind = .SlashEquals, .start = self.index - 2, .end = self.index };
                } else if (self.peek() == '/') {
                    // @TODO handle comments properly?
                    // like /*@__PURE__*/ or /** @type {number} */
                    // Single line comment
                    while (self.index < self.file_contents.len) {
                        const c2 = self.nextChar();
                        if (c2 == '\n' or c2 == '\r') {
                            break;
                        }
                    }
                    return true;
                } else if (self.peek() == '*') {
                    // Multi-line comment
                    while (self.index < self.file_contents.len) {
                        const c2 = self.nextChar();
                        if (c2 == '*' and self.peek() == '/') {
                            _ = self.nextChar();
                            break;
                        }
                    }
                    return true;
                } else {
                    token = Token{ .kind = .Slash, .start = self.index - 1, .end = self.index };
                }
            },
            '%' => {
                if (self.peek() == '=') {
                    _ = self.nextChar();
                    token = Token{ .kind = .PercentEquals, .start = self.index - 2, .end = self.index };
                } else {
                    token = Token{ .kind = .Percent, .start = self.index - 1, .end = self.index };
                }
            },
            '=' => {
                if (self.peek() == '=') {
                    _ = self.nextChar();
                    if (self.peek() == '=') {
                        _ = self.nextChar();
                        token = Token{ .kind = .EqualsEqualsEquals, .start = self.index - 3, .end = self.index };
                    } else {
                        token = Token{ .kind = .EqualsEquals, .start = self.index - 2, .end = self.index };
                    }
                } else {
                    token = Token{ .kind = .Equals, .start = self.index - 1, .end = self.index };
                }
            },
            '!' => {
                if (self.peek() == '=') {
                    _ = self.nextChar();
                    if (self.peek() == '=') {
                        _ = self.nextChar();
                        token = Token{ .kind = .ExclamationMarkEqualsEquals, .start = self.index - 3, .end = self.index };
                    } else {
                        token = Token{ .kind = .ExclamationMarkEquals, .start = self.index - 2, .end = self.index };
                    }
                } else {
                    token = Token{ .kind = .ExclamationMark, .start = self.index - 1, .end = self.index };
                }
            },
            '<' => {
                if (self.peek() == '=') {
                    _ = self.nextChar();
                    token = Token{ .kind = .LessThanEquals, .start = self.index - 2, .end = self.index };
                } else if (self.peek() == '<') {
                    _ = self.nextChar();
                    if (self.peek() == '=') {
                        _ = self.nextChar();
                        token = Token{ .kind = .ShiftLeftEquals, .start = self.index - 3, .end = self.index };
                    } else {
                        token = Token{ .kind = .ShiftLeft, .start = self.index - 2, .end = self.index };
                    }
                } else {
                    token = Token{ .kind = .LessThan, .start = self.index - 1, .end = self.index };
                }
            },
            '>' => {
                if (self.peek() == '=') {
                    _ = self.nextChar();
                    token = Token{ .kind = .GreaterThanEquals, .start = self.index - 2, .end = self.index };
                } else if (self.peek() == '>') {
                    _ = self.nextChar();
                    if (self.peek() == '>') {
                        _ = self.nextChar();
                        if (self.peek() == '=') {
                            _ = self.nextChar();
                            token = Token{ .kind = .UnsignedShiftRightEquals, .start = self.index - 4, .end = self.index };
                        } else {
                            token = Token{ .kind = .UnsignedShiftRight, .start = self.index - 3, .end = self.index };
                        }
                    } else if (self.peek() == '=') {
                        _ = self.nextChar();
                        token = Token{ .kind = .ShiftRightEquals, .start = self.index - 3, .end = self.index };
                    } else {
                        token = Token{ .kind = .ShiftRight, .start = self.index - 2, .end = self.index };
                    }
                } else {
                    token = Token{ .kind = .GreaterThan, .start = self.index - 1, .end = self.index };
                }
            },
            '&' => {
                if (self.peek() == '&') {
                    _ = self.nextChar();
                    if (self.peek() == '=') {
                        _ = self.nextChar();
                        token = Token{ .kind = .DoubleAmpersandEquals, .start = self.index - 3, .end = self.index };
                    } else {
                        token = Token{ .kind = .DoubleAmpersand, .start = self.index - 2, .end = self.index };
                    }
                } else if (self.peek() == '=') {
                    _ = self.nextChar();
                    token = Token{ .kind = .AmpersandEquals, .start = self.index - 2, .end = self.index };
                } else {
                    token = Token{ .kind = .Ampersand, .start = self.index - 1, .end = self.index };
                }
            },
            '|' => {
                if (self.peek() == '|') {
                    _ = self.nextChar();
                    if (self.peek() == '=') {
                        _ = self.nextChar();
                        token = Token{ .kind = .DoublePipeEquals, .start = self.index - 3, .end = self.index };
                    } else {
                        token = Token{ .kind = .DoublePipe, .start = self.index - 2, .end = self.index };
                    }
                } else if (self.peek() == '=') {
                    _ = self.nextChar();
                    token = Token{ .kind = .PipeEquals, .start = self.index - 2, .end = self.index };
                } else {
                    token = Token{ .kind = .Pipe, .start = self.index - 1, .end = self.index };
                }
            },
            '^' => {
                if (self.peek() == '=') {
                    _ = self.nextChar();
                    token = Token{ .kind = .CaretEquals, .start = self.index - 2, .end = self.index };
                } else {
                    token = Token{ .kind = .Caret, .start = self.index - 1, .end = self.index };
                }
            },
            '~' => {
                token = Token{ .kind = .Tilde, .start = self.index - 1, .end = self.index };
            },
            '(' => {
                token = Token{ .kind = .ParenOpen, .start = self.index - 1, .end = self.index };
            },
            ')' => {
                token = Token{ .kind = .ParenClose, .start = self.index - 1, .end = self.index };
            },
            '{' => {
                token = Token{ .kind = .CurlyOpen, .start = self.index - 1, .end = self.index };
            },
            '}' => {
                token = Token{ .kind = .CurlyClose, .start = self.index - 1, .end = self.index };
            },
            '[' => {
                token = Token{ .kind = .BracketOpen, .start = self.index - 1, .end = self.index };
            },
            ']' => {
                token = Token{ .kind = .BracketClose, .start = self.index - 1, .end = self.index };
            },
            ';' => {
                token = Token{ .kind = .Semicolon, .start = self.index - 1, .end = self.index };
            },
            ':' => {
                token = Token{ .kind = .Colon, .start = self.index - 1, .end = self.index };
            },
            ',' => {
                token = Token{ .kind = .Comma, .start = self.index - 1, .end = self.index };
            },
            '.' => {
                if (self.index + 1 < self.file_contents.len) {
                    if (self.peek() == '.' and self.secondNextChar() == '.') {
                        _ = self.nextChar(); // consume second dot
                        _ = self.nextChar(); // consume third dot
                        token = Token{ .kind = .TripleDot, .start = self.index - 3, .end = self.index };
                    } else {
                        token = Token{ .kind = .Period, .start = self.index - 1, .end = self.index };
                    }
                } else {
                    token = Token{ .kind = .Period, .start = self.index - 1, .end = self.index };
                }
            },
            '?' => {
                if (self.peek() == '?') {
                    _ = self.nextChar();
                    if (self.peek() == '=') {
                        _ = self.nextChar();
                        token = Token{ .kind = .DoubleQuestionMarkEquals, .start = self.index - 3, .end = self.index };
                    } else {
                        token = Token{ .kind = .DoubleQuestionMark, .start = self.index - 2, .end = self.index };
                    }
                } else if (self.peek() == '.') {
                    _ = self.nextChar();
                    token = Token{ .kind = .QuestionMarkPeriod, .start = self.index - 2, .end = self.index };
                } else {
                    token = Token{ .kind = .QuestionMark, .start = self.index - 1, .end = self.index };
                }
            },
            '#' => {
                if (isIdentifierStart(self.peek())) {
                    token = Token{
                        .kind = TokenType.Private,
                        .start = self.index - 1,
                        .end = self.index,
                    };
                } else {
                    return error.UnexpectedCharacter;
                }
            },
            else => {
                return error.NotFound;
            },
        }

        try self.tokens.append(token);
        return true;
    }

    pub fn getErrorMessageFromLexerState(self: @This(), tmp_allocator: std.mem.Allocator, lex_err: LexerError) LexerError![]const u8 {
        var res = std.ArrayList(u8).init(tmp_allocator);
        const writer = res.writer();
        // recalcute the line and column
        var start = skipShebang(self.file_contents);

        var line: usize = if (start >= 0) 1 else 0;
        var column: usize = 0;

        while (start < self.index) : (start += 1) {
            const c = self.file_contents[start];
            if (c == '\n') {
                line += 1;
                column = 0;
            } else {
                column += 1;
            }
        }
        try writer.print("{!}\n\t{s}:{d}:{d}\n", .{ lex_err, self.file_name, line, column });
        return res.toOwnedSlice();
    }

    pub fn lexIdentifier(self: *@This(), first_char: u8) LexerError!Token {
        const start = self.index - 1;
        std.debug.assert(isIdentifierStart(first_char));

        while (self.index < self.file_contents.len) {
            const c = self.peek();
            if (!isIdentifierPart(c)) {
                break;
            }
            _ = self.nextChar();
        }

        const identifier = self.file_contents[start..self.index];

        // Check if the identifier is a keyword
        const token_type = keyword_map.get(identifier) orelse .Identifier;

        return Token{
            .kind = token_type,
            .start = start,
            .end = self.index,
            .value = identifier,
        };
    }

    pub fn lexString(self: *@This(), string_type: TokenType, quote_char: u8) LexerError!Token {
        const start = self.index - 1; // Include the opening quote

        while (self.index < self.file_contents.len) {
            const c = self.nextChar();

            if (c == quote_char) {
                // End of string
                return Token{
                    .kind = string_type,
                    .start = start,
                    .end = self.index,
                    .value = self.file_contents[start..self.index],
                };
            } else if (c == '\\') {
                // Handle escape sequence - skip the next character
                if (self.index < self.file_contents.len) {
                    _ = self.nextChar();
                }
            } else if (c == '\n' or c == '\r') {
                // Strings can't contain unescaped newlines
                return error.UnterminatedStringLiteral;
            }
        }

        return error.UnterminatedStringLiteral;
    }

    fn isIdentifierStart(c: u8) bool {
        return (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            c == '_' or
            c == '$';
    }

    fn isIdentifierPart(c: u8) bool {
        return isIdentifierStart(c) or (c >= '0' and c <= '9');
    }
};

pub fn skipShebang(file_contents: []const u8) usize {
    var index: usize = 0;
    if (file_contents.len > 1) { // Check for at least 2 characters
        if (file_contents[0] == '#' and file_contents[1] == '!') {
            // skip the shebang
            for (file_contents) |c| {
                index += 1;
                if (c == '\n') {
                    break;
                }
            }
        }
    }
    return index;
}

// Complete keywords map with all JavaScript keywords
const keyword_map = std.StaticStringMap(TokenType).initComptime(.{
    .{ "break", .Break },
    .{ "case", .Case },
    .{ "catch", .Catch },
    .{ "class", .Class },
    .{ "const", .Const },
    .{ "continue", .Continue },
    .{ "debugger", .Debugger },
    .{ "default", .Default },
    .{ "delete", .Delete },
    .{ "do", .Do },
    .{ "else", .Else },
    .{ "enum", .Enum },
    .{ "export", .Export },
    .{ "extends", .Extends },
    .{ "false", .BoolLiteral },
    .{ "finally", .Finally },
    .{ "for", .For },
    .{ "function", .Function },
    .{ "if", .If },
    .{ "implements", .Implements },
    .{ "import", .Import },
    .{ "in", .In },
    .{ "instanceof", .Instanceof },
    .{ "interface", .Interface },
    .{ "let", .Let },
    .{ "new", .New },
    .{ "null", .NullLiteral },
    .{ "package", .Package },
    .{ "private", .Private },
    .{ "protected", .Protected },
    .{ "public", .Public },
    .{ "return", .Return },
    .{ "static", .Static },
    .{ "super", .Super },
    .{ "switch", .Switch },
    .{ "this", .This },
    .{ "throw", .Throw },
    .{ "true", .BoolLiteral },
    .{ "try", .Try },
    .{ "typeof", .Typeof },
    .{ "var", .Var },
    .{ "void", .Void },
    .{ "while", .While },
    .{ "with", .With },
    .{ "yield", .Yield },
    .{ "async", .Async },
    .{ "await", .Await },
});

pub const LexerError = error{
    NotFound,
    Unreachable,
    UnterminatedStringLiteral,
    InvalidExponent,
    EndOfFile,
    UnexpectedCharacter,
    OutOfMemory,
};
