/* Escaped identifiers through vpi_handle_by_name: every object of
 * escaped.v, whose names hold `[`, `]`, `.`, `(` and `)` (IEEE 1364-2005
 * §3.7.1), is looked up again by the vpiFullName VerA gives it. Oracle: the
 * round trip is the identity, `vpi_handle_by_name(vpi_get_str(vpiFullName,
 * obj), NULL)` compares equal to obj (§27.18, §27.6); each object's vpiName
 * is the identifier escaped.v declares, without its backslash and space
 * (§3.7.1: neither is part of the identifier); and the walk reaches the 32
 * objects escaped.v's header counts by hand. A name that resolves to nothing
 * or to another object, or a vpiName escaped.v does not declare, is BAD; so is
 * a crash, which kills the run.
 *
 * Known failures are `known[]` below, each with its reason: a known full name
 * that misbehaves is XFAIL, one that behaves is an XPASS and fails the run
 * until its line goes, and so does a known line that names no object. */
#include "vpi_user.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define OBJECTS 32 /* escaped.v's header */

#define PORT_NET "vpi_handle_by_name of a port net's vpiFullName returns its vpiPort (type 44), which has the same full name; also on plain names. Open: tests/conformance structure.c and object_traversal.c expect the port by that name (vpiType vpiPort, vpiDirection), so the fix waits on which the suite holds"
static const char *const known[][2] = {
    {"vpi_escaped.m(0).u[1].\\in.a ", PORT_NET},
    {"vpi_escaped.m(0).u[1].out(b)", PORT_NET},
    {"vpi_escaped.m(0).\\u[1].v .\\in.a ", PORT_NET},
    {"vpi_escaped.m(0).\\u[1].v .out(b)", PORT_NET},
    {"vpi_escaped.\\m.1 .u[1].\\in.a ", PORT_NET},
    {"vpi_escaped.\\m.1 .u[1].out(b)", PORT_NET},
    {"vpi_escaped.\\m.1 .\\u[1].v .\\in.a ", PORT_NET},
    {"vpi_escaped.\\m.1 .\\u[1].v .out(b)", PORT_NET},
    {NULL, NULL},
};

/* Every identifier escaped.v declares, as §3.7.1 reads it. */
static const char *const declared[] = {
    "vpi_escaped", "top[0]", "m(0)", "m.1", "a[2]", "b)", "u[1]", "u[1].v", "in.a", "out(b)", "w[1]", "r]x", "n[3]",
};

static int bad, objects, xfails;
static int seen[sizeof known / sizeof known[0]];

static const char *knownReason(const char *full) {
    size_t i;
    for (i = 0; known[i][0] != NULL; i++)
        if (strcmp(known[i][0], full) == 0) return seen[i] = 1, known[i][1];
    return NULL;
}

static void check(vpiHandle obj) {
    char full[1024];
    const char *got = vpi_get_str(vpiFullName, obj);
    const char *why = NULL;
    const char *reason;
    vpiHandle back;
    objects++;
    if (got == NULL || strlen(got) >= sizeof full) {
        printf("BAD object %d: no vpiFullName\n", objects);
        bad = 1;
        return;
    }
    strcpy(full, got);
    back = vpi_handle_by_name(full, NULL);
    if (back == NULL) why = "names nothing";
    else if (!vpi_compare_objects(back, obj)) why = "names another object";
    else {
        const char *name = vpi_get_str(vpiName, obj);
        size_t i;
        for (i = 0; name && i < sizeof declared / sizeof declared[0] && strcmp(declared[i], name) != 0; i++) {}
        if (name == NULL || i == sizeof declared / sizeof declared[0]) why = "its vpiName is not an identifier escaped.v declares";
    }
    reason = knownReason(full);
    if (reason && why) xfails++, printf("XFAIL %s: %s (%s)\n", full, why, reason);
    else if (reason) bad = 1, printf("BAD %s: XPASS, delete its known[] line\n", full);
    else if (why) {
        bad = 1;
        printf("BAD %s (type %d): %s", full, (int)vpi_get(vpiType, obj), why);
        if (back) printf(", type %d `%s`", (int)vpi_get(vpiType, back), vpi_get_str(vpiFullName, back));
        printf(" (vpiName `%s`)", vpi_get_str(vpiName, obj));
        printf("\n");
    }
}

/* Bound: escaped.v nests three modules deep. */
static void walk(vpiHandle mod, int depth) {
    static const PLI_INT32 kinds[] = {vpiNet, vpiReg, vpiParameter, vpiModule};
    size_t k;
    if (depth > 8) {
        printf("BAD walk: deeper than escaped.v\n");
        bad = 1;
        return;
    }
    check(mod);
    for (k = 0; k < sizeof kinds / sizeof kinds[0]; k++) {
        vpiHandle it = vpi_iterate(kinds[k], mod), h;
        if (it == NULL) continue;
        while ((h = vpi_scan(it)) != NULL) {
            if (kinds[k] == vpiModule) walk(h, depth + 1);
            else check(h);
        }
    }
}

static PLI_INT32 start(p_cb_data d) {
    vpiHandle it = vpi_iterate(vpiModule, NULL), top;
    size_t i;
    (void)d;
    if (it == NULL) {
        printf("BAD: no top module\n");
        exit(1);
    }
    while ((top = vpi_scan(it)) != NULL) walk(top, 0);
    for (i = 0; known[i][0] != NULL; i++)
        if (!seen[i]) bad = 1, printf("BAD %s: known[] names no object\n", known[i][0]);
    if (objects != OBJECTS) bad = 1, printf("BAD walk: %d objects, escaped.v has %d\n", objects, OBJECTS);
    if (bad) exit(1);
    printf("vpi-escaped=ok objects=%d xfail=%d\n", objects, xfails);
    return 0;
}

static void startup(void) {
    s_cb_data d = {cbStartOfSimulation, start, NULL, NULL, NULL, 0, NULL};
    if (!vpi_register_cb(&d)) exit(1);
}
void (*vlog_startup_routines[])(void) = {startup, NULL};
