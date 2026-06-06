const std = @import("std");
const lexer_mod = @import("lexer.zig");
const parser_mod = @import("parser.zig");
const desugar_mod = @import("desugar.zig");
const engine_mod = @import("engine.zig");
const types = @import("types.zig");
const editor_mod = @import("editor.zig"); // axiom-82z
const jsonout = @import("jsonout.zig"); // axiom-47h

const Lexer = lexer_mod.Lexer;
const Parser = parser_mod.Parser;
const Desugarer = desugar_mod.Desugarer;
const Engine = engine_mod.Engine;
const Substitution = engine_mod.Substitution;
const Term = types.Term;
const Goal = types.Goal;
const Statement = types.Statement;
const Clause = types.Clause;
const Determinism = types.Determinism;
const PredicateInfo = types.PredicateInfo;

// axiom-6th
const stdout_file = std.Io.File.stdout();

fn output(comptime fmt: []const u8, args: anytype) void {
    var buf: [8192]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    eout.writeRaw(text); // axiom-47h: capture-aware (JSON notes)
}

fn writeStr(s: []const u8) void {
    eout.writeRaw(s); // axiom-47h: capture-aware (JSON notes)
}

// axiom-wk4
const eout = engine_mod.output;

fn errStr(s: []const u8) void {
    eout.style(.err);
    writeStr(s);
    eout.style(.reset);
}

fn errOut(comptime fmt: []const u8, args: anytype) void {
    eout.style(.err);
    output(fmt, args);
    eout.style(.reset);
}

fn okStr(s: []const u8) void {
    eout.style(.ok);
    writeStr(s);
    eout.style(.reset);
}

// axiom-82z: completion list for the line editor
const REPL_COMMANDS = [_][]const u8{
    ":check", ":clear", ":diff ", ":help", ":load ", ":pred ", ":quit", ":reload",
    ":whatif ",
    ":retract ", ":save ", ":show", ":show english", ":show facts", ":show ids", ":show rules",
    ":trace", ":trace on", ":trace off", ":why",
};

// axiom-76a / axiom-ekd — moved to types.zig (axiom-02w) so the lib and
// C-API loaders share span and label capture.
const statementSpan = types.statementSpan;
const labelBefore = types.labelBefore;


// axiom-8zj
// Curated hints for common unsupported-English phrasings. Word-boundary,
// case-insensitive matching so atoms like "warehouse" never trigger.
fn phrasingHint(input: []const u8) ?[]const u8 {
    // axiom-3af: negated query forms are excluded by design — most
    // specific trigger, so it fires before the generic hints
    if (containsWord(input, "not") and
        (startsWithWord(input, "is") or startsWithWord(input, "who") or
        startsWithWord(input, "what") or startsWithWord(input, "which") or
        startsWithWord(input, "can")))
    {
        return "negated queries are not supported - ask the positive form; \"No.\" already means not provable. (Negation belongs in rule bodies: \"... if X is not banned.\")";
    }
    if (containsWord(input, "isn't") or containsWord(input, "aren't") or
        containsWord(input, "don't") or containsWord(input, "doesn't") or
        containsWord(input, "can't") or containsWord(input, "cannot") or
        containsWord(input, "won't"))
    {
        return "contractions are not supported - write \"is not\" / \"can\" forms.";
    }
    if (startsWithWord(input, "if") or containsWord(input, "then")) {
        return "head-first conditionals are not supported - use the tail form: \"X is mortal if X is a man.\"";
    }
    if (containsWord(input, "are")) {
        return "plurals are not supported - write one sentence per subject: \"X is a Y.\"";
    }
    if (containsWord(input, "or")) {
        return "disjunction is not supported - write one rule per alternative.";
    }
    if (containsWord(input, "and")) {
        // 'and' is valid in rule bodies; only hint when there is no 'if'
        if (!containsWord(input, "if")) {
            return "compound subjects are not supported - split into one sentence per subject.";
        }
    }
    return null;
}

fn sourceLineAt(source: []const u8, line_no: usize) []const u8 {
    var it = std.mem.splitScalar(u8, source, '\n');
    var n: usize = 1;
    while (it.next()) |line| : (n += 1) {
        if (n == line_no) return line;
    }
    return "";
}

fn containsWord(haystack: []const u8, word: []const u8) bool {
    var i: usize = 0;
    while (i + word.len <= haystack.len) : (i += 1) {
        if (!std.ascii.eqlIgnoreCase(haystack[i .. i + word.len], word)) continue;
        const before_ok = i == 0 or !std.ascii.isAlphanumeric(haystack[i - 1]);
        const after = i + word.len;
        const after_ok = after >= haystack.len or
            (!std.ascii.isAlphanumeric(haystack[after]) and haystack[after] != '_');
        const before_ok2 = before_ok and (i == 0 or haystack[i - 1] != '_');
        if (before_ok2 and after_ok) return true;
    }
    return false;
}

fn startsWithWord(haystack: []const u8, word: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, haystack, &std.ascii.whitespace);
    if (trimmed.len < word.len) return false;
    if (!std.ascii.eqlIgnoreCase(trimmed[0..word.len], word)) return false;
    return trimmed.len == word.len or !std.ascii.isAlphanumeric(trimmed[word.len]);
}

// axiom-aof
fn printReasonsIndented(tag: []const u8, reasons: []const []const u8) void {
    if (reasons.len == 0) return;
    writeStr("    ");
    writeStr(tag);
    writeStr(": ");
    for (reasons, 0..) |r, i| {
        if (i > 0) writeStr(", ");
        writeStr(r);
    }
    writeStr("\n");
}

