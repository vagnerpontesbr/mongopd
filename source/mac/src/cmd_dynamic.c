#include "cmd_dynamic.h"
#include "output.h"
#include "bsonutil.h"
#include <stdio.h>
#include <string.h>

/*
 * -dynamic
 *
 * Show active queries running > -secs threshold,
 * optionally display / toggle the profiler and show recent slow ops.
 *
 * Equivalent:
 *   db.adminCommand({ currentOp: true, active: true }) → filter secs_running
 *   db.getProfilingStatus()
 *   db.setProfilingLevel(2, { slowms: N })
 *   db.system.profile.find().sort({ts:-1}).limit(N)
 */

static void show_active_queries(Conn *c, const Args *a) {
    bson_t *cmd = BCON_NEW("currentOp", BCON_INT32(1), "active", BCON_BOOL(true));
    bson_t reply; bson_error_t err;
    if (!conn_admin_cmd(c, cmd, &reply, &err)) { bson_destroy(cmd); return; }
    bson_destroy(cmd);

    bson_iter_t it;
    if (!bson_iter_init_find(&it, &reply, "inprog") ||
        !BSON_ITER_HOLDS_ARRAY(&it)) {
        bson_destroy(&reply); return;
    }

    print_section("Active Queries");
    printf("\n  %-10s  %-8s  %-35s  %7s  %-24s  %s\n",
           "opId", "type", "namespace", "secs", "appName", "client");
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
        if (a->secs > 0 && secs < (int64_t)a->secs) continue;

        /* skip internal background ops (no client) */
        char client[128] = "";
        bu_str(&op, "client", client, sizeof(client));
        if (client[0] == '\0') continue;

        char opid[64], type[32], ns[256], app[128];
        bu_opid_str(&op, opid,  sizeof(opid));
        bu_str(&op, "op",      type,   sizeof(type));
        bu_str(&op, "ns",      ns,     sizeof(ns));
        bu_str(&op, "appName", app,    sizeof(app));

        printf("  %-10s  %-8s  %-35s  %7lld  %-24s  %s\n",
               opid,
               bu_or_dash(type),
               bu_or_dash(ns),
               (long long)secs,
               bu_or_dash(app),
               bu_or_dash(client));
        count++;
    }

    if (count == 0) print_info("No active queries (secs_running >= %d).", a->secs);
    printf("\n  Total: %d\n", count);
    bson_destroy(&reply);
}

static void show_profiler_status(Conn *c, const Args *a) {
    const char *db = (a->db_name && a->db_name[0]) ? a->db_name : "test";

    bson_t *cmd = BCON_NEW("profile", BCON_INT32(-1));
    bson_t reply; bson_error_t err;
    if (!conn_db_cmd(c, db, cmd, &reply, &err)) {
        bson_destroy(cmd); return;
    }
    bson_destroy(cmd);

    int64_t level = 0, slowms_val = 200;
    bu_int64(&reply, "was",    &level);
    bu_int64(&reply, "slowms", &slowms_val);
    bson_destroy(&reply);

    print_section("Profiler Status");
    printf("  %-28s  %lld  (%s)\n", "Profiler level", (long long)level,
           level == 0 ? "off" : level == 1 ? "slow ops" : "all ops");
    printf("  %-28s  %lld ms\n", "slowms threshold", (long long)slowms_val);
}

static void toggle_profiler(Conn *c, const Args *a) {
    const char *db = (a->db_name && a->db_name[0]) ? a->db_name : "test";
    int new_level = (!strcmp(a->profiling, "on")) ? 1 : 0;

    bson_t *cmd = BCON_NEW("profile", BCON_INT32(new_level),
                           "slowms", BCON_INT32(a->slowms));
    bson_t reply; bson_error_t err;
    if (conn_db_cmd(c, db, cmd, &reply, &err)) {
        print_info("Profiler set to level %d (slowms=%d) on database '%s'.",
                   new_level, a->slowms, db);
        bson_destroy(&reply);
    }
    bson_destroy(cmd);
}

static void show_slow_ops(Conn *c, const Args *a) {
    const char *db = (a->db_name && a->db_name[0]) ? a->db_name : "test";

    /* sort: {ts: -1}, limit */
    bson_t *cmd = BCON_NEW(
        "find",  "system.profile",
        "filter", "{",
            "millis", "{", "$gte", BCON_INT32(a->slowms), "}",
        "}",
        "sort",  "{", "ts", BCON_INT32(-1), "}",
        "limit", BCON_INT32(a->limit)
    );

    bson_t reply; bson_error_t err;
    if (!conn_db_cmd(c, db, cmd, &reply, &err)) {
        bson_destroy(cmd); return;
    }
    bson_destroy(cmd);

    /* cursor is embedded in reply.cursor.firstBatch array */
    bson_t cursor_doc, first_batch;
    if (!bu_subdoc(&reply, "cursor", &cursor_doc) ||
        !bu_subdoc(&cursor_doc, "firstBatch", &first_batch)) {
        print_warn("system.profile not available or empty.");
        bson_destroy(&reply);
        return;
    }

    print_section("Recent Slow Operations (system.profile)");
    printf("\n  %-26s  %7s  %-8s  %-35s  %s\n",
           "timestamp", "ms", "op", "namespace", "planSummary");
    print_sep();

    bson_iter_t it;
    bson_iter_init(&it, &first_batch);
    int count = 0;

    while (bson_iter_next(&it)) {
        if (!BSON_ITER_HOLDS_DOCUMENT(&it)) continue;
        uint32_t len; const uint8_t *data;
        bson_iter_document(&it, &len, &data);
        bson_t doc; bson_init_static(&doc, data, len);

        char ts[64] = "", op[32] = "", ns[256] = "", plan[256] = "";
        int64_t millis = 0;
        bu_str(&doc, "ts",          ts,   sizeof(ts));
        bu_str(&doc, "op",          op,   sizeof(op));
        bu_str(&doc, "ns",          ns,   sizeof(ns));
        bu_str(&doc, "planSummary", plan, sizeof(plan));
        bu_int64(&doc, "millis",    &millis);

        printf("  %-26s  %7lld  %-8s  %-35s  %s\n",
               bu_or_dash(ts),
               (long long)millis,
               bu_or_dash(op),
               bu_or_dash(ns),
               bu_or_dash(plan));
        count++;
    }

    if (count == 0) print_info("No slow operations recorded.");
    printf("\n  Shown: %d (slowms >= %d)\n", count, a->slowms);
    bson_destroy(&reply);
}

void cmd_dynamic(Conn *c, const Args *a) {
    print_header("Active Queries and Profiler  [equiv: db2pd -dynamic]");

    /* Optionally toggle profiler before anything else */
    if (a->profiling && a->profiling[0]) toggle_profiler(c, a);

    show_active_queries(c, a);
    show_profiler_status(c, a);
    show_slow_ops(c, a);

    print_footer();
}
