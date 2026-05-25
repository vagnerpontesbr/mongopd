#include "cmd_hadr.h"
#include "output.h"
#include "bsonutil.h"
#include <stdio.h>
#include <string.h>
#include <time.h>

/*
 * -hadr
 *
 * Replica set health, member states and replication lag.
 *
 * Equivalent:
 *   db.adminCommand({ replSetGetStatus: 1 })
 *   db.adminCommand({ serverStatus: 1 }) → repl section
 */

static const char *rs_state_name(int state) {
    switch (state) {
        case 0: return "STARTUP";
        case 1: return "PRIMARY";
        case 2: return "SECONDARY";
        case 3: return "RECOVERING";
        case 5: return "STARTUP2";
        case 6: return "UNKNOWN";
        case 7: return "ARBITER";
        case 8: return "DOWN";
        case 9: return "ROLLBACK";
        case 10: return "REMOVED";
        default: return "?";
    }
}

/* Extract epoch seconds from a BSON Date value stored as int64 */
static double date_to_secs(int64_t ms) { return (double)ms / 1000.0; }

void cmd_hadr(Conn *c, const Args *a) {
    (void)a;
    print_header("Replica Set Health and State  [equiv: db2pd -hadr]");

    bson_t *cmd = BCON_NEW("replSetGetStatus", BCON_INT32(1));
    bson_t reply; bson_error_t err;

    if (!conn_admin_cmd(c, cmd, &reply, &err)) {
        bson_destroy(cmd);
        print_warn("replSetGetStatus failed — this node may not be part of a replica set.");
        print_footer();
        return;
    }
    bson_destroy(cmd);

    /* ── Set overview ────────────────────────────────────────────────── */
    char set_name[128] = "";
    int64_t my_state = 0;
    bu_str(&reply,   "set",     set_name,  sizeof(set_name));
    bu_int64(&reply, "myState", &my_state);

    print_section("Replica Set Overview");
    printf("  %-30s  %s\n",   "Set name",  bu_or_dash(set_name));
    printf("  %-30s  %lld (%s)\n", "My state", (long long)my_state,
           rs_state_name((int)my_state));

    /* ── Members table ───────────────────────────────────────────────── */
    bson_iter_t it;
    if (!bson_iter_init_find(&it, &reply, "members") ||
        !BSON_ITER_HOLDS_ARRAY(&it)) {
        print_warn("No members array in replSetGetStatus.");
        bson_destroy(&reply);
        print_footer();
        return;
    }

    print_section("Members");
    printf("\n  %-32s  %-12s  %-10s  %10s  %-24s  %s\n",
           "name", "state", "health", "lag(s)", "lastHeartbeat", "optime");
    print_sep();

    /* get primary optime for lag calculation */
    int64_t primary_optime_ts = 0;
    {
        bson_iter_t arr2, mem2;
        bson_iter_init_find(&it, &reply, "members");
        bson_iter_recurse(&it, &arr2);
        while (bson_iter_next(&arr2)) {
            if (!BSON_ITER_HOLDS_DOCUMENT(&arr2)) continue;
            uint32_t l; const uint8_t *d;
            bson_iter_document(&arr2, &l, &d);
            bson_t m; bson_init_static(&m, d, l);
            int64_t st = 0; bu_int64(&m, "state", &st);
            if (st == 1) { /* PRIMARY */
                /* optime is a subdocument with ts (Timestamp type) */
                bson_iter_t oit;
                if (bson_iter_init_find(&oit, &m, "optime") &&
                    BSON_ITER_HOLDS_DOCUMENT(&oit)) {
                    bson_iter_t child;
                    bson_iter_recurse(&oit, &child);
                    if (bson_iter_find(&child, "ts") &&
                        BSON_ITER_HOLDS_TIMESTAMP(&child)) {
                        uint32_t ts_val, ts_inc;
                        bson_iter_timestamp(&child, &ts_val, &ts_inc);
                        primary_optime_ts = (int64_t)ts_val;
                    }
                }
            }
        }
        /* reset iterator for main loop */
        bson_iter_init_find(&it, &reply, "members");
        (void)mem2;
    }

    bson_iter_t arr;
    bson_iter_recurse(&it, &arr);

    while (bson_iter_next(&arr)) {
        if (!BSON_ITER_HOLDS_DOCUMENT(&arr)) continue;
        uint32_t len; const uint8_t *data;
        bson_iter_document(&arr, &len, &data);
        bson_t m; bson_init_static(&m, data, len);

        char name[128] = "", lhb[64] = "";
        int64_t state = 0;
        double health = 0.0;
        bu_str(&m,    "name",    name, sizeof(name));
        bu_int64(&m,  "state",   &state);
        bu_double(&m, "health",  &health);

        /* lastHeartbeat is a BSON Date (int64 ms since epoch) */
        char lhb_buf[32] = "—";
        bson_iter_t lhb_it;
        if (bson_iter_init_find(&lhb_it, &m, "lastHeartbeat") &&
            BSON_ITER_HOLDS_DATE_TIME(&lhb_it)) {
            int64_t ms = bson_iter_date_time(&lhb_it);
            time_t t = (time_t)(ms / 1000);
            struct tm *tm_info = localtime(&t);
            strftime(lhb_buf, sizeof(lhb_buf), "%Y-%m-%dT%H:%M:%S", tm_info);
        }
        snprintf(lhb, sizeof(lhb), "%s", lhb_buf);

        /* optime lag vs primary */
        double lag_s = 0.0;
        char lag_str[16] = "—";
        bson_iter_t oit;
        if (primary_optime_ts > 0 &&
            bson_iter_init_find(&oit, &m, "optime") &&
            BSON_ITER_HOLDS_DOCUMENT(&oit)) {
            bson_iter_t child;
            bson_iter_recurse(&oit, &child);
            if (bson_iter_find(&child, "ts") && BSON_ITER_HOLDS_TIMESTAMP(&child)) {
                uint32_t ts_val, ts_inc;
                bson_iter_timestamp(&child, &ts_val, &ts_inc);
                lag_s = date_to_secs(primary_optime_ts * 1000LL) -
                        date_to_secs((int64_t)ts_val * 1000LL);
                snprintf(lag_str, sizeof(lag_str), "%.0f", lag_s);
            }
        }

        const char *state_name = rs_state_name((int)state);
        printf("  %-32s  %-12s  %-10.1f  %10s  %-24s  %s\n",
               bu_or_dash(name),
               state_name,
               health,
               lag_str,
               lhb,
               "");
    }

    bson_destroy(&reply);
    print_footer();
}
