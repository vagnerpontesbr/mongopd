#include "cmd_agents.h"
#include "output.h"
#include "bsonutil.h"
#include <stdio.h>
#include <string.h>

/*
 * -agents
 *
 * Show engine agents (internal threads) and background operations.
 *
 * Equivalent:
 *   db.adminCommand({ currentOp: true, $ownOps: false })
 *   filter on op == "none" or client == ""  (internal ops)
 *   plus serverStatus.connections and threads section
 */

void cmd_agents(Conn *c, const Args *a) {
    (void)a;
    print_header("Engine Agents and Background Threads  [equiv: db2pd -agents]");

    /* ── serverStatus: threads section ───────────────────────────────── */
    {
        bson_t *cmd = BCON_NEW("serverStatus", BCON_INT32(1),
                               "connections", BCON_INT32(0),
                               "metrics", BCON_INT32(0));
        bson_t reply; bson_error_t err;
        if (conn_admin_cmd(c, cmd, &reply, &err)) {
            print_section("Thread Summary (serverStatus)");

            bson_t mem;
            if (bu_subdoc(&reply, "mem", &mem)) {
                int64_t res = 0, virt = 0, bits = 0;
                bu_int64(&mem, "resident", &res);
                bu_int64(&mem, "virtual",  &virt);
                bu_int64(&mem, "bits",     &bits);
                printf("  %-28s  %lld MB\n", "Resident memory", (long long)res);
                printf("  %-28s  %lld MB\n", "Virtual memory",  (long long)virt);
                printf("  %-28s  %lld-bit\n", "Process bits",   (long long)bits);
            }
            bson_destroy(&reply);
        }
        bson_destroy(cmd);
    }

    /* ── currentOp: internal (system) operations ─────────────────────── */
    {
        bson_t *cmd = BCON_NEW("currentOp", BCON_INT32(1));
        bson_t reply; bson_error_t err;
        if (!conn_admin_cmd(c, cmd, &reply, &err)) {
            bson_destroy(cmd); print_footer(); return;
        }
        bson_destroy(cmd);

        bson_iter_t it;
        if (!bson_iter_init_find(&it, &reply, "inprog") ||
            !BSON_ITER_HOLDS_ARRAY(&it)) {
            print_warn("No operations found.");
            bson_destroy(&reply);
            print_footer();
            return;
        }

        print_section("Internal / Background Operations");
        printf("\n  %-10s  %-8s  %-35s  %7s  %s\n",
               "opId", "type", "namespace", "secs", "desc");
        print_sep();

        bson_iter_t arr;
        bson_iter_recurse(&it, &arr);
        int internal = 0, active = 0;

        while (bson_iter_next(&arr)) {
            if (!BSON_ITER_HOLDS_DOCUMENT(&arr)) continue;
            uint32_t len; const uint8_t *data;
            bson_iter_document(&arr, &len, &data);
            bson_t op; bson_init_static(&op, data, len);

            char client[128] = "";
            bu_str(&op, "client", client, sizeof(client));
            bool is_internal = (client[0] == '\0');

            active++;
            if (!is_internal) continue;
            internal++;

            char opid[64], type[32], ns[256], desc[256];
            int64_t secs = 0;
            bu_opid_str(&op, opid, sizeof(opid));
            bu_str(&op, "op",   type, sizeof(type));
            bu_str(&op, "ns",   ns,   sizeof(ns));
            bu_str(&op, "desc", desc, sizeof(desc));
            bu_int64(&op, "secs_running", &secs);

            printf("  %-10s  %-8s  %-35s  %7lld  %s\n",
                   opid,
                   bu_or_dash(type),
                   bu_or_dash(ns),
                   (long long)secs,
                   bu_or_dash(desc));
        }

        if (internal == 0) print_info("No internal background operations found.");
        printf("\n  Total active operations: %d   Internal: %d\n", active, internal);

        bson_destroy(&reply);
    }

    print_footer();
}
