#include "cmd_wlocks.h"
#include "output.h"
#include "bsonutil.h"
#include <stdio.h>
#include <string.h>

/*
 * -wlocks
 *
 * Show ALL active operations that are either waiting for a lock or currently
 * holding at least one lock.  Richer detail than -locks.
 *
 * Equivalent: db.adminCommand({ currentOp: true }) filtered on locks != {}
 */

static void print_lock_detail(const bson_t *op) {
    bson_iter_t it;
    if (!bson_iter_init_find(&it, op, "locks") ||
        !BSON_ITER_HOLDS_DOCUMENT(&it)) { printf("  (none)"); return; }

    bson_iter_t child;
    bson_iter_recurse(&it, &child);

    while (bson_iter_next(&child)) {
        const char *k = bson_iter_key(&child);
        uint32_t vlen = 0;
        const char *v = BSON_ITER_HOLDS_UTF8(&child) ?
                        bson_iter_utf8(&child, &vlen) : "?";
        printf("    %-20s  %.*s\n", k, (int)vlen, v);
    }
}

void cmd_wlocks(Conn *c, const Args *a) {
    (void)a;
    print_header("All Lock Activity  [equiv: db2pd -wlocks]");

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
        print_warn("No active operations.");
        bson_destroy(&reply);
        print_footer();
        return;
    }

    int total = 0;

    bson_iter_t arr;
    bson_iter_recurse(&it, &arr);

    while (bson_iter_next(&arr)) {
        if (!BSON_ITER_HOLDS_DOCUMENT(&arr)) continue;
        uint32_t len; const uint8_t *data;
        bson_iter_document(&arr, &len, &data);
        bson_t op; bson_init_static(&op, data, len);

        /* only print ops with a non-empty locks subdoc or waitingForLock */
        bool waiting = false;
        bu_bool(&op, "waitingForLock", &waiting);

        bson_iter_t lit;
        bool has_locks = (bson_iter_init_find(&lit, &op, "locks") &&
                          BSON_ITER_HOLDS_DOCUMENT(&lit));
        if (!has_locks && !waiting) continue;

        /* count keys in locks doc to skip empty {} */
        if (has_locks && !waiting) {
            bson_iter_t child;
            bson_iter_recurse(&lit, &child);
            int nkeys = 0;
            while (bson_iter_next(&child)) nkeys++;
            if (nkeys == 0) continue;
        }

        total++;
        char opid[64], type[32], ns[256], client[128];
        int64_t secs = 0;
        bu_opid_str(&op, opid, sizeof(opid));
        bu_str(&op, "op",     type,   sizeof(type));
        bu_str(&op, "ns",     ns,     sizeof(ns));
        bu_str(&op, "client", client, sizeof(client));
        bu_int64(&op, "secs_running", &secs);

        printf("\n  %sopId:%-8s%s  op:%-8s  ns:%-35s  secs:%lld  wait:%s  client:%s\n",
               C_BOLD(), opid, C_RESET(),
               bu_or_dash(type), bu_or_dash(ns),
               (long long)secs,
               waiting ? "true" : "false",
               bu_or_dash(client));
        printf("  Locks:\n");
        print_lock_detail(&op);
    }

    if (total == 0) print_info("No lock activity found.");
    printf("\n  Total ops with lock activity: %d\n", total);

    bson_destroy(&reply);
    print_footer();
}
