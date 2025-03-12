const std = @import("std");

pub const EscapeError = error{
    InvalidEscapeSequence,
};

/// Parse a single character escape sequence and append it to the result
pub fn parseSimpleEscape(c: u8, result: *std.ArrayList(u8)) !void {
    switch (c) {
        '0' => try result.append(0),
        'a' => try result.append(0x07),
        'b' => try result.append(0x08),
        't' => try result.append(0x09),
        'n' => try result.append(0x0A),
        'v' => try result.append(0x0B),
        'f' => try result.append(0x0C),
        'r' => try result.append(0x0D),
        'e' => try result.append(0x1B),
        '"' => try result.append('"'),
        '\'' => try result.append('\''),
        '\\' => try result.append('\\'),
        else => return error.InvalidEscapeSequence,
    }
}

/// Parse a hexadecimal escape sequence \xHH
pub fn parseHexEscape(str: []const u8, i: usize, end_idx: usize, result: *std.ArrayList(u8)) !usize {
    if (i + 2 >= end_idx) {
        return error.InvalidEscapeSequence;
    }
    const hex = str[i + 1 .. i + 3];
    const value = try std.fmt.parseInt(u8, hex, 16);
    try result.append(value);
    return 2; // Skip over the two hex digits
}

/// Parse a unicode escape sequence \uXXXX or surrogate pair \uXXXX\uXXXX
pub fn parseUnicodeEscape(str: []const u8, i: usize, end_idx: usize, result: *std.ArrayList(u8)) !usize {
    if (i + 4 >= end_idx) {
        return error.InvalidEscapeSequence;
    }

    const hex = str[i + 1 .. i + 5];
    const value: u21 = try std.fmt.parseInt(u21, hex, 16);

    // Handle surrogate pairs for UTF-16 encoding
    if (value >= 0xD800 and value <= 0xDBFF) {
        // This is a high surrogate, we need to find the low surrogate
        if (i + 6 >= end_idx or str[i + 5] != '\\' or str[i + 6] != 'u') {
            return error.InvalidEscapeSequence;
        }

        if (i + 10 >= end_idx) {
            return error.InvalidEscapeSequence;
        }

        const hex2 = str[i + 7 .. i + 11];
        const value2 = try std.fmt.parseInt(u16, hex2, 16);

        if (value2 < 0xDC00 or value2 > 0xDFFF) {
            return error.InvalidEscapeSequence;
        }

        // Calculate the actual codepoint from surrogate pair
        const codepoint: u21 = 0x10000 + (((value - 0xD800) << 10) | (value2 - 0xDC00));

        // Encode as UTF-8
        var utf8_buf: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(codepoint, &utf8_buf);
        try result.appendSlice(utf8_buf[0..len]);

        return 10; // Skip over both escape sequences
    } else {
        // Regular single character Unicode escape
        var utf8_buf: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(value, &utf8_buf);
        try result.appendSlice(utf8_buf[0..len]);
        return 4; // Skip over the four hex digits
    }
}

/// Parse all escape sequences in a string
pub fn parseEscapes(str: []const u8, allocator: std.mem.Allocator, isTemplate: bool) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();

    // Handle empty string case
    if (str.len <= 2) {
        return result.toOwnedSlice();
    }

    // Determine start and end indices based on string type
    const start_idx: usize = if (isTemplate) 0 else 1; // Skip opening quote for regular strings
    const end_idx: usize = if (isTemplate) str.len else str.len - 1; // Exclude closing quote

    var i: usize = start_idx;
    while (i < end_idx) {
        const c = str[i];

        if (c == '\\' and i + 1 < end_idx) {
            i += 1; // Move to the character after '\'
            const escape_char = str[i];

            switch (escape_char) {
                'x' => {
                    const skip = try parseHexEscape(str, i, end_idx, &result);
                    i += skip;
                },
                'u' => {
                    const skip = try parseUnicodeEscape(str, i, end_idx, &result);
                    i += skip;
                },
                else => {
                    try parseSimpleEscape(escape_char, &result);
                },
            }
        } else {
            try result.append(c);
        }

        i += 1;
    }

    return result.toOwnedSlice();
}
