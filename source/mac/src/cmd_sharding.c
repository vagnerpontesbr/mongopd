#include "cmd_sharding.h"
#include "output.h"
#include "bsonutil.h"
#include <stdio.h>
#include <string.h>

/*
 * -sharding
 *
 * Show sharding topology, balancer state and chunk distribution.
 * Requires connection to a mongos.  Gracefully advisory on mongod.
 *
 * Equivalent:
 *   sh.status()
 *   db.adminCommand({ listShards: 1 })
 *   db.adminCommand({ balancerStatus: 1 })
 *   config.collections + config.chunks (via mongos)
 */

static bool is_mongos(Conn *c) {
    bson_t *cmd = BCON_NEW("isMaster", BCON_INT32(1));
    bson_t reply; bson_error_t err;
    bool result = false;
    if (conn_admin_cmd(c, cmd, &reply, &err)) {
        char msg[128] = "";
        bu_str(&reply, "msg", msg, sizeof(msg));
        result = !strcmp(msg, "isdbgrid");
        bson_destroy(&reply);
    }
    bson_destroy(cmd);
    return result;
}

static void print_shards(Conn *c) {
    bson_t *cmd = BCON_NEW("listShards", BCON_INT32(1));
    bson_t reply; bson_error_t err;
    if (!conn_admin_cmd(c, cmd, &reply, &err)) { bson_destroy(cmd); return; }
    bson_destroy(cmd);

    bson_iter_t it;
    if (!bson_iter_init_find(&it, &reply, "shards") ||
        !BSON_ITER_HOLDS_ARRAY(&it)) {
        bson_destroy(&reply); return;
    }

    print_section("Shards");
    printf("\n  %-20s  %-50s  %s\n", "shardId", "host", "state");
    print_sep();

    bson_iter_t arr;
    bson_iter_recurse(&it, &arr);
    while (bson_iter_next(&arr)) {
        if (!BSON_ITER_HOLDS_DOCUMENT(&arr)) continue;
        uint32_t len; const uint8_t *data;
        bson_iter_document(&arr, &len, &data);
        bson_t s; bson_init_static(&s, data, len);

        char shard_id[64] = "", host[256] = "", state[32] = "";
        bu_str(&s, "_id",   shard_id, sizeof(shard_id));
        bu_str(&s, "host",  host,     sizeof(host));
        bu_str(&s, "state", state,    sizeof(state));
        printf("  %-20s  %-50s  %s\n",
               bu_or_dash(shard_id), bu_or_dash(host), bu_or_dash(state));
    }

    bson_destroy(&reply);
}

static void print_balancer(Conn *c) {
    bson_t *cmd = BCON_NEW("balancerStatus", BCON_INT32(1));
    bson_t reply; bson_error_t err;
    if (!conn_admin_cmd(c, cmd, &reply, &err)) { bson_destroy(cmd); return; }
    bson_destroy(cmd);

    print_section("Balancer");
    bool enabled = false, in_balance = false;
    bu_bool(&reply, "mode",        &enabled);    /* "full" or "off" */
    bu_bool(&reply, "inBalancerRound", &in_balance);

    char mode[32] = "";
    bu_str(&reply, "mode", mode, sizeof(mode));
    printf("  %-28s  %s\n", "Mode",            bu_or_dash(mode));
    printf("  %-28s  %s\n", "In balance round", in_balance ? "yes" : "no");
    (void)enabled;
    bson_destroy(&reply);
}

static void print_sharded_collections(Conn *c) {
    /* Query config.collections on the config server via mongos */
    bson_t *cmd = BCON_NEW(
        "find",   "collections",
        "filter", "{", "dropped", BCON_BOOL(false), "}",
        "limit",  BCON_INT32(50)
    );
    bson_t reply; bson_error_t err;
    if (!conn_db_cmd(c, "config", cmd, &reply, &err)) {
        bson_destroy(cmd); return;
    }
    bson_destroy(cmd);

    bson_t cursor_doc;
    if (!bu_subdoc(&reply, "cursor", &cursor_doc)) {
        bson_destroy(&reply); return;
    }

    /* firstBatch array */
    bson_iter_t it;
    if (!bson_iter_init_find(&it, &cursor_doc, "firstBatch") ||
        !BSON_ITER_HOLDS_ARRAY(&it)) {
        bson_destroy(&reply); return;
    }

    print_section("Sharded Collections");
    printf("\n  %-50s  %s\n", "namespace", "shardKey");
    print_sep();

    bson_iter_t arr;
    bson_iter_recurse(&it, &arr);
    int count = 0;
    while (bson_iter_next(&arr)) {
        if (!BSON_ITER_HOLDS_DOCUMENT(&arr)) continue;
        uint32_t len; const uint8_t *data;
        bson_iter_document(&arr, &len, &data);
        bson_t col; bson_init_static(&col, data, len);

        char ns[256] = "";
        bu_str(&col, "_id", ns, sizeof(ns));

        /* shardKey document → show as JSON */
        bson_t key_doc;
        char key_str[256] = "";
        if (bu_subdoc(&col, "key", &key_doc)) {
            char *js = bu_to_json(&key_doc);
            if (js) { snprintf(key_str, sizeof(key_str), "%s", js); bson_free(js); }
        }

        printf("  %-50s  %s\n", bu_or_dash(ns), bu_or_dash(key_str));
        count++;
    }

    if (count == 0) print_info("No sharded collections found in config.collections.");
    bson_destroy(&reply);
}

void cmd_sharding(Conn *c, const Args *a) {
    (void)a;
    print_header("Sharding Topology  [equiv: db2pd -sharding]");

    if (!is_mongos(c)) {
        print_warn("This node is NOT a mongos.");
        print_warn("Connect to a mongos router for full sharding diagnostics.");
        print_warn("Advisory: sh.status(), db.adminCommand({ listShards: 1 })");
        print_footer();
        return;
    }

    print_shards(c);
    print_balancer(c);
    print_sharded_collections(c);

    print_footer();
}