const Axiom = struct {
    engine: Engine,
    allocator: std.mem.Allocator,
    include_stack: std.ArrayList([]const u8), // for cyclic include detection
    last_solutions: []Substitution, // axiom-9nz: for :why [n]
    last_query_goals: ?[]const Goal,
    loaded_files: std.ArrayList([]const u8), // axiom-76a: for :reload
    verbose_asserts: bool, // axiom-wk4: per-clause Added: feedback (off during loads)
    history_path: ?[]const u8, // axiom-82z
    json_mode: bool, // axiom-47h
    notes_buf: std.ArrayList(u8), // axiom-47h: captured engine text
    pending_label: []const u8, // axiom-m0n: '% id:' line awaiting its statement
    last_should: ?struct { // axiom-07s: inputs + outcome of the last Should
        subject: []const u8,
        action: []const u8,
        resource: ?[]const u8,
        outcome: Engine.DecisionOutcome,
    },

    fn init(allocator: std.mem.Allocator) Axiom {
        return .{
            .engine = Engine.init(allocator),
            .allocator = allocator,
            .include_stack = .empty,
            .last_solutions = &.{},
            .last_query_goals = null,
            .loaded_files = .empty,
            .verbose_asserts = true,
            .history_path = null,
            .json_mode = false,
            .notes_buf = .empty,
            .pending_label = "",
            .last_should = null,
        };
    }

    fn processSource(self: *Axiom, source: []const u8) !void {
        _ = self.processSourceWithDir(source, null, null) catch |err| return err;
    }

    /// Returns the number of statements skipped due to parse errors.
    fn processSourceWithDir(self: *Axiom, source: []const u8, base_dir: ?[]const u8, context: ?[]const u8) !usize {
        var lex = Lexer.init(source);
        const tokens = try lex.tokenize(self.allocator);
        var parser = Parser.init(tokens, self.allocator);

        // axiom-76a: parse statement-by-statement to capture source spans
        var skipped: usize = 0;
        while (parser.peek().tag != .eof) {
            const start_idx = parser.pos;
            if (parser.parseStatement()) |stmt| {
                const span = statementSpan(source, tokens, start_idx, parser.pos - 1);
                const label = labelBefore(source, span); // axiom-ekd
                try self.processStatementWithDir(stmt, base_dir, span, label);
            } else |_| {
                // axiom-wk4: report instead of silently dropping
                skipped += 1;
                const fname = context orelse "<input>";
                errOut("{s}:{d}:{d}: skipped statement near \"{s}\"\n", .{ fname, parser.last_error_line, parser.last_error_col, parser.last_error_token });
                if (phrasingHint(sourceLineAt(source, parser.last_error_line))) |hint| { // axiom-8zj
                    writeStr("  Hint: ");
                    writeStr(hint);
                    writeStr("\n");
                }
                parser.recover();
            }
        }
        return skipped;
    }

    const ProcessError = std.mem.Allocator.Error || parser_mod.ParseError || desugar_mod.DesugarError;

    fn processStatement(self: *Axiom, stmt: Statement) ProcessError!void {
        return self.processStatementWithDir(stmt, null, "", "");
    }

    fn processStatementWithDir(self: *Axiom, stmt: Statement, base_dir: ?[]const u8, source_text: []const u8, label: []const u8) ProcessError!void {
        switch (stmt) {
            .command => |cmd| {
                switch (cmd) {
                    .load => |filename| self.loadFileNoError(filename),
                    .show => self.showClauses(.all),
                    .include => |filename| self.handleInclude(filename, base_dir),
                }
            },
            .mode_decl => |decl| {
                self.engine.registerMode(decl) catch |err| {
                    output("Error registering mode: {}\n", .{err});
                };
                output("  Mode: {s}/{d}\n", .{ decl.pred_name, decl.arg_modes.len });
            },
            // axiom-i01
            .should_query => |q| {
                self.runDecide(q.subject, q.action, q.resource);
            },
            // axiom-02w
            .which_actions_query => |q| {
                self.runAllowedActions(q.subject, q.resource);
            },
            // axiom-07s
            .why_not_query => {
                self.runWhyNot();
            },
            // axiom-d4s
            .closed_world_decl => |name| {
                self.engine.declareClosedWorld(name) catch |err| {
                    output("Error declaring closed_world: {}\n", .{err});
                };
                if (self.verbose_asserts) output("  Closed-world: {s}\n", .{name});
            },
            else => {
                var desugarer = Desugarer.init(self.allocator);
                if (try desugarer.desugar(stmt)) |result| {
                    switch (result) {
                        .clause => |clause| {
                            // axiom-76a
                            var c = clause;
                            c.source_text = source_text;
                            c.label = label; // axiom-ekd
                            try self.engine.addClause(c);
                            if (self.verbose_asserts) { // axiom-wk4
                                const det_str = if (clause.det.marker()) |m| &[_]u8{m} else "";
                                output("  Added: {s}/{d}{s}\n", .{ clause.head.functor, clause.head.args.len, det_str });
                            }
                        },
                        .query => |q| {
                            try self.runQuery(q.goals, q.variables);
                        },
                    }
                }
            },
        }
    }

    // axiom-i01
    fn runDecide(self: *Axiom, subject: []const u8, action: []const u8, resource: ?[]const u8) void {
        const decision = self.engine.decide(subject, action, resource) catch |err| {
            errOut("Decision error: {}\n", .{err});
            return;
        };
        self.last_should = .{ .subject = subject, .action = action, .resource = resource, .outcome = decision.outcome }; // axiom-07s
        switch (decision.outcome) {
            .allow => okStr("Allow.\n"),
            // axiom-2fx: gated allows sit between allow and deny
            .allow_with_redaction => writeStr("Allow with redaction.\n"),
            .allow_with_sandbox => writeStr("Allow with sandbox.\n"),
            .require_confirmation => writeStr("Require confirmation.\n"),
            .deny => errStr("Deny.\n"),
            .indeterminate => writeStr("Indeterminate. (no outcome rule matched)\n"),
        }
        if (decision.reasons.len > 0) {
            writeStr("Reasons:\n");
            for (decision.reasons) |r| {
                writeStr("  - ");
                writeStr(r);
                writeStr("\n");
            }
        }
        if (decision.evidence.len > 0) {
            writeStr("Evidence:\n");
            for (decision.evidence) |e| {
                writeStr("  - ");
                writeStr(e);
                writeStr(".\n");
            }
        }
    }

    // axiom-07s
    fn runWhyNot(self: *Axiom) void {
        const last = self.last_should orelse {
            writeStr("No decision to explain. Ask a Should question first.\n");
            return;
        };
        if (last.outcome == .allow) {
            writeStr("Last decision was Allow — nothing to explain. (:why explains it)\n");
            return;
        }
        const wn = self.engine.whyNot(last.subject, last.action, last.resource) catch |err| {
            errOut("Decision error: {}\n", .{err});
            return;
        };
        if (wn.denies.len == 0 and wn.near_misses.len == 0) {
            writeStr("No outcome rules reference these inputs.\n");
            return;
        }
        if (wn.denies.len > 0) {
            writeStr("Blocking rules in effect:\n");
            for (wn.denies) |d| {
                writeStr("  - ");
                writeStr(d.rule);
                // axiom-2fx: show which gate fired when it isn't a plain deny
                if (!std.mem.eql(u8, d.outcome, "deny")) {
                    writeStr(" (");
                    writeStr(d.outcome);
                    writeStr(")");
                }
                if (d.evidence.len > 0) {
                    writeStr(", relying on: ");
                    for (d.evidence, 0..) |e, i| {
                        if (i > 0) writeStr("; ");
                        writeStr("\"");
                        writeStr(e);
                        writeStr("\"");
                    }
                }
                writeStr("\n");
            }
        }
        if (wn.near_misses.len > 0) {
            writeStr("Allow would need:\n");
            for (wn.near_misses) |m| {
                writeStr("  - ");
                writeStr(m.rule);
                writeStr(": blocked at \"");
                writeStr(m.blocker);
                writeStr("\"");
                if (m.blocker_negated) {
                    writeStr(" (currently true — would need to be false)");
                }
                writeStr("\n");
            }
        }
    }

    // axiom-02w
    fn runAllowedActions(self: *Axiom, subject: []const u8, resource: ?[]const u8) void {
        const actions = self.engine.allowedActions(subject, resource) catch |err| {
            errOut("Decision error: {}\n", .{err});
            return;
        };
        if (actions.len == 0) {
            writeStr("No allowed actions.\n");
            return;
        }
        eout.style(.ok);
        for (actions) |a| {
            writeStr("  ");
            writeStr(a);
            writeStr("\n");
        }
        eout.style(.reset);
    }

    // axiom-d4s
    fn allGoalsClosedWorld(self: *const Axiom, goals: []const Goal) bool {
        if (goals.len == 0) return false;
        for (goals) |g| {
            switch (g) {
                .call => |c| if (!self.engine.isClosedWorld(c.functor)) return false,
                else => return false, // mixed negation: keep the plain answer
            }
        }
        return true;
    }

    fn runQuery(self: *Axiom, goals: []const Goal, variables: []const []const u8) !void {
        self.last_query_goals = goals;
        const solutions = self.engine.solveAll(goals) catch |err| switch (err) {
            // axiom-7yv: budgets turn hangs into clean, named errors
            error.StepLimitExceeded, error.DepthLimitExceeded => {
                errOut("Error: recursion limit exceeded in {s}/{d} — query aborted (likely unbounded recursion).\n", .{ self.engine.limit_functor, self.engine.limit_arity });
                return;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };

        self.last_solutions = solutions; // axiom-9nz

        if (solutions.len == 0) {
            // axiom-d4s: annotate when every positive goal is closed-world
            if (self.allGoalsClosedWorld(goals)) {
                errStr("No (by closed-world assumption; no proof found).\n");
            } else {
                errStr("No.\n"); // axiom-wk4
            }
            return;
        }

        if (variables.len == 0) {
            okStr("Yes.\n"); // axiom-wk4
            return;
        }

        // Filter to displayable variables
        var real_vars: std.ArrayList([]const u8) = .empty;
        for (variables) |v| {
            try real_vars.append(self.allocator, v);
        }

        if (real_vars.items.len == 0) {
            okStr("Yes.\n"); // axiom-wk4
            return;
        }

        for (solutions) |solution| {
            var has_output = false;
            eout.style(.ok); // axiom-wk4
            defer eout.style(.reset);
            for (real_vars.items) |varname| {
                const resolved = try solution.deepWalk(.{ .variable = varname }, self.allocator);
                switch (resolved) {
                    .variable => |v| {
                        if (std.mem.eql(u8, v, varname)) continue;
                        if (isRenamedVar(varname, v)) continue;
                    },
                    else => {},
                }
                if (has_output) writeStr(", ");
                const display_name = if (std.mem.startsWith(u8, varname, "_"))
                    varname[1..]
                else
                    varname;
                output("{s} = ", .{display_name});
                printTerm(resolved);
                has_output = true;
            }
            if (has_output) {
                writeStr("\n");
            }
        }
    }

    // ─── Include handling ──────────────────────────────────────────────

    fn handleInclude(self: *Axiom, filename: []const u8, base_dir: ?[]const u8) void {
        self.doInclude(filename, base_dir) catch |err| {
            errOut("Error including '{s}': {}\n", .{ filename, err });
        };
    }

    fn doInclude(self: *Axiom, filename: []const u8, base_dir: ?[]const u8) !void {
        // Check for cyclic includes
        for (self.include_stack.items) |included| {
            if (std.mem.eql(u8, included, filename)) {
                errOut("Error: cyclic include detected for '{s}'\n", .{filename});
                return;
            }
        }

        try self.include_stack.append(self.allocator, filename);
        defer _ = self.include_stack.pop();

        // Resolve path relative to including file's directory
        const resolved = if (base_dir) |dir|
            try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir, filename })
        else
            filename;

        const source = std.Io.Dir.cwd().readFileAlloc(types.defaultIo(), resolved, self.allocator, .limited(1024 * 1024)) catch |err| {
            errOut("Error loading '{s}': {}\n", .{ resolved, err });
            return;
        };

        // Compute the directory of the included file for nested includes
        const new_dir = if (std.mem.lastIndexOfScalar(u8, resolved, '/')) |pos|
            resolved[0..pos]
        else
            base_dir;

        _ = try self.processSourceWithDir(source, new_dir, resolved);
    }

    // ─── File loading ──────────────────────────────────────────────────

    fn loadFileNoError(self: *Axiom, filename: []const u8) void {
        self.loadFile(filename) catch |err| {
            errOut("Error loading: {}\n", .{err});
        };
    }

    const LoadInfo = struct { actual: []const u8, added: usize, skipped: usize }; // axiom-47h

    fn loadFile(self: *Axiom, filename: []const u8) !void {
        const info = (try self.loadFileInfo(filename)) orelse return;
        const word: []const u8 = if (info.added == 1) "clause" else "clauses";
        if (info.skipped > 0) {
            output("Loaded '{s}' ({d} {s}, {d} skipped).\n", .{ info.actual, info.added, word, info.skipped });
        } else {
            output("Loaded '{s}' ({d} {s}).\n", .{ info.actual, info.added, word });
        }
    }

    /// axiom-47h: structured load result; null when the file is unreadable
    /// (error already reported).
    fn loadFileInfo(self: *Axiom, filename: []const u8) !?LoadInfo {
        var actual: []const u8 = filename; // axiom-76a: path that actually loaded
        const source = std.Io.Dir.cwd().readFileAlloc(types.defaultIo(), filename, self.allocator, .limited(1024 * 1024)) catch blk: {
            const with_ext = try std.fmt.allocPrint(self.allocator, "{s}.axm", .{filename});
            const src2 = std.Io.Dir.cwd().readFileAlloc(types.defaultIo(), with_ext, self.allocator, .limited(1024 * 1024)) catch |err| {
                errOut("Error loading '{s}': {}\n", .{ filename, err });
                return null;
            };
            actual = with_ext;
            break :blk src2;
        };

        // Compute base directory for includes
        const base_dir = if (std.mem.lastIndexOfScalar(u8, filename, '/')) |pos|
            filename[0..pos]
        else
            null;

        // axiom-wk4: quiet bulk load with summary
        const before = self.engine.getClauses().len;
        const was_verbose = self.verbose_asserts;
        self.verbose_asserts = false;
        const skipped = try self.processSourceWithDir(source, base_dir, actual);
        self.verbose_asserts = was_verbose;
        const added = self.engine.getClauses().len - before;

        // axiom-76a: track for :reload (dupe — callers may pass transient buffers)
        const stored = try self.allocator.dupe(u8, actual);
        try self.loaded_files.append(self.allocator, stored);
        return .{ .actual = stored, .added = added, .skipped = skipped };
    }

    // axiom-krf
    fn printClause(clause: Clause) void {
        output("{s}(", .{clause.head.functor});
        for (clause.head.args, 0..) |arg, j| {
            if (j > 0) writeStr(", ");
            printTerm(arg);
        }
        writeStr(")");
        // Show determinism marker if declared
        if (clause.det.marker()) |m| {
            const marker_str = &[_]u8{m};
            writeStr(marker_str);
        }
        if (clause.body.len > 0) {
            writeStr(" :- ");
            for (clause.body, 0..) |goal, j| {
                if (j > 0) writeStr(", ");
                printGoal(goal);
            }
        }
    }

    const ShowFilter = enum { all, facts, rules };

    fn showClauses(self: *Axiom, filter: ShowFilter) void {
        const clauses = self.engine.getClauses();
        var shown: usize = 0;
        for (clauses, 0..) |clause, i| {
            switch (filter) {
                .all => {},
                .facts => if (clause.body.len > 0) continue,
                .rules => if (clause.body.len == 0) continue,
            }
            shown += 1;
            output("{d}: ", .{i + 1});
            printClause(clause);
            writeStr(".\n");
        }
        if (shown == 0) {
            switch (filter) {
                .all => writeStr("No clauses loaded.\n"),
                .facts => writeStr("No facts loaded.\n"),
                .rules => writeStr("No rules loaded.\n"),
            }
        }
    }

    // axiom-ekd
    fn showClauseIds(self: *Axiom) void {
        const clauses = self.engine.getClauses();
        if (clauses.len == 0) {
            writeStr("No clauses loaded.\n");
            return;
        }
        for (clauses, 0..) |clause, i| {
            var hex_buf: [16]u8 = undefined;
            const hex = engine_mod.identity.hashHex(clause.id, &hex_buf);
            writeStr(hex);
            if (clause.label.len > 0) {
                writeStr(" (");
                writeStr(clause.label);
                writeStr(")");
            }
            output("  {d}: ", .{i + 1});
            printClause(clause);
            writeStr(".\n");
        }
    }

    // axiom-xec
    fn showClausesEnglish(self: *Axiom) void {
        const clauses = self.engine.getClauses();
        if (clauses.len == 0) {
            writeStr("No clauses loaded.\n");
            return;
        }
        for (clauses, 0..) |clause, i| {
            const sentence = engine_mod.english.clauseToEnglish(self.allocator, clause) catch continue;
            output("{d}: {s}\n", .{ i + 1, sentence });
        }
    }

    // axiom-9nz
    fn explainWhy(self: *Axiom, arg: []const u8) void {
        const goals = self.last_query_goals orelse {
            errStr("No successful query to explain. Run a query first.\n");
            return;
        };
        if (self.last_solutions.len == 0) {
            errStr("No successful query to explain. Run a query first.\n");
            return;
        }
        const n = if (arg.len == 0) 1 else std.fmt.parseInt(usize, arg, 10) catch 0;
        if (n == 0 or n > self.last_solutions.len) {
            errOut("Query had {d} solution(s) — :why 1..{d}.\n", .{ self.last_solutions.len, self.last_solutions.len });
            return;
        }
        self.engine.explainSolution(goals, &self.last_solutions[n - 1]);
    }

    // axiom-76a
    fn retractClause(self: *Axiom, arg: []const u8) void {
        const n = std.fmt.parseInt(usize, arg, 10) catch 0;
        if (n == 0) {
            errStr("Usage: :retract <clause-number>  (see :show)\n");
            return;
        }
        const removed = self.engine.removeClause(n - 1) orelse {
            errOut("No clause {d} ({d} clauses loaded — see :show).\n", .{ n, self.engine.getClauses().len });
            return;
        };
        output("Retracted {d}: ", .{n});
        printClause(removed);
        writeStr(".\n");
    }

    // axiom-76a
    fn clearKb(self: *Axiom) void {
        const n = self.engine.getClauses().len;
        self.engine.clearClauses();
        self.loaded_files.clearRetainingCapacity();
        output("Cleared {d} clauses.\n", .{n});
    }

    // axiom-76a
    fn saveClauses(self: *Axiom, path: []const u8) void {
        if (path.len == 0) {
            errStr("Usage: :save <file>\n");
            return;
        }
        const clauses = self.engine.getClauses();
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        var saved: usize = 0;
        var skipped: usize = 0;
        for (clauses) |clause| {
            if (clause.source_text.len == 0) {
                skipped += 1;
                continue;
            }
            buf.appendSlice(self.allocator, clause.source_text) catch return;
            buf.append(self.allocator, '\n') catch return;
            saved += 1;
        }
        std.Io.Dir.cwd().writeFile(types.defaultIo(), .{ .sub_path = path, .data = buf.items }) catch |err| {
            errOut("Error saving '{s}': {}\n", .{ path, err });
            return;
        };
        if (skipped > 0) {
            output("Saved {d} clauses to '{s}' ({d} had no source text).\n", .{ saved, path, skipped });
        } else {
            output("Saved {d} clauses to '{s}'.\n", .{ saved, path });
        }
    }

    // axiom-76a
    fn reloadFiles(self: *Axiom) void {
        if (self.loaded_files.items.len == 0) {
            writeStr("No files loaded this session.\n");
            return;
        }
        // Snapshot and reset; loadFile re-appends each file it loads.
        const files = self.loaded_files.toOwnedSlice(self.allocator) catch return;
        self.engine.clearClauses();
        for (files) |f| {
            self.loadFile(f) catch |err| {
                errOut("Error reloading '{s}': {}\n", .{ f, err });
            };
        }
    }

    // axiom-aof
    // Load a file into a fresh engine by swapping self.engine — reuses the
    // whole loader (spans, labels, includes, skip reporting). Restores the
    // session engine and loaded-file list on all paths.
    fn loadScratch(self: *Axiom, path: []const u8) ?Engine {
        const saved_engine = self.engine;
        const saved_files_len = self.loaded_files.items.len;
        const saved_verbose = self.verbose_asserts;
        self.engine = Engine.init(self.allocator);
        self.verbose_asserts = false;

        var failed = false;
        self.loadFile(path) catch {
            failed = true;
        };
        const scratch = self.engine;

        self.engine = saved_engine;
        self.verbose_asserts = saved_verbose;
        self.loaded_files.shrinkRetainingCapacity(saved_files_len);

        if (failed or scratch.getClauses().len == 0) {
            // loadFile already printed the error for unreadable files
            return if (failed) null else scratch;
        }
        return scratch;
    }

    // axiom-aof
    fn diffFiles(self: *Axiom, old_path: []const u8, new_path: []const u8) void {
        var old_eng = self.loadScratch(old_path) orelse return;
        var new_eng = self.loadScratch(new_path) orelse return;
        _ = &old_eng;
        _ = &new_eng;

        const diffs = engine_mod.diff.diffPrograms(self.allocator, old_eng.getClauses(), new_eng.getClauses()) catch |err| {
            errOut("Diff error: {}\n", .{err});
            return;
        };
        if (diffs.len == 0) {
            writeStr("No semantic changes.\n");
            return;
        }
        for (diffs) |d| {
            switch (d.kind) {
                .added => {
                    eout.style(.ok);
                    writeStr("+ added:    ");
                    self.writeClauseEnglish(d.new_clause.?);
                    eout.style(.reset);
                },
                .removed => {
                    eout.style(.err);
                    writeStr("- removed:  ");
                    self.writeClauseEnglish(d.old_clause.?);
                    eout.style(.reset);
                },
                .modified => {
                    eout.style(.accent);
                    writeStr("~ modified");
                    if (d.old_clause.?.label.len > 0) {
                        writeStr(" (");
                        writeStr(d.old_clause.?.label);
                        writeStr(")");
                    }
                    writeStr(":\n    old: ");
                    self.writeClauseEnglish(d.old_clause.?);
                    writeStr("    new: ");
                    self.writeClauseEnglish(d.new_clause.?);
                    eout.style(.reset);
                },
            }
        }
    }

    fn writeClauseEnglish(self: *Axiom, clause: Clause) void {
        const sentence = engine_mod.english.clauseToEnglish(self.allocator, clause) catch {
            writeStr("(render error)\n");
            return;
        };
        writeStr(sentence);
        writeStr("\n");
    }

    // axiom-aof
    fn whatIf(self: *Axiom, old_path: []const u8, new_path: []const u8, inputs_path: []const u8) void {
        var old_eng = self.loadScratch(old_path) orelse return;
        var new_eng = self.loadScratch(new_path) orelse return;

        const data = std.Io.Dir.cwd().readFileAlloc(types.defaultIo(), inputs_path, self.allocator, .limited(1024 * 1024)) catch |err| {
            errOut("Error reading '{s}': {}\n", .{ inputs_path, err });
            return;
        };

        var changed: usize = 0;
        var total: usize = 0;
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, &std.ascii.whitespace);
            if (line.len == 0 or line[0] == '%') continue;
            var fields = std.mem.tokenizeAny(u8, line, " \t");
            const subject = fields.next() orelse continue;
            const action = fields.next() orelse {
                errOut("Skipping malformed input line: {s}\n", .{line});
                continue;
            };
            const resource = fields.next();
            total += 1;

            const old_d = old_eng.decide(subject, action, resource) catch continue;
            const new_d = new_eng.decide(subject, action, resource) catch continue;
            if (old_d.outcome == new_d.outcome) continue;
            changed += 1;

            if (changed == 1) writeStr("Changed:\n");
            output("  {s} {s}", .{ subject, action });
            if (resource) |r| output(" {s}", .{r});
            output(": {s} -> {s}\n", .{ @tagName(old_d.outcome), @tagName(new_d.outcome) });
            printReasonsIndented("old reasons", old_d.reasons);
            printReasonsIndented("new reasons", new_d.reasons);
        }
        if (changed == 0) {
            output("No decision changes across {d} input(s).\n", .{total});
        } else {
            output("{d} of {d} decision(s) changed.\n", .{ changed, total });
        }
    }

    fn showPredInfo(self: *Axiom, spec: []const u8) void {
        // Parse "name/arity"
        const slash = std.mem.indexOfScalar(u8, spec, '/') orelse {
            output("Usage: :pred <name>/<arity>  (e.g., :pred mortal/1)\n", .{});
            return;
        };
        const name = spec[0..slash];
        const arity_str = spec[slash + 1 ..];
        const arity = std.fmt.parseInt(u8, arity_str, 10) catch {
            output("Invalid arity: '{s}'\n", .{arity_str});
            return;
        };

        if (self.engine.getPredInfo(name, arity)) |info| {
            output("{s}/{d}\n", .{ info.name, info.arity });
            output("  determinism: {s}\n", .{info.det.label()});
            if (info.arg_modes) |modes| {
                writeStr("  modes: (");
                for (modes, 0..) |m, idx| {
                    if (idx > 0) writeStr(", ");
                    const marker_str = &[_]u8{m.marker()};
                    writeStr(marker_str);
                }
                writeStr(")\n");
            } else {
                writeStr("  modes: not declared\n");
            }
            // axiom-d4s
            if (self.engine.isClosedWorld(name)) {
                writeStr("  closed-world: yes\n");
            }

            // Count clauses
            var count: usize = 0;
            for (self.engine.getClauses()) |clause| {
                if (std.mem.eql(u8, clause.head.functor, name) and clause.head.args.len == arity) {
                    count += 1;
                }
            }
            output("  clauses: {d}\n", .{count});
        } else {
            // axiom-d4s: a closed-world declaration alone is still info
            if (self.engine.isClosedWorld(name)) {
                output("{s}/{d}\n", .{ name, arity });
                writeStr("  closed-world: yes\n");
                writeStr("  clauses: 0\n");
            } else {
                output("No info for {s}/{d}. Predicate not found.\n", .{ name, arity });
            }
        }
    }

    fn runChecks(self: *Axiom) void {
        writeStr("Running determinism and mode checks...\n");
        self.engine.runChecks() catch |err| {
            output("Error during checks: {}\n", .{err});
        };
        writeStr("Checks complete.\n");
    }

    fn repl(self: *Axiom) !void {
        // axiom-47h: protocol mode — no banner, no prompt, piped loop
        if (self.json_mode) {
            self.enableJsonCapture();
            try self.replPiped();
            return;
        }
        writeStr("Axiom v0.3 — A Prolog-style logic language with controlled-English syntax\n");
        writeStr("Commands: :load, :show, :trace, :why, :pred, :check, :help, :quit\n\n");

        // axiom-82z: line editor on a terminal, plain loop otherwise
        const io = types.defaultIo();
        const tty = (std.Io.File.stdin().isTty(io) catch false) and
            (std.Io.File.stdout().isTty(io) catch false);
        if (tty) {
            try self.replInteractive();
        } else {
            try self.replPiped();
        }
    }

    // axiom-82z
    fn replInteractive(self: *Axiom) !void {
        const prompt = if (eout.color_enabled) "\x1b[36maxiom> \x1b[0m" else "axiom> ";
        var ed = editor_mod.Editor.init(self.allocator, types.defaultIo(), .{
            .prompt = prompt,
            .commands = &REPL_COMMANDS,
            .history_path = self.history_path,
        });
        defer ed.deinit();

        while (true) {
            const line = (ed.readLine() catch |err| {
                errOut("Editor error: {}\n", .{err});
                return;
            }) orelse {
                writeStr("Goodbye.\n");
                return;
            };
            const input = std.mem.trim(u8, line, &std.ascii.whitespace);
            if (input.len == 0) continue;
            if (!self.handleLine(input)) return;
        }
    }

    fn replPiped(self: *Axiom) !void {
        const stdin_file = std.Io.File.stdin(); // axiom-6th
        var line_buf: [4096]u8 = undefined;

        while (true) {
            if (!self.json_mode) { // axiom-47h
                eout.style(.accent); // axiom-wk4
                writeStr("axiom> ");
                eout.style(.reset);
            }

            // axiom-6th
            const n = stdin_file.readStreaming(types.defaultIo(), &.{&line_buf}) catch |err| switch (err) {
                error.EndOfStream => break,
                else => {
                    output("Read error: {}\n", .{err});
                    continue;
                },
            };

            if (n == 0) continue;

            var data = line_buf[0..n];
            while (data.len > 0) {
                const nl_pos = std.mem.indexOfScalar(u8, data, '\n');
                const line = if (nl_pos) |pos| data[0..pos] else data;
                data = if (nl_pos) |pos| data[pos + 1 ..] else &.{};

                const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
                if (trimmed.len == 0) continue;

                // axiom-m0n: line_buf is reused by the next read(); asserted
                // clauses keep term slices into the input, so it must be
                // duped — batch pipes masked this, interactive-paced piped
                // clients (agents) corrupted clause functors.
                const input = self.allocator.dupe(u8, trimmed) catch return;

                if (!self.handleLine(input)) return;
            }
        }
    }

    // ─── JSON protocol mode (axiom-47h) ────────────────────────────

    fn enableJsonCapture(self: *Axiom) void {
        eout.capture_alloc = self.allocator;
        eout.capture_buf = &self.notes_buf;
        eout.color_enabled = false;
    }

    fn disableJsonCapture(_: *Axiom) void {
        eout.capture_buf = null;
    }

    /// Write protocol bytes directly to stdout, bypassing the capture.
    fn jsonWrite(s: []const u8) void {
        stdout_file.writeStreamingAll(types.defaultIo(), s) catch {};
    }

    fn newObj(self: *Axiom, input: []const u8, kind: []const u8) jsonout.Buf {
        var buf = jsonout.Buf.init(self.allocator);
        buf.beginObj();
        buf.numField("v", 1);
        buf.strField("input", input);
        buf.strField("type", kind);
        return buf;
    }

    fn emitObj(self: *Axiom, buf: *jsonout.Buf) void {
        // drain captured engine text into notes[]
        if (self.notes_buf.items.len > 0) {
            buf.key("notes");
            buf.beginArr();
            var it = std.mem.splitScalar(u8, self.notes_buf.items, '\n');
            while (it.next()) |line| {
                if (line.len == 0) continue;
                buf.sep();
                buf.string(line);
                buf.first_in_scope = false;
            }
            buf.endArr();
            self.notes_buf.clearRetainingCapacity();
        }
        buf.endObj();
        jsonWrite(buf.list.items);
        jsonWrite("\n");
    }

    /// Render through the engine's text printers into a string by
    /// temporarily swapping the capture target.
    fn captureStart(self: *Axiom) *std.ArrayList(u8) {
        const tmp = self.allocator.create(std.ArrayList(u8)) catch unreachable;
        tmp.* = .empty;
        eout.capture_buf = tmp;
        return tmp;
    }

    fn captureEnd(self: *Axiom, tmp: *std.ArrayList(u8)) []const u8 {
        const text = tmp.items;
        eout.capture_buf = if (self.json_mode) &self.notes_buf else null;
        return text;
    }

    fn clauseText(self: *Axiom, clause: Clause) []const u8 {
        const tmp = self.captureStart();
        printClause(clause);
        return self.captureEnd(tmp);
    }

    fn goalText(self: *Axiom, c: types.Term.Compound) []const u8 {
        const tmp = self.captureStart();
        eout.writeTermTo(.{ .compound = c });
        return self.captureEnd(tmp);
    }

    fn termValue(self: *Axiom, buf: *jsonout.Buf, term: Term) void {
        switch (term) {
            .string => |s| { // axiom-rhc: bare value, no embedded quotes
                buf.string(s);
                buf.first_in_scope = false;
            },
            .integer => |v| {
                var tmpn: [24]u8 = undefined;
                const sn = std.fmt.bufPrint(&tmpn, "{d}", .{v}) catch return;
                buf.raw(sn);
                buf.first_in_scope = false;
            },
            else => {
                const tmp = self.captureStart();
                printTerm(term);
                buf.string(self.captureEnd(tmp));
            },
        }
    }

    fn proofNodeJson(self: *Axiom, buf: *jsonout.Buf, node: *const engine_mod.ProofNode) void {
        buf.beginObj();
        buf.strField("kind", @tagName(node.kind));
        buf.strField("goal", self.goalText(node.goal));
        if (node.clause_label.len > 0) {
            buf.strField("rule", node.clause_label);
        } else if (node.kind == .rule) {
            var hex_buf: [16]u8 = undefined;
            buf.strField("rule", engine_mod.identity.hashHex(node.clause_id, &hex_buf));
        }
        buf.key("children");
        buf.beginArr();
        for (node.children) |*child| {
            buf.sep();
            self.proofNodeJson(buf, child);
            buf.first_in_scope = false;
        }
        buf.endArr();
        buf.endObj();
        buf.first_in_scope = false;
    }

    fn jsonLoadFile(self: *Axiom, path: []const u8) void {
        const info = (self.loadFileInfo(path) catch null) orelse {
            var buf = self.newObj(path, "error");
            buf.strField("kind", "file");
            buf.strField("message", "could not read file");
            self.emitObj(&buf);
            return;
        };
        var inbuf: [512]u8 = undefined;
        const in_s = std.fmt.bufPrint(&inbuf, ":load {s}", .{path}) catch path;
        var buf = self.newObj(in_s, "loaded");
        buf.strField("file", info.actual);
        buf.numField("clauses", info.added);
        buf.numField("skipped", info.skipped);
        self.emitObj(&buf);
    }

    fn jsonError(self: *Axiom, input: []const u8, kind: []const u8, message: []const u8) void {
        var buf = self.newObj(input, "error");
        buf.strField("kind", kind);
        buf.strField("message", message);
        self.emitObj(&buf);
    }

    fn handleLineJson(self: *Axiom, input: []const u8) bool {
        if (std.mem.eql(u8, input, ":quit") or std.mem.eql(u8, input, ":q")) {
            var buf = self.newObj(input, "ok");
            buf.strField("action", "quit");
            self.emitObj(&buf);
            return false;
        }
        if (std.mem.eql(u8, input, ":json")) {
            self.json_mode = false;
            self.disableJsonCapture();
            writeStr("JSON mode off.\n");
            return true;
        }
        if (std.mem.startsWith(u8, input, ":load ")) {
            self.jsonLoadFile(std.mem.trim(u8, input[6..], &std.ascii.whitespace));
            return true;
        }
        if (std.mem.eql(u8, input, ":show") or std.mem.startsWith(u8, input, ":show ")) {
            const arg = if (input.len > 5) std.mem.trim(u8, input[5..], &std.ascii.whitespace) else "";
            return self.jsonShow(input, arg);
        }
        if (std.mem.startsWith(u8, input, ":retract")) {
            const arg = std.mem.trim(u8, input[8..], &std.ascii.whitespace);
            const n = std.fmt.parseInt(usize, arg, 10) catch 0;
            if (n == 0) {
                self.jsonError(input, "usage", ":retract <clause-number>");
                return true;
            }
            const removed = self.engine.removeClause(n - 1) orelse {
                self.jsonError(input, "usage", "no such clause");
                return true;
            };
            var buf = self.newObj(input, "retracted");
            buf.numField("index", n);
            buf.strField("text", self.clauseText(removed));
            self.emitObj(&buf);
            return true;
        }
        if (std.mem.eql(u8, input, ":clear")) {
            const n = self.engine.getClauses().len;
            self.engine.clearClauses();
            self.loaded_files.clearRetainingCapacity();
            var buf = self.newObj(input, "cleared");
            buf.numField("count", n);
            self.emitObj(&buf);
            return true;
        }
        if (std.mem.startsWith(u8, input, ":save")) {
            const path = std.mem.trim(u8, input[5..], &std.ascii.whitespace);
            if (path.len == 0) {
                self.jsonError(input, "usage", ":save <file>");
                return true;
            }
            return self.jsonSave(input, path);
        }
        if (std.mem.eql(u8, input, ":reload")) {
            return self.jsonReload(input);
        }
        if (std.mem.eql(u8, input, ":why") or std.mem.startsWith(u8, input, ":why ")) {
            const arg = if (input.len > 4) std.mem.trim(u8, input[4..], &std.ascii.whitespace) else "";
            return self.jsonWhy(input, arg);
        }
        if (std.mem.startsWith(u8, input, ":diff")) {
            var fields = std.mem.tokenizeAny(u8, input[5..], " \t");
            const a = fields.next() orelse {
                self.jsonError(input, "usage", ":diff <old.axm> <new.axm>");
                return true;
            };
            const b = fields.next() orelse {
                self.jsonError(input, "usage", ":diff <old.axm> <new.axm>");
                return true;
            };
            return self.jsonDiff(input, a, b);
        }
        if (std.mem.startsWith(u8, input, ":whatif")) {
            var fields = std.mem.tokenizeAny(u8, input[7..], " \t");
            const a = fields.next();
            const b = fields.next();
            const f = fields.next();
            if (a == null or b == null or f == null) {
                self.jsonError(input, "usage", ":whatif <old> <new> <inputs>");
                return true;
            }
            return self.jsonWhatIf(input, a.?, b.?, f.?);
        }
        if (std.mem.eql(u8, input, ":check")) {
            self.runChecks();
            // capture lands in notes_buf; promote to warnings
            var buf = self.newObj(input, "check");
            buf.key("warnings");
            buf.beginArr();
            var it = std.mem.splitScalar(u8, self.notes_buf.items, '\n');
            while (it.next()) |line| {
                if (line.len == 0) continue;
                buf.sep();
                buf.string(line);
                buf.first_in_scope = false;
            }
            buf.endArr();
            self.notes_buf.clearRetainingCapacity();
            self.emitObj(&buf);
            return true;
        }
        if (std.mem.eql(u8, input, ":trace on") or std.mem.eql(u8, input, ":trace off") or std.mem.eql(u8, input, ":trace")) {
            if (std.mem.eql(u8, input, ":trace on")) self.engine.trace_enabled = true;
            if (std.mem.eql(u8, input, ":trace off")) self.engine.trace_enabled = false;
            var buf = self.newObj(input, "ok");
            buf.boolField("trace", self.engine.trace_enabled);
            self.emitObj(&buf);
            return true;
        }
        if (std.mem.startsWith(u8, input, ":pred ")) {
            return self.jsonPred(input, std.mem.trim(u8, input[6..], &std.ascii.whitespace));
        }
        if (std.mem.eql(u8, input, ":help")) {
            const tmp = self.captureStart();
            self.printHelp();
            const text = self.captureEnd(tmp);
            var buf = self.newObj(input, "text");
            buf.strField("text", text);
            self.emitObj(&buf);
            return true;
        }
        if (std.mem.startsWith(u8, input, ":")) {
            self.jsonError(input, "usage", "unknown command");
            return true;
        }
        self.jsonStatements(input);
        return true;
    }

    fn jsonShow(self: *Axiom, input: []const u8, arg: []const u8) bool {
        const filter: ShowFilter = if (std.mem.eql(u8, arg, "facts")) .facts else if (std.mem.eql(u8, arg, "rules")) .rules else .all;
        if (arg.len > 0 and filter == .all and !std.mem.eql(u8, arg, "ids") and !std.mem.eql(u8, arg, "english")) {
            self.jsonError(input, "usage", ":show [facts|rules|ids|english]");
            return true;
        }
        var buf = self.newObj(input, "clauses");
        buf.key("clauses");
        buf.beginArr();
        for (self.engine.getClauses(), 0..) |clause, i| {
            switch (filter) {
                .all => {},
                .facts => if (clause.body.len > 0) continue,
                .rules => if (clause.body.len == 0) continue,
            }
            buf.sep();
            buf.beginObj();
            buf.numField("index", i + 1);
            var hex_buf: [16]u8 = undefined;
            buf.strField("id", engine_mod.identity.hashHex(clause.id, &hex_buf));
            if (clause.label.len > 0) buf.strField("label", clause.label);
            buf.strField("text", self.clauseText(clause));
            if (engine_mod.english.clauseToEnglish(self.allocator, clause)) |eng| {
                buf.strField("english", eng);
            } else |_| {}
            buf.endObj();
            buf.first_in_scope = false;
        }
        buf.endArr();
        self.emitObj(&buf);
        return true;
    }

    fn jsonSave(self: *Axiom, input: []const u8, path: []const u8) bool {
        const clauses = self.engine.getClauses();
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.allocator);
        var saved: usize = 0;
        var skipped: usize = 0;
        for (clauses) |clause| {
            if (clause.source_text.len == 0) {
                skipped += 1;
                continue;
            }
            out.appendSlice(self.allocator, clause.source_text) catch return true;
            out.append(self.allocator, '\n') catch return true;
            saved += 1;
        }
        std.Io.Dir.cwd().writeFile(types.defaultIo(), .{ .sub_path = path, .data = out.items }) catch {
            self.jsonError(input, "file", "could not write file");
            return true;
        };
        var buf = self.newObj(input, "saved");
        buf.strField("file", path);
        buf.numField("saved", saved);
        buf.numField("no_source", skipped);
        self.emitObj(&buf);
        return true;
    }

    fn jsonReload(self: *Axiom, input: []const u8) bool {
        if (self.loaded_files.items.len == 0) {
            self.jsonError(input, "usage", "no files loaded this session");
            return true;
        }
        const files = self.loaded_files.toOwnedSlice(self.allocator) catch return true;
        self.engine.clearClauses();
        var buf = self.newObj(input, "reloaded");
        buf.key("files");
        buf.beginArr();
        for (files) |f| {
            const info = (self.loadFileInfo(f) catch null) orelse continue;
            buf.sep();
            buf.beginObj();
            buf.strField("file", info.actual);
            buf.numField("clauses", info.added);
            buf.numField("skipped", info.skipped);
            buf.endObj();
            buf.first_in_scope = false;
        }
        buf.endArr();
        self.emitObj(&buf);
        return true;
    }

    fn jsonWhy(self: *Axiom, input: []const u8, arg: []const u8) bool {
        const goals = self.last_query_goals orelse {
            self.jsonError(input, "usage", "no successful query to explain");
            return true;
        };
        if (self.last_solutions.len == 0) {
            self.jsonError(input, "usage", "no successful query to explain");
            return true;
        }
        const n = if (arg.len == 0) 1 else std.fmt.parseInt(usize, arg, 10) catch 0;
        if (n == 0 or n > self.last_solutions.len) {
            self.jsonError(input, "usage", "solution index out of range");
            return true;
        }
        const trees = self.engine.buildProofTrees(goals, &self.last_solutions[n - 1]) catch {
            self.jsonError(input, "usage", "explanation failed");
            return true;
        };
        var buf = self.newObj(input, "proof");
        buf.numField("solution", n);
        buf.key("trees");
        buf.beginArr();
        for (trees) |*node| {
            buf.sep();
            self.proofNodeJson(&buf, node);
            buf.first_in_scope = false;
        }
        buf.endArr();
        self.emitObj(&buf);
        return true;
    }

    fn jsonDiff(self: *Axiom, input: []const u8, old_path: []const u8, new_path: []const u8) bool {
        var old_eng = self.loadScratch(old_path) orelse {
            self.jsonError(input, "file", "could not load old version");
            return true;
        };
        var new_eng = self.loadScratch(new_path) orelse {
            self.jsonError(input, "file", "could not load new version");
            return true;
        };
        const diffs = engine_mod.diff.diffPrograms(self.allocator, old_eng.getClauses(), new_eng.getClauses()) catch {
            self.jsonError(input, "usage", "diff failed");
            return true;
        };
        var buf = self.newObj(input, "diff");
        buf.key("changes");
        buf.beginArr();
        for (diffs) |d| {
            buf.sep();
            buf.beginObj();
            buf.strField("kind", @tagName(d.kind));
            const rep = d.new_clause orelse d.old_clause.?;
            if (rep.label.len > 0) buf.strField("label", rep.label);
            if (d.old_clause) |c| {
                if (engine_mod.english.clauseToEnglish(self.allocator, c)) |eng| buf.strField("old", eng) else |_| {}
            }
            if (d.new_clause) |c| {
                if (engine_mod.english.clauseToEnglish(self.allocator, c)) |eng| buf.strField("new", eng) else |_| {}
            }
            buf.endObj();
            buf.first_in_scope = false;
        }
        buf.endArr();
        self.emitObj(&buf);
        return true;
    }

    fn jsonWhatIf(self: *Axiom, input: []const u8, old_path: []const u8, new_path: []const u8, inputs_path: []const u8) bool {
        var old_eng = self.loadScratch(old_path) orelse {
            self.jsonError(input, "file", "could not load old version");
            return true;
        };
        var new_eng = self.loadScratch(new_path) orelse {
            self.jsonError(input, "file", "could not load new version");
            return true;
        };
        const data = std.Io.Dir.cwd().readFileAlloc(types.defaultIo(), inputs_path, self.allocator, .limited(1024 * 1024)) catch {
            self.jsonError(input, "file", "could not read inputs file");
            return true;
        };
        var buf = self.newObj(input, "whatif");
        buf.key("changed");
        buf.beginArr();
        var total: usize = 0;
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, &std.ascii.whitespace);
            if (line.len == 0 or line[0] == '%') continue;
            var fields = std.mem.tokenizeAny(u8, line, " \t");
            const subject = fields.next() orelse continue;
            const action = fields.next() orelse continue;
            const resource = fields.next();
            total += 1;
            const old_d = old_eng.decide(subject, action, resource) catch continue;
            const new_d = new_eng.decide(subject, action, resource) catch continue;
            if (old_d.outcome == new_d.outcome) continue;
            buf.sep();
            buf.beginObj();
            buf.strField("subject", subject);
            buf.strField("action", action);
            if (resource) |r| buf.strField("resource", r);
            buf.strField("old", @tagName(old_d.outcome));
            buf.strField("new", @tagName(new_d.outcome));
            buf.stringArrField("old_reasons", old_d.reasons);
            buf.stringArrField("new_reasons", new_d.reasons);
            buf.endObj();
            buf.first_in_scope = false;
        }
        buf.endArr();
        buf.numField("total", total);
        self.emitObj(&buf);
        return true;
    }

    fn jsonPred(self: *Axiom, input: []const u8, spec: []const u8) bool {
        const slash = std.mem.indexOfScalar(u8, spec, '/') orelse {
            self.jsonError(input, "usage", ":pred <name>/<arity>");
            return true;
        };
        const name = spec[0..slash];
        const arity = std.fmt.parseInt(u8, spec[slash + 1 ..], 10) catch {
            self.jsonError(input, "usage", "invalid arity");
            return true;
        };
        var buf = self.newObj(input, "pred");
        buf.strField("name", name);
        buf.numField("arity", arity);
        buf.boolField("closed_world", self.engine.isClosedWorld(name));
        if (self.engine.getPredInfo(name, arity)) |info| {
            buf.strField("determinism", info.det.label());
            buf.boolField("declared", true);
        } else {
            buf.boolField("declared", false);
        }
        var count: usize = 0;
        for (self.engine.getClauses()) |clause| {
            if (std.mem.eql(u8, clause.head.functor, name) and clause.head.args.len == arity) count += 1;
        }
        buf.numField("clauses", count);
        self.emitObj(&buf);
        return true;
    }

    /// Statements (facts, rules, queries, decisions) in JSON mode: one
    /// object per parsed statement.
    fn jsonStatements(self: *Axiom, input: []const u8) void {
        var lex = Lexer.init(input);
        const tokens = lex.tokenize(self.allocator) catch {
            self.jsonError(input, "parse", "tokenize failed");
            return;
        };
        var parser = Parser.init(tokens, self.allocator);
        while (parser.peek().tag != .eof) {
            const start_idx = parser.pos;
            if (parser.parseStatement()) |stmt| {
                const span = statementSpan(input, tokens, start_idx, parser.pos - 1);
                const stmt_input = if (span.len > 0) span else input;
                self.jsonStatement(stmt_input, stmt);
            } else |_| {
                var buf = self.newObj(input, "error");
                buf.strField("kind", "parse");
                buf.numField("line", parser.last_error_line);
                buf.numField("col", parser.last_error_col);
                buf.strField("near", parser.last_error_token);
                if (phrasingHint(input)) |hint| buf.strField("hint", hint);
                self.emitObj(&buf);
                parser.recover();
            }
        }
    }

    fn jsonStatement(self: *Axiom, input: []const u8, stmt: Statement) void {
        switch (stmt) {
            .should_query => |q| {
                const decision = self.engine.decide(q.subject, q.action, q.resource) catch {
                    self.jsonError(input, "usage", "decision failed");
                    return;
                };
                self.last_should = .{ .subject = q.subject, .action = q.action, .resource = q.resource, .outcome = decision.outcome };
                var buf = self.newObj(input, "decision");
                buf.strField("outcome", @tagName(decision.outcome));
                buf.stringArrField("reasons", decision.reasons);
                buf.stringArrField("evidence", decision.evidence);
                self.emitObj(&buf);
            },
            .why_not_query => {
                const last = self.last_should orelse {
                    self.jsonError(input, "usage", "no decision to explain");
                    return;
                };
                const wn = self.engine.whyNot(last.subject, last.action, last.resource) catch {
                    self.jsonError(input, "usage", "whynot failed");
                    return;
                };
                var buf = self.newObj(input, "whynot");
                buf.key("denies");
                buf.beginArr();
                for (wn.denies) |d| {
                    buf.sep();
                    buf.beginObj();
                    buf.strField("rule", d.rule);
                    buf.strField("outcome", d.outcome); // axiom-2fx
                    buf.stringArrField("evidence", d.evidence);
                    buf.endObj();
                    buf.first_in_scope = false;
                }
                buf.endArr();
                buf.key("near_misses");
                buf.beginArr();
                for (wn.near_misses) |m| {
                    buf.sep();
                    buf.beginObj();
                    buf.strField("rule", m.rule);
                    buf.strField("blocker", m.blocker);
                    buf.boolField("blocker_negated", m.blocker_negated);
                    buf.endObj();
                    buf.first_in_scope = false;
                }
                buf.endArr();
                self.emitObj(&buf);
            },
            .which_actions_query => |q| {
                const actions = self.engine.allowedActions(q.subject, q.resource) catch {
                    self.jsonError(input, "usage", "enumeration failed");
                    return;
                };
                var buf = self.newObj(input, "actions");
                buf.stringArrField("actions", actions);
                self.emitObj(&buf);
            },
            .closed_world_decl => |name| {
                self.engine.declareClosedWorld(name) catch {};
                var buf = self.newObj(input, "ok");
                buf.strField("declared", "closed_world");
                buf.strField("name", name);
                self.emitObj(&buf);
            },
            .mode_decl => |decl| {
                self.engine.registerMode(decl) catch {};
                var buf = self.newObj(input, "ok");
                buf.strField("declared", "mode");
                buf.strField("name", decl.pred_name);
                self.emitObj(&buf);
            },
            .command => |cmd| {
                switch (cmd) {
                    .load => |filename| self.jsonLoadFile(filename),
                    .show => _ = self.jsonShow(input, ""),
                    .include => |filename| {
                        self.handleInclude(filename, null);
                        var buf = self.newObj(input, "ok");
                        buf.strField("action", "include");
                        self.emitObj(&buf);
                    },
                }
            },
            else => {
                var desugarer = Desugarer.init(self.allocator);
                const result = (desugarer.desugar(stmt) catch {
                    self.jsonError(input, "parse", "could not translate sentence pattern");
                    return;
                }) orelse return;
                switch (result) {
                    .clause => |clause| {
                        var c = clause;
                        c.source_text = input;
                        c.label = self.takePendingLabel(); // axiom-m0n
                        self.engine.addClause(c) catch {
                            self.jsonError(input, "usage", "assert failed");
                            return;
                        };
                        const stored = self.engine.getClauses()[self.engine.getClauses().len - 1];
                        var buf = self.newObj(input, "ok");
                        buf.key("added");
                        buf.beginObj();
                        buf.strField("pred", stored.head.functor);
                        buf.numField("arity", stored.head.args.len);
                        var hex_buf: [16]u8 = undefined;
                        buf.strField("id", engine_mod.identity.hashHex(stored.id, &hex_buf));
                        if (stored.label.len > 0) buf.strField("label", stored.label);
                        buf.endObj();
                        self.emitObj(&buf);
                    },
                    .query => |q| {
                        self.jsonQuery(input, q.goals, q.variables);
                    },
                }
            },
        }
    }

    fn jsonQuery(self: *Axiom, input: []const u8, goals: []const Goal, variables: []const []const u8) void {
        self.last_query_goals = goals;
        const solutions = self.engine.solveAll(goals) catch |err| switch (err) {
            // axiom-7yv: limit errors get their own kind so agents can react
            error.StepLimitExceeded, error.DepthLimitExceeded => {
                var msg_buf: [128]u8 = undefined;
                const msg = std.fmt.bufPrint(&msg_buf, "recursion limit exceeded in {s}/{d}", .{ self.engine.limit_functor, self.engine.limit_arity }) catch "recursion limit exceeded";
                self.jsonError(input, "limit", msg);
                return;
            },
            else => {
                self.jsonError(input, "usage", "query failed");
                return;
            },
        };
        self.last_solutions = solutions;

        if (variables.len == 0) {
            var buf = self.newObj(input, "yesno");
            buf.boolField("answer", solutions.len > 0);
            buf.boolField("cwa", solutions.len == 0 and self.allGoalsClosedWorld(goals));
            self.emitObj(&buf);
            return;
        }

        var buf = self.newObj(input, "solutions");
        buf.numField("count", solutions.len);
        buf.key("solutions");
        buf.beginArr();
        for (solutions) |solution| {
            buf.sep();
            buf.beginObj();
            for (variables) |varname| {
                const resolved = solution.deepWalk(.{ .variable = varname }, self.allocator) catch continue;
                switch (resolved) {
                    .variable => |v| {
                        if (std.mem.eql(u8, v, varname)) continue;
                        if (isRenamedVar(varname, v)) continue;
                    },
                    else => {},
                }
                const display_name = if (std.mem.startsWith(u8, varname, "_")) varname[1..] else varname;
                buf.key(display_name);
                self.termValue(&buf, resolved);
            }
            buf.endObj();
            buf.first_in_scope = false;
        }
        buf.endArr();
        self.emitObj(&buf);
    }

    fn takePendingLabel(self: *Axiom) []const u8 {
        const label = self.pending_label;
        self.pending_label = "";
        return label;
    }

    /// Dispatch one REPL line. Returns false when the session should end.
    fn handleLine(self: *Axiom, input: []const u8) bool {
        // axiom-m0n: a pure '% id:' comment line names the next statement
        // (line-splitting separates it from its rule, so :load-style
        // adjacency capture cannot see it here)
        if (std.mem.startsWith(u8, input, "% id:")) {
            self.pending_label = std.mem.trim(u8, input["% id:".len..], &std.ascii.whitespace);
            return true;
        }
        if (std.mem.startsWith(u8, input, "%")) return true; // plain comment

        if (self.json_mode) return self.handleLineJson(input); // axiom-47h
                // REPL commands
                if (std.mem.eql(u8, input, ":quit") or std.mem.eql(u8, input, ":q")) {
                    writeStr("Goodbye.\n");
                    return false;
                }

                if (std.mem.startsWith(u8, input, ":load ")) {
                    const filename = std.mem.trim(u8, input[6..], &std.ascii.whitespace);
                    self.loadFile(filename) catch |err| {
                        output("Error: {}\n", .{err});
                    };
                    return true;
                }

                if (std.mem.eql(u8, input, ":show")) {
                    self.showClauses(.all);
                    return true;
                }

                // axiom-krf
                if (std.mem.startsWith(u8, input, ":show ")) {
                    const arg = std.mem.trim(u8, input[6..], &std.ascii.whitespace);
                    if (std.mem.eql(u8, arg, "facts")) {
                        self.showClauses(.facts);
                    } else if (std.mem.eql(u8, arg, "rules")) {
                        self.showClauses(.rules);
                    } else if (std.mem.eql(u8, arg, "ids")) {
                        self.showClauseIds(); // axiom-ekd
                    } else if (std.mem.eql(u8, arg, "english")) {
                        self.showClausesEnglish(); // axiom-xec
                    } else {
                        errStr("Usage: :show [facts|rules|ids|english]\n");
                    }
                    return true;
                }

                // axiom-76a
                if (std.mem.startsWith(u8, input, ":retract")) {
                    const arg = std.mem.trim(u8, input[8..], &std.ascii.whitespace);
                    self.retractClause(arg);
                    return true;
                }

                if (std.mem.eql(u8, input, ":clear")) {
                    self.clearKb();
                    return true;
                }

                if (std.mem.startsWith(u8, input, ":save")) {
                    const arg = std.mem.trim(u8, input[5..], &std.ascii.whitespace);
                    self.saveClauses(arg);
                    return true;
                }

                if (std.mem.eql(u8, input, ":reload")) {
                    self.reloadFiles();
                    return true;
                }

                // axiom-47h
                if (std.mem.eql(u8, input, ":json")) {
                    self.json_mode = true;
                    self.enableJsonCapture();
                    var buf = self.newObj(input, "mode");
                    buf.boolField("json", true);
                    self.emitObj(&buf);
                    return true;
                }

                // axiom-aof
                if (std.mem.startsWith(u8, input, ":diff")) {
                    var fields = std.mem.tokenizeAny(u8, input[5..], " \t");
                    const a = fields.next();
                    const b = fields.next();
                    if (a == null or b == null or fields.next() != null) {
                        errStr("Usage: :diff <old.axm> <new.axm>\n");
                    } else {
                        self.diffFiles(a.?, b.?);
                    }
                    return true;
                }

                if (std.mem.startsWith(u8, input, ":whatif")) {
                    var fields = std.mem.tokenizeAny(u8, input[7..], " \t");
                    const a = fields.next();
                    const b = fields.next();
                    const inp = fields.next();
                    if (a == null or b == null or inp == null or fields.next() != null) {
                        errStr("Usage: :whatif <old.axm> <new.axm> <inputs.txt>\n");
                    } else {
                        self.whatIf(a.?, b.?, inp.?);
                    }
                    return true;
                }

                // Trace commands
                if (std.mem.eql(u8, input, ":trace on")) {
                    self.engine.trace_enabled = true;
                    writeStr("Trace: ON\n");
                    return true;
                }
                if (std.mem.eql(u8, input, ":trace off")) {
                    self.engine.trace_enabled = false;
                    writeStr("Trace: OFF\n");
                    return true;
                }
                if (std.mem.eql(u8, input, ":trace")) {
                    if (self.engine.trace_enabled) {
                        writeStr("Trace is ON\n");
                    } else {
                        writeStr("Trace is OFF\n");
                    }
                    return true;
                }

                // Why command — axiom-9nz: :why [n]
                if (std.mem.eql(u8, input, ":why") or std.mem.startsWith(u8, input, ":why ")) {
                    const arg = if (input.len > 4) std.mem.trim(u8, input[4..], &std.ascii.whitespace) else "";
                    self.explainWhy(arg);
                    return true;
                }

                // :pred Name/Arity
                if (std.mem.startsWith(u8, input, ":pred ")) {
                    self.showPredInfo(std.mem.trim(u8, input[6..], &std.ascii.whitespace));
                    return true;
                }

                // :check
                if (std.mem.eql(u8, input, ":check")) {
                    self.runChecks();
                    return true;
                }

                // Help
                if (std.mem.eql(u8, input, ":help")) {
                    self.printHelp();
                    return true;
                }

                // Process as Axiom source
                self.processSourceHandleError(input);
                return true;
    }

    fn printHelp(_: *Axiom) void {
        writeStr(
            \\Commands:
            \\  :load <file>     Load an .axm file
            \\  :show            List all loaded clauses
            \\  :show facts      List only facts
            \\  :show rules      List only rules
            \\  :show ids        List clauses with stable ids and labels
            \\  :show english    List clauses as canonical English
            \\  :retract <n>     Remove clause n (numbers shift; see :show)
            \\  :clear           Remove all clauses and declarations
            \\  :save <file>     Save clause sentences to a file
            \\  :reload          Clear, then re-load all loaded files
            \\  :diff a b        Semantic diff between two .axm files
            \\  :whatif a b in   Decision deltas between versions (inputs file)
            \\  :trace on/off    Toggle execution tracing
            \\  :trace           Show current trace status
            \\  :why [n]         Explain solution n of the last query (default 1)
            \\  :pred name/arity Show predicate info (determinism, modes)
            \\  :check           Run determinism and mode checks
            \\  :help            Show this help
            \\  :quit / :q       Exit the REPL
            \\
            \\Syntax:
            \\  Facts:    Socrates is a man.
            \\  Rules:    X is mortal if X is a man.
            \\  Queries:  Is Socrates mortal?  /  Who is mortal?
            \\  Decision: Should leslie log_in?  (deny-overrides)
            \\            Which actions can leslie perform on prod?
            \\            Why not?   (counterfactuals for the last Should)
            \\  Negation: X is not banned.
            \\  Include:  include "file.axm".
            \\  Det:      X is a Y! if ...   (! det, ? semidet, * nondet)
            \\  Mode:     mode pred(+In, -Out) !.
            \\
            \\
        );
    }

    fn processSourceHandleError(self: *Axiom, input: []const u8) void {
        var lex = Lexer.init(input);
        const tokens = lex.tokenize(self.allocator) catch |err| {
            output("Error: {}\n", .{err});
            return;
        };
        var parser = Parser.init(tokens, self.allocator);

        // Try parsing each statement individually for better error reporting
        while (parser.peek().tag != .eof) {
            const start_idx = parser.pos; // axiom-76a
            if (parser.parseStatement()) |stmt| {
                const span = statementSpan(input, tokens, start_idx, parser.pos - 1);
                const label = self.takePendingLabel(); // axiom-m0n
                self.processStatementWithDir(stmt, null, span, label) catch |err| {
                    self.printParseErrorWithPos(input, err, 0, 0, "");
                };
            } else |_| {
                // Report the error with position info
                self.printParseErrorWithPos(input, error.UnexpectedToken, parser.last_error_line, parser.last_error_col, parser.last_error_token);
                parser.recover();
            }
        }
    }

    // axiom-wk4: echo the offending line with a caret under the column
    fn printCaretLine(input: []const u8, line: usize, col: usize) void {
        var it = std.mem.splitScalar(u8, input, '\n');
        var ln: usize = 1;
        while (it.next()) |l| : (ln += 1) {
            if (ln != line) continue;
            writeStr("  ");
            writeStr(l);
            writeStr("\n  ");
            const stop = @min(col -| 1, l.len);
            var i: usize = 0;
            while (i < stop) : (i += 1) writeStr(" ");
            writeStr("^\n");
            return;
        }
    }

    fn printParseErrorWithPos(_: *Axiom, input: []const u8, err: anyerror, line: usize, col: usize, token: []const u8) void {
        switch (err) {
            error.UnexpectedToken => {
                if (line > 0) {
                    eout.style(.err); // axiom-wk4
                    output("Parse error at line {d}, column {d}", .{ line, col });
                    if (token.len > 0) {
                        output(" near \"{s}\"", .{token});
                    }
                    writeStr(":\n");
                    eout.style(.reset);
                    printCaretLine(input, line, col); // axiom-wk4
                    if (phrasingHint(input)) |hint| { // axiom-8zj
                        writeStr("  Hint: ");
                        writeStr(hint);
                        writeStr("\n");
                    }
                } else {
                    errOut("Parse error in: \"{s}\"\n", .{input});
                }
                writeStr("  Expected a sentence like:\n");
                writeStr("    \"X is a Y.\"  or  \"X has Y Z.\"  or  \"X is Y if ...\".\n");
                writeStr("  Queries start with: Is, Who, What, Which, Can\n");
            },
            error.UnexpectedEof => {
                writeStr("Parse error: unexpected end of input.\n");
                writeStr("  Did you forget a '.' or '?' at the end?\n");
            },
            error.OutOfMemory => writeStr("Error: out of memory.\n"),
            error.InvalidPattern => {
                output("Desugar error in: \"{s}\"\n", .{input});
                writeStr("  Could not translate this sentence pattern to logic.\n");
                writeStr("  Try: \"X is a Y.\", \"X has Y Z.\", or \"X is Y of Z.\"\n");
            },
            else => output("Error: {}\n", .{err}),
        }
    }
};

