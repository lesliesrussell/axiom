const std = @import("std");
const types = @import("types.zig");
const Token = types.Token;
const TokenTag = types.TokenTag;

pub const Lexer = struct {
    source: []const u8,
    pos: usize,
    line: usize,
    col: usize,

    pub fn init(source: []const u8) Lexer {
        return .{
            .source = source,
            .pos = 0,
            .line = 1,
            .col = 1,
        };
    }

    pub fn tokenize(self: *Lexer, allocator: std.mem.Allocator) ![]Token {
        var tokens: std.ArrayList(Token) = .empty;
        while (true) {
            const tok = self.next();
            try tokens.append(allocator, tok);
            if (tok.tag == .eof) break;
        }
        return tokens.toOwnedSlice(allocator);
    }

    pub fn next(self: *Lexer) Token {
        self.skipWhitespace();

        // Skip comments
        if (self.pos < self.source.len and self.source[self.pos] == '%') {
            while (self.pos < self.source.len and self.source[self.pos] != '\n') {
                self.advance();
            }
            return self.next();
        }

        if (self.pos >= self.source.len) {
            return self.makeToken(.eof, "");
        }

        const ch = self.source[self.pos];
        const start_line = self.line;
        const start_col = self.col;

        // Single char tokens
        switch (ch) {
            '.' => {
                self.advance();
                return .{ .tag = .dot, .lexeme = ".", .line = start_line, .col = start_col };
            },
            '?' => {
                self.advance();
                return .{ .tag = .question, .lexeme = "?", .line = start_line, .col = start_col };
            },
            ',' => {
                self.advance();
                return .{ .tag = .comma, .lexeme = ",", .line = start_line, .col = start_col };
            },
            ';' => {
                self.advance();
                return .{ .tag = .semicolon, .lexeme = ";", .line = start_line, .col = start_col };
            },
            '[' => {
                self.advance();
                return .{ .tag = .lbracket, .lexeme = "[", .line = start_line, .col = start_col };
            },
            ']' => {
                self.advance();
                return .{ .tag = .rbracket, .lexeme = "]", .line = start_line, .col = start_col };
            },
            '|' => {
                self.advance();
                return .{ .tag = .pipe, .lexeme = "|", .line = start_line, .col = start_col };
            },
            '!' => {
                self.advance();
                return .{ .tag = .bang, .lexeme = "!", .line = start_line, .col = start_col };
            },
            '*' => {
                self.advance();
                return .{ .tag = .star, .lexeme = "*", .line = start_line, .col = start_col };
            },
            '+' => {
                self.advance();
                return .{ .tag = .plus, .lexeme = "+", .line = start_line, .col = start_col };
            },
            '-' => {
                self.advance();
                return .{ .tag = .minus, .lexeme = "-", .line = start_line, .col = start_col };
            },
            '(' => {
                self.advance();
                return .{ .tag = .lparen, .lexeme = "(", .line = start_line, .col = start_col };
            },
            ')' => {
                self.advance();
                return .{ .tag = .rparen, .lexeme = ")", .line = start_line, .col = start_col };
            },
            else => {},
        }

        // Quoted strings
        if (ch == '"') {
            return self.readString(start_line, start_col);
        }

        // Numbers
        if (std.ascii.isDigit(ch)) {
            return self.readNumber(start_line, start_col);
        }

        // Identifiers and keywords
        if (std.ascii.isAlphabetic(ch) or ch == '_') {
            return self.readIdentifier(start_line, start_col);
        }

        // Unknown character - skip
        self.advance();
        return self.next();
    }

    fn readString(self: *Lexer, line: usize, col: usize) Token {
        self.advance(); // skip opening "
        const start = self.pos;
        while (self.pos < self.source.len and self.source[self.pos] != '"') {
            self.advance();
        }
        const content = self.source[start..self.pos];
        if (self.pos < self.source.len) self.advance(); // skip closing "
        return .{ .tag = .string, .lexeme = content, .line = line, .col = col };
    }

    fn readNumber(self: *Lexer, line: usize, col: usize) Token {
        const start = self.pos;
        while (self.pos < self.source.len and std.ascii.isDigit(self.source[self.pos])) {
            self.advance();
        }
        return .{ .tag = .integer, .lexeme = self.source[start..self.pos], .line = line, .col = col };
    }

    fn readIdentifier(self: *Lexer, line: usize, col: usize) Token {
        const start = self.pos;
        while (self.pos < self.source.len and (std.ascii.isAlphanumeric(self.source[self.pos]) or self.source[self.pos] == '_')) {
            self.advance();
        }
        const lexeme = self.source[start..self.pos];
        const tag = classifyWord(lexeme);
        return .{ .tag = tag, .lexeme = lexeme, .line = line, .col = col };
    }

    fn classifyWord(word: []const u8) TokenTag {
        // Single uppercase letter is always a variable (A, B, X, Y, Z...)
        if (word.len == 1 and std.ascii.isUpper(word[0])) {
            return .variable;
        }

        const lower = asLowerBuf(word);
        const len = @min(word.len, 20);
        const lower_slice = lower[0..len];

        const keywords = .{
            .{ "is", TokenTag.kw_is },
            .{ "a", TokenTag.kw_a },
            .{ "an", TokenTag.kw_an },
            .{ "if", TokenTag.kw_if },
            .{ "and", TokenTag.kw_and },
            .{ "not", TokenTag.kw_not },
            .{ "has", TokenTag.kw_has },
            .{ "have", TokenTag.kw_has },
            .{ "of", TokenTag.kw_of },
            .{ "every", TokenTag.kw_every },
            .{ "each", TokenTag.kw_each },
            .{ "who", TokenTag.kw_who },
            .{ "what", TokenTag.kw_what },
            .{ "which", TokenTag.kw_which },
            .{ "cut", TokenTag.kw_cut },
            .{ "here", TokenTag.kw_here },
            .{ "can", TokenTag.kw_can },
            .{ "the", TokenTag.kw_the },
            .{ "that", TokenTag.kw_that },
            .{ "whose", TokenTag.kw_whose },
            .{ "head", TokenTag.kw_head },
            .{ "tail", TokenTag.kw_tail },
            .{ "less", TokenTag.kw_less },
            .{ "than", TokenTag.kw_than },
            .{ "include", TokenTag.kw_include },
            .{ "mode", TokenTag.kw_mode },
        };

        inline for (keywords) |kv| {
            if (std.mem.eql(u8, lower_slice, kv[0])) return kv[1];
        }

        // Check if it starts with uppercase -> variable
        if (std.ascii.isUpper(word[0])) {
            return .variable;
        }

        return .atom;
    }

    fn asLowerBuf(word: []const u8) [20]u8 {
        var buf: [20]u8 = undefined;
        const len = @min(word.len, 20);
        for (0..len) |i| {
            buf[i] = std.ascii.toLower(word[i]);
        }
        return buf;
    }

    fn advance(self: *Lexer) void {
        if (self.pos < self.source.len) {
            if (self.source[self.pos] == '\n') {
                self.line += 1;
                self.col = 1;
            } else {
                self.col += 1;
            }
            self.pos += 1;
        }
    }

    fn skipWhitespace(self: *Lexer) void {
        while (self.pos < self.source.len and std.ascii.isWhitespace(self.source[self.pos])) {
            self.advance();
        }
    }

    fn makeToken(self: *Lexer, tag: TokenTag, lexeme: []const u8) Token {
        return .{ .tag = tag, .lexeme = lexeme, .line = self.line, .col = self.col };
    }
};
