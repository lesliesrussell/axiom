//! Axiom C-ABI Foreign Function Interface
//!
//! All incoming C strings are copied into arena memory owned by
//! the program instance. Query results get their own arena and
//! MUST be freed with axiom_result_free() to avoid leaks.

const std = @import("std");
const types = @import("types.zig");
const lexer_mod = @import("lexer.zig");
const parser_mod = @import("parser.zig");
const desugar_mod = @import("desugar.zig");
const engine_mod = @import("engine.zig");

const Term = types.Term;
const Goal = types.Goal;
const Substitution = engine_mod.Substitution;

// ─── Opaque handle types ────────────────────────────────────────────────────

const ProgramHandle = struct {
    engine: engine_mod.Engine,
    arena: std.heap.ArenaAllocator,

    fn allocator(self: *ProgramHandle) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn dupe(self: *ProgramHandle, s: []const u8) ?[]const u8 {
        const alloc = self.arena.allocator();
        const buf = alloc.alloc(u8, s.len) catch return null;
        @memcpy(buf, s);
        return buf;
    }
};

const QueryResultHandle = struct {
    solutions: []Substitution,
    count: usize,
    arena: std.heap.ArenaAllocator,

    fn allocator(self: *QueryResultHandle) std.mem.Allocator {
        return self.arena.allocator();
    }
};

// ─── Program lifecycle ──────────────────────────────────────────────────────

export fn axiom_new() ?*ProgramHandle {
    const handle = std.heap.c_allocator.create(ProgramHandle) catch return null;
    handle.* = .{
        .arena = std.heap.ArenaAllocator.init(std.heap.c_allocator),
        .engine = undefined,
    };
    handle.engine = engine_mod.Engine.init(handle.arena.allocator());
    return handle;
}

export fn axiom_free(handle: ?*ProgramHandle) void {
    if (handle) |h| {
        h.arena.deinit();
        std.heap.c_allocator.destroy(h);
    }
}

// ─── Loading source ─────────────────────────────────────────────────────────

export fn axiom_load_source(handle: ?*ProgramHandle, source_ptr: [*c]const u8) c_int {
    const h = handle orelse return -1;
    const source = std.mem.span(source_ptr);
    const owned = h.dupe(source) orelse return -1;
    loadSourceInternal(h, owned) catch return -1;
    return 0;
}

export fn axiom_load_source_len(handle: ?*ProgramHandle, source_ptr: [*c]const u8, len: usize) c_int {
    const h = handle orelse return -1;
    const source = source_ptr[0..len];
    const owned = h.dupe(source) orelse return -1;
    loadSourceInternal(h, owned) catch return -1;
    return 0;
}

export fn axiom_load_file(handle: ?*ProgramHandle, path_ptr: [*c]const u8) c_int {
    const h = handle orelse return -1;
    const path = std.mem.span(path_ptr);
    const alloc = h.allocator();
    const source = std.Io.Dir.cwd().readFileAlloc(types.defaultIo(), path, alloc, .limited(4 * 1024 * 1024)) catch return -1; // axiom-6th
    loadSourceInternal(h, source) catch return -1;
    return 0;
}

fn loadSourceInternal(h: *ProgramHandle, source: []const u8) !void {
    const alloc = h.allocator();
    var lex = lexer_mod.Lexer.init(source);
    const tokens = try lex.tokenize(alloc);
    var parser = parser_mod.Parser.init(tokens, alloc);

    // axiom-02w: per-statement parsing captures spans and '% id:' labels
    while (parser.peek().tag != .eof) {
        const start_idx = parser.pos;
        if (parser.parseStatement()) |stmt| {
            const span = types.statementSpan(source, tokens, start_idx, parser.pos - 1);
            var desugarer = desugar_mod.Desugarer.init(alloc);
            if (try desugarer.desugar(stmt)) |result| {
                switch (result) {
                    .clause => |clause| {
                        var c = clause;
                        c.source_text = span;
                        c.label = types.labelBefore(source, span);
                        try h.engine.addClause(c);
                    },
                    .query => {},
                }
            }
        } else |_| {
            parser.recover();
        }
    }
}

// ─── Asserting facts ────────────────────────────────────────────────────────

