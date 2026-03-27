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

    printf("\n=== All tests passed ===\n");

    axiom_free(p);
    return 0;
}
