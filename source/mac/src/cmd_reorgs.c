#include "cmd_reorgs.h"
#include "output.h"
#include "bsonutil.h"
#include <stdio.h>
#include <string.h>

/*
 * -reorgs
 *
 * Background index builds and chunk migration activity.
 *
 * Equivalent:
 *   db.adminCommand({ currentOp: true })
 *     → filter ops where desc contains "IndexBuild" or "createIndex"
 *   config.migrations (on mongos) for chunk movements (advisory only)
 */

void cmd_reorgs(Conn *c, const Args *a) {
    (void)a;
    print_header("Background Index Builds and Data Movement  [equiv: db2pd -reorgs]");

    /* ── 1. Active index builds via currentOp ────────────────────────── */
    {
        bson_t *cmd = BCON_NEW("currentOp", BCON_INT32(1));
        bson_t reply; bson_error_t err;
        if (!conn_admin_cmd(c, cmd, &reply, &err)) {
            bson_destroy(cmd); print_footer(); return;
        }
        bson_destroy(cmd);

        bson_iter_t it;
        if (bson_iter_init_find(&it, &reply, "inprog") &&
            BSON_ITER_HOLDS_ARRAY(&it)) {

            print_section("Active Index Builds (currentOp)");
            printf("\n  %-10s  %-40s  %7s  %s\n",
                   "opId", "namespace / desc", "secs", "phase");
            print_sep();

            bson_iter_t arr;
            bson_iter_recurse(&it, &arr);
            int count = 0;

            while (bson_iter_next(&arr)) {
                if (!BSON_ITER_HOLDS_DOCUMENT(&arr)) continue;
                uint32_t len; const uint8_t *data;
                bson_iter_document(&arr, &len, &data);
                bson_t op; bson_init_static(&op, data, len);

                char desc[256] = "", ns[256] = "", opid[64] = "", phase[128] = "";
                int64_t secs = 0;
                bu_str(&op, "desc", desc, sizeof(desc));
                bu_str(&op, "ns",   ns,   sizeof(ns));
                bu_opid_str(&op, opid, sizeof(opid));
                bu_int64(&op, "secs_running", &secs);
                bu_str(&op, "msg",  phase, sizeof(phase));

                bool is_build = (strstr(desc, "IndexBuild")   ||
                                 strstr(desc, "createIndex")  ||
                                 strstr(ns,   "$cmd.createIndexes"));
                if (!is_build) continue;

                printf("  %-10s  %-40s  %7lld  %s\n",
                       opid,
                       *ns ? ns : bu_or_dash(desc),
                       (long long)secs,
                       bu_or_dash(phase));
                count++;
            }

            if (count == 0) print_info("No active index builds.");
        }
        bson_destroy(&reply);
    }

    /* ── 2. currentIndexBuilds command (MongoDB 4.4+) ────────────────── */
    {
        bson_t *cmd = BCON_NEW("currentIndexBuilds", BCON_INT32(1));
        bson_t reply; bson_error_t err;
        if (conn_admin_cmd(c, cmd, &reply, &err)) {
            bson_t in_prog;
            if (bu_subdoc(&reply, "inprog", &in_prog)) {
                print_section("Index Builds Catalog (currentIndexBuilds)");
                printf("\n  %-40s  %-20s  %s\n", "collection", "buildUUID", "phase");
                print_sep();

                bson_iter_t it2;
                bson_iter_init(&it2, &in_prog);
                int cnt = 0;
                while (bson_iter_next(&it2)) {
                    if (!BSON_ITER_HOLDS_DOCUMENT(&it2)) continue;
                    uint32_t l2; const uint8_t *d2;
                    bson_iter_document(&it2, &l2, &d2);
                    bson_t b2; bson_init_static(&b2, d2, l2);
                    char col[256] = "", uuid[128] = "", ph[64] = "";
                    bu_str(&b2, "collection", col,  sizeof(col));
                    bu_str(&b2, "buildUUID",  uuid, sizeof(uuid));
                    bu_str(&b2, "phase",      ph,   sizeof(ph));
                    printf("  %-40s  %-20s  %s\n",
                           bu_or_dash(col), bu_or_dash(uuid), bu_or_dash(ph));
                    cnt++;
                }
                if (cnt == 0) print_info("No index builds in catalog.");
            }
            bson_destroy(&reply);
        }
        bson_destroy(cmd);
    }

    print_footer();
}