export fn axiom_assert_fact1(handle: ?*ProgramHandle, functor: [*c]const u8, arg1: [*c]const u8) c_int {
    const h = handle orelse return -1;
    const alloc = h.allocator();
    const f = h.dupe(std.mem.span(functor)) orelse return -1;
    const a1 = h.dupe(std.mem.span(arg1)) orelse return -1;
    const args = alloc.alloc(Term, 1) catch return -1;
    args[0] = .{ .atom = a1 };
    h.engine.addClause(.{
        .head = .{ .functor = f, .args = args },
        .body = &.{},
    }) catch return -1;
    return 0;
}

export fn axiom_assert_fact2(handle: ?*ProgramHandle, functor: [*c]const u8, arg1: [*c]const u8, arg2: [*c]const u8) c_int {
    const h = handle orelse return -1;
    const alloc = h.allocator();
    const f = h.dupe(std.mem.span(functor)) orelse return -1;
    const a1 = h.dupe(std.mem.span(arg1)) orelse return -1;
    const a2 = h.dupe(std.mem.span(arg2)) orelse return -1;
    const args = alloc.alloc(Term, 2) catch return -1;
    args[0] = .{ .atom = a1 };
    args[1] = .{ .atom = a2 };
    h.engine.addClause(.{
        .head = .{ .functor = f, .args = args },
        .body = &.{},
    }) catch return -1;
    return 0;
}

// ─── Querying ───────────────────────────────────────────────────────────────

export fn axiom_query1(handle: ?*ProgramHandle, functor: [*c]const u8) ?*QueryResultHandle {
    const h = handle orelse return null;
    const f = h.dupe(std.mem.span(functor)) orelse return null;
    return doQueryBuild(h, f, &.{.{ .variable = "X" }});
}

export fn axiom_query_ground1(handle: ?*ProgramHandle, functor: [*c]const u8, arg1: [*c]const u8) ?*QueryResultHandle {
    const h = handle orelse return null;
    const f = h.dupe(std.mem.span(functor)) orelse return null;
    const a1 = h.dupe(std.mem.span(arg1)) orelse return null;
    return doQueryBuild(h, f, &.{.{ .atom = a1 }});
}

export fn axiom_query2_av(handle: ?*ProgramHandle, functor: [*c]const u8, arg1: [*c]const u8) ?*QueryResultHandle {
    const h = handle orelse return null;
    const f = h.dupe(std.mem.span(functor)) orelse return null;
    const a1 = h.dupe(std.mem.span(arg1)) orelse return null;
    return doQueryBuild(h, f, &.{ .{ .atom = a1 }, .{ .variable = "Y" } });
}

export fn axiom_query2_vv(handle: ?*ProgramHandle, functor: [*c]const u8) ?*QueryResultHandle {
    const h = handle orelse return null;
    const f = h.dupe(std.mem.span(functor)) orelse return null;
    return doQueryBuild(h, f, &.{ .{ .variable = "X" }, .{ .variable = "Y" } });
}

export fn axiom_query_english(handle: ?*ProgramHandle, query_ptr: [*c]const u8) ?*QueryResultHandle {
    const h = handle orelse return null;
    const query_str = std.mem.span(query_ptr);
    const owned = h.dupe(query_str) orelse return null;

    // Parse on the program arena (source/tokens are transient)
    const prog_alloc = h.allocator();
    var lex = lexer_mod.Lexer.init(owned);
    const tokens = lex.tokenize(prog_alloc) catch return null;
    var parser = parser_mod.Parser.init(tokens, prog_alloc);
    const stmts = parser.parseProgram() catch return null;

    for (stmts) |stmt| {
        var desugarer = desugar_mod.Desugarer.init(prog_alloc);
        if (desugarer.desugar(stmt) catch null) |result| {
            switch (result) {
                .query => |q| return doQuery(h, q.goals),
                .clause => {},
            }
        }
    }
    return null;
}

/// Build goal args on the program arena, then run query on its own arena.
fn doQueryBuild(h: *ProgramHandle, functor: []const u8, template_args: []const Term) ?*QueryResultHandle {
    const prog_alloc = h.allocator();
    const args = prog_alloc.alloc(Term, template_args.len) catch return null;
    @memcpy(args, template_args);
    const goals = prog_alloc.alloc(Goal, 1) catch return null;
    goals[0] = .{ .call = .{ .functor = functor, .args = args } };
    return doQuery(h, goals);
}

