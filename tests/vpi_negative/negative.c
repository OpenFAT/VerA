/* The negative-input table: every vpi_* entry point VerA exports, handed each
 * invalid argument it takes (a NULL handle, a forged handle, a handle of the
 * wrong type, a NULL value or info pointer, a bad format, type, property or
 * flag, an out-of-range index). Oracle: IEEE 1364-2005 §27.4 vpi_chk_error()
 * ("determine if the previous call resulted in an error") together with each
 * routine's documented failure return (NULL, 0, FALSE, vpiUndefined, EOF, or
 * the mcd that failed). A row is ok when the call returned that value and
 * vpi_chk_error() then reports a level; anything else, a crash included, is
 * BAD. Each row runs in its own child process (POSIX), so a crash names its
 * row and a call's side effects stay in it.
 *
 * Known failures are `known[]` below, each with its reason: a known row that
 * misbehaves is XFAIL, one that behaves is an XPASS and fails the run until
 * its line goes. */
#define _POSIX_C_SOURCE 200809L
#include "vpi_user.h"
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#if !defined(_WIN32)
#include <sys/wait.h>
#include <unistd.h>
#endif

/* The fixtures, made once at start of simulation, before any row runs. */
static vpiHandle mod, reg, mem, word, itr, cb, systf;
static char forged_obj[64]; /* an address VerA never issued */
#define FORGED ((vpiHandle)forged_obj)
#define UNOPENED_MCD 0x40000000u /* a channel bit no vpi_mcd_open returned */
#define BAD 99999                /* no format, type, property, flag or reason */

static PLI_INT32 nop_cb(p_cb_data d) { (void)d; return 0; }
static PLI_INT32 nop_tf(PLI_BYTE8 *u) { (void)u; return 0; }
static PLI_INT32 nop_atf(p_cb_data d) { (void)d; return 0; }

static int vprintf_null(void (*unused)(void), ...) {
    va_list ap;
    int r;
    va_start(ap, unused);
    r = vpi_vprintf(NULL, ap);
    va_end(ap);
    return r;
}
static int mcd_vprintf(PLI_UINT32 mcd, char *fmt, ...) {
    va_list ap;
    int r;
    va_start(ap, fmt);
    r = vpi_mcd_vprintf(mcd, fmt, ap);
    va_end(ap);
    return r;
}

/* Each row returns nonzero when the call returned its failure value. A void
 * routine has none; the error status alone judges it. */
#define ROW(fn, expr) static int fn(void) { return (expr); }
#define VOID_ROW(fn, stmt) static int fn(void) { stmt; return 1; }

