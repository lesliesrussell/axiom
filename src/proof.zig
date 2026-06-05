// axiom-s0w / axiom-9nz
// Proof tree representation and printing. Trees are built by the witness
// re-prover in explain.zig; this file only defines the node shape and the
// recursive printer. Part of the engine module.
const std = @import("std");
const types = @import("types.zig");
const Term = types.Term;
const Substitution = @import("substitution.zig").Substitution;
const output = @import("output.zig");
const writeRaw = output.writeRaw;
const writeTermTo = output.writeTermTo;

pub const ProofNode = struct {
    goal: Term.Compound,
    kind: Kind,
    children: []const ProofNode,

    pub const Kind = enum {
        fact, // matched a body-less clause
        rule, // matched a clause; children are the body's sub-proofs
        builtin, // satisfied by a built-in predicate
        negation, // goal shown was confirmed unprovable (\+)
        truncated, // proof exceeded the depth cap
        unproven, // no proof found (e.g. KB changed since the query)
    };
};

pub fn printTree(node: *const ProofNode, subst: *const Substitution, allocator: std.mem.Allocator, indent: usize) void {
    var spaces: [64]u8 = undefined;
    const n = @min(indent * 2, 64);
    @memset(spaces[0..n], ' ');
    writeRaw(spaces[0..n]);

    writeRaw("- ");
    if (node.kind == .negation) writeRaw("\\+ ");

    writeRaw(node.goal.functor);
    writeRaw("(");
    for (node.goal.args, 0..) |arg, i| {
        if (i > 0) writeRaw(", ");
        const walked = subst.deepWalk(arg, allocator) catch arg;
        writeTermTo(walked);
    }
    writeRaw(")");

    output.style(.dim); // axiom-wk4
    switch (node.kind) {
        .fact => writeRaw("  [fact]"),
        .rule => writeRaw("  [rule]"),
        .builtin => writeRaw("  [built-in]"),
        .negation => writeRaw("  [negation]"),
        .truncated => writeRaw("  [...]"),
        .unproven => writeRaw("  [unproven?]"),
    }
    output.style(.reset);
    writeRaw("\n");

    for (node.children) |*child| {
        printTree(child, subst, allocator, indent + 1);
    }
}