/// Run a query. Solutions are allocated in their own arena so they
/// can be freed independently via axiom_result_free().
fn doQuery(h: *ProgramHandle, goals: []const Goal) ?*QueryResultHandle {
    // Allocate the result handle with c_allocator (not in any arena)
    const qr = std.heap.c_allocator.create(QueryResultHandle) catch return null;
    qr.* = .{
        .solutions = &.{},
        .count = 0,
        .arena = std.heap.ArenaAllocator.init(std.heap.c_allocator),
    };

    // Run the engine — it allocates renamed vars, substitutions, etc.
    // We need to temporarily swap the engine's allocator to the query arena
    // so all solution data lives there and can be freed with the result.
    const saved_alloc = h.engine.allocator;
    h.engine.allocator = qr.arena.allocator();
    defer h.engine.allocator = saved_alloc;

    const solutions = h.engine.solveAll(goals) catch {
        qr.arena.deinit();
        std.heap.c_allocator.destroy(qr);
        return null;
    };

    qr.solutions = solutions;
    qr.count = solutions.len;
    return qr;
}

// ─── Query result access ────────────────────────────────────────────────────

export fn axiom_result_count(result: ?*QueryResultHandle) usize {
    if (result) |r| return r.count;
    return 0;
}

export fn axiom_result_get_binding(result: ?*QueryResultHandle, solution_index: usize, var_name: [*c]const u8) [*c]const u8 {
    const r = result orelse return null;
    if (solution_index >= r.count) return null;
    const solution = &r.solutions[solution_index];
    const name = std.mem.span(var_name);
    const alloc = r.arena.allocator();

    const resolved = solution.deepWalk(.{ .variable = name }, alloc) catch return null;
    return termToCStr(resolved, alloc) orelse return null;
}

export fn axiom_result_has_solutions(result: ?*QueryResultHandle) bool {
    if (result) |r| return r.count > 0;
    return false;
}

/// Free a query result and all its solution memory.
/// Must be called for every result returned by axiom_query_*.
export fn axiom_result_free(result: ?*QueryResultHandle) void {
    if (result) |r| {
        r.arena.deinit();
        std.heap.c_allocator.destroy(r);
    }
}

fn termToCStr(term: Term, alloc: std.mem.Allocator) ?[*c]const u8 {
    switch (term) {
        .atom => |a| {
            const buf = alloc.allocSentinel(u8, a.len, 0) catch return null;
            @memcpy(buf, a);
            return buf.ptr;
        },
        .integer => |i| {
            var num_buf: [20]u8 = undefined;
            var v: u64 = if (i < 0) @intCast(-i) else @intCast(i);
            var pos: usize = num_buf.len;
            if (v == 0) {
                pos -= 1;
                num_buf[pos] = '0';
            } else {
                while (v > 0) {
                    pos -= 1;
                    num_buf[pos] = @intCast('0' + (v % 10));
                    v /= 10;
                }
            }
            if (i < 0) {
                pos -= 1;
                num_buf[pos] = '-';
            }
            const digits = num_buf[pos..];
            const buf = alloc.allocSentinel(u8, digits.len, 0) catch return null;
            @memcpy(buf, digits);
            return buf.ptr;
        },
        .variable => |v_str| {
            const buf = alloc.allocSentinel(u8, v_str.len, 0) catch return null;
            @memcpy(buf, v_str);
            return buf.ptr;
        },
        .nil => {
            const buf = alloc.allocSentinel(u8, 2, 0) catch return null;
            buf[0] = '[';
            buf[1] = ']';
            return buf.ptr;
        },
        else => return null,
    }
}

// ─── Utility ────────────────────────────────────────────────────────────────

export fn axiom_clause_count(handle: ?*ProgramHandle) usize {
    if (handle) |h| return h.engine.getClauses().len;
    return 0;
}

export fn axiom_set_trace(handle: ?*ProgramHandle, enabled: bool) void {
    if (handle) |h| h.engine.trace_enabled = enabled;
}

// ─── Decisions (axiom-i01) ──────────────────────────────────────────────────

pub const AxiomDecisionOutcome = enum(c_int) {
    allow = 0,
    deny = 1,
    indeterminate = 2,
};

pub const AxiomDecision = extern struct {
    outcome: AxiomDecisionOutcome,
    subject: [*:0]const u8,
    action: [*:0]const u8,
    resource: ?[*:0]const u8,
    reason_count: usize,
    reasons: ?[*]const [*:0]const u8,
    evidence_count: usize,
    evidence: ?[*]const [*:0]const u8,
};

fn dupeZ(alloc: std.mem.Allocator, s: []const u8) ?[*:0]const u8 {
    const buf = alloc.allocSentinel(u8, s.len, 0) catch return null;
    @memcpy(buf, s);
    return buf.ptr;
}

