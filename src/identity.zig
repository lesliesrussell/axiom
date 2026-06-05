// axiom-ekd
// Stable clause identity: alpha-normalized serialization + Wyhash. Two
// clauses that differ only in variable naming hash identically; any
// structural difference (functor, args, body, det) changes the hash.
//
// Stability caveat: hashes are stable across runs of the same binary but
// pinned to std.hash.Wyhash — a stdlib change could shift them. Fine for
// in-process diffing; revisit before persisting hashes externally.
const std = @import("std");
const types = @import("types.zig");
const Term = types.Term;
const Goal = types.Goal;
const Clause = types.Clause;

pub fn clauseHash(allocator: std.mem.Allocator, clause: Clause) u64 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var ctx = Ctx{
        .allocator = allocator,
        .buf = &buf,
        .var_map = std.StringHashMap(usize).init(allocator),
    };
    defer ctx.var_map.deinit();

    ctx.serializeCompound(clause.head);
    ctx.put(" :- ");
    for (clause.body, 0..) |goal, i| {
        if (i > 0) ctx.put(", ");
        ctx.serializeGoal(goal);
    }
    if (clause.det.marker()) |m| {
        ctx.put(" det:");
        ctx.putByte(m);
    }

    return std.hash.Wyhash.hash(0, buf.items);
}

/// Render an id as fixed-width lowercase hex into `out` (16 bytes).
pub fn hashHex(id: u64, out: *[16]u8) []const u8 {
    const digits = "0123456789abcdef";
    var v = id;
    var i: usize = 16;
    while (i > 0) {
        i -= 1;
        out[i] = digits[@intCast(v & 0xf)];
        v >>= 4;
    }
    return out[0..16];
}

const Ctx = struct {
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    var_map: std.StringHashMap(usize),

    fn put(self: *Ctx, s: []const u8) void {
        self.buf.appendSlice(self.allocator, s) catch {};
    }

    fn putByte(self: *Ctx, b: u8) void {
        self.buf.append(self.allocator, b) catch {};
    }

    fn putUint(self: *Ctx, val: u64) void {
        var tmp: [20]u8 = undefined;
        var v = val;
        var i: usize = tmp.len;
        if (v == 0) {
            self.putByte('0');
            return;
        }
        while (v > 0) {
            i -= 1;
            tmp[i] = @intCast('0' + (v % 10));
            v /= 10;
        }
        self.put(tmp[i..]);
    }

    fn serializeGoal(self: *Ctx, goal: Goal) void {
        switch (goal) {
            .call => |c| self.serializeCompound(c),
            .not => |inner| {
                self.put("\\+ ");
                self.serializeGoal(inner.*);
            },
            .cut => self.putByte('!'),
        }
    }

    fn serializeCompound(self: *Ctx, c: Term.Compound) void {
        self.put(c.functor);
        self.putByte('(');
        for (c.args, 0..) |arg, i| {
            if (i > 0) self.putByte(',');
            self.serializeTerm(arg);
        }
        self.putByte(')');
    }

    fn serializeTerm(self: *Ctx, term: Term) void {
        switch (term) {
            .atom => |a| self.put(a),
            .variable => |name| {
                // alpha-normalization: positional index, '?' cannot
                // appear in identifiers so no collision with atoms
                const gop = self.var_map.getOrPut(name) catch return;
                if (!gop.found_existing) gop.value_ptr.* = self.var_map.count() - 1;
                self.putByte('?');
                self.putUint(gop.value_ptr.*);
            },
            .integer => |v| {
                if (v < 0) {
                    self.putByte('-');
                    self.putUint(@intCast(-v));
                } else {
                    self.putUint(@intCast(v));
                }
            },
            .nil => self.put("[]"),
            .compound => |c| self.serializeCompound(c),
            .list => |l| {
                self.putByte('[');
                self.serializeTerm(l.head.*);
                self.putByte('|');
                self.serializeTerm(l.tail.*);
                self.putByte(']');
            },
        }
    }
};
