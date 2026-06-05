const std = @import("std");
const types = @import("types.zig");
const Term = types.Term;
const Goal = types.Goal;
const Clause = types.Clause;
const Sentence = types.Sentence;
const NounPhrase = types.NounPhrase;
const VerbPhrase = types.VerbPhrase;
const Condition = types.Condition;
const Statement = types.Statement;
const QueryKind = types.QueryKind;

pub const DesugarError = error{
    InvalidPattern,
    OutOfMemory,
};

pub const DesugarResult = union(enum) {
    clause: Clause,
    query: struct {
        goals: []const Goal,
        variables: []const []const u8,
    },
};

pub const Desugarer = struct {
    allocator: std.mem.Allocator,
    ground_context: bool, // true in facts (no free variables expected)
    in_query: bool, // true in queries (only _-prefixed vars are free)

    pub fn init(allocator: std.mem.Allocator) Desugarer {
        return .{ .allocator = allocator, .ground_context = false, .in_query = false };
    }

    pub fn desugar(self: *Desugarer, stmt: Statement) DesugarError!?DesugarResult {
        switch (stmt) {
            .fact => |f| {
                self.ground_context = true;
                defer self.ground_context = false;
                const head = try self.sentenceToCompound(f.sentence);
                return .{ .clause = .{ .head = head, .body = &.{}, .det = f.det } };
            },
            .rule => |rule| {
                self.ground_context = false;
                const head = try self.sentenceToCompound(rule.head);
                const body = try self.conditionsToGoals(rule.body);
                return .{ .clause = .{ .head = head, .body = body, .det = rule.det } };
            },
            .query => |q| {
                self.in_query = true;
                defer self.in_query = false;
                self.ground_context = (q.kind == .yes_no);
                const compound = try self.sentenceToCompound(q.sentence);
                const goal: Goal = .{ .call = compound };
                const goals = try self.allocSlice(Goal, &.{goal});

                // Collect variables
                var vars: std.ArrayList([]const u8) = .empty;
                try self.collectVarsFromCompound(compound, &vars);
                return .{ .query = .{
                    .goals = goals,
                    .variables = try vars.toOwnedSlice(self.allocator),
                } };
            },
            .command => return null,
            .mode_decl => return null, // handled directly by main
            .closed_world_decl => return null, // axiom-d4s: handled by host
            .should_query => return null, // axiom-i01: handled by host
            .which_actions_query => return null, // axiom-02w: handled by host
        }
    }

    fn sentenceToCompound(self: *Desugarer, sent: Sentence) DesugarError!Term.Compound {
        const subject_term = try self.npToTerm(sent.subject);

        switch (sent.verb) {
            .is_a => |ia| {
                if (ia.of_arg) |of_np| {
                    const obj_term = try self.npToTerm(of_np.*);
                    return .{
                        .functor = ia.noun,
                        .args = try self.allocSlice(Term, &.{ subject_term, obj_term }),
                    };
                }
                return .{
                    .functor = ia.noun,
                    .args = try self.allocSlice(Term, &.{subject_term}),
                };
            },
            .is_np => |np| {
                switch (np) {
                    .determined => |d| {
                        return .{
                            .functor = d.noun,
                            .args = try self.allocSlice(Term, &.{subject_term}),
                        };
                    },
                    .proper => |name| {
                        return .{
                            .functor = name,
                            .args = try self.allocSlice(Term, &.{subject_term}),
                        };
                    },
                    .variable => |name| {
                        return .{
                            .functor = name,
                            .args = try self.allocSlice(Term, &.{subject_term}),
                        };
                    },
                    .integer => return DesugarError.InvalidPattern,
                    .list_literal => return DesugarError.InvalidPattern,
                }
            },
            .has => |h| {
                const val_term = try self.npToTerm(h.value);
                return .{
                    .functor = h.property,
                    .args = try self.allocSlice(Term, &.{ subject_term, val_term }),
                };
            },
            .can => |c| {
                var name_buf: std.ArrayList(u8) = .empty;
                name_buf.appendSlice(self.allocator, "can_") catch return DesugarError.OutOfMemory;
                name_buf.appendSlice(self.allocator, c.verb) catch return DesugarError.OutOfMemory;
                if (c.particle) |p| {
                    name_buf.append(self.allocator, '_') catch return DesugarError.OutOfMemory;
                    name_buf.appendSlice(self.allocator, p) catch return DesugarError.OutOfMemory;
                }
                const functor = name_buf.toOwnedSlice(self.allocator) catch return DesugarError.OutOfMemory;
                return .{
                    .functor = functor,
                    .args = try self.allocSlice(Term, &.{subject_term}),
                };
            },
            .is_not => |neg| {
                switch (neg) {
                    .type_check => |n| {
                        return .{
                            .functor = n,
                            .args = try self.allocSlice(Term, &.{subject_term}),
                        };
                    },
                    .predicate => |p| {
                        return .{
                            .functor = p,
                            .args = try self.allocSlice(Term, &.{subject_term}),
                        };
                    },
                    .predicate_with_arg => |pa| {
                        const arg_term = try self.npToTerm(pa.arg);
                        return .{
                            .functor = pa.pred,
                            .args = try self.allocSlice(Term, &.{ subject_term, arg_term }),
                        };
                    },
                }
            },
        }
    }

    fn conditionsToGoals(self: *Desugarer, conditions: []const Condition) DesugarError![]const Goal {
        var goals: std.ArrayList(Goal) = .empty;
        for (conditions) |cond| {
            switch (cond) {
                .positive => |sent| {
                    const compound = try self.sentenceToCompound(sent);
                    goals.append(self.allocator, .{ .call = compound }) catch return DesugarError.OutOfMemory;
                },
                .negated => |sent| {
                    const compound = try self.sentenceToCompound(sent);
                    const inner_goal = self.allocator.create(Goal) catch return DesugarError.OutOfMemory;
                    inner_goal.* = .{ .call = compound };
                    goals.append(self.allocator, .{ .not = inner_goal }) catch return DesugarError.OutOfMemory;
                },
                .cut => {
                    goals.append(self.allocator, .cut) catch return DesugarError.OutOfMemory;
                },
            }
        }
        return goals.toOwnedSlice(self.allocator) catch return DesugarError.OutOfMemory;
    }

    fn npToTerm(self: *Desugarer, np: NounPhrase) DesugarError!Term {
        switch (np) {
            .proper => |name| {
                const lower = self.lowerString(name) catch return DesugarError.OutOfMemory;
                return .{ .atom = lower };
            },
            .variable => |name| {
                // Names starting with _ are always internal variables (query words)
                if (std.mem.startsWith(u8, name, "_")) {
                    return .{ .variable = name };
                }
                if (self.ground_context or self.in_query) {
                    // In ground contexts and queries, capitalized words are atoms
                    // (only _Who/_What/_Which are variables in queries)
                    const lower = self.lowerString(name) catch return DesugarError.OutOfMemory;
                    return .{ .atom = lower };
                }
                // In rules: all capitalized words are variables
                return .{ .variable = name };
            },
            .determined => |d| {
                if (d.det) |det| {
                    if (std.mem.eql(u8, det, "every") or std.mem.eql(u8, det, "each") or std.mem.eql(u8, det, "that")) {
                        const cap = self.capitalizeString(d.noun) catch return DesugarError.OutOfMemory;
                        return .{ .variable = cap };
                    }
                }
                return .{ .atom = d.noun };
            },
            .integer => |val| {
                return .{ .integer = val };
            },
            .list_literal => |items| {
                return self.buildListFromTerms(items);
            },
        }
    }

    fn buildListFromTerms(self: *Desugarer, items: []const Term) DesugarError!Term {
        if (items.len == 0) return .nil;
        var current: Term = .nil;
        var i: usize = items.len;
        while (i > 0) {
            i -= 1;
            const head_ptr = self.allocator.create(Term) catch return DesugarError.OutOfMemory;
            head_ptr.* = items[i];
            const tail_ptr = self.allocator.create(Term) catch return DesugarError.OutOfMemory;
            tail_ptr.* = current;
            current = .{ .list = .{ .head = head_ptr, .tail = tail_ptr } };
        }
        return current;
    }

    fn collectVarsFromCompound(self: *Desugarer, compound: Term.Compound, vars: *std.ArrayList([]const u8)) DesugarError!void {
        for (compound.args) |arg| {
            try self.collectVarsFromTerm(arg, vars);
        }
    }

    fn collectVarsFromTerm(self: *Desugarer, term: Term, vars: *std.ArrayList([]const u8)) DesugarError!void {
        switch (term) {
            .variable => |name| {
                for (vars.items) |existing| {
                    if (std.mem.eql(u8, existing, name)) return;
                }
                vars.append(self.allocator, name) catch return DesugarError.OutOfMemory;
            },
            .compound => |c| {
                for (c.args) |arg| {
                    try self.collectVarsFromTerm(arg, vars);
                }
            },
            .list => |l| {
                try self.collectVarsFromTerm(l.head.*, vars);
                try self.collectVarsFromTerm(l.tail.*, vars);
            },
            else => {},
        }
    }

    fn allocSlice(self: *Desugarer, comptime T: type, items: []const T) DesugarError![]const T {
        const slice = self.allocator.alloc(T, items.len) catch return DesugarError.OutOfMemory;
        @memcpy(slice, items);
        return slice;
    }

    fn lowerString(self: *Desugarer, s: []const u8) ![]const u8 {
        const buf = try self.allocator.alloc(u8, s.len);
        for (s, 0..) |c, i| {
            buf[i] = std.ascii.toLower(c);
        }
        return buf;
    }

    fn capitalizeString(self: *Desugarer, s: []const u8) ![]const u8 {
        if (s.len == 0) return s;
        const buf = try self.allocator.alloc(u8, s.len);
        @memcpy(buf, s);
        buf[0] = std.ascii.toUpper(buf[0]);
        return buf;
    }
};