fn dupeStringList(alloc: std.mem.Allocator, items: []const []const u8) ?[*]const [*:0]const u8 {
    if (items.len == 0) return null;
    const out = alloc.alloc([*:0]const u8, items.len) catch return null;
    for (items, 0..) |item, i| {
        out[i] = dupeZ(alloc, item) orelse return null;
    }
    return out.ptr;
}

/// Evaluate decision rules for (subject, action[, resource]).
/// Deny-overrides conflict resolution. Result and all strings are owned
/// by the program's arena — valid until axiom_free, do not free.
export fn axiom_decide(handle: ?*ProgramHandle, subject: ?[*:0]const u8, action: ?[*:0]const u8, resource: ?[*:0]const u8) ?*AxiomDecision {
    const h = handle orelse return null;
    const subj = subject orelse return null;
    const act = action orelse return null;
    const alloc = h.arena.allocator();

    // copy inputs into the arena (existing capi memory-safety policy)
    const subj_s = alloc.dupe(u8, std.mem.span(subj)) catch return null;
    const act_s = alloc.dupe(u8, std.mem.span(act)) catch return null;
    const res_s: ?[]const u8 = if (resource) |r| alloc.dupe(u8, std.mem.span(r)) catch return null else null;

    const decision = h.engine.decide(subj_s, act_s, res_s) catch return null;

    const out = alloc.create(AxiomDecision) catch return null;
    out.* = .{
        .outcome = switch (decision.outcome) {
            .allow => .allow,
            .deny => .deny,
            .indeterminate => .indeterminate,
        },
        .subject = dupeZ(alloc, subj_s) orelse return null,
        .action = dupeZ(alloc, act_s) orelse return null,
        .resource = if (res_s) |r| dupeZ(alloc, r) else null,
        .reason_count = decision.reasons.len,
        .reasons = dupeStringList(alloc, decision.reasons),
        .evidence_count = decision.evidence.len,
        .evidence = dupeStringList(alloc, decision.evidence),
    };
    return out;
}

// ─── Semantic diff + what-if (axiom-aof) ────────────────────────────────────

pub const AxiomDiffKind = enum(c_int) {
    added = 0,
    removed = 1,
    modified = 2,
};

pub const AxiomRuleDiff = extern struct {
    kind: AxiomDiffKind,
    predicate: [*:0]const u8, // "name/arity" of the head
    rule_id: [*:0]const u8, // label, or 16-hex clause id
    old_english: ?[*:0]const u8, // null for added
    new_english: ?[*:0]const u8, // null for removed
};

fn predSpec(alloc: std.mem.Allocator, clause: types.Clause) ?[*:0]const u8 {
    var buf: [160]u8 = undefined;
    const spec = std.fmt.bufPrint(&buf, "{s}/{d}", .{ clause.head.functor, clause.head.args.len }) catch return null;
    return dupeZ(alloc, spec);
}

fn ruleIdStr(alloc: std.mem.Allocator, clause: types.Clause) ?[*:0]const u8 {
    if (clause.label.len > 0) return dupeZ(alloc, clause.label);
    var hex_buf: [16]u8 = undefined;
    const hex = engine_mod.identity.hashHex(clause.id, &hex_buf);
    return dupeZ(alloc, hex);
}

fn clauseEnglishZ(alloc: std.mem.Allocator, clause: types.Clause) ?[*:0]const u8 {
    const sentence = engine_mod.english.clauseToEnglish(alloc, clause) catch return null;
    return dupeZ(alloc, sentence);
}

/// Clause-level semantic diff. Results (and strings) are owned by NEWP's
/// arena: valid until axiom_free(newp), do not free individually.
export fn axiom_diff_programs(oldp: ?*ProgramHandle, newp: ?*ProgramHandle, out_count: ?*usize) ?[*]AxiomRuleDiff {
    const op = oldp orelse return null;
    const np = newp orelse return null;
    const count_out = out_count orelse return null;
    const alloc = np.arena.allocator();

    const diffs = engine_mod.diff.diffPrograms(alloc, op.engine.getClauses(), np.engine.getClauses()) catch return null;
    const out = alloc.alloc(AxiomRuleDiff, diffs.len) catch return null;
    for (diffs, 0..) |d, i| {
        const rep = d.new_clause orelse d.old_clause.?;
        out[i] = .{
            .kind = switch (d.kind) {
                .added => .added,
                .removed => .removed,
                .modified => .modified,
            },
            .predicate = predSpec(alloc, rep) orelse return null,
            .rule_id = ruleIdStr(alloc, rep) orelse return null,
            .old_english = if (d.old_clause) |c| clauseEnglishZ(alloc, c) else null,
            .new_english = if (d.new_clause) |c| clauseEnglishZ(alloc, c) else null,
        };
    }
    count_out.* = diffs.len;
    return out.ptr;
}

