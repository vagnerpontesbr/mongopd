#include "cmd_locks.h"
#include "output.h"
#include "bsonutil.h"
#include <stdio.h>
#include <string.h>

/*
 * -locks [wait]
 *
 * Without "wait": show both lock waiters AND blocking operations.
 * With    "wait": show only operations waiting for a lock.
 *
 * Equivalent MongoDB: db.adminCommand({ currentOp: true })
 * Filter on waitingForLock and presence of locks{} document.
 */

/* Pretty-print the locks document from an op */
static void print_locks_doc(const bson_t *op) {
    bson_iter_t it;
    if (!bson_iter_init_find(&it, op, "locks")) return;
    if (!BSON_ITER_HOLDS_DOCUMENT(&it)) return;

    bson_iter_t child;
    if (!bson_iter_recurse(&it, &child)) return;

    bool first = true;
    while (bson_iter_next(&child)) {
        const char *k = bson_iter_key(&child);
        uint32_t len;
        const char *v = BSON_ITER_HOLDS_UTF8(&child) ? bson_iter_utf8(&child, &len) : "?";
        if (first) first = false; else printf(",");
        printf("%s:%s", k, v);
    }
}

static void print_op_row(const bson_t *op, bool waiting) {
    char opid[64], type[32], ns[256], state[64];
    int64_t secs = 0;

    bu_opid_str(op, opid, sizeof(opid));
    bu_str(op, "op",          type,  sizeof(type));
    bu_str(op, "ns",          ns,    sizeof(ns));
    bu_str(op, "lockStats",   state, sizeof(state));
    bu_int64(op, "secs_running", &secs);

    printf("  %-10s  %-8s  %-35s  %5lld s  wait=%-5s  locks=",
           opid,
           bu_or_dash(type),
           bu_or_dash(ns),
           (long long)secs,
           waiting ? "true" : "false");
    print_locks_doc(op);
    printf("\n");
}

void cmd_locks(Conn *c, const Args *a) {
    print_header("Locks and Lock Waiters  [equiv: db2pd -locks]");

    bson_t *cmd = BCON_NEW("currentOp", BCON_INT32(1));
    bson_t reply;
    bson_error_t err;

    if (!conn_admin_cmd(c, cmd, &reply, &err)) {
        bson_destroy(cmd);
        print_footer();
        return;
    }
    bson_destroy(cmd);

    bson_iter_t it;
    if (!bson_iter_init_find(&it, &reply, "inprog") ||
        !BSON_ITER_HOLDS_ARRAY(&it)) {
        print_warn("No active operations found.");
        bson_destroy(&reply);
        print_footer();
        return;
    }

    bson_iter_t arr;
    bson_iter_recurse(&it, &arr);

    int waiters = 0, blockers = 0;

    /* ── pass 1: collect waiters ─────────────────────────────────────── */
    if (!a->flag_locks_wait) {
        printf("\n  %s── Blocking Operations (holding locks)%s\n\n",
               C_YELLOW(), C_RESET());
        printf("  %-10s  %-8s  %-35s  %7s  %-10s  %s\n",
               "opId", "type", "namespace", "running", "waiting", "locks");
        print_sep();
    }

    bson_iter_t arr2;
    bson_iter_init_find(&it, &reply, "inprog");
    bson_iter_recurse(&it, &arr2);

    while (bson_iter_next(&arr2)) {
        if (!BSON_ITER_HOLDS_DOCUMENT(&arr2)) continue;
        uint32_t len; const uint8_t *data;
        bson_iter_document(&arr2, &len, &data);
        bson_t op; bson_init_static(&op, data, len);

        bool waiting = false;
        bu_bool(&op, "waitingForLock", &waiting);

        /* check if there is a non-empty locks subdoc */
        bson_iter_t lit;
        bool has_locks = (bson_iter_init_find(&lit, &op, "locks") &&
                          BSON_ITER_HOLDS_DOCUMENT(&lit));

        if (waiting) {
            waiters++;
            if (!a->flag_locks_wait) continue; /* print in pass 2 */
            print_op_row(&op, true);
        } else if (!a->flag_locks_wait && has_locks) {
            blockers++;
            print_op_row(&op, false);
        }
    }

    if (!a->flag_locks_wait) {
        if (blockers == 0) print_info("No blocking operations found.");
        printf("\n  %s── Lock Waiters (waitingForLock: true)%s\n\n",
               C_YELLOW(), C_RESET());
        printf("  %-10s  %-8s  %-35s  %7s  %-10s  %s\n",
               "opId", "type", "namespace", "running", "waiting", "locks");
        print_sep();

        /* print the waiters now */
        bson_iter_init_find(&it, &reply, "inprog");
        bson_iter_t arr3; bson_iter_recurse(&it, &arr3);
        while (bson_iter_next(&arr3)) {
            if (!BSON_ITER_HOLDS_DOCUMENT(&arr3)) continue;
            uint32_t len2; const uint8_t *data2;
            bson_iter_document(&arr3, &len2, &data2);
            bson_t op2; bson_init_static(&op2, data2, len2);
            bool w = false;
            bu_bool(&op2, "waitingForLock", &w);
            if (w) { waiters++; print_op_row(&op2, true); }
        }
        if (waiters == 0) print_info("No lock waiters found.");
    } else {
        if (waiters == 0) print_info("No lock waiters found.");
    }

    printf("\n  Blockers: %d   Waiters: %d\n", blockers, waiters);

    bson_destroy(&reply);
    print_footer();
}
