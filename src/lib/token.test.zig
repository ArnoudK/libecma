const std = @import("std");
const Token = @import("token.zig").Token;

test "Token ParseDoubleValues" {
    const t = std.testing;
    var token = Token{
        .type = .NumericLiteral,
        .start = 0,
        .end = 0,
        .value = "0",
    };

    try t.expectEqual(0, try token.parseDoubleValue());

    token.value = "1";
    try t.expectEqual(1, try token.parseDoubleValue());

    token.value = "123";
    try t.expectEqual(123, try token.parseDoubleValue());

    token.value = "123.456";
    try t.expectEqual(123.456, try token.parseDoubleValue());

    token.value = "0x123";
    try t.expectEqual(0x123, try token.parseDoubleValue());

    token.value = "0x123.456";
    try t.expectError(error.InvalidNumber, token.parseDoubleValue());

    token.value = "0b101";
    try t.expectEqual(0b101, try token.parseDoubleValue());

    token.value = "0b101.101";
    try t.expectError(error.InvalidNumber, token.parseDoubleValue());

    token.value = "0o123";
    try t.expectEqual(0o123, try token.parseDoubleValue());
}

test "Token ParseBoolValues" {
    const t = std.testing;
    var token = Token{
        .type = .BoolLiteral,
        .start = 0,
        .end = 0,
        .value = "true",
    };

    try t.expectEqual(true, try token.parseBoolValue());

    token.value = "false";
    try t.expectEqual(false, try token.parseBoolValue());
}

test "Token StringValue" {
    const t = std.testing;
    const allocator = std.testing.allocator;

    var token = Token{
        .type = .StringLiteral,
        .start = 0,
        .end = 0,
        .value = "",
    };

    {
        const empty = try token.parseStringValue(allocator);
        defer allocator.free(empty);
        try t.expectEqualStrings("", empty);
    }

    {
        token.value = "\"Hello, World!\"";
        const result = try token.parseStringValue(allocator);
        defer allocator.free(result);
        try t.expectEqualStrings("Hello, World!", result);
    }

    {
        token.value = "\"\\\"\"";
        const result = try token.parseStringValue(allocator);
        defer allocator.free(result);
        try t.expectEqualStrings("\"", result);
    }

    {
        token.value = "\"\\n\"";
        const result = try token.parseStringValue(allocator);
        defer allocator.free(result);
        try t.expectEqualStrings("\n", result);
    }

    {
        token.value = "\"\\u0041\"";
        const result = try token.parseStringValue(allocator);
        defer allocator.free(result);
        try t.expectEqualStrings("A", result);
    }

    {
        token.value = "\"\\u00E9\"";
        const result = try token.parseStringValue(allocator);
        defer allocator.free(result);
        try t.expectEqualStrings("é", result);
    }

    {
        token.value = "\"\\uD83D\\uDE00\"";
        const result = try token.parseStringValue(allocator);
        defer allocator.free(result);
        try t.expectEqualStrings("😀", result);
    }

    {
        token.value = "\"\\uD83D\\uDE00\\uD83D\\uDE01\"";
        const result = try token.parseStringValue(allocator);
        defer allocator.free(result);
        try t.expectEqualStrings("😀😁", result);
    }

    {
        token.value = "\"\\uD83D\\uDE00\\uD83D\\uDE01\\uD83D\\uDE02\"";
        const result = try token.parseStringValue(allocator);
        defer allocator.free(result);
        try t.expectEqualStrings("😀😁😂", result);
    }

    {
        token.value = "\"\\uD83D\\uDE00\\uD83D\\uDE01\\uD83D\\uDE02\\uD83D\\uDE03\"";
        const result = try token.parseStringValue(allocator);
        defer allocator.free(result);
        try t.expectEqualStrings("😀😁😂😃", result);
    }

    {
        token.value = "\"\\uD83D\\uDE00\\uD83D\\uDE01\\uD83D\\uDE02\\uD83D\\uDE03\\uD83D\\uDE04\"";
        const result = try token.parseStringValue(allocator);
        defer allocator.free(result);
        try t.expectEqualStrings("😀😁😂😃😄", result);
    }

    {
        token.value = "\"\\uD83D\\uDE00\\uD83D\\uDE01\\uD83D\\uDE02\\uD83D\\uDE03\\uD83D\\uDE04\\uD83D\\uDE05\"";
        const result = try token.parseStringValue(allocator);
        defer allocator.free(result);
        try t.expectEqualStrings("😀😁😂😃😄😅", result);
    }
}
