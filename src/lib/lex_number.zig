const LexerError = @import("lexer.zig").LexerError;
const Lexer = @import("lexer.zig").Lexer;
const Token = @import("token.zig").Token;
const TokenType = @import("tokentypes.zig").TokenType;

pub fn lexNumber(self: *Lexer, first_char: u8) LexerError!Token {
    const start = self.index - 1;
    var is_float = false;

    // Check for hex, binary, or octal format
    if (first_char == '0' and self.index < self.file_contents.len) {
        const c = self.peek();
        if (c == 'x' or c == 'X') {
            // Hexadecimal
            _ = self.nextChar(); // consume 'x'
            while (self.index < self.file_contents.len) {
                const c2 = self.peek();
                if (isHexDigit(c2) or c2 == '_') {
                    _ = self.nextChar();
                } else {
                    break;
                }
            }
        } else if (c == 'b' or c == 'B') {
            // Binary
            _ = self.nextChar(); // consume 'b'
            while (self.index < self.file_contents.len) {
                const c2 = self.peek();
                if (c2 == '0' or c2 == '1' or c2 == '_') {
                    _ = self.nextChar();
                } else {
                    break;
                }
            }
        } else if (c == 'o' or c == 'O') {
            // Octal
            _ = self.nextChar(); // consume 'o'
            while (self.index < self.file_contents.len) {
                const c2 = self.peek();
                if ((c2 >= '0' and c2 <= '7') or c2 == '_') {
                    _ = self.nextChar();
                } else {
                    break;
                }
            }
        }
    }

    // Parse decimal part
    if (first_char != '0' or self.index == start + 1) {
        while (self.index < self.file_contents.len) {
            const c = self.peek();
            if (c >= '0' and c <= '9' or c == '_') {
                _ = self.nextChar();
            } else {
                break;
            }
        }
    }

    // Parse fractional part if present
    if (self.index < self.file_contents.len and self.peek() == '.') {
        is_float = true;
        _ = self.nextChar(); // consume the '.'

        while (self.index < self.file_contents.len) {
            const c = self.peek();
            if (c >= '0' and c <= '9' or c == '_') {
                _ = self.nextChar();
            } else {
                break;
            }
        }
    }

    // Parse exponent part if present
    if (self.index < self.file_contents.len) {
        const c = self.peek();
        if (c == 'e' or c == 'E') {
            is_float = true;
            _ = self.nextChar(); // consume 'e'

            // Optional + or -
            if (self.index < self.file_contents.len) {
                const c2 = self.peek();
                if (c2 == '+' or c2 == '-') {
                    _ = self.nextChar();
                }
            }

            // At least one digit required in exponent
            var has_digits = false;
            while (self.index < self.file_contents.len) {
                const c2 = self.peek();
                if (c2 >= '0' and c2 <= '9') {
                    has_digits = true;
                    _ = self.nextChar();
                } else {
                    break;
                }
            }

            if (!has_digits) {
                return error.InvalidExponent;
            }
        }
    }

    // Check if this is a BigInt literal (ends with 'n')
    if (self.index < self.file_contents.len and self.peek() == 'n') {
        _ = self.nextChar();
        return Token{
            .kind = .BigIntLiteral,
            .start = start,
            .end = self.index,
            .value = self.file_contents[start..self.index],
        };
    }

    return Token{
        .kind = .NumericLiteral,
        .start = start,
        .end = self.index,
        .value = self.file_contents[start..self.index],
    };
}

pub fn isHexDigit(c: u8) bool {
    return (c >= '0' and c <= '9') or
        (c >= 'a' and c <= 'f') or
        (c >= 'A' and c <= 'F');
}
