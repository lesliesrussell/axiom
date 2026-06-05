//! Axiom Embedding API
//!
//! Use this to embed the Axiom logic engine in your Zig application.
//!
//! ```zig
//! const axiom = @import("axiom");
//!
//! var program = try axiom.Program.init(allocator);
//! try program.loadFile("rules.axm");
//! try program.assertFact("man", &.{.{ .atom = "socrates" }});
//!
//! var iter = try program.query("mortal", &.{.{ .variable = "X" }});
//! while (iter.next()) |solution| {
//!     const x = solution.get("X");
//!     // ...
//! }
//! ```

const std = @import("std");
const types = @import("types.zig");
const lexer_mod = @import("lexer.zig");
const parser_mod = @import("parser.zig");
const desugar_mod = @import("desugar.zig");
const engine_mod = @import("engine.zig");

pub const Term = types.Term;
pub const Goal = types.Goal;
pub const Clause = types.Clause;
pub const Substitution = engine_mod.Substitution;

pub const Program = struct {
    engine: engine_mod.Engine,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Program {
        return .{
            .engine = engine_mod.Engine.init(allocator),
            .allocator = allocator,
        };
    }

    /// Load and process an Axiom source file
    pub fn loadFile(self: *Program, path: []const u8) !void {
        const source = try std.Io.Dir.cwd().readFileAlloc(types.defaultIo(), path, self.allocator, .limited(1024 * 1024)); // axiom-6th
        try self.loadSource(source);
    }

    /// Load and process Axiom source code from a string
    pub fn loadSource(self: *Program, source: []const u8) !void {
        var lex = lexer_mod.Lexer.init(source);
        const tokens = try lex.tokenize(self.allocator);
        var parser = parser_mod.Parser.init(tokens, self.allocator);
        const stmts = try parser.parseProgram();

        for (stmts) |stmt| {
            var desugarer = desugar_mod.Desugarer.init(self.allocator);
            if (try desugarer.desugar(stmt)) |result| {
                switch (result) {
                    .clause => |clause| try self.engine.addClause(clause),
                    .query => {},
                }
            }
        }
    }

    /// Assert a fact directly using the core AST
    pub fn assertFact(self: *Program, functor: []const u8, args: []const Term) !void {
        const args_copy = try self.allocator.alloc(Term, args.len);
        @memcpy(args_copy, args);
        try self.engine.addClause(.{
            .head = .{ .functor = functor, .args = args_copy },
            .body = &.{},
        });
    }

    /// Assert a rule directly using the core AST
    pub fn assertRule(self: *Program, head_functor: []const u8, head_args: []const Term, body: []const Goal) !void {
        const args_copy = try self.allocator.alloc(Term, head_args.len);
        @memcpy(args_copy, head_args);
        const body_copy = try self.allocator.alloc(Goal, body.len);
        @memcpy(body_copy, body);
        try self.engine.addClause(.{
            .head = .{ .functor = head_functor, .args = args_copy },
            .body = body_copy,
        });
    }

    /// Query the engine and return all solutions
    pub fn queryAll(self: *Program, functor: []const u8, args: []const Term) ![]Substitution {
        const args_copy = try self.allocator.alloc(Term, args.len);
        @memcpy(args_copy, args);
        const goal = Goal{ .call = .{ .functor = functor, .args = args_copy } };
        const goals = try self.allocator.alloc(Goal, 1);
        goals[0] = goal;
        return self.engine.solveAll(goals);
    }

    /// Query and return an iterator over solutions
    pub fn query(self: *Program, functor: []const u8, args: []const Term) !QueryIterator {
        const solutions = try self.queryAll(functor, args);
        return QueryIterator{
            .solutions = solutions,
            .index = 0,
            .allocator = self.allocator,
        };
    }

    /// Evaluate decision rules for (subject, action[, resource]).
    /// Deny-overrides; see Engine.decide. axiom-i01
    pub fn decide(self: *Program, subject: []const u8, action: []const u8, resource: ?[]const u8) !engine_mod.Engine.Decision {
        return self.engine.decide(subject, action, resource);
    }

    /// Get the number of loaded clauses
    pub fn clauseCount(self: *const Program) usize {
        return self.engine.getClauses().len;
    }

    /// Enable or disable tracing
    pub fn setTrace(self: *Program, enabled: bool) void {
        self.engine.trace_enabled = enabled;
    }
};

pub const QueryIterator = struct {
    solutions: []Substitution,
    index: usize,
    allocator: std.mem.Allocator,

    pub fn next(self: *QueryIterator) ?*const Substitution {
        if (self.index >= self.solutions.len) return null;
        const result = &self.solutions[self.index];
        self.index += 1;
        return result;
    }

    /// Reset iterator to the beginning
    pub fn reset(self: *QueryIterator) void {
        self.index = 0;
    }

    /// Get total number of solutions
    pub fn count(self: *const QueryIterator) usize {
        return self.solutions.len;
    }
};