pub const AxiomDecisionInput = extern struct {
    subject: [*:0]const u8,
    action: [*:0]const u8,
    resource: ?[*:0]const u8,
};

pub const AxiomDecisionDelta = extern struct {
    input: AxiomDecisionInput,
    old_decision: *AxiomDecision,
    new_decision: *AxiomDecision,
};

fn decisionToC(alloc: std.mem.Allocator, d: engine_mod.Engine.Decision, subj: [*:0]const u8, act: [*:0]const u8, res: ?[*:0]const u8) ?*AxiomDecision {
    const out = alloc.create(AxiomDecision) catch return null;
    out.* = .{
        .outcome = switch (d.outcome) {
            .allow => .allow,
            .deny => .deny,
            .indeterminate => .indeterminate,
        },
        .subject = subj,
        .action = act,
        .resource = res,
        .reason_count = d.reasons.len,
        .reasons = dupeStringList(alloc, d.reasons),
        .evidence_count = d.evidence.len,
        .evidence = dupeStringList(alloc, d.evidence),
    };
    return out;
}

/// Run each input against both programs; return the inputs whose OUTCOME
/// differs. Results owned by NEWP's arena (valid until axiom_free(newp)).
export fn axiom_compare_decisions(oldp: ?*ProgramHandle, newp: ?*ProgramHandle, inputs: ?[*]const AxiomDecisionInput, input_count: usize, out_count: ?*usize) ?[*]AxiomDecisionDelta {
    const op = oldp orelse return null;
    const np = newp orelse return null;
    const ins = inputs orelse return null;
    const count_out = out_count orelse return null;
    const alloc = np.arena.allocator();

    var deltas: std.ArrayList(AxiomDecisionDelta) = .empty;
    for (ins[0..input_count]) |inp| {
        const subj = alloc.dupe(u8, std.mem.span(inp.subject)) catch return null;
        const act = alloc.dupe(u8, std.mem.span(inp.action)) catch return null;
        const res: ?[]const u8 = if (inp.resource) |r| alloc.dupe(u8, std.mem.span(r)) catch return null else null;

        const old_d = op.engine.decide(subj, act, res) catch continue;
        const new_d = np.engine.decide(subj, act, res) catch continue;
        if (old_d.outcome == new_d.outcome) continue;

        const subj_z = dupeZ(alloc, subj) orelse return null;
        const act_z = dupeZ(alloc, act) orelse return null;
        const res_z: ?[*:0]const u8 = if (res) |r| dupeZ(alloc, r) else null;
        deltas.append(alloc, .{
            .input = .{ .subject = subj_z, .action = act_z, .resource = res_z },
            .old_decision = decisionToC(alloc, old_d, subj_z, act_z, res_z) orelse return null,
            .new_decision = decisionToC(alloc, new_d, subj_z, act_z, res_z) orelse return null,
        }) catch return null;
    }
    count_out.* = deltas.items.len;
    const slice = deltas.toOwnedSlice(alloc) catch return null;
    return slice.ptr;
}

// ─── Allowed alternatives (axiom-02w) ───────────────────────────────────────

/// Actions from the KB's action/1 universe that decide() allows for this
/// subject[/resource]. Returns an array of strings owned by the program's
/// arena (valid until axiom_free); count written to out_count.
export fn axiom_allowed_actions(handle: ?*ProgramHandle, subject: ?[*:0]const u8, resource: ?[*:0]const u8, out_count: ?*usize) ?[*]const [*:0]const u8 {
    const h = handle orelse return null;
    const subj = subject orelse return null;
    const count_out = out_count orelse return null;
    const alloc = h.arena.allocator();

    const subj_s = alloc.dupe(u8, std.mem.span(subj)) catch return null;
    const res_s: ?[]const u8 = if (resource) |r| alloc.dupe(u8, std.mem.span(r)) catch return null else null;

    const actions = h.engine.allowedActions(subj_s, res_s) catch return null;
    count_out.* = actions.len;
    if (actions.len == 0) return null;
    return dupeStringList(alloc, actions);
}
