const std = @import("std");
const TokenType = @import("tokentypes.zig").TokenType;
const escapes = @import("escapes.zig");

const line_separator = 0x2028;
const paragraph_separator = 0x2029;
const no_break_space = 0x00A0;
const zero_width_non_joiner = 0x200C;
const zero_width_no_break_space = 0xFEFF;
const zero_width_joiner = 0x200D;

pub const Token = struct {
    type: TokenType,
    start: usize,
    end: usize,
    value: ?[]const u8 = null,

    pub fn parseDoubleValue(self: *const Token) !f64 {
        std.debug.assert(self.type == .NumericLiteral);
        const value = self.value.?;

        // Handle empty string
        if (value.len == 0) {
            unreachable;
        }

        // Check for hexadecimal format (0x or 0X)
        if (value.len >= 2 and value[0] == '0' and (value[1] == 'x' or value[1] == 'X')) {
            if (value.len == 2) return error.InvalidNumber; // Just '0x' without digits

            var result: f64 = 0.0;
            var i: usize = 2; // Start after the "0x" prefix

            while (i < value.len) : (i += 1) {
                const c = value[i];

                // Skip underscores
                if (c == '_') continue;

                var digit: f64 = undefined;

                if (c >= '0' and c <= '9') {
                    digit = @as(f64, @floatFromInt(c - '0'));
                } else if (c >= 'a' and c <= 'f') {
                    digit = @as(f64, @floatFromInt(c - 'a' + 10));
                } else if (c >= 'A' and c <= 'F') {
                    digit = @as(f64, @floatFromInt(c - 'A' + 10));
                } else {
                    return error.InvalidNumber;
                }

                result = result * 16.0 + digit;
            }

            return result;
        }

        // Check for binary format (0b or 0B)
        if (value.len >= 2 and value[0] == '0' and (value[1] == 'b' or value[1] == 'B')) {
            if (value.len == 2) return error.InvalidNumber; // Just '0b' without digits

            var result: f64 = 0.0;
            var i: usize = 2; // Start after the "0b" prefix

            while (i < value.len) : (i += 1) {
                const c = value[i];

                // Skip underscores
                if (c == '_') continue;

                if (c == '0') {
                    result *= 2.0;
                } else if (c == '1') {
                    result = result * 2.0 + 1.0;
                } else {
                    return error.InvalidNumber;
                }
            }

            return result;
        }

        // Determine if this could be an octal number
        var is_octal = false;
        var is_explicit_octal = false; // Track explicit 0o/0O format

        // Check for explicit octal notation (0o/0O)
        if (value.len >= 2 and value[0] == '0' and (value[1] == 'o' or value[1] == 'O')) {
            is_octal = true;
            is_explicit_octal = true;
        }
        // Check for implicit octal notation (0 followed by 0-7)
        else if (value.len >= 2 and value[0] == '0' and value[1] >= '0' and value[1] <= '7') {
            is_octal = true;
        }

        // Check if the octal number contains 8 or 9, which would make it decimal
        if (is_octal) {
            const start_idx: usize = if (is_explicit_octal) 2 else 1;
            for (value[start_idx..]) |c| {
                if (c == '_') continue; // Skip underscores when checking
                if (c == '8' or c == '9') {
                    is_octal = false;
                    break;
                }
                if (c == '.') {
                    // Octal doesn't have decimal points in this context
                    is_octal = false;
                    break;
                }
            }
        }

        var result: f64 = 0.0;
        var i: usize = 0;

        // Set correct starting index based on number format
        if (is_octal) {
            i = if (is_explicit_octal) 2 else 1; // Skip '0o' or just '0'
        }

        // Parse integer part
        while (i < value.len) : (i += 1) {
            const c = value[i];

            // Skip underscores
            if (c == '_') continue;

            if (c == '.') {
                i += 1;
                break;
            }

            if (c < '0' or c > '9') {
                return error.InvalidNumber;
            }

            const digit = @as(f64, @floatFromInt(c - '0'));

            if (is_octal) {
                result = result * 8.0 + digit;
            } else {
                result = result * 10.0 + digit;
            }
        }

        // Parse decimal part if present
        if (i < value.len) {
            var decimal: f64 = 0.1;
            while (i < value.len) : (i += 1) {
                const c = value[i];

                // Skip underscores
                if (c == '_') continue;

                if (c < '0' or c > '9') {
                    return error.InvalidNumber;
                }
                const digit = @as(f64, @floatFromInt(c - '0'));
                result += digit * decimal;
                decimal /= 10.0;
            }
        }

        return result;
    }

    pub fn parseBoolValue(self: *const Token) !bool {
        std.debug.assert(self.type == .BoolLiteral);

        return (std.mem.eql(u8, self.value.?, "true"));
    }

    pub fn parseBigIntValue(self: *const Token) !u128 {
        std.debug.assert(self.type == .BigIntLiteral);

        var result: u128 = 0;
        var i: usize = 0;

        while (i < self.value.len) : (i += 1) {
            const c = self.value[i];

            // Skip underscores
            if (c == '_') continue;

            if (c < '0' or c > '9') {
                return error.InvalidNumber;
            }

            const digit = @as(u128, c - '0');
            result = result * 10 + digit;
        }

        return result;
    }

    pub fn parseStringValue(self: *const Token, allocator: std.mem.Allocator) ![]u8 {
        std.debug.assert(self.type == .StringLiteral or self.type == .TemplateLiteralString);
        const isTemplate: bool = self.type == .TemplateLiteralString;

        return escapes.parseEscapes(self.value.?, allocator, isTemplate);
    }
};
