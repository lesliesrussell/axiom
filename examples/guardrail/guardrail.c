/* axiom-02w
 * Agent guardrail demo: a (fake) LLM agent proposes a plan; the host
 * gates every step through axiom_decide before acting. Denied steps are
 * rendered back as explanation + allowed alternatives — the text an
 * orchestrator would feed to the model for replanning.
 *
 * Self-checking: exits nonzero on any unexpected outcome.
 *
 * Build:
 *   cc guardrail.c -I../../zig-out/include ../../zig-out/lib/libaxiom.a -o guardrail
 */
#include <stdio.h>
#include <string.h>
#include "axiom.h"

typedef struct {
    const char *subject;
    const char *action;
} PlanStep;

/* The guardrail contract: act only on ALLOW; DENY and INDETERMINATE both
 * block (an unmodeled action is not an allowed action). */
static int check(AxiomProgram *p, const char *subject, const char *action,
                 AxiomDecision **out) {
    AxiomDecision *d = axiom_decide(p, subject, action, NULL);
    *out = d;
    return d && d->outcome == AXIOM_DECISION_ALLOW;
}

/* Render the denial as LLM-feedback text. */
static void explain_denial(AxiomProgram *p, const char *subject,
                           const char *action, const AxiomDecision *d) {
    printf("  Your proposed action \"%s\" for %s is %s because:\n", action,
           subject,
           d->outcome == AXIOM_DECISION_DENY ? "denied" : "not permitted");
    for (size_t i = 0; i < d->reason_count; i++)
        printf("    - rule: %s\n", d->reasons[i]);
    for (size_t i = 0; i < d->evidence_count; i++)
        printf("    - because: %s\n", d->evidence[i]);

    size_t n_alt = 0;
    const char **alts = axiom_allowed_actions(p, subject, NULL, &n_alt);
    printf("  Allowed alternatives for %s:\n", subject);
    if (n_alt == 0) {
        printf("    (none)\n");
    } else {
        for (size_t i = 0; i < n_alt; i++)
            printf("    - %s\n", alts[i]);
    }
}

int main(void) {
    AxiomProgram *p = axiom_new();
    if (axiom_load_file(p, "policy.axm") != 0 &&
        axiom_load_file(p, "examples/guardrail/policy.axm") != 0) {
        fprintf(stderr, "could not load policy.axm\n");
        return 1;
    }

    /* the "LLM" proposes a plan: read logs, then delete the database */
    PlanStep plan[2] = {
        { "leslie", "read_logs" },
        { "leslie", "delete_database" },
    };

    printf("=== Plan validation (per-step gate) ===\n");
    int denied_step = -1;
    for (int i = 0; i < 2; i++) {
        AxiomDecision *d = NULL;
        if (check(p, plan[i].subject, plan[i].action, &d)) {
            printf("step %d: %s %s -> ALLOW, executing\n", i + 1,
                   plan[i].subject, plan[i].action);
        } else {
            printf("step %d: %s %s -> BLOCKED\n", i + 1, plan[i].subject,
                   plan[i].action);
            explain_denial(p, plan[i].subject, plan[i].action, d);
            denied_step = i;
            break;
        }
    }

    /* self-checks */
    if (denied_step != 1) {
        fprintf(stderr, "FAIL: expected step 2 to be blocked\n");
        return 1;
    }

    /* the "LLM" revises the plan to an allowed alternative */
    printf("\n=== Revised plan ===\n");
    AxiomDecision *d = NULL;
    if (!check(p, "leslie", "restart_service", &d)) {
        fprintf(stderr, "FAIL: expected restart_service to be allowed\n");
        return 1;
    }
    printf("revised: leslie restart_service -> ALLOW, executing\n");

    /* contractor gets nothing */
    size_t n = 0;
    axiom_allowed_actions(p, "rae", NULL, &n);
    if (n != 0) {
        fprintf(stderr, "FAIL: contractor should have no allowed actions\n");
        return 1;
    }

    printf("\n=== guardrail demo passed ===\n");
    axiom_free(p);
    return 0;
}