ROW(handle_bad_type, vpi_handle(BAD, mod) == NULL)
ROW(handle_forged, vpi_handle(vpiModule, FORGED) == NULL)
ROW(handle_wrong_type, vpi_handle(vpiModule, itr) == NULL)
ROW(by_name_null_name, vpi_handle_by_name(NULL, NULL) == NULL)
ROW(by_name_forged_scope, vpi_handle_by_name("r", FORGED) == NULL)
ROW(by_name_wrong_type_scope, vpi_handle_by_name("r", itr) == NULL)
ROW(by_index_null, vpi_handle_by_index(NULL, 0) == NULL)
ROW(by_index_forged, vpi_handle_by_index(FORGED, 0) == NULL)
ROW(by_index_wrong_type, vpi_handle_by_index(itr, 0) == NULL)
ROW(by_index_above, vpi_handle_by_index(mem, 99) == NULL)
ROW(by_index_negative, vpi_handle_by_index(mem, -1) == NULL)
ROW(by_index_bit_above, vpi_handle_by_index(reg, 8) == NULL)
static int multi_index_above(void) { PLI_INT32 i[1] = {99}; return vpi_handle_by_multi_index(mem, 1, i) == NULL; }
static int multi_index_count(void) { PLI_INT32 i[1] = {0}; return vpi_handle_by_multi_index(mem, 0, i) == NULL; }
ROW(multi_index_null_array, vpi_handle_by_multi_index(mem, 1, NULL) == NULL)
ROW(multi_index_null, vpi_handle_by_multi_index(NULL, 1, NULL) == NULL)
ROW(handle_multi_null, vpi_handle_multi(vpiInterModPath, NULL, NULL) == NULL)
ROW(handle_multi_forged, vpi_handle_multi(vpiInterModPath, FORGED, FORGED) == NULL)
ROW(handle_multi_bad_type, vpi_handle_multi(BAD, reg, reg) == NULL)
ROW(iterate_bad_type, vpi_iterate(BAD, mod) == NULL)
ROW(iterate_forged, vpi_iterate(vpiReg, FORGED) == NULL)
ROW(iterate_wrong_type, vpi_iterate(vpiReg, itr) == NULL)
ROW(scan_null, vpi_scan(NULL) == NULL)
ROW(scan_forged, vpi_scan(FORGED) == NULL)
ROW(scan_wrong_type, vpi_scan(mod) == NULL)
ROW(get_null, vpi_get(vpiSize, NULL) == vpiUndefined)
ROW(get_forged, vpi_get(vpiSize, FORGED) == vpiUndefined)
ROW(get_bad_prop, vpi_get(BAD, reg) == vpiUndefined)
ROW(get_real_forged, vpi_get_real(vpiSize, FORGED) == (double)vpiUndefined)
ROW(get_real_bad_prop, vpi_get_real(BAD, reg) == (double)vpiUndefined)
ROW(get_str_null, vpi_get_str(vpiName, NULL) == NULL)
ROW(get_str_forged, vpi_get_str(vpiName, FORGED) == NULL)
ROW(get_str_bad_prop, vpi_get_str(BAD, reg) == NULL)
ROW(compare_null, vpi_compare_objects(NULL, reg) == 0)
ROW(compare_forged, vpi_compare_objects(FORGED, FORGED) == 0)
ROW(free_null, vpi_free_object(NULL) == 0)
ROW(free_forged, vpi_free_object(FORGED) == 0)
ROW(release_null, vpi_release_handle(NULL) == 0)
ROW(release_forged, vpi_release_handle(FORGED) == 0)
ROW(vlog_info_null, vpi_get_vlog_info(NULL) == 0)
static int get_value_null(void) { s_vpi_value v = {vpiIntVal, {0}}; vpi_get_value(NULL, &v); return 1; }
static int get_value_forged(void) { s_vpi_value v = {vpiIntVal, {0}}; vpi_get_value(FORGED, &v); return 1; }
static int get_value_wrong_type(void) { s_vpi_value v = {vpiIntVal, {0}}; vpi_get_value(itr, &v); return 1; }
VOID_ROW(get_value_null_value, vpi_get_value(reg, NULL))
static int get_value_bad_format(void) { s_vpi_value v = {BAD, {0}}; vpi_get_value(reg, &v); return 1; }
static int put_value_null(void) { s_vpi_value v = {vpiIntVal, {0}}; return vpi_put_value(NULL, &v, NULL, vpiNoDelay) == NULL; }
static int put_value_forged(void) { s_vpi_value v = {vpiIntVal, {0}}; return vpi_put_value(FORGED, &v, NULL, vpiNoDelay) == NULL; }
static int put_value_wrong_type(void) { s_vpi_value v = {vpiIntVal, {0}}; return vpi_put_value(mod, &v, NULL, vpiNoDelay) == NULL; }
ROW(put_value_null_value, vpi_put_value(reg, NULL, NULL, vpiNoDelay) == NULL)
static int put_value_bad_format(void) { s_vpi_value v = {BAD, {0}}; return vpi_put_value(reg, &v, NULL, vpiNoDelay) == NULL; }
static int put_value_bad_flag(void) { s_vpi_value v = {vpiIntVal, {0}}; return vpi_put_value(reg, &v, NULL, BAD) == NULL; }
static int put_value_null_time(void) { s_vpi_value v = {vpiIntVal, {0}}; return vpi_put_value(reg, &v, NULL, vpiInertialDelay) == NULL; }
static int get_time_forged(void) { s_vpi_time t = {vpiSimTime, 0, 0, 0}; vpi_get_time(FORGED, &t); return 1; }
VOID_ROW(get_time_null_time, vpi_get_time(NULL, NULL))
static int get_time_bad_type(void) { s_vpi_time t = {BAD, 0, 0, 0}; vpi_get_time(NULL, &t); return 1; }
static int get_delays_null(void) { s_vpi_time da[3]; s_vpi_delay d = {da, 1, vpiSimTime, 0, 0, 0}; vpi_get_delays(NULL, &d); return 1; }
static int get_delays_wrong_type(void) { s_vpi_time da[3]; s_vpi_delay d = {da, 1, vpiSimTime, 0, 0, 0}; vpi_get_delays(itr, &d); return 1; }
VOID_ROW(get_delays_null_delay, vpi_get_delays(mod, NULL))
static int put_delays_null(void) { s_vpi_time da[3]; s_vpi_delay d = {da, 1, vpiSimTime, 0, 0, 0}; vpi_put_delays(NULL, &d); return 1; }
static int put_delays_forged(void) { s_vpi_time da[3]; s_vpi_delay d = {da, 1, vpiSimTime, 0, 0, 0}; vpi_put_delays(FORGED, &d); return 1; }
VOID_ROW(put_delays_null_delay, vpi_put_delays(mod, NULL))
ROW(register_systf_null, vpi_register_systf(NULL) == NULL)
static int register_systf_no_dollar(void) { s_vpi_systf_data d = {vpiSysTask, 0, "nodollar", nop_tf, NULL, NULL, NULL}; return vpi_register_systf(&d) == NULL; }
static int register_systf_null_name(void) { s_vpi_systf_data d = {vpiSysTask, 0, NULL, nop_tf, NULL, NULL, NULL}; return vpi_register_systf(&d) == NULL; }
static int register_systf_bad_type(void) { s_vpi_systf_data d = {BAD, 0, "$neg_bad_type", nop_tf, NULL, NULL, NULL}; return vpi_register_systf(&d) == NULL; }
ROW(register_analog_systf_null, vpi_register_analog_systf(NULL) == NULL)
static int register_analog_systf_no_dollar(void) { s_vpi_analog_systf_data d = {vpiAnalogSysTask, 0, "nodollar", nop_atf, NULL, NULL, NULL, NULL}; return vpi_register_analog_systf(&d) == NULL; }
static int register_analog_systf_bad_type(void) { s_vpi_analog_systf_data d = {BAD, 0, "$neg_abad", nop_atf, NULL, NULL, NULL, NULL}; return vpi_register_analog_systf(&d) == NULL; }
static int systf_info_null(void) { s_vpi_systf_data d; vpi_get_systf_info(NULL, &d); return 1; }
static int systf_info_wrong_type(void) { s_vpi_systf_data d; vpi_get_systf_info(mod, &d); return 1; }
VOID_ROW(systf_info_null_data, vpi_get_systf_info(systf, NULL))
static int analog_systf_info_forged(void) { s_vpi_analog_systf_data d; vpi_get_analog_systf_info(FORGED, &d); return 1; }
VOID_ROW(analog_systf_info_null_data, vpi_get_analog_systf_info(systf, NULL))
ROW(put_userdata_null, vpi_put_userdata(NULL, forged_obj) == 0)
ROW(put_userdata_wrong_type, vpi_put_userdata(mod, forged_obj) == 0)
ROW(get_userdata_forged, vpi_get_userdata(FORGED) == NULL)
ROW(get_userdata_wrong_type, vpi_get_userdata(mod) == NULL)
ROW(register_cb_null, vpi_register_cb(NULL) == NULL)
static int register_cb_bad_reason(void) { s_cb_data d = {BAD, nop_cb, NULL, NULL, NULL, 0, NULL}; return vpi_register_cb(&d) == NULL; }
static int register_cb_null_routine(void) { s_cb_data d = {cbEndOfSimulation, NULL, NULL, NULL, NULL, 0, NULL}; return vpi_register_cb(&d) == NULL; }
static int register_cb_forged_obj(void) { s_cb_data d = {cbValueChange, nop_cb, FORGED, NULL, NULL, 0, NULL}; return vpi_register_cb(&d) == NULL; }
ROW(remove_cb_null, vpi_remove_cb(NULL) == 0)
ROW(remove_cb_forged, vpi_remove_cb(FORGED) == 0)
ROW(remove_cb_wrong_type, vpi_remove_cb(mod) == 0)
static int cb_info_wrong_type(void) { s_cb_data d; vpi_get_cb_info(mod, &d); return 1; }
VOID_ROW(cb_info_null_data, vpi_get_cb_info(cb, NULL))
static int get_data_bad_id(void) { char b[4]; return vpi_get_data(BAD, b, 4) == 0; }
static int put_data_bad_id(void) { char b[4] = {0}; return vpi_put_data(BAD, b, 4) == 0; }
static int analog_value_forged(void) { s_vpi_analog_value v = {vpiRealVal, {0}, {0}}; vpi_get_analog_value(FORGED, &v); return 1; }
static int analog_value_wrong_type(void) { s_vpi_analog_value v = {vpiRealVal, {0}, {0}}; vpi_get_analog_value(reg, &v); return 1; }
VOID_ROW(analog_value_null_value, vpi_get_analog_value(reg, NULL))
ROW(mcd_open_null, vpi_mcd_open(NULL) == 0)
ROW(mcd_close_unopened, vpi_mcd_close(UNOPENED_MCD) == UNOPENED_MCD)
ROW(mcd_name_unopened, vpi_mcd_name(UNOPENED_MCD) == NULL)
ROW(mcd_flush_unopened, vpi_mcd_flush(UNOPENED_MCD) != 0)
ROW(mcd_printf_unopened, vpi_mcd_printf(UNOPENED_MCD, "x") == EOF)
ROW(mcd_printf_null_format, vpi_mcd_printf(1, NULL) == EOF)
ROW(printf_null_format, vpi_printf(NULL) == EOF)
ROW(vprintf_null_format, vprintf_null(NULL) == EOF)
ROW(mcd_vprintf_unopened, mcd_vprintf(UNOPENED_MCD, "x") == EOF)
ROW(control_bad_op, vpi_control(BAD) == 0)
ROW(sim_control_bad_op, vpi_sim_control(BAD) == 0)

