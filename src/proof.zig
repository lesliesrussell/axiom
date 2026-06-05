// axiom-s0w
// Proof tree representation and explanation printing. Split out of
// engine.zig; part of the engine module.
const std = @import("std");
const types = @import("types.zig");
const Term = types.Term;
const Clause = types.Clause;
const Substitution = @import("substitution.zig").Substitution;
const output = @import("output.zig");
const writeRaw = output.writeRaw;
const writeTermTo = output.writeTermTo;

pub const ProofNode = struct {
    goal: Term.Compound,
    clause_used: ?Clause, // null for built-ins / facts
    is_fact: bool,
    is_builtin: bool,
    children: []const ProofNode,
};

pub fn explainProof(proof: ?ProofNode, subst: *const Substitution, allocator: std.mem.Allocator) void {
    const p = proof orelse {
        writeRaw("No proof available. Run a query first.\n");
        return;
    };
    writeRaw("\nBecause:\n");
    printProofNode(&p, subst, allocator, 1);
}

fn printProofNode(node: *const ProofNode, subst: *const Substitution, allocator: std.mem.Allocator, indent: usize) void {
    // Print indent
    var spaces: [64]u8 = undefined;
    const n = @min(indent * 2, 64);
    @memset(spaces[0..n], ' ');
    writeRaw(spaces[0..n]);

    writeRaw("- ");

    // Print the resolved goal
    writeRaw(node.goal.functor);
    writeRaw("(");
    for (node.goal.args, 0..) |arg, i| {
        if (i > 0) writeRaw(", ");
        const walked = subst.deepWalk(arg, allocator) catch arg;
        writeTermTo(walked);
    }
    writeRaw(")");

    if (node.is_builtin) {
        writeRaw("  [built-in]\n");
    } else if (node.is_fact) {
        writeRaw("  [fact]\n");
    } else {
        writeRaw("  [rule]\n");
        // Show clause body as sub-proof
        if (node.clause_used) |clause| {
            for (clause.body) |body_goal| {
                switch (body_goal) {
                    .call => |c| {
                        const child = ProofNode{
                            .goal = c,
                            .clause_used = null,
                            .is_fact = true,
                            .is_builtin = false,
                            .children = &.{},
                        };
                        printProofNode(&child, subst, allocator, indent + 1);
                    },
                    .not => |inner| {
                        switch (inner.*) {
                            .call => |c| {
                                writeRaw(spaces[0..n]);
                                writeRaw("    \\+ ");
                                var nbuf: [256]u8 = undefined;
                                const nt = std.fmt.bufPrint(&nbuf, "{s}(...)", .{c.functor}) catch "?";
                                writeRaw(nt);
                                writeRaw("  [negation succeeded]\n");
                            },
                            else => {},
                        }
                    },
                    .cut => {},
                }
            }
        }
    }
}
