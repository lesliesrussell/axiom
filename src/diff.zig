// axiom-aof
// Semantic clause-level diff between two programs. Works on F1's
// alpha-normalized hashes, so variable renaming and phrasing variants
// (which canonicalize identically) never appear as changes. A removed
// and an added clause sharing a non-empty '% id:' label pair up as
// MODIFIED — the label names the rule across edits.
const std = @import("std");
const types = @import("types.zig");
const Clause = types.Clause;

pub const DiffKind = enum { added, removed, modified };

pub const RuleDiff = struct {
    kind: DiffKind,
    old_clause: ?Clause, // null for added
    new_clause: ?Clause, // null for removed
};

pub fn diffPrograms(allocator: std.mem.Allocator, old: []const Clause, new: []const Clause) ![]RuleDiff {
    // multiset of hashes per side
    var old_counts = std.AutoHashMap(u64, usize).init(allocator);
    defer old_counts.deinit();
    var new_counts = std.AutoHashMap(u64, usize).init(allocator);
    defer new_counts.deinit();

    for (old) |c| {
        const gop = try old_counts.getOrPut(c.id);
        gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
    }
    for (new) |c| {
        const gop = try new_counts.getOrPut(c.id);
        gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
    }

    // surplus clauses on each side, in stable program order
    var removed: std.ArrayList(Clause) = .empty;
    defer removed.deinit(allocator);
    var added: std.ArrayList(Clause) = .empty;
    defer added.deinit(allocator);

    var old_seen = std.AutoHashMap(u64, usize).init(allocator);
    defer old_seen.deinit();
    for (old) |c| {
        const gop = try old_seen.getOrPut(c.id);
        gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
        const in_new = new_counts.get(c.id) orelse 0;
        if (gop.value_ptr.* > in_new) try removed.append(allocator, c);
    }
    var new_seen = std.AutoHashMap(u64, usize).init(allocator);
    defer new_seen.deinit();
    for (new) |c| {
        const gop = try new_seen.getOrPut(c.id);
        gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
        const in_old = old_counts.get(c.id) orelse 0;
        if (gop.value_ptr.* > in_old) try added.append(allocator, c);
    }

    // pair by label -> modified
    var diffs: std.ArrayList(RuleDiff) = .empty;
    const added_used = try allocator.alloc(bool, added.items.len);
    @memset(added_used, false);

    for (removed.items) |oc| {
        var paired = false;
        if (oc.label.len > 0) {
            for (added.items, 0..) |nc, i| {
                if (!added_used[i] and std.mem.eql(u8, nc.label, oc.label)) {
                    try diffs.append(allocator, .{ .kind = .modified, .old_clause = oc, .new_clause = nc });
                    added_used[i] = true;
                    paired = true;
                    break;
                }
            }
        }
        if (!paired) {
            try diffs.append(allocator, .{ .kind = .removed, .old_clause = oc, .new_clause = null });
        }
    }
    for (added.items, 0..) |nc, i| {
        if (!added_used[i]) {
            try diffs.append(allocator, .{ .kind = .added, .old_clause = null, .new_clause = nc });
        }
    }

    return diffs.toOwnedSlice(allocator);
}
