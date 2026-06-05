const std = @import("std");

pub const Allocator = std.mem.Allocator;

// axiom-6th
// Shared default Io instance for blocking file/stdio operations (Zig 0.16
// threads an explicit `std.Io` through fs and stdio APIs).
var io_threaded: ?std.Io.Threaded = null;

// axiom-02w (moved from main.zig so lib/capi loaders capture labels too)
/// Byte offset of (1-based) line/col in source. The lexer counts columns
/// per byte.
pub fn byteOffsetOf(source: []const u8, line: usize, col: usize) usize {
    var cur_line: usize = 1;
    var i: usize = 0;
    while (i < source.len and cur_line < line) : (i += 1) {
        if (source[i] == '\n') cur_line += 1;
    }
    return @min(i + col - 1, source.len);
}

/// Source span of a statement from its first through last token
/// (inclusive). Token lexemes can be static literals, so offsets come
/// from line/col.
pub fn statementSpan(source: []const u8, tokens: []const Token, start_idx: usize, end_idx: usize) []const u8 {
    if (start_idx >= tokens.len or end_idx >= tokens.len or end_idx < start_idx) return "";
    const st = tokens[start_idx];
    const et = tokens[end_idx];
    const s = byteOffsetOf(source, st.line, st.col);
    const e = @min(byteOffsetOf(source, et.line, et.col) + et.lexeme.len, source.len);
    if (e <= s) return "";
    return source[s..e];
}

/// '% id: <label>' on the line immediately above a statement names it.
pub fn labelBefore(source: []const u8, span: []const u8) []const u8 {
    if (span.len == 0) return "";
    const offset = @intFromPtr(span.ptr) - @intFromPtr(source.ptr);
    if (offset == 0 or offset > source.len) return "";
    var i = offset;
    while (i > 0 and (source[i - 1] == ' ' or source[i - 1] == '\t' or source[i - 1] == '\n' or source[i - 1] == '\r')) i -= 1;
    if (i == 0) return "";
    const line_end = i;
    var line_start = i;
    while (line_start > 0 and source[line_start - 1] != '\n') line_start -= 1;
    const line = std.mem.trim(u8, source[line_start..line_end], &std.ascii.whitespace);
    const prefix = "% id:";
    if (!std.mem.startsWith(u8, line, prefix)) return "";
    return std.mem.trim(u8, line[prefix.len..], &std.ascii.whitespace);
}

pub fn defaultIo() std.Io {
    if (io_threaded == null) io_threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    return io_threaded.?.io();
}

// ─── Tokens ────────────────────────────────────────────────────────────────

pub const TokenTag = enum {
    // Identifiers
    atom, // lowercase identifier
    variable, // capitalized identifier
    integer, // integer literal

    // Keywords
    kw_is,
    kw_a,
    kw_an,
    kw_if,
    kw_and,
    kw_not,
    kw_has, // also "have"
    kw_of,
    kw_every,
    kw_each,
    kw_who,
    kw_what,
    kw_which,
    kw_cut,
    kw_here,
    kw_can,
    kw_the,
    kw_that,
    kw_whose,
    kw_head,
    kw_tail,
    kw_less,
    kw_than,
    kw_include,
    kw_mode,

    // Literals
    string, // "quoted string"

    // Punctuation
    dot, // .
    question, // ?
    comma, // ,
    semicolon, // ;
    lbracket, // [
    rbracket, // ]
    pipe, // |
    percent, // % (comment start)
    bang, // !
    star, // *
    plus, // +
    minus, // -
    lparen, // (
    rparen, // )

    eof,
};

pub const Token = struct {
    tag: TokenTag,
    lexeme: []const u8,
    line: usize,
    col: usize,
};

// ─── Core AST (Prolog-like) ────────────────────────────────────────────────

pub const Term = union(enum) {
    atom: []const u8,
    variable: []const u8,
    integer: i64,
    compound: Compound,
    list: TermList,
    nil, // empty list

    pub const Compound = struct {
        functor: []const u8,
        args: []const Term,
    };

    pub const TermList = struct {
        head: *const Term,
        tail: *const Term,
    };

    pub fn eql(a: Term, b: Term) bool {
        const a_tag: @typeInfo(Term).@"union".tag_type.? = a;
        const b_tag: @typeInfo(Term).@"union".tag_type.? = b;
        if (a_tag != b_tag) return false;
        switch (a) {
            .atom => return std.mem.eql(u8, a.atom, b.atom),
            .variable => return std.mem.eql(u8, a.variable, b.variable),
            .integer => return a.integer == b.integer,
            .nil => return true,
            .compound => {
                if (!std.mem.eql(u8, a.compound.functor, b.compound.functor)) return false;
                if (a.compound.args.len != b.compound.args.len) return false;
                for (a.compound.args, b.compound.args) |aa, bb| {
                    if (!eql(aa, bb)) return false;
                }
                return true;
            },
            .list => {
                return eql(a.list.head.*, b.list.head.*) and eql(a.list.tail.*, b.list.tail.*);
            },
        }
    }

    pub fn format(self: Term, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try formatTerm(self, writer);
    }

    fn formatTerm(self: Term, writer: anytype) !void {
        switch (self) {
            .atom => |a| try writer.print("{s}", .{a}),
            .variable => |v| try writer.print("{s}", .{v}),
            .integer => |i| try writer.print("{d}", .{i}),
            .nil => try writer.writeAll("[]"),
            .compound => |c| {
                try writer.print("{s}(", .{c.functor});
                for (c.args, 0..) |arg, idx| {
                    if (idx > 0) try writer.writeAll(", ");
                    try formatTerm(arg, writer);
                }
                try writer.writeAll(")");
            },
            .list => |l| {
                try writer.writeAll("[");
                try formatTerm(l.head.*, writer);
                var tail = l.tail;
                while (true) {
                    switch (tail.*) {
                        .list => |next| {
                            try writer.writeAll(", ");
                            try formatTerm(next.head.*, writer);
                            tail = next.tail;
                        },
                        .nil => break,
                        else => {
                            try writer.writeAll(" | ");
                            try formatTerm(tail.*, writer);
                            break;
                        },
                    }
                }
                try writer.writeAll("]");
            },
        }
    }
};

