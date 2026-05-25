#include "cmd_utilities.h"
#include "output.h"
#include "bsonutil.h"
#include <stdio.h>
#include <string.h>

/*
 * -utilities
 *
 * Show active utility / maintenance operations (compact, validate, etc.)
 * and long-running internal tasks.
 *
 * Equivalent: db.adminCommand({ currentOp: true })
 *   filter on op == "command" AND (desc includes "Compact" OR "Validate"
 *   OR "createIndex" OR secs_running > threshold)
 */

static bool is_utility_op(const bson_t *op) {
    char type[32] = "", desc[256] = "", ns[256] = "";
    bu_str(op, "op",   type, sizeof(type));
    bu_str(op, "desc", desc, sizeof(desc));
    bu_str(op, "ns",   ns,   sizeof(ns));

    if (strstr(desc, "Compact"))      return true;
    if (strstr(desc, "Validate"))     return true;
    if (strstr(desc, "createIndex"))  return true;
    if (strstr(desc, "dropIndex"))    return true;
    if (strstr(desc, "reIndex"))      return true;
    if (strstr(desc, "IndexBuild"))   return true;
    if (strstr(desc, "resync"))       return true;
    if (strstr(desc, "repl"))         return true;
    if (strstr(type,  "command") && ns[0] == '\0') return true;
    return false;
}

void cmd_utilities(Conn *c, const Args *a) {
    print_header("Active Utility Operations  [equiv: db2pd -utilities]");

    bson_t *cmd = BCON_NEW("currentOp", BCON_INT32(1));
    bson_t reply; bson_error_t err;
    if (!conn_admin_cmd(c, cmd, &reply, &err)) {
        bson_destroy(cmd); print_footer(); return;
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

    printf("\n  %-10s  %-8s  %-35s  %7s  %s\n",
           "opId", "type", "namespace", "secs", "desc");
    print_sep();

    bson_iter_t arr;
    bson_iter_recurse(&it, &arr);
    int count = 0;

    while (bson_iter_next(&arr)) {
        if (!BSON_ITER_HOLDS_DOCUMENT(&arr)) continue;
        uint32_t len; const uint8_t *data;
        bson_iter_document(&arr, &len, &data);
        bson_t op; bson_init_static(&op, data, len);

        int64_t secs = 0;
        bu_int64(&op, "secs_running", &secs);

        bool long_op = (a->secs > 0 && secs >= (int64_t)a->secs);
        if (!is_utility_op(&op) && !long_op) continue;

        char opid[64], type[32], ns[256], desc[256];
        bu_opid_str(&op, opid, sizeof(opid));
        bu_str(&op, "op",   type, sizeof(type));
        bu_str(&op, "ns",   ns,   sizeof(ns));
        bu_str(&op, "desc", desc, sizeof(desc));

        printf("  %-10s  %-8s  %-35s  %7lld  %s\n",
               opid,
               bu_or_dash(type),
               bu_or_dash(ns),
               (long long)secs,
               bu_or_dash(desc));
        count++;
    }

    if (count == 0) print_info("No utility operations found.");
    printf("\n  Total: %d\n", count);

    bson_destroy(&reply);
    print_footer();
}
