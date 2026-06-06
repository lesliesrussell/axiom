// axiom-s0w
// Trace / output helpers (no std.fmt allocation — safe across shared lib
// boundaries). Split out of engine.zig; part of the engine module.
const std = @import("std");
const types = @import("types.zig");
const Term = types.Term;
const Substitution = @import("substitution.zig").Substitution;

// axiom-6th
const stdout_file = std.Io.File.stdout();

// axiom-wk4
pub const Style = enum { err, ok, dim, accent, reset };

/// Set once at REPL startup: stdout is a TTY and NO_COLOR is unset.
/// Piped output stays byte-identical to uncolored output.
pub var color_enabled: bool = false;

pub fn style(s: Style) void {
    if (!color_enabled) return;
    writeRaw(switch (s) {
        .err => "\x1b[31m",
        .ok => "\x1b[32m",
        .dim => "\x1b[2m",
        .accent => "\x1b[36m",
        .reset => "\x1b[0m",
    });
}

// axiom-47h: JSON mode captures incidental engine text (trace, lint,
// warnings) instead of letting it pollute the protocol stream.
pub var capture_buf: ?*std.ArrayList(u8) = null;
pub var capture_alloc: std.mem.Allocator = undefined;

pub fn writeRaw(s: []const u8) void {
    if (capture_buf) |buf| {
        buf.appendSlice(capture_alloc, s) catch {};
        return;
    }
    stdout_file.writeStreamingAll(types.defaultIo(), s) catch {}; // axiom-6th
}

pub fn writeInt(val: anytype) void {
    var buf: [20]u8 = undefined;
    const T = @TypeOf(val);
    if (@typeInfo(T) == .int) {
        const v: i64 = @intCast(val);
        if (v < 0) {
            writeRaw("-");
            writeUint(@intCast(-v), &buf);
        } else {
            writeUint(@intCast(v), &buf);
        }
    } else {
        writeUint(val, &buf);
    }
}

fn writeUint(val: u64, buf: *[20]u8) void {
    if (val == 0) {
        writeRaw("0");
        return;
    }
    var v = val;
    var i: usize = buf.len;
    while (v > 0) {
        i -= 1;
        buf[i] = @intCast('0' + (v % 10));
        v /= 10;
    }
    writeRaw(buf[i..]);
}

/// Render an unsigned value as decimal digits into `buf`, returning the
/// used slice. Shared by predicate-key and variable-name builders.
pub fn uintToStr(val: usize, buf: []u8) []const u8 {
    if (val == 0) {
        buf[0] = '0';
        return buf[0..1];
    }
    var v = val;
    var i: usize = buf.len;
    while (v > 0) {
        i -= 1;
        buf[i] = @intCast('0' + (v % 10));
        v /= 10;
    }
    return buf[i..];
}

pub fn traceCompound(depth: usize, tag: []const u8, compound: Term.Compound, subst: *const Substitution, allocator: std.mem.Allocator) void {
    var indent_buf: [256]u8 = undefined;
    const indent_len = @min(depth * 2, 256);
    @memset(indent_buf[0..indent_len], ' ');
    writeRaw(indent_buf[0..indent_len]);

    writeRaw("[");
    writeRaw(tag);
    writeRaw("] ");
    writeRaw(compound.functor);
    writeRaw("(");
    for (compound.args, 0..) |arg, i| {
        if (i > 0) writeRaw(", ");
        const walked = subst.deepWalk(arg, allocator) catch arg;
        writeTermTo(walked);
    }
    writeRaw(")\n");
}

pub fn writeTermTo(term: Term) void {
    switch (term) {
        .atom => |a| writeRaw(a),
        .variable => |v| writeRaw(v),
        .integer => |i| writeInt(i),
        .string => |s| { // axiom-rhc
            writeRaw("\"");
            writeRaw(s);
            writeRaw("\"");
        },
        .nil => writeRaw("[]"),
        .compound => |c| {
            writeRaw(c.functor);
            writeRaw("(");
            for (c.args, 0..) |arg, idx| {
                if (idx > 0) writeRaw(", ");
                writeTermTo(arg);
            }
            writeRaw(")");
        },
        .list => |l| {
            writeRaw("[");
            writeTermTo(l.head.*);
            var tail = l.tail;
            while (true) {
                switch (tail.*) {
                    .list => |next| {
                        writeRaw(", ");
                        writeTermTo(next.head.*);
                        tail = next.tail;
                    },
                    .nil => break,
                    else => {
                        writeRaw(" | ");
                        writeTermTo(tail.*);
                        break;
                    },
                }
            }
            writeRaw("]");
        },
    }
}
