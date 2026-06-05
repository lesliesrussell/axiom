# Clause identity — design (F1)

**Date:** 2026-06-05 · **Bead:** axiom-ekd · **Status:** approved
(foundation for decisions `axiom-i01` and diff/what-if `axiom-aof`)

## Goal

Every clause gets a **stable identity**: an alpha-normalized 64-bit hash,
plus an optional human label. Decisions use it for `reason_id`; semantic
diff uses it for ADDED/REMOVED/MODIFIED.

## Hash (`src/identity.zig`, engine module)

`clauseHash(allocator, clause) u64`:

1. **Alpha-normalize**: variables renamed positionally (`?0`, `?1`, …) in
   order of first appearance across head then body — `renameClause`
   suffixes (`X_47`) and author naming choices must not affect identity.
   `X is mortal if X is a man.` ≡ `Y is mortal if Y is a man.`
   The `?` prefix cannot collide with identifiers.
2. **Serialize deterministically**: head `functor(args)`, ` :- `, body
   goals comma-joined; `\+` prefix for negation, `!` for cut; atoms and
   functors verbatim, integers in decimal, lists as `[h|t]` recursion;
   det marker appended (det is part of the clause's meaning).
3. **Hash**: `std.hash.Wyhash.hash(0, bytes)`. Stability caveat
   (documented): stable across runs; pinned to the Wyhash implementation,
   so a Zig stdlib change could shift hashes — acceptable for diffing
   programs built by the same binary, revisit if hashes are persisted.

`Clause` gains `id: u64 = 0` and `label: []const u8 = ""`. `addClause`
computes the hash (after source-text duping) so every stored clause
carries it — lib/capi callers included.

## Labels

A comment line `% id: <label>` immediately above a statement names it:

```
% id: login_rule_1
X can log_in if X is a user and X is not banned.
```

The lexer skips comments, so capture happens in the loader: from the
statement span's start offset, walk back over blank space to the previous
line; if it matches `% id: <label>`, attach the trimmed label to the
clause. Main-loader only for v1 (REPL lines and lib/capi get hash-only).

## Surface

- `:show ids` — full listing with an 16-hex-digit id column and labels:
  `a1b2c3… (login_rule_1)  1: can_log_in(X) :- …`
- Existing `:show`/`:show facts`/`:show rules` output unchanged (piped
  regression suite depends on it).
- `:help` updated.

## Testing

1. Alpha-equivalence: same rule under different variable names → same id.
2. Distinct rules → distinct ids; same fact loaded twice → same id.
3. `% id:` label captured from file and displayed by `:show ids`;
   unlabeled clauses show hash only.
4. Regression: piped battery byte-identical (no default-output change),
   examples sweep, PTY suite, C FFI suite.
