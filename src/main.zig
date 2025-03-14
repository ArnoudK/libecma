const std = @import("std");

/// This imports the separate module containing `root.zig`. Take a look in `build.zig` for details.
const lib = @import("root.zig");

pub fn main() !void {
    // get args
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .stack_trace_frames = 32,
    }){};
    {
        var gpa_allocator = gpa.allocator();

        const args = try std.process.argsAlloc(gpa_allocator);
        defer std.process.argsFree(gpa_allocator, args);
        // check if we have enough args
        if (args.len < 2) {
            std.debug.print("Usage: {s} <source file>\n", .{args[0]});
            return;
        }
        // read source file
        const source_path = args[1];
        const source = try std.fs.cwd().readFileAlloc(gpa_allocator, source_path, std.math.maxInt(usize));
        defer gpa_allocator.free(source);

        // parse source
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        var lexer = lib.Lexer.init(gpa_allocator, arena_allocator, source_path, source);
        defer lexer.deinit();
        lexer.startLexing() catch |err| {
            const lex_err = try lexer.getErrorMessageFromLexerState(gpa_allocator, err);
            defer gpa_allocator.free(lex_err);
            std.debug.print("{s}\n", .{lex_err});
            return err;
        };
        var parser = lib.Parser.init(gpa_allocator, lexer.tokens.items);
        defer parser.deinit();
        var program = try parser.parse();
        defer program.deinit();
        var interp = try lib.Interpreter.init(gpa_allocator);
        defer interp.deinit();

        try interp.interpret(program);
        interp.collectGarbage();
    }
    const c = gpa.deinit();
    if (c != .ok) {
        std.debug.print("We leaking boys :(\nMSG: {}\n", .{c});
    }
}
