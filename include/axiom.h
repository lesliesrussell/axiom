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