struct row { const char *name; int (*fn)(void); };
#define R(entry, fn) {entry "/" #fn, fn}
static const struct row rows[] = {
    R("vpi_handle", handle_bad_type), R("vpi_handle", handle_forged), R("vpi_handle", handle_wrong_type),
    R("vpi_handle_by_name", by_name_null_name), R("vpi_handle_by_name", by_name_forged_scope),
    R("vpi_handle_by_name", by_name_wrong_type_scope),
    R("vpi_handle_by_index", by_index_null), R("vpi_handle_by_index", by_index_forged),
    R("vpi_handle_by_index", by_index_wrong_type), R("vpi_handle_by_index", by_index_above),
    R("vpi_handle_by_index", by_index_negative), R("vpi_handle_by_index", by_index_bit_above),
    R("vpi_handle_by_multi_index", multi_index_above), R("vpi_handle_by_multi_index", multi_index_count),
    R("vpi_handle_by_multi_index", multi_index_null_array), R("vpi_handle_by_multi_index", multi_index_null),
    R("vpi_handle_multi", handle_multi_null), R("vpi_handle_multi", handle_multi_forged),
    R("vpi_handle_multi", handle_multi_bad_type),
    R("vpi_iterate", iterate_bad_type), R("vpi_iterate", iterate_forged), R("vpi_iterate", iterate_wrong_type),
    R("vpi_scan", scan_null), R("vpi_scan", scan_forged), R("vpi_scan", scan_wrong_type),
    R("vpi_get", get_null), R("vpi_get", get_forged), R("vpi_get", get_bad_prop),
    R("vpi_get_real", get_real_forged), R("vpi_get_real", get_real_bad_prop),
    R("vpi_get_str", get_str_null), R("vpi_get_str", get_str_forged), R("vpi_get_str", get_str_bad_prop),
    R("vpi_compare_objects", compare_null), R("vpi_compare_objects", compare_forged),
    R("vpi_free_object", free_null), R("vpi_free_object", free_forged),
    R("vpi_release_handle", release_null), R("vpi_release_handle", release_forged),
    R("vpi_get_vlog_info", vlog_info_null),
    R("vpi_get_value", get_value_null), R("vpi_get_value", get_value_forged),
    R("vpi_get_value", get_value_wrong_type), R("vpi_get_value", get_value_null_value),
    R("vpi_get_value", get_value_bad_format),
    R("vpi_put_value", put_value_null), R("vpi_put_value", put_value_forged),
    R("vpi_put_value", put_value_wrong_type), R("vpi_put_value", put_value_null_value),
    R("vpi_put_value", put_value_bad_format), R("vpi_put_value", put_value_bad_flag),
    R("vpi_put_value", put_value_null_time),
    R("vpi_get_time", get_time_forged), R("vpi_get_time", get_time_null_time), R("vpi_get_time", get_time_bad_type),
    R("vpi_get_delays", get_delays_null), R("vpi_get_delays", get_delays_wrong_type),
    R("vpi_get_delays", get_delays_null_delay),
    R("vpi_put_delays", put_delays_null), R("vpi_put_delays", put_delays_forged),
    R("vpi_put_delays", put_delays_null_delay),
    R("vpi_register_systf", register_systf_null), R("vpi_register_systf", register_systf_no_dollar),
    R("vpi_register_systf", register_systf_null_name), R("vpi_register_systf", register_systf_bad_type),
    R("vpi_register_analog_systf", register_analog_systf_null),
    R("vpi_register_analog_systf", register_analog_systf_no_dollar),
    R("vpi_register_analog_systf", register_analog_systf_bad_type),
    R("vpi_get_systf_info", systf_info_null), R("vpi_get_systf_info", systf_info_wrong_type),
    R("vpi_get_systf_info", systf_info_null_data),
    R("vpi_get_analog_systf_info", analog_systf_info_forged),
    R("vpi_get_analog_systf_info", analog_systf_info_null_data),
    R("vpi_put_userdata", put_userdata_null), R("vpi_put_userdata", put_userdata_wrong_type),
    R("vpi_get_userdata", get_userdata_forged), R("vpi_get_userdata", get_userdata_wrong_type),
    R("vpi_register_cb", register_cb_null), R("vpi_register_cb", register_cb_bad_reason),
    R("vpi_register_cb", register_cb_null_routine), R("vpi_register_cb", register_cb_forged_obj),
    R("vpi_remove_cb", remove_cb_null), R("vpi_remove_cb", remove_cb_forged), R("vpi_remove_cb", remove_cb_wrong_type),
    R("vpi_get_cb_info", cb_info_wrong_type), R("vpi_get_cb_info", cb_info_null_data),
    R("vpi_get_data", get_data_bad_id), R("vpi_put_data", put_data_bad_id),
    R("vpi_get_analog_value", analog_value_forged), R("vpi_get_analog_value", analog_value_wrong_type),
    R("vpi_get_analog_value", analog_value_null_value),
    R("vpi_mcd_open", mcd_open_null), R("vpi_mcd_close", mcd_close_unopened), R("vpi_mcd_name", mcd_name_unopened),
    R("vpi_mcd_flush", mcd_flush_unopened), R("vpi_mcd_printf", mcd_printf_unopened),
    R("vpi_mcd_printf", mcd_printf_null_format), R("vpi_printf", printf_null_format),
    R("vpi_vprintf", vprintf_null_format), R("vpi_mcd_vprintf", mcd_vprintf_unopened),
    R("vpi_control", control_bad_op), R("vpi_sim_control", sim_control_bad_op),
};

