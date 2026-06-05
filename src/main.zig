const std = @import("std");
const lexer_mod = @import("lexer.zig");
const parser_mod = @import("parser.zig");
const desugar_mod = @import("desugar.zig");
const engine_mod = @import("engine.zig");
const types = @import("types.zig");
const editor_mod = @import("editor.zig"); // axiom-82z

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
    stdout_file.writeStreamingAll(types.defaultIo(), text) catch {}; // axiom-6th
}

fn writeStr(s: []const u8) void {
    stdout_file.writeStreamingAll(types.defaultIo(), s) catch {}; // axiom-6th
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
    ":check", ":clear", ":help", ":load ", ":pred ", ":quit", ":reload",
    ":retract ", ":save ", ":show", ":show facts", ":show rules",
    ":trace", ":trace on", ":trace off", ":why",
};

// axiom-76a
// Byte offset of (1-based) line/col in source. Lexer counts cols per byte.
fn byteOffsetOf(source: []const u8, line: usize, col: usize) usize {
    var cur_line: usize = 1;
    var i: usize = 0;
    while (i < source.len and cur_line < line) : (i += 1) {
        if (source[i] == '\n') cur_line += 1;
    }
    return @min(i + col - 1, source.len);
}

// axiom-76a
// Source span of a statement from its first through last token (inclusive).
// Token lexemes can be static literals, so offsets come from line/col.
fn statementSpan(source: []const u8, tokens: []const types.Token, start_idx: usize, end_idx: usize) []const u8 {
    if (start_idx >= tokens.len or end_idx >= tokens.len or end_idx < start_idx) return "";
    const st = tokens[start_idx];
    const et = tokens[end_idx];
    const s = byteOffsetOf(source, st.line, st.col);
    const e = @min(byteOffsetOf(source, et.line, et.col) + et.lexeme.len, source.len);
    if (e <= s) return "";
    return source[s..e];
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
                try self.processStatementWithDir(stmt, base_dir, span);
            } else |_| {
                // axiom-wk4: report instead of silently dropping
                skipped += 1;
                const fname = context orelse "<input>";
                errOut("{s}:{d}:{d}: skipped statement near \"{s}\"\n", .{ fname, parser.last_error_line, parser.last_error_col, parser.last_error_token });
                parser.recover();
            }
        }
        return skipped;
    }

    const ProcessError = std.mem.Allocator.Error || parser_mod.ParseError || desugar_mod.DesugarError;

    fn processStatement(self: *Axiom, stmt: Statement) ProcessError!void {
        return self.processStatementWithDir(stmt, null, "");
    }

    fn processStatementWithDir(self: *Axiom, stmt: Statement, base_dir: ?[]const u8, source_text: []const u8) ProcessError!void {
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
            else => {
                var desugarer = Desugarer.init(self.allocator);
                if (try desugarer.desugar(stmt)) |result| {
                    switch (result) {
                        .clause => |clause| {
                            // axiom-76a
                            var c = clause;
                            c.source_text = source_text;
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

    fn runQuery(self: *Axiom, goals: []const Goal, variables: []const []const u8) !void {
        self.last_query_goals = goals;
        const solutions = try self.engine.solveAll(goals);

        self.last_solutions = solutions; // axiom-9nz

        if (solutions.len == 0) {
            errStr("No.\n"); // axiom-wk4
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

    fn loadFile(self: *Axiom, filename: []const u8) !void {
        var actual: []const u8 = filename; // axiom-76a: path that actually loaded
        const source = std.Io.Dir.cwd().readFileAlloc(types.defaultIo(), filename, self.allocator, .limited(1024 * 1024)) catch blk: {
            const with_ext = try std.fmt.allocPrint(self.allocator, "{s}.axm", .{filename});
            const src2 = std.Io.Dir.cwd().readFileAlloc(types.defaultIo(), with_ext, self.allocator, .limited(1024 * 1024)) catch |err| {
                errOut("Error loading '{s}': {}\n", .{ filename, err });
                return;
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
        const word: []const u8 = if (added == 1) "clause" else "clauses";
        if (skipped > 0) {
            output("Loaded '{s}' ({d} {s}, {d} skipped).\n", .{ actual, added, word, skipped });
        } else {
            output("Loaded '{s}' ({d} {s}).\n", .{ actual, added, word });
        }
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

            // Count clauses
            var count: usize = 0;
            for (self.engine.getClauses()) |clause| {
                if (std.mem.eql(u8, clause.head.functor, name) and clause.head.args.len == arity) {
                    count += 1;
                }
            }
            output("  clauses: {d}\n", .{count});
        } else {
            output("No info for {s}/{d}. Predicate not found.\n", .{ name, arity });
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
            eout.style(.accent); // axiom-wk4
            writeStr("axiom> ");
            eout.style(.reset);

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

                const input = std.mem.trim(u8, line, &std.ascii.whitespace);
                if (input.len == 0) continue;

                if (!self.handleLine(input)) return;
            }
        }
    }

    /// Dispatch one REPL line. Returns false when the session should end.
    fn handleLine(self: *Axiom, input: []const u8) bool {
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
                    } else {
                        errStr("Usage: :show [facts|rules]\n");
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
            \\  :retract <n>     Remove clause n (numbers shift; see :show)
            \\  :clear           Remove all clauses and declarations
            \\  :save <file>     Save clause sentences to a file
            \\  :reload          Clear, then re-load all loaded files
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
                self.processStatementWithDir(stmt, null, span) catch |err| {
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

    // axiom-6th
    var args_it = std.process.Args.Iterator.init(init.minimal.args);
    defer args_it.deinit();
    _ = args_it.skip(); // argv[0]
    while (args_it.next()) |arg| {
        axiom.loadFile(arg) catch |err| {
            output("Error: {}\n", .{err});
        };
    }

    try axiom.repl();
}