fn printTerm(term: Term) void {
    switch (term) {
        .atom => |a| output("{s}", .{a}),
        .variable => |v| output("{s}", .{v}),
        .integer => |i| output("{d}", .{i}),
        .string => |s| output("\"{s}\"", .{s}), // axiom-rhc
        .nil => writeStr("[]"),
        .compound => |c| {
            output("{s}(", .{c.functor});
            for (c.args, 0..) |arg, idx| {
                if (idx > 0) writeStr(", ");
                printTerm(arg);
            }
            writeStr(")");
        },
        .list => |l| {
            writeStr("[");
            printTerm(l.head.*);
            var tail = l.tail;
            while (true) {
                switch (tail.*) {
                    .list => |next| {
                        writeStr(", ");
                        printTerm(next.head.*);
                        tail = next.tail;
                    },
                    .nil => break,
                    else => {
                        writeStr(" | ");
                        printTerm(tail.*);
                        break;
                    },
                }
            }
            writeStr("]");
        },
    }
}

fn printGoal(goal: Goal) void {
    switch (goal) {
        .call => |c| {
            output("{s}(", .{c.functor});
            for (c.args, 0..) |arg, i| {
                if (i > 0) writeStr(", ");
                printTerm(arg);
            }
            writeStr(")");
        },
        .not => |inner| {
            writeStr("\\+ ");
            printGoal(inner.*);
        },
        .cut => writeStr("!"),
    }
}

fn isRenamedVar(original: []const u8, resolved: []const u8) bool {
    if (!std.mem.startsWith(u8, resolved, original)) return false;
    if (resolved.len <= original.len) return false;
    return resolved[original.len] == '_';
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // axiom-wk4: colors when stdout is a TTY and NO_COLOR is unset
    const is_tty = std.Io.File.stdout().isTty(types.defaultIo()) catch false;
    eout.color_enabled = is_tty and init.environ_map.get("NO_COLOR") == null;

    var axiom = Axiom.init(allocator);

    // axiom-82z: persistent history location
    if (init.environ_map.get("HOME")) |home| {
        axiom.history_path = try std.fmt.allocPrint(allocator, "{s}/.axiom_history", .{home});
    }

    // axiom-6th / axiom-47h: flags before file arguments
    var args_it = std.process.Args.Iterator.init(init.minimal.args);
    defer args_it.deinit();
    _ = args_it.skip(); // argv[0]
    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            axiom.json_mode = true;
            eout.color_enabled = false;
            continue;
        }
        if (axiom.json_mode) {
            axiom.jsonLoadFile(arg);
        } else {
            axiom.loadFile(arg) catch |err| {
                output("Error: {}\n", .{err});
            };
        }
    }

    try axiom.repl();
}
