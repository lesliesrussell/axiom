/*
 * Axiom FFI Test — proves the C library works from plain C.
 *
 * Build:
 *   cc -o ffi_test examples/ffi_test.c -Izig-out/include zig-out/lib/libaxiom.a
 *
 * Run:
 *   ./ffi_test
 */

#include <stdio.h>
#include "axiom.h"

int main(void) {
    printf("=== Axiom FFI Test ===\n\n");

    /* Create engine */
    AxiomProgram *p = axiom_new();
    if (!p) { fprintf(stderr, "Failed to create program\n"); return 1; }

    /* Load Axiom source as English */
    axiom_load_source(p,
        "Socrates is a man.\n"
        "Plato is a man.\n"
        "Aristotle is a man.\n"
        "X is mortal if X is a man.\n"
    );

    printf("Loaded %zu clauses.\n\n", axiom_clause_count(p));

    /* Yes/No query: Is Socrates mortal? */
    AxiomResult *r1 = axiom_query_english(p, "Is Socrates mortal?");
    printf("Is Socrates mortal?  %s\n",
           axiom_result_has_solutions(r1) ? "Yes." : "No.");
    axiom_result_free(r1);

    /* Who query: Who is mortal? */
    AxiomResult *r2 = axiom_query_english(p, "Who is mortal?");
    printf("Who is mortal?       %zu solutions:\n", axiom_result_count(r2));
    for (size_t i = 0; i < axiom_result_count(r2); i++) {
        const char *who = axiom_result_get_binding(r2, i, "_Who");
        if (who) printf("  _Who = %s\n", who);
    }
    axiom_result_free(r2);

    /* Programmatic query: mortal(X) */
    printf("\nProgrammatic: mortal(X)\n");
    AxiomResult *r3 = axiom_query1(p, "mortal");
    for (size_t i = 0; i < axiom_result_count(r3); i++) {
        const char *x = axiom_result_get_binding(r3, i, "X");
        if (x) printf("  X = %s\n", x);
    }
    axiom_result_free(r3);

    /* Assert a new fact and re-query */
    axiom_assert_fact1(p, "man", "hypatia");
    AxiomResult *r4 = axiom_query_ground1(p, "mortal", "hypatia");
    printf("\nAsserted man(hypatia). Is hypatia mortal? %s\n",
           axiom_result_has_solutions(r4) ? "Yes." : "No.");
    axiom_result_free(r4);

    /* Binary predicate */
    axiom_assert_fact2(p, "parent", "socrates", "plato");
    AxiomResult *r5 = axiom_query2_av(p, "parent", "socrates");
    printf("\nparent(socrates, Y): %zu solutions\n", axiom_result_count(r5));
    for (size_t i = 0; i < axiom_result_count(r5); i++) {
        const char *y = axiom_result_get_binding(r5, i, "Y");
        if (y) printf("  Y = %s\n", y);
    }
    axiom_result_free(r5);

    /* ── decisions (axiom-i01) ───────────────────────────────────── */
    {
        AxiomProgram *dp = axiom_new();
        axiom_load_source(dp,
            "Leslie is a user.\n"
            "Mallory is a user.\n"
            "Mallory is banned.\n"
            "D has outcome allow if D has subject S and D has action log_in and S is a user.\n"
            "D has outcome deny if D has subject S and S is banned.\n");

        AxiomDecision *d1 = axiom_decide(dp, "leslie", "log_in", NULL);
        if (!d1 || d1->outcome != AXIOM_DECISION_ALLOW) {
            printf("FAIL: expected ALLOW for leslie\n");
            return 1;
        }
        printf("decide(leslie, log_in): ALLOW, %zu reason(s), %zu evidence\n",
               d1->reason_count, d1->evidence_count);

        AxiomDecision *d2 = axiom_decide(dp, "mallory", "log_in", NULL);
        if (!d2 || d2->outcome != AXIOM_DECISION_DENY) {
            printf("FAIL: expected DENY for mallory (deny-overrides)\n");
            return 1;
        }
        printf("decide(mallory, log_in): DENY (deny-overrides ok)\n");

        AxiomDecision *d3 = axiom_decide(dp, "ghost", "log_in", NULL);
        if (!d3 || d3->outcome != AXIOM_DECISION_INDETERMINATE) {
            printf("FAIL: expected INDETERMINATE for ghost\n");
            return 1;
        }
        printf("decide(ghost, log_in): INDETERMINATE\n");

        /* temp scope hygiene: decide must not leak clauses */
        size_t n = axiom_clause_count(dp);
        axiom_decide(dp, "leslie", "log_in", NULL);
        if (axiom_clause_count(dp) != n) {
            printf("FAIL: decide leaked clauses\n");
            return 1;
        }
        printf("decide scope hygiene: ok\n");
        axiom_free(dp);
    }

    printf("\n=== All tests passed ===\n");

    axiom_free(p);
    return 0;
}