/* Rows VerA is known to get wrong, with the reason: an XFAIL, not a pass. */
static const char *const known[][2] = {
    {NULL, NULL},
};

static const char *knownReason(const char *name) {
    size_t i;
    for (i = 0; known[i][0] != NULL; i++)
        if (strcmp(known[i][0], name) == 0) return known[i][1];
    return NULL;
}

/* 0: ok. 1: returned something other than its failure value. 2: returned it
 * with no error recorded. 3: crashed. */
static int judge(const struct row *r) {
    int returned = r->fn();
    s_vpi_error_info info;
    int level;
    memset(&info, 0, sizeof info);
    level = vpi_chk_error(&info);
    if (!returned) return 1;
    if (level == 0 || info.level == 0) return 2;
    return 0;
}

static int runRow(const struct row *r) {
#if defined(_WIN32)
    return judge(r);
#else
    int status = 0;
    pid_t pid;
    fflush(stdout);
    fflush(stderr);
    pid = fork();
    if (pid < 0) return 3;
    if (pid == 0) _exit(judge(r));
    if (waitpid(pid, &status, 0) != pid) return 3;
    return WIFEXITED(status) ? WEXITSTATUS(status) : 3;
#endif
}

static PLI_INT32 table(p_cb_data d) {
    static const char *const why[] = {"ok", "wrong return value", "no error recorded", "crashed"};
    size_t i;
    int bad = 0;
    (void)d;
    mod = vpi_handle_by_name("vpi_negative", NULL);
    reg = vpi_handle_by_name("vpi_negative.r", NULL);
    mem = vpi_handle_by_name("vpi_negative.mem", NULL);
    word = vpi_handle_by_index(mem, 0);
    itr = vpi_iterate(vpiReg, mod);
    if (!mod || !reg || !mem || !word || !itr || !cb || !systf) {
        fprintf(stderr, "vpi-negative: a fixture handle is NULL\n");
        exit(1);
    }
    for (i = 0; i < sizeof rows / sizeof rows[0]; i++) {
        int got = runRow(&rows[i]);
        const char *reason = knownReason(rows[i].name);
        if (reason && got != 0) printf("XFAIL %s: %s (%s)\n", rows[i].name, why[got], reason);
        else if (reason) bad = 1, printf("BAD %s: XPASS, delete its known[] line\n", rows[i].name);
        else if (got != 0) bad = 1, printf("BAD %s: %s\n", rows[i].name, why[got]);
        else printf("ok %s\n", rows[i].name);
    }
    for (i = 0; known[i][0] != NULL; i++) {
        size_t j;
        for (j = 0; j < sizeof rows / sizeof rows[0] && strcmp(rows[j].name, known[i][0]) != 0; j++) {}
        if (j == sizeof rows / sizeof rows[0]) bad = 1, printf("BAD %s: known[] names no row\n", known[i][0]);
    }
    if (bad) exit(1);
    puts("vpi-negative=ok");
    return 0;
}

static void startup(void) {
    s_cb_data d = {cbStartOfSimulation, table, NULL, NULL, NULL, 0, NULL};
    s_cb_data end = {cbEndOfSimulation, nop_cb, NULL, NULL, NULL, 0, NULL};
    s_vpi_systf_data tf = {vpiSysTask, 0, "$vpi_negative", nop_tf, NULL, NULL, NULL};
    if (!vpi_register_cb(&d)) exit(1);
    cb = vpi_register_cb(&end);
    systf = vpi_register_systf(&tf);
}
void (*vlog_startup_routines[])(void) = {startup, NULL};
