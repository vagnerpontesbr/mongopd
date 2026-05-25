#include "cmd_applications.h"
#include "output.h"
#include "bsonutil.h"
#include <stdio.h>
#include <string.h>

/*
 * -applications
 *
 * Show active sessions / client connections.
 *
 * Equivalent:
 *   db.adminCommand({ currentOp: true })  → summary per client appName
 *   db.adminCommand({ serverStatus: 1 })  → connections.current / available
 */

void cmd_applications(Conn *c, const Args *a) {
    (void)a;
    print_header("Active Sessions and Connections  [equiv: db2pd -applications]");

    /* ── 1. serverStatus for connection summary ──────────────────────── */
    {
        bson_t *cmd = BCON_NEW("serverStatus", BCON_INT32(1),
                               "repl", BCON_INT32(0),
                               "metrics", BCON_INT32(0));
        bson_t reply; bson_error_t err;

        if (conn_admin_cmd(c, cmd, &reply, &err)) {
            int64_t current = 0, available = 0, total_created = 0;
            bu_nested_int64(&reply, "connections", "current",      &current);
            bu_nested_int64(&reply, "connections", "available",    &available);
            bu_nested_int64(&reply, "connections", "totalCreated", &total_created);

            print_section("Connection Summary");
            printf("  %-28s  %lld\n", "Current connections",   (long long)current);
            printf("  %-28s  %lld\n", "Available connections", (long long)available);
            printf("  %-28s  %lld\n", "Total created",         (long long)total_created);
            bson_destroy(&reply);
        }
        bson_destroy(cmd);
    }

    /* ── 2. currentOp for active sessions ────────────────────────────── */
    {
        bson_t *cmd = BCON_NEW("currentOp", BCON_INT32(1), "active", BCON_BOOL(true));
        bson_t reply; bson_error_t err;

        if (!conn_admin_cmd(c, cmd, &reply, &err)) {
            bson_destroy(cmd);
            print_footer();
            return;
        }
        bson_destroy(cmd);

        bson_iter_t it;
        if (!bson_iter_init_find(&it, &reply, "inprog") ||
            !BSON_ITER_HOLDS_ARRAY(&it)) {
            bson_destroy(&reply);
            print_footer();
            return;
        }

        print_section("Active Operations by Client");
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

            char opid[64], type[32], ns[256], app[128], client[128];
            int64_t secs = 0;
            bu_opid_str(&op, opid, sizeof(opid));
            bu_str(&op, "op",      type,   sizeof(type));
            bu_str(&op, "ns",      ns,     sizeof(ns));
            bu_str(&op, "appName", app,    sizeof(app));
            bu_str(&op, "client",  client, sizeof(client));
            bu_int64(&op, "secs_running", &secs);

            printf("  %-10s  %-8s  %-35s  %7lld  %-24s  %s\n",
                   opid,
                   bu_or_dash(type),
                   bu_or_dash(ns),
                   (long long)secs,
                   bu_or_dash(app),
                   bu_or_dash(client));
            count++;
        }

        if (count == 0) print_info("No active operations found.");
        printf("\n  Total active operations: %d\n", count);

        bson_destroy(&reply);
    }

    print_footer();
}
