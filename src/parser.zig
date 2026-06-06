const std = @import("std");
const types = @import("types.zig");
const Token = types.Token;
const TokenTag = types.TokenTag;
const Term = types.Term;
const Sentence = types.Sentence;
const NounPhrase = types.NounPhrase;
const VerbPhrase = types.VerbPhrase;
const Condition = types.Condition;
const Statement = types.Statement;
const QueryKind = types.QueryKind;
const Command = types.Command;
const Determinism = types.Determinism;
const Mode = types.Mode;
const ModeDecl = types.ModeDecl;

pub const ParseError = error{
    UnexpectedToken,
    UnexpectedEof,
    OutOfMemory,
};

pub const Parser = struct {
    tokens: []const Token,
    pos: usize,
    allocator: std.mem.Allocator,
    last_error_line: usize,
    last_error_col: usize,
    last_error_token: []const u8,

    pub fn init(tokens: []const Token, allocator: std.mem.Allocator) Parser {
        return .{
            .tokens = tokens,
            .pos = 0,
            .allocator = allocator,
            .last_error_line = 0,
            .last_error_col = 0,
            .last_error_token = "",
        };
    }

    pub fn parseProgram(self: *Parser) ![]Statement {
        var stmts: std.ArrayList(Statement) = .empty;
        while (self.peek().tag != .eof) {
            if (self.parseStatement()) |stmt| {
                try stmts.append(self.allocator, stmt);
            } else |_| {
                self.recover();
            }
        }
        return stmts.toOwnedSlice(self.allocator);
    }

    pub fn parseStatement(self: *Parser) ParseError!Statement {
        const first = self.peek();

        // Include
        if (first.tag == .kw_include) return self.parseInclude();

        // Mode declaration
        if (first.tag == .kw_mode) return self.parseModeDecl();

        // axiom-d4s: "Predicate banned is closed_world."
        // "Predicate" lexes as a variable token; commit to this parse only
        // when the full shape matches, otherwise fall through.
        if (first.tag == .variable and std.mem.eql(u8, first.lexeme, "Predicate")) {
            if (self.tryClosedWorldDecl()) |stmt| return stmt;
        }

        // axiom-i01: "Should <subject> <action> [<resource>]?"
        if (first.tag == .variable and std.mem.eql(u8, first.lexeme, "Should")) {
            if (self.tryShouldQuery()) |stmt| return stmt;
        }

        // axiom-07s: "Why not?"
        if (first.tag == .variable and std.mem.eql(u8, first.lexeme, "Why")) {
            if (self.tryWhyNotQuery()) |stmt| return stmt;
        }

        // Queries
        if (first.tag == .kw_is) return self.parseYesNoQuery();
        if (first.tag == .kw_who) return self.parseWhoQuery();
        if (first.tag == .kw_what) return self.parseWhatQuery();
        if (first.tag == .kw_which) {
            // axiom-02w: "Which actions can <subject> perform [on <resource>]?"
            if (self.tryWhichActionsQuery()) |stmt| return stmt;
            return self.parseWhichQuery();
        }
        if (first.tag == .kw_can) return self.parseCanQuery();

        // Every/Each
        if (first.tag == .kw_every or first.tag == .kw_each) {
            return self.parseEveryRule();
        }

        // Fact or rule
        const sentence = try self.parseSentence();

        // Check for determinism marker before "if" or "."
        const det = self.tryDetMarker();

        if (self.peek().tag == .kw_if) {
            self.pos += 1;
            const body = try self.parseConditionList();
            try self.expectDot();
            return .{ .rule = .{ .head = sentence, .body = body, .det = det } };
        }

        try self.expectDot();
        return .{ .fact = .{ .sentence = sentence, .det = det } };
    }

    fn tryDetMarker(self: *Parser) Determinism {
        const tag = self.peek().tag;
        if (tag == .bang) {
            self.pos += 1;
            return .det;
        }
        // '?' as det marker only when followed by 'if' or identifier (not end of query)
        // Actually in facts/rules, ? before . or if means semidet
        if (tag == .question) {
            // Peek ahead: if next is 'if' or '.', it's a det marker
            const after = if (self.pos + 1 < self.tokens.len) self.tokens[self.pos + 1].tag else .eof;
            if (after == .kw_if or after == .dot) {
                self.pos += 1;
                return .semidet;
            }
        }
        if (tag == .star) {
            self.pos += 1;
            return .nondet;
        }
        return .unspecified;
    }

    fn parseInclude(self: *Parser) ParseError!Statement {
        self.pos += 1;
        if (self.peek().tag != .string) return self.fail(ParseError.UnexpectedToken);
        const filename = self.peek().lexeme;
        self.pos += 1;
        try self.expectDot();
        return .{ .command = .{ .include = filename } };
    }

    // axiom-02w
    fn tryWhichActionsQuery(self: *Parser) ?Statement {
        const saved = self.pos;
        self.pos += 1; // "Which"
        if (!isIdentLike(self.peek().tag) or !std.mem.eql(u8, self.peek().lexeme, "actions")) {
            self.pos = saved;
            return null;
        }
        self.pos += 1;
        if (self.peek().tag != .kw_can) {
            self.pos = saved;
            return null;
        }
        self.pos += 1;
        if (!isIdentLike(self.peek().tag) and self.peek().tag != .variable) {
            self.pos = saved;
            return null;
        }
        const subject = self.peek().lexeme;
        self.pos += 1;
        if (!isIdentLike(self.peek().tag) or !std.mem.eql(u8, self.peek().lexeme, "perform")) {
            self.pos = saved;
            return null;
        }
        self.pos += 1;
        var resource: ?[]const u8 = null;
        if (isIdentLike(self.peek().tag) and std.mem.eql(u8, self.peek().lexeme, "on")) {
            self.pos += 1;
            if (!isIdentLike(self.peek().tag) and self.peek().tag != .variable) {
                self.pos = saved;
                return null;
            }
            resource = self.peek().lexeme;
            self.pos += 1;
        }
        if (self.peek().tag != .question) {
            self.pos = saved;
            return null;
        }
        self.pos += 1;
        return .{ .which_actions_query = .{ .subject = subject, .resource = resource } };
    }

    // axiom-07s
    fn tryWhyNotQuery(self: *Parser) ?Statement {
        const saved = self.pos;
        self.pos += 1; // "Why"
        if (self.peek().tag != .kw_not) {
            self.pos = saved;
            return null;
        }
        self.pos += 1;
        if (self.peek().tag != .question) {
            self.pos = saved;
            return null;
        }
        self.pos += 1;
        return .why_not_query;
    }

    // axiom-i01
    fn tryShouldQuery(self: *Parser) ?Statement {
        const saved = self.pos;
        self.pos += 1; // "Should"
        // subject: lowercase atom or capitalized name
        if (!isIdentLike(self.peek().tag) and self.peek().tag != .variable) {
            self.pos = saved;
            return null;
        }
        const subject = self.peek().lexeme;
        self.pos += 1;
        if (!isIdentLike(self.peek().tag)) {
            self.pos = saved;
            return null;
        }
        const action = self.peek().lexeme;
        self.pos += 1;
        var resource: ?[]const u8 = null;
        if (isIdentLike(self.peek().tag) or self.peek().tag == .variable) {
            resource = self.peek().lexeme;
            self.pos += 1;
        }
        if (self.peek().tag != .question) {
            self.pos = saved;
            return null;
        }
        self.pos += 1;
        return .{ .should_query = .{ .subject = subject, .action = action, .resource = resource } };
    }

    // axiom-d4s
    fn tryClosedWorldDecl(self: *Parser) ?Statement {
        const saved = self.pos;
        self.pos += 1; // "Predicate"
        if (!isIdentLike(self.peek().tag)) {
            self.pos = saved;
            return null;
        }
        const name = self.peek().lexeme;
        self.pos += 1;
        if (self.peek().tag != .kw_is) {
            self.pos = saved;
            return null;
        }
        self.pos += 1;
        if (!isIdentLike(self.peek().tag) or !std.mem.eql(u8, self.peek().lexeme, "closed_world")) {
            self.pos = saved;
            return null;
        }
        self.pos += 1;
        if (self.peek().tag != .dot) {
            self.pos = saved;
            return null;
        }
        self.pos += 1;
        return .{ .closed_world_decl = name };
    }

    fn parseModeDecl(self: *Parser) ParseError!Statement {
        self.pos += 1; // skip "mode"

        // Predicate name
        if (!isIdentLike(self.peek().tag)) return self.fail(ParseError.UnexpectedToken);
        const pred_name = self.peek().lexeme;
        self.pos += 1;

        // (
        if (self.peek().tag != .lparen) return self.fail(ParseError.UnexpectedToken);
        self.pos += 1;

        // Parse argument modes: +X, -Y, ?Z
        var arg_modes: std.ArrayList(Mode) = .empty;
        var arg_names: std.ArrayList([]const u8) = .empty;

        if (self.peek().tag != .rparen) {
            const mode_arg = try self.parseModeArg();
            try arg_modes.append(self.allocator, mode_arg.mode);
            try arg_names.append(self.allocator, mode_arg.name);

            while (self.peek().tag == .comma) {
                self.pos += 1;
                const next_arg = try self.parseModeArg();
                try arg_modes.append(self.allocator, next_arg.mode);
                try arg_names.append(self.allocator, next_arg.name);
            }
        }

        // )
        if (self.peek().tag != .rparen) return self.fail(ParseError.UnexpectedToken);
        self.pos += 1;

        // Optional det marker
        const det = self.tryDetMarker();

        try self.expectDot();

        return .{ .mode_decl = .{
            .pred_name = pred_name,
            .arg_names = try arg_names.toOwnedSlice(self.allocator),
            .arg_modes = try arg_modes.toOwnedSlice(self.allocator),
            .det = det,
        } };
    }

    const ModeArg = struct { mode: Mode, name: []const u8 };

    fn parseModeArg(self: *Parser) ParseError!ModeArg {
        var mode: Mode = .any;
        if (self.peek().tag == .plus) {
            mode = .in;
            self.pos += 1;
        } else if (self.peek().tag == .minus) {
            mode = .out;
            self.pos += 1;
        } else if (self.peek().tag == .question) {
            mode = .any;
            self.pos += 1;
        }

        if (!isIdentLike(self.peek().tag) and self.peek().tag != .variable) {
            return self.fail(ParseError.UnexpectedToken);
        }
        const name = self.peek().lexeme;
        self.pos += 1;
        return .{ .mode = mode, .name = name };
    }

    fn parseYesNoQuery(self: *Parser) ParseError!Statement {
        self.pos += 1;
        const subject = try self.parseNounPhrase();

        if (self.peek().tag == .kw_is) {
            const sentence = try self.parseSentenceAfterSubject(subject);
            try self.expectQuestion();
            return .{ .query = .{ .kind = .yes_no, .sentence = sentence } };
        }

        const vp = try self.parseVerbPhraseAfterIs();
        try self.expectQuestion();
        return .{ .query = .{
            .kind = .yes_no,
            .sentence = .{ .subject = subject, .verb = vp },
        } };
    }

    fn parseCanQuery(self: *Parser) ParseError!Statement {
        self.pos += 1;
        const subject = try self.parseNounPhrase();

        if (!isIdentLike(self.peek().tag)) return self.fail(ParseError.UnexpectedToken);
        const verb = self.peek().lexeme;
        self.pos += 1;

        var particle: ?[]const u8 = null;
        if (isIdentLike(self.peek().tag) and self.peek().tag != .question) {
            particle = self.peek().lexeme;
            self.pos += 1;
        }

        try self.expectQuestion();
        return .{ .query = .{
            .kind = .yes_no,
            .sentence = .{
                .subject = subject,
                .verb = .{ .can = .{ .verb = verb, .particle = particle } },
            },
        } };
    }

    fn parseWhoQuery(self: *Parser) ParseError!Statement {
        self.pos += 1;
        const who_np: NounPhrase = .{ .variable = "_Who" };

        if (self.peek().tag == .kw_is) {
            self.pos += 1;
            const vp = try self.parseVerbPhraseAfterIs();
            try self.expectQuestion();
            return .{ .query = .{
                .kind = .who,
                .sentence = .{ .subject = who_np, .verb = vp },
            } };
        }

        if (self.peek().tag == .kw_has) {
            self.pos += 1;
            if (!isIdentLike(self.peek().tag)) return self.fail(ParseError.UnexpectedToken);
            const prop = self.peek().lexeme;
            self.pos += 1;
            const val = try self.parseNounPhrase();
            try self.expectQuestion();
            return .{ .query = .{
                .kind = .who,
                .sentence = .{
                    .subject = who_np,
                    .verb = .{ .has = .{ .property = prop, .value = val } },
                },
            } };
        }

        return self.fail(ParseError.UnexpectedToken);
    }

    fn parseWhatQuery(self: *Parser) ParseError!Statement {
        self.pos += 1;
        const what_np: NounPhrase = .{ .variable = "_What" };

        if (self.peek().tag == .kw_is) {
            self.pos += 1;
            const vp = try self.parseVerbPhraseAfterIs();
            try self.expectQuestion();
            return .{ .query = .{
                .kind = .what,
                .sentence = .{ .subject = what_np, .verb = vp },
            } };
        }
        return self.fail(ParseError.UnexpectedToken);
    }

    fn parseWhichQuery(self: *Parser) ParseError!Statement {
        self.pos += 1;
        if (!isIdentLike(self.peek().tag)) return self.fail(ParseError.UnexpectedToken);
        self.pos += 1;
        const which_np: NounPhrase = .{ .variable = "_Which" };

        if (self.peek().tag == .kw_has) {
            self.pos += 1;
            if (!isIdentLike(self.peek().tag)) return self.fail(ParseError.UnexpectedToken);
            const prop = self.peek().lexeme;
            self.pos += 1;
            const val = try self.parseNounPhrase();
            try self.expectQuestion();
            return .{ .query = .{
                .kind = .which,
                .sentence = .{
                    .subject = which_np,
                    .verb = .{ .has = .{ .property = prop, .value = val } },
                },
            } };
        }
        return self.fail(ParseError.UnexpectedToken);
    }

    fn parseEveryRule(self: *Parser) ParseError!Statement {
        self.pos += 1;
        if (!isIdentLike(self.peek().tag)) return self.fail(ParseError.UnexpectedToken);
        const type_noun = self.peek().lexeme;
        self.pos += 1;
        if (self.peek().tag != .kw_is) return self.fail(ParseError.UnexpectedToken);
        self.pos += 1;
        const vp = try self.parseVerbPhraseAfterIs();

        const det = self.tryDetMarker();

        var extra_body: []const Condition = &.{};
        if (self.peek().tag == .kw_if) {
            self.pos += 1;
            extra_body = try self.parseConditionList();
        }

        try self.expectDot();

        const var_name = try self.internCapitalize(type_noun);
        const head = Sentence{
            .subject = .{ .variable = var_name },
            .verb = vp,
        };

        if (extra_body.len > 0) {
            return .{ .rule = .{ .head = head, .body = extra_body, .det = det } };
        }

        var conditions: std.ArrayList(Condition) = .empty;
        try conditions.append(self.allocator, .{
            .positive = .{
                .subject = .{ .variable = var_name },
                .verb = .{ .is_a = .{ .noun = type_noun, .of_arg = null } },
            },
        });
        return .{ .rule = .{
            .head = head,
            .body = try conditions.toOwnedSlice(self.allocator),
            .det = det,
        } };
    }

    fn parseSentence(self: *Parser) ParseError!Sentence {
        if (self.peek().tag == .kw_every or self.peek().tag == .kw_each) {
            self.pos += 1;
            if (!isIdentLike(self.peek().tag)) return self.fail(ParseError.UnexpectedToken);
            const name = self.peek().lexeme;
            self.pos += 1;
            if (self.peek().tag == .kw_is) {
                self.pos += 1;
                const vp = try self.parseVerbPhraseAfterIs();
                return .{
                    .subject = .{ .variable = try self.internCapitalize(name) },
                    .verb = vp,
                };
            }
            return self.fail(ParseError.UnexpectedToken);
        }

        const subject = try self.parseNounPhrase();
        return self.parseSentenceAfterSubject(subject);
    }

    fn parseSentenceAfterSubject(self: *Parser, subject: NounPhrase) ParseError!Sentence {
        if (self.peek().tag == .kw_is) {
            self.pos += 1;
            if (self.peek().tag == .kw_not) {
                self.pos += 1;
                const neg_vp = try self.parseNegatedPredicate();
                return .{ .subject = subject, .verb = neg_vp };
            }
            const vp = try self.parseVerbPhraseAfterIs();
            return .{ .subject = subject, .verb = vp };
        }

        if (self.peek().tag == .kw_has) {
            self.pos += 1;
            if (!isIdentLike(self.peek().tag)) return self.fail(ParseError.UnexpectedToken);
            const prop = self.peek().lexeme;
            self.pos += 1;
            const val = try self.parseNounPhrase();
            return .{
                .subject = subject,
                .verb = .{ .has = .{ .property = prop, .value = val } },
            };
        }

        if (self.peek().tag == .kw_can) {
            self.pos += 1;
            if (!isIdentLike(self.peek().tag)) return self.fail(ParseError.UnexpectedToken);
            const verb = self.peek().lexeme;
            self.pos += 1;
            var particle: ?[]const u8 = null;
            if (isIdentLike(self.peek().tag) and self.peek().tag != .kw_if and self.peek().tag != .kw_and and self.peek().tag != .dot) {
                particle = self.peek().lexeme;
                self.pos += 1;
            }
            return .{
                .subject = subject,
                .verb = .{ .can = .{ .verb = verb, .particle = particle } },
            };
        }

        return self.fail(ParseError.UnexpectedToken);
    }

    fn parseNegatedPredicate(self: *Parser) ParseError!VerbPhrase {
        // axiom-bjr: "X is not less than Y" etc.
        if (try self.tryThanComparison()) |vp| {
            return .{ .is_not = .{ .predicate_with_arg = .{ .pred = vp.is_a.noun, .arg = vp.is_a.of_arg.?.* } } };
        }

        if (self.peek().tag == .kw_a or self.peek().tag == .kw_an) {
            self.pos += 1;
            if (!isIdentLike(self.peek().tag)) return self.fail(ParseError.UnexpectedToken);
            const noun = self.peek().lexeme;
            self.pos += 1;
            // axiom-g00: "X is not a Y of Z" -> \+ Y(X, Z), mirroring the
            // positive of-pattern in parseVerbPhraseAfterIs
            if (self.peek().tag == .kw_of) {
                self.pos += 1;
                const of_np = try self.parseNounPhrase();
                return .{ .is_not = .{ .predicate_with_arg = .{ .pred = noun, .arg = of_np } } };
            }
            return .{ .is_not = .{ .type_check = noun } };
        }
        if (isIdentLike(self.peek().tag)) {
            const pred = self.peek().lexeme;
            self.pos += 1;
            if (isIdentLike(self.peek().tag) or self.peek().tag == .variable or
                self.peek().tag == .kw_a or self.peek().tag == .kw_an or
                self.peek().tag == .kw_the)
            {
                const arg_np = try self.parseNounPhrase();
                return .{ .is_not = .{ .predicate_with_arg = .{ .pred = pred, .arg = arg_np } } };
            }
            return .{ .is_not = .{ .predicate = pred } };
        }
        return self.fail(ParseError.UnexpectedToken);
    }

    // axiom-bjr
    // "less than Y" (kw_less is a keyword) or "<word> than Y" (greater,
    // bigger, smaller...). Returns an is_a phrase with functor
    // "<word>_than"; desugar's canonFunctor maps the wrappers.
    fn tryThanComparison(self: *Parser) ParseError!?VerbPhrase {
        const saved = self.pos;
        var word: ?[]const u8 = null;
        if (self.peek().tag == .kw_less) {
            word = "less";
            self.pos += 1;
        } else if (isIdentLike(self.peek().tag) and self.tokens[self.pos + 1].tag == .kw_than) {
            word = self.peek().lexeme;
            self.pos += 1;
        }
        if (word == null) return null;
        if (self.peek().tag != .kw_than) {
            self.pos = saved;
            return null;
        }
        self.pos += 1;
        const functor = std.mem.concat(self.allocator, u8, &.{ word.?, "_than" }) catch return ParseError.OutOfMemory;
        const arg_np = try self.allocNP(try self.parseNounPhrase());
        return .{ .is_a = .{ .noun = functor, .of_arg = arg_np } };
    }

    fn parseVerbPhraseAfterIs(self: *Parser) ParseError!VerbPhrase {
        // axiom-bjr: spaced comparison forms — "X is less than Y",
        // "X is greater than Y" (also bigger/smaller). The lexer has
        // tokenized less/than as keywords since the start; consume them.
        if (try self.tryThanComparison()) |vp| return vp;

        if (self.peek().tag == .kw_a or self.peek().tag == .kw_an) {
            self.pos += 1;
            if (!isIdentLike(self.peek().tag)) return self.fail(ParseError.UnexpectedToken);
            const noun = self.peek().lexeme;
            self.pos += 1;

            if (self.peek().tag == .kw_of) {
                self.pos += 1;
                const of_np = try self.allocNP(try self.parseNounPhrase());
                return .{ .is_a = .{ .noun = noun, .of_arg = of_np } };
            }

            // Direct argument without "of"
            const next_after_noun = self.peek().tag;
            if (next_after_noun == .lbracket or next_after_noun == .integer or
                (isIdentLike(next_after_noun) and next_after_noun != .dot and
                next_after_noun != .question and next_after_noun != .kw_if and
                next_after_noun != .kw_and and next_after_noun != .bang and
                next_after_noun != .star))
            {
                const arg_np = try self.allocNP(try self.parseNounPhrase());
                return .{ .is_a = .{ .noun = noun, .of_arg = arg_np } };
            }

            return .{ .is_a = .{ .noun = noun, .of_arg = null } };
        }

        if (isIdentLike(self.peek().tag)) {
            const word = self.peek().lexeme;
            self.pos += 1;

            if (self.peek().tag == .kw_of) {
                self.pos += 1;
                const of_np = try self.allocNP(try self.parseNounPhrase());
                return .{ .is_a = .{ .noun = word, .of_arg = of_np } };
            }

            const next = self.peek().tag;
            if (isIdentLike(next) or next == .variable or
                next == .kw_a or next == .kw_an or next == .kw_the or
                next == .integer or next == .lbracket)
            {
                if (next != .dot and next != .question and next != .kw_if and
                    next != .kw_and and next != .bang and next != .star)
                {
                    const arg_np = try self.allocNP(try self.parseNounPhrase());
                    return .{ .is_a = .{ .noun = word, .of_arg = arg_np } };
                }
            }

            return .{ .is_np = .{ .determined = .{ .det = null, .noun = word, .of_arg = null } } };
        }

        return self.fail(ParseError.UnexpectedToken);
    }

    fn parseNounPhrase(self: *Parser) ParseError!NounPhrase {
        const tok = self.peek();

        if (tok.tag == .lbracket) return self.parseListLiteral();

        if (tok.tag == .kw_a or tok.tag == .kw_an or tok.tag == .kw_the or tok.tag == .kw_every or tok.tag == .kw_each or tok.tag == .kw_that) {
            const det = tok.lexeme;
            self.pos += 1;
            if (!isIdentLike(self.peek().tag)) return self.fail(ParseError.UnexpectedToken);
            const noun = self.peek().lexeme;
            self.pos += 1;
            if (self.peek().tag == .kw_of) {
                self.pos += 1;
                const of_np = try self.allocNP(try self.parseNounPhrase());
                return .{ .determined = .{ .det = det, .noun = noun, .of_arg = of_np } };
            }
            return .{ .determined = .{ .det = det, .noun = noun, .of_arg = null } };
        }

        if (tok.tag == .variable) {
            self.pos += 1;
            return .{ .variable = tok.lexeme };
        }

        if (isIdentLike(tok.tag)) {
            self.pos += 1;
            return .{ .proper = tok.lexeme };
        }

        if (tok.tag == .integer) {
            self.pos += 1;
            const val = std.fmt.parseInt(i64, tok.lexeme, 10) catch return ParseError.UnexpectedToken;
            return .{ .integer = val };
        }

        return self.fail(ParseError.UnexpectedToken);
    }

    fn parseListLiteral(self: *Parser) ParseError!NounPhrase {
        self.pos += 1;
        var items: std.ArrayList(Term) = .empty;
        if (self.peek().tag != .rbracket) {
            try items.append(self.allocator, try self.parseTermElement());
            while (self.peek().tag == .comma) {
                self.pos += 1;
                try items.append(self.allocator, try self.parseTermElement());
            }
        }
        if (self.peek().tag != .rbracket) return self.fail(ParseError.UnexpectedToken);
        self.pos += 1;
        return .{ .list_literal = try items.toOwnedSlice(self.allocator) };
    }

    fn parseTermElement(self: *Parser) ParseError!Term {
        const tok = self.peek();
        if (tok.tag == .integer) {
            self.pos += 1;
            const val = std.fmt.parseInt(i64, tok.lexeme, 10) catch return ParseError.UnexpectedToken;
            return .{ .integer = val };
        }
        if (tok.tag == .variable) {
            self.pos += 1;
            return .{ .variable = tok.lexeme };
        }
        if (isIdentLike(tok.tag)) {
            self.pos += 1;
            return .{ .atom = tok.lexeme };
        }
        if (tok.tag == .lbracket) {
            const np = try self.parseListLiteral();
            switch (np) {
                .list_literal => |litems| return self.buildListTerm(litems),
                else => return ParseError.UnexpectedToken,
            }
        }
        return self.fail(ParseError.UnexpectedToken);
    }

    fn buildListTerm(self: *Parser, items: []const Term) ParseError!Term {
        if (items.len == 0) return .nil;
        var current: Term = .nil;
        var i: usize = items.len;
        while (i > 0) {
            i -= 1;
            const head_ptr = self.allocator.create(Term) catch return ParseError.OutOfMemory;
            head_ptr.* = items[i];
            const tail_ptr = self.allocator.create(Term) catch return ParseError.OutOfMemory;
            tail_ptr.* = current;
            current = .{ .list = .{ .head = head_ptr, .tail = tail_ptr } };
        }
        return current;
    }

    fn parseConditionList(self: *Parser) ParseError![]Condition {
        var conditions: std.ArrayList(Condition) = .empty;
        try conditions.append(self.allocator, try self.parseCondition());
        while (self.peek().tag == .kw_and) {
            self.pos += 1;
            try conditions.append(self.allocator, try self.parseCondition());
        }
        return conditions.toOwnedSlice(self.allocator);
    }

    fn parseCondition(self: *Parser) ParseError!Condition {
        if (self.peek().tag == .kw_cut) {
            self.pos += 1;
            if (self.peek().tag == .kw_here) self.pos += 1;
            return .cut;
        }
        if (self.peek().tag == .kw_not) {
            self.pos += 1;
            const sent = try self.parseSentence();
            return .{ .negated = sent };
        }
        const sent = try self.parseSentence();
        switch (sent.verb) {
            .is_not => |neg| return .{ .negated = .{
                .subject = sent.subject,
                .verb = switch (neg) {
                    .type_check => |n| .{ .is_a = .{ .noun = n, .of_arg = null } },
                    .predicate => |p| .{ .is_np = .{ .determined = .{ .det = null, .noun = p, .of_arg = null } } },
                    .predicate_with_arg => |pa| .{ .is_a = .{
                        .noun = pa.pred,
                        .of_arg = blk: {
                            const ptr = self.allocator.create(NounPhrase) catch break :blk null;
                            ptr.* = pa.arg;
                            break :blk ptr;
                        },
                    } },
                },
            } },
            else => return .{ .positive = sent },
        }
    }

    // ─── Helpers ───────────────────────────────────────────────────────────

    fn fail(self: *Parser, err: ParseError) ParseError {
        const tok = self.peek();
        self.last_error_line = tok.line;
        self.last_error_col = tok.col;
        self.last_error_token = tok.lexeme;
        return err;
    }

    pub fn peek(self: *const Parser) Token {
        if (self.pos < self.tokens.len) return self.tokens[self.pos];
        return .{ .tag = .eof, .lexeme = "", .line = 0, .col = 0 };
    }

    fn expectDot(self: *Parser) ParseError!void {
        if (self.peek().tag == .dot) {
            self.pos += 1;
            return;
        }
        return self.fail(ParseError.UnexpectedToken);
    }

    fn expectQuestion(self: *Parser) ParseError!void {
        if (self.peek().tag == .question) {
            self.pos += 1;
            return;
        }
        return self.fail(ParseError.UnexpectedToken);
    }

    pub fn recover(self: *Parser) void {
        while (self.pos < self.tokens.len) {
            const tag = self.tokens[self.pos].tag;
            self.pos += 1;
            if (tag == .dot or tag == .question or tag == .eof) break;
        }
    }

    fn allocNP(self: *Parser, np: NounPhrase) ParseError!*const NounPhrase {
        const ptr = self.allocator.create(NounPhrase) catch return ParseError.OutOfMemory;
        ptr.* = np;
        return ptr;
    }

    fn internCapitalize(self: *Parser, name: []const u8) ParseError![]const u8 {
        if (name.len == 0) return name;
        if (std.ascii.isUpper(name[0])) return name;
        const buf = self.allocator.alloc(u8, name.len) catch return ParseError.OutOfMemory;
        @memcpy(buf, name);
        buf[0] = std.ascii.toUpper(buf[0]);
        return buf;
    }

    fn isIdentLike(tag: TokenTag) bool {
        return switch (tag) {
            .atom, .variable => true,
            else => false,
        };
    }
};
