// axiom-82z
// Raw-mode line editor for the interactive REPL: emacs-style bindings,
// persistent history, and tab completion (command names; file arguments
// via fzf when available, prefix-cycling fallback otherwise).
//
// Only constructed when stdin and stdout are both TTYs — piped input never
// touches this code. Rendering is full-line redraw per keystroke; lines
// longer than the terminal width render imperfectly (accepted v1 limit).
const std = @import("std");

const stdin_file = std.Io.File.stdin();
const stdout_file = std.Io.File.stdout();

const max_history = 1000;

pub const Options = struct {
    prompt: []const u8,
    commands: []const []const u8,
    history_path: ?[]const u8 = null,
};

pub const Editor = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    prompt: []const u8,
    prompt_width: usize,
    commands: []const []const u8,
    history_path: ?[]const u8,

    buf: std.ArrayList(u8),
    cursor: usize,

    history: std.ArrayList([]const u8),
    hist_index: ?usize,
    stash: []const u8,

    // completion cycling state
    comp_candidates: std.ArrayList([]const u8),
    comp_index: usize,
    comp_start: usize, // buffer offset the candidate replaces from
    comp_active: bool,

    orig_termios: ?std.posix.termios,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, opts: Options) Editor {
        var ed: Editor = .{
            .allocator = allocator,
            .io = io,
            .prompt = opts.prompt,
            .prompt_width = displayWidth(opts.prompt),
            .commands = opts.commands,
            .history_path = opts.history_path,
            .buf = .empty,
            .cursor = 0,
            .history = .empty,
            .hist_index = null,
            .stash = "",
            .comp_candidates = .empty,
            .comp_index = 0,
            .comp_start = 0,
            .comp_active = false,
            .orig_termios = null,
        };
        ed.loadHistory();
        return ed;
    }

    pub fn deinit(self: *Editor) void {
        self.restoreTermios();
    }

    /// Read one line. Returns null on EOF (C-d on an empty line).
    /// The returned slice is owned by the editor's allocator.
    pub fn readLine(self: *Editor) !?[]const u8 {
        try self.enterRaw();
        defer self.restoreTermios();

        self.buf.clearRetainingCapacity();
        self.cursor = 0;
        self.hist_index = null;
        self.comp_active = false;
        self.redraw();

        while (true) {
            const c = self.readByte() orelse {
                self.write("\r\n");
                return null; // EOF
            };

            // any key other than Tab ends a completion cycle
            if (c != 0x09) self.comp_active = false;

            switch (c) {
                0x0d, 0x0a => { // Enter
                    self.write("\r\n");
                    const line = try self.allocator.dupe(u8, self.buf.items);
                    self.appendHistory(line);
                    return line;
                },
                0x03 => { // C-c: cancel line, fresh prompt
                    self.write("^C\r\n");
                    self.buf.clearRetainingCapacity();
                    self.cursor = 0;
                    self.hist_index = null;
                    self.redraw();
                },
                0x04 => { // C-d: EOF on empty line, else delete forward
                    if (self.buf.items.len == 0) {
                        self.write("\r\n");
                        return null;
                    }
                    if (self.cursor < self.buf.items.len) {
                        _ = self.buf.orderedRemove(self.cursor);
                        self.redraw();
                    }
                },
                0x01 => { // C-a
                    self.cursor = 0;
                    self.redraw();
                },
                0x05 => { // C-e
                    self.cursor = self.buf.items.len;
                    self.redraw();
                },
                0x02 => { // C-b
                    if (self.cursor > 0) self.cursor -= 1;
                    self.redraw();
                },
                0x06 => { // C-f
                    if (self.cursor < self.buf.items.len) self.cursor += 1;
                    self.redraw();
                },
                0x0b => { // C-k: kill to end of line
                    self.buf.shrinkRetainingCapacity(self.cursor);
                    self.redraw();
                },
                0x15 => { // C-u: kill whole line
                    self.buf.clearRetainingCapacity();
                    self.cursor = 0;
                    self.redraw();
                },
                0x17 => { // C-w: kill word backwards
                    const start = self.wordLeft();
                    self.deleteRange(start, self.cursor);
                    self.cursor = start;
                    self.redraw();
                },
                0x10 => self.historyPrev(), // C-p
                0x0e => self.historyNext(), // C-n
                0x0c => { // C-l: clear screen
                    self.write("\x1b[2J\x1b[H");
                    self.redraw();
                },
                0x7f, 0x08 => { // Backspace
                    if (self.cursor > 0) {
                        _ = self.buf.orderedRemove(self.cursor - 1);
                        self.cursor -= 1;
                        self.redraw();
                    }
                },
                0x09 => try self.complete(), // Tab
                0x1b => self.handleEscape(),
                else => {
                    if (c >= 0x20 and c < 0x7f) {
                        try self.buf.insert(self.allocator, self.cursor, c);
                        self.cursor += 1;
                        self.redraw();
                    }
                    // other control bytes ignored
                },
            }
        }
    }

    // ─── Terminal mode ──────────────────────────────────────────────

    fn enterRaw(self: *Editor) !void {
        const fd = std.posix.STDIN_FILENO;
        const orig = try std.posix.tcgetattr(fd);
        self.orig_termios = orig;
        var raw = orig;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ISIG = false;
        raw.iflag.IXON = false;
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        try std.posix.tcsetattr(fd, .NOW, raw);
    }

    fn restoreTermios(self: *Editor) void {
        if (self.orig_termios) |orig| {
            std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, orig) catch {};
            self.orig_termios = null;
        }
    }

    // ─── I/O ────────────────────────────────────────────────────────

    fn readByte(self: *Editor) ?u8 {
        var b: [1]u8 = undefined;
        const n = stdin_file.readStreaming(self.io, &.{b[0..1]}) catch return null;
        if (n == 0) return null;
        return b[0];
    }

    fn write(self: *Editor, s: []const u8) void {
        stdout_file.writeStreamingAll(self.io, s) catch {};
    }

    fn redraw(self: *Editor) void {
        self.write("\r");
        self.write(self.prompt);
        self.write(self.buf.items);
        self.write("\x1b[K");
        // reposition cursor
        self.write("\r");
        const col = self.prompt_width + self.cursor;
        if (col > 0) {
            var num_buf: [32]u8 = undefined;
            const seq = std.fmt.bufPrint(&num_buf, "\x1b[{d}C", .{col}) catch return;
            self.write(seq);
        }
    }

    /// Visible width of a string containing SGR escape sequences.
    fn displayWidth(s: []const u8) usize {
        var w: usize = 0;
        var i: usize = 0;
        while (i < s.len) {
            if (s[i] == 0x1b) {
                while (i < s.len and s[i] != 'm') i += 1;
                if (i < s.len) i += 1;
            } else {
                w += 1;
                i += 1;
            }
        }
        return w;
    }

    // ─── Escape sequences ───────────────────────────────────────────

    fn handleEscape(self: *Editor) void {
        const c1 = self.readByte() orelse return;
        switch (c1) {
            '[' => {
                const c2 = self.readByte() orelse return;
                switch (c2) {
                    'A' => self.historyPrev(),
                    'B' => self.historyNext(),
                    'C' => {
                        if (self.cursor < self.buf.items.len) self.cursor += 1;
                        self.redraw();
                    },
                    'D' => {
                        if (self.cursor > 0) self.cursor -= 1;
                        self.redraw();
                    },
                    'H' => {
                        self.cursor = 0;
                        self.redraw();
                    },
                    'F' => {
                        self.cursor = self.buf.items.len;
                        self.redraw();
                    },
                    '1', '7' => { // ESC [ 1 ~ → Home
                        _ = self.readByte();
                        self.cursor = 0;
                        self.redraw();
                    },
                    '4', '8' => { // ESC [ 4 ~ → End
                        _ = self.readByte();
                        self.cursor = self.buf.items.len;
                        self.redraw();
                    },
                    '3' => { // ESC [ 3 ~ → Delete
                        _ = self.readByte();
                        if (self.cursor < self.buf.items.len) {
                            _ = self.buf.orderedRemove(self.cursor);
                            self.redraw();
                        }
                    },
                    else => {},
                }
            },
            'b' => { // Alt-b: word left
                self.cursor = self.wordLeft();
                self.redraw();
            },
            'f' => { // Alt-f: word right
                self.cursor = self.wordRight();
                self.redraw();
            },
            else => {},
        }
    }

    // ─── Editing helpers ────────────────────────────────────────────

    fn wordLeft(self: *Editor) usize {
        var i = self.cursor;
        while (i > 0 and self.buf.items[i - 1] == ' ') i -= 1;
        while (i > 0 and self.buf.items[i - 1] != ' ') i -= 1;
        return i;
    }

    fn wordRight(self: *Editor) usize {
        var i = self.cursor;
        const items = self.buf.items;
        while (i < items.len and items[i] == ' ') i += 1;
        while (i < items.len and items[i] != ' ') i += 1;
        return i;
    }

    fn deleteRange(self: *Editor, start: usize, end: usize) void {
        if (start >= end) return;
        const items = self.buf.items;
        std.mem.copyForwards(u8, items[start..], items[end..]);
        self.buf.shrinkRetainingCapacity(items.len - (end - start));
    }

    fn setBuffer(self: *Editor, content: []const u8) void {
        self.buf.clearRetainingCapacity();
        self.buf.appendSlice(self.allocator, content) catch return;
        self.cursor = self.buf.items.len;
    }

    // ─── History ────────────────────────────────────────────────────

    fn historyPrev(self: *Editor) void {
        if (self.history.items.len == 0) return;
        if (self.hist_index == null) {
            self.stash = self.allocator.dupe(u8, self.buf.items) catch return;
            self.hist_index = self.history.items.len;
        }
        if (self.hist_index.? == 0) return;
        self.hist_index = self.hist_index.? - 1;
        self.setBuffer(self.history.items[self.hist_index.?]);
        self.redraw();
    }

    fn historyNext(self: *Editor) void {
        if (self.hist_index == null) return;
        self.hist_index = self.hist_index.? + 1;
        if (self.hist_index.? >= self.history.items.len) {
            self.hist_index = null;
            self.setBuffer(self.stash);
        } else {
            self.setBuffer(self.history.items[self.hist_index.?]);
        }
        self.redraw();
    }

    fn appendHistory(self: *Editor, line: []const u8) void {
        if (line.len == 0) return;
        if (self.history.items.len > 0 and
            std.mem.eql(u8, self.history.items[self.history.items.len - 1], line))
            return;
        self.history.append(self.allocator, line) catch return;
        self.persistLine(line);
    }

    fn loadHistory(self: *Editor) void {
        const path = self.history_path orelse return;
        const data = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(1024 * 1024)) catch return;
        var lines: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            lines.append(self.allocator, line) catch return;
        }
        const start = if (lines.items.len > max_history) lines.items.len - max_history else 0;
        for (lines.items[start..]) |line| {
            self.history.append(self.allocator, line) catch return;
        }
    }

    fn persistLine(self: *Editor, line: []const u8) void {
        const path = self.history_path orelse return;
        const file = std.Io.Dir.cwd().createFile(self.io, path, .{ .truncate = false }) catch return;
        defer file.close(self.io);
        const end = file.length(self.io) catch return;
        var data = self.allocator.alloc(u8, line.len + 1) catch return;
        @memcpy(data[0..line.len], line);
        data[line.len] = '\n';
        file.writePositionalAll(self.io, data, end) catch {};
    }

    // ─── Completion ─────────────────────────────────────────────────

    fn complete(self: *Editor) !void {
        if (self.comp_active) {
            self.cycleCompletion();
            return;
        }

        const items = self.buf.items;

        // command-name completion: line starts with ':' and has no space yet
        if (items.len > 0 and items[0] == ':' and std.mem.indexOfScalar(u8, items, ' ') == null) {
            self.comp_candidates.clearRetainingCapacity();
            for (self.commands) |cmd| {
                if (std.mem.startsWith(u8, cmd, items)) {
                    try self.comp_candidates.append(self.allocator, cmd);
                }
            }
            if (self.comp_candidates.items.len == 0) return;
            self.comp_start = 0;
            self.comp_index = 0;
            self.comp_active = true;
            self.applyCandidate();
            return;
        }

        // file-argument completion for :load / :save
        for ([_][]const u8{ ":load ", ":save " }) |prefix| {
            if (std.mem.startsWith(u8, items, prefix)) {
                const arg_start = prefix.len;
                const arg = items[arg_start..];
                switch (self.runFzf()) {
                    .selection => |sel| {
                        self.buf.shrinkRetainingCapacity(arg_start);
                        try self.buf.appendSlice(self.allocator, sel);
                        self.cursor = self.buf.items.len;
                        self.redraw();
                    },
                    .cancelled => {}, // user dismissed fzf — leave the line alone
                    .unavailable => try self.completeFile(arg_start, arg),
                }
                return;
            }
        }
    }

    fn cycleCompletion(self: *Editor) void {
        if (self.comp_candidates.items.len == 0) return;
        self.comp_index = (self.comp_index + 1) % self.comp_candidates.items.len;
        self.applyCandidate();
    }

    fn applyCandidate(self: *Editor) void {
        const cand = self.comp_candidates.items[self.comp_index];
        self.buf.shrinkRetainingCapacity(self.comp_start);
        self.buf.appendSlice(self.allocator, cand) catch return;
        self.cursor = self.buf.items.len;
        self.redraw();
    }

    const FzfResult = union(enum) {
        unavailable, // fzf not on PATH — use the builtin fallback
        cancelled, // fzf ran and the user dismissed it — change nothing
        selection: []const u8,
    };

    /// Spawn fzf with stdout piped, stdin/stderr inherited.
    fn runFzf(self: *Editor) FzfResult {
        // fzf manages the terminal itself; hand it a cooked tty
        const saved = self.orig_termios;
        self.restoreTermios();
        defer {
            self.orig_termios = saved;
            if (saved) |orig| {
                var raw = orig;
                raw.lflag.ICANON = false;
                raw.lflag.ECHO = false;
                raw.lflag.ISIG = false;
                raw.iflag.IXON = false;
                raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
                raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
                std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, raw) catch {};
            }
            self.redraw();
        }

        var child = std.process.spawn(self.io, .{
            .argv = &.{"fzf"},
            .stdout = .pipe,
        }) catch return .unavailable;
        const out = child.stdout orelse return .cancelled;

        var result: std.ArrayList(u8) = .empty;
        var chunk: [256]u8 = undefined;
        while (true) {
            const n = out.readStreaming(self.io, &.{chunk[0..]}) catch break;
            if (n == 0) break;
            result.appendSlice(self.allocator, chunk[0..n]) catch break;
        }
        const term = child.wait(self.io) catch return .cancelled;
        switch (term) {
            .exited => |code| if (code != 0) return .cancelled,
            else => return .cancelled,
        }
        const trimmed = std.mem.trim(u8, result.items, &std.ascii.whitespace);
        if (trimmed.len == 0) return .cancelled;
        const sel = self.allocator.dupe(u8, trimmed) catch return .cancelled;
        return .{ .selection = sel };
    }

    /// Builtin fallback: cycle directory entries matching the typed prefix.
    /// `.axm` files and directories sort first.
    fn completeFile(self: *Editor, arg_start: usize, arg: []const u8) !void {
        const slash = std.mem.lastIndexOfScalar(u8, arg, '/');
        const dir_path = if (slash) |pos| arg[0 .. pos + 1] else "";
        const name_prefix = if (slash) |pos| arg[pos + 1 ..] else arg;

        const open_path = if (dir_path.len == 0) "." else dir_path;
        var dir = std.Io.Dir.cwd().openDir(self.io, open_path, .{ .iterate = true }) catch return;
        defer dir.close(self.io);

        self.comp_candidates.clearRetainingCapacity();
        var it = dir.iterate();
        while (it.next(self.io) catch null) |entry| {
            if (!std.mem.startsWith(u8, entry.name, name_prefix)) continue;
            const is_dir = entry.kind == .directory;
            const extra: usize = if (is_dir) 1 else 0;
            const cand = try self.allocator.alloc(u8, dir_path.len + entry.name.len + extra);
            @memcpy(cand[0..dir_path.len], dir_path);
            @memcpy(cand[dir_path.len..][0..entry.name.len], entry.name);
            if (is_dir) cand[cand.len - 1] = '/';
            try self.comp_candidates.append(self.allocator, cand);
        }
        if (self.comp_candidates.items.len == 0) return;

        std.mem.sort([]const u8, self.comp_candidates.items, {}, candidateLessThan);
        // candidates carry the dir prefix; replace from the arg start
        self.comp_start = arg_start;
        self.comp_index = 0;
        self.comp_active = true;
        self.applyCandidate();
    }

    fn candidateLessThan(_: void, a: []const u8, b: []const u8) bool {
        const rank_a = candidateRank(a);
        const rank_b = candidateRank(b);
        if (rank_a != rank_b) return rank_a < rank_b;
        return std.mem.lessThan(u8, a, b);
    }

    fn candidateRank(name: []const u8) u8 {
        if (std.mem.endsWith(u8, name, ".axm")) return 0;
        if (std.mem.endsWith(u8, name, "/")) return 1;
        return 2;
    }
};
