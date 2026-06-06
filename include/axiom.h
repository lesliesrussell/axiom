/*
 * Axiom — Logic Programming Engine (C FFI)
 *
 * Embed the Axiom Prolog-style logic engine in any program.
 * Link against libaxiom.a (static) or libaxiom.dylib/.so (shared).
 *
 * Usage:
 *   AxiomProgram *p = axiom_new();
 *   axiom_load_source(p, "Socrates is a man.\nX is mortal if X is a man.\n");
 *   AxiomResult *r = axiom_query_english(p, "Is Socrates mortal?");
 *   if (axiom_result_has_solutions(r)) { printf("Yes!\n"); }
 *   axiom_free(p);
 */

#ifndef AXIOM_H
#define AXIOM_H

#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ─── Opaque handle types ─────────────────────────────────────────── */

typedef struct AxiomProgram AxiomProgram;
typedef struct AxiomResult  AxiomResult;

/* ─── Program lifecycle ───────────────────────────────────────────── */

/* Create a new Axiom program instance. Returns NULL on failure. */
AxiomProgram *axiom_new(void);

/* Destroy a program instance and free all memory. */
void axiom_free(AxiomProgram *program);

/* ─── Loading source ──────────────────────────────────────────────── */

/* Load Axiom source from a null-terminated string. Returns 0 on success. */
int axiom_load_source(AxiomProgram *program, const char *source);

/* Load Axiom source from a buffer with explicit length. Returns 0 on success. */
int axiom_load_source_len(AxiomProgram *program, const char *source, size_t len);

/* Load Axiom source from a file path. Returns 0 on success. */
int axiom_load_file(AxiomProgram *program, const char *path);

/* ─── Asserting facts ─────────────────────────────────────────────── */

/* Assert a unary fact: functor(arg1). Returns 0 on success. */
int axiom_assert_fact1(AxiomProgram *program, const char *functor, const char *arg1);

/* Assert a binary fact: functor(arg1, arg2). Returns 0 on success. */
int axiom_assert_fact2(AxiomProgram *program, const char *functor,
                       const char *arg1, const char *arg2);

/* ─── Querying ────────────────────────────────────────────────────── */

/* Query with one variable: functor(X). Returns result handle. */
AxiomResult *axiom_query1(AxiomProgram *program, const char *functor);

/* Yes/no query with one ground arg: functor(arg). */
AxiomResult *axiom_query_ground1(AxiomProgram *program, const char *functor,
                                 const char *arg);

/* Query: functor(arg1, Y). Binds Y. */
AxiomResult *axiom_query2_av(AxiomProgram *program, const char *functor,
                             const char *arg1);

/* Query with two variables: functor(X, Y). */
AxiomResult *axiom_query2_vv(AxiomProgram *program, const char *functor);

/* Query using Axiom English syntax, e.g. "Who is mortal?" */
AxiomResult *axiom_query_english(AxiomProgram *program, const char *query);

/* ─── Query result access ─────────────────────────────────────────── */

/* Number of solutions. */
size_t axiom_result_count(const AxiomResult *result);

/* Check if query succeeded (has at least one solution). */
bool axiom_result_has_solutions(const AxiomResult *result);

/*
 * Get variable binding as a string for solution at index.
 * var_name is "X", "Y", "_Who", etc.
 * Returns NULL if not found. String valid for lifetime of the program.
 */
const char *axiom_result_get_binding(const AxiomResult *result,
                                     size_t solution_index,
                                     const char *var_name);

/* ─── Decisions (axiom-i01) ─────────────────────────────────────────── */

typedef enum {
    AXIOM_DECISION_ALLOW = 0,
    AXIOM_DECISION_DENY = 1,
    AXIOM_DECISION_INDETERMINATE = 2,
    /* axiom-2fx: gated outcomes, appended for ABI stability */
    AXIOM_DECISION_ALLOW_WITH_REDACTION = 3,
    AXIOM_DECISION_ALLOW_WITH_SANDBOX = 4,
    AXIOM_DECISION_REQUIRE_CONFIRMATION = 5
} AxiomDecisionOutcome;

typedef struct {
    AxiomDecisionOutcome outcome;
    const char *subject;
    const char *action;
    const char *resource;        /* NULL when not provided */
    size_t reason_count;
    const char **reasons;        /* rule labels or 16-hex clause ids */
    size_t evidence_count;
    const char **evidence;       /* canonical-English ground facts */
} AxiomDecision;

/* Evaluate decision rules for (subject, action[, resource]). resource may
 * be NULL. Conflict resolution is deny-overrides: any derivable deny wins;
 * allow requires at least one allow and zero denies; neither derivable
 * yields INDETERMINATE. The decision and all strings are owned by the
 * program's arena: valid until axiom_free, do not free individually. */
AxiomDecision *axiom_decide(AxiomProgram *program, const char *subject,
                            const char *action, const char *resource);

/* ─── Allowed alternatives (axiom-02w) ──────────────────────────────── */

/* Actions from the KB's action/1 universe that decide() allows for this
 * subject (resource may be NULL). Returns an array of strings owned by
 * the program's arena (valid until axiom_free); count via out_count.
 * Returns NULL when the count is zero. */
const char **axiom_allowed_actions(AxiomProgram *program, const char *subject,
                                   const char *resource, size_t *out_count);

/* ─── Semantic diff + what-if (axiom-aof) ───────────────────────────── */

typedef enum {
    AXIOM_DIFF_ADDED = 0,
    AXIOM_DIFF_REMOVED = 1,
    AXIOM_DIFF_MODIFIED = 2
} AxiomDiffKind;

typedef struct {
    AxiomDiffKind kind;
    const char *predicate;   /* "name/arity" of the head */
    const char *rule_id;     /* '% id:' label, or 16-hex clause id */
    const char *old_english; /* NULL for added */
    const char *new_english; /* NULL for removed */
} AxiomRuleDiff;

/* Clause-level semantic diff (alpha-normalized: variable renaming is not
 * a change). Result owned by NEWP's arena — valid until axiom_free(newp). */
AxiomRuleDiff *axiom_diff_programs(AxiomProgram *oldp, AxiomProgram *newp,
                                   size_t *out_count);

typedef struct {
    const char *subject;
    const char *action;
    const char *resource;    /* NULL when not applicable */
} AxiomDecisionInput;

typedef struct {
    AxiomDecisionInput input;
    AxiomDecision *old_decision;
    AxiomDecision *new_decision;
} AxiomDecisionDelta;

/* Run each input against both programs; return inputs whose outcome
 * differs. Result owned by NEWP's arena — valid until axiom_free(newp). */
AxiomDecisionDelta *axiom_compare_decisions(AxiomProgram *oldp, AxiomProgram *newp,
                                            const AxiomDecisionInput *inputs,
                                            size_t input_count, size_t *out_count);

/* Free a query result. Must be called for every result from axiom_query_*. */
void axiom_result_free(AxiomResult *result);

/* ─── Utility ─────────────────────────────────────────────────────── */

/* Number of clauses loaded. */
size_t axiom_clause_count(const AxiomProgram *program);

/* Enable or disable trace output. */
void axiom_set_trace(AxiomProgram *program, bool enabled);

#ifdef __cplusplus
}
#endif

#endif /* AXIOM_H */