pub const Goal = union(enum) {
    call: Term.Compound,
    not: *const Goal,
    cut: void,
};

pub const Clause = struct {
    head: Term.Compound,
    body: []const Goal,
    det: Determinism = .unspecified,
    source_text: []const u8 = "", // axiom-76a: original sentence for :save
    id: u64 = 0, // axiom-ekd: alpha-normalized hash, set by addClause
    label: []const u8 = "", // axiom-ekd: optional '% id: name' annotation
};

// ─── English Surface AST ───────────────────────────────────────────────────

pub const Sentence = struct {
    subject: NounPhrase,
    verb: VerbPhrase,
};

pub const NounPhrase = union(enum) {
    proper: []const u8, // capitalized name -> atom
    variable: []const u8, // capitalized word used as variable in rules
    integer: i64, // numeric literal
    determined: struct {
        det: ?[]const u8, // a, an, every, each, the, that
        noun: []const u8,
        of_arg: ?*const NounPhrase,
    },
    list_literal: []const Term, // [1, 2, 3]
};

pub const VerbPhrase = union(enum) {
    is_a: struct {
        noun: []const u8,
        of_arg: ?*const NounPhrase,
    },
    is_np: NounPhrase, // X is Y (adjective/predicate)
    has: struct {
        property: []const u8,
        value: NounPhrase,
    },
    can: struct {
        verb: []const u8, // e.g. "log"
        particle: ?[]const u8, // e.g. "in"
    },
    is_not: IsNot,

    pub const IsNot = union(enum) {
        type_check: []const u8, // X is not a Y -> \+ Y(X)
        predicate: []const u8, // X is not banned -> \+ banned(X)
        predicate_with_arg: struct { // X is not same_as Y -> \+ same_as(X, Y)
            pred: []const u8,
            arg: NounPhrase,
        },
    };
};

pub const Condition = union(enum) {
    positive: Sentence,
    negated: Sentence,
    cut: void,
};

pub const Statement = union(enum) {
    fact: struct {
        sentence: Sentence,
        det: Determinism,
    },
    rule: struct {
        head: Sentence,
        body: []const Condition,
        det: Determinism,
    },
    query: struct {
        kind: QueryKind,
        sentence: Sentence,
    },
    command: Command,
    mode_decl: ModeDecl,
    closed_world_decl: []const u8, // axiom-d4s: predicate name
    should_query: struct { // axiom-i01: Should <subject> <action> [<resource>]?
        subject: []const u8,
        action: []const u8,
        resource: ?[]const u8,
    },
    which_actions_query: struct { // axiom-02w: Which actions can S perform [on R]?
        subject: []const u8,
        resource: ?[]const u8,
    },
    why_not_query: void, // axiom-07s: "Why not?"
};

pub const QueryKind = enum {
    yes_no, // Is X ...?
    who, // Who is ...?
    what, // What is ...?
    which, // Which X ...?
};

pub const Command = union(enum) {
    load: []const u8,
    show: void,
    include: []const u8,
};

// ─── Determinism and Mode Annotations ──────────────────────────────────────

pub const Determinism = enum {
    det, // ! — exactly one solution
    semidet, // ? — zero or one solution
    nondet, // * — multiple solutions
    unspecified,

    pub fn marker(self: Determinism) ?u8 {
        return switch (self) {
            .det => '!',
            .semidet => '?',
            .nondet => '*',
            .unspecified => null,
        };
    }

    pub fn label(self: Determinism) []const u8 {
        return switch (self) {
            .det => "det (!)",
            .semidet => "semidet (?)",
            .nondet => "nondet (*)",
            .unspecified => "unspecified",
        };
    }
};

pub const Mode = enum {
    in, // + — must be ground
    out, // - — will be bound
    any, // ? — either

    pub fn marker(self: Mode) u8 {
        return switch (self) {
            .in => '+',
            .out => '-',
            .any => '?',
        };
    }
};

pub const PredicateInfo = struct {
    name: []const u8,
    arity: u8,
    det: Determinism,
    arg_modes: ?[]const Mode, // null if no mode declared
    source_file: ?[]const u8,
    first_line: usize,
};

pub const ModeDecl = struct {
    pred_name: []const u8,
    arg_names: []const []const u8,
    arg_modes: []const Mode,
    det: Determinism,
};
