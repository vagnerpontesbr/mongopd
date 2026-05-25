#include "cmd_transactions.h"
#include "output.h"
#include "bsonutil.h"
#include <stdio.h>
#include <string.h>

/*
 * -transactions
 *
 * In-flight transactions and transaction counters.
 *
 * Equivalent:
 *   db.adminCommand({ serverStatus: 1 }) → transactions.*
 *   db.adminCommand({ currentOp: true, $ownOps: false }) → filter txnNumber
 */

static void print_tx_counters(const bson_t *status) {
    bson_t tx;
    if (!bu_subdoc(status, "transactions", &tx)) {
        print_warn("Transaction stats not available (MongoDB < 4.0?).");
        return;
    }

    print_section("Transaction Counters");
    int64_t started = 0, committed = 0, aborted = 0, active = 0,
            total_committed = 0, total_aborted = 0;
    bu_int64(&tx, "currentActive",          &active);
    bu_int64(&tx, "currentInactive",        &started);
    bu_int64(&tx, "totalStarted",           &total_committed); /* re-use field */
    bu_int64(&tx, "totalCommitted",         &committed);
    bu_int64(&tx, "totalAborted",           &aborted);
    /* reset to correct values */
    total_committed = committed;
    total_aborted   = aborted;
    bu_int64(&tx, "totalStarted",           &started);

    printf("  %-38s  %lld\n", "Currently active",            (long long)active);
    printf("  %-38s  %lld\n", "Total started",               (long long)started);
    printf("  %-38s  %lld\n", "Total committed",             (long long)total_committed);
    printf("  %-38s  %lld\n", "Total aborted",               (long long)total_aborted);
    if (started > 0) {
        double commit_rate = (double)total_committed * 100.0 / (double)started;
        printf("  %-38s  %.1f%%\n", "Commit rate", commit_rate);
    }

    /* pinned range */
    int64_t oldest_ts = 0, stable_ts = 0;
    bu_int64(&tx, "totalPrepared", &oldest_ts);  /* field may not exist */
    bu_nested_int64(status, "wiredTiger", "transaction", &stable_ts); /* try */
    (void)oldest_ts; (void)stable_ts;
}

static void print_active_txns(Conn *c, const Args *a) {
    (void)a;
    bson_t *cmd = BCON_NEW("currentOp", BCON_INT32(1));
    bson_t reply; bson_error_t err;
    if (!conn_admin_cmd(c, cmd, &reply, &err)) { bson_destroy(cmd); return; }
    bson_destroy(cmd);

    bson_iter_t it;
    if (!bson_iter_init_find(&it, &reply, "inprog") ||
        !BSON_ITER_HOLDS_ARRAY(&it)) {
        bson_destroy(&reply); return;
    }

    print_section("In-Flight Transactions (currentOp)");
    printf("\n  %-10s  %-35s  %7s  %-10s  %s\n",
           "opId", "namespace", "secs", "txnNumber", "autocommit");
    print_sep();

    bson_iter_t arr;
    bson_iter_recurse(&it, &arr);
    int count = 0;

    while (bson_iter_next(&arr)) {
        if (!BSON_ITER_HOLDS_DOCUMENT(&arr)) continue;
        uint32_t len; const uint8_t *data;
        bson_iter_document(&arr, &len, &data);
        bson_t op; bson_init_static(&op, data, len);

        /* only show ops with a txnNumber */
        bson_iter_t tit;
        if (!bson_iter_init_find(&tit, &op, "txnNumber")) continue;

        char opid[64], ns[256], txnnum[32], autocommit[8];
        int64_t secs = 0;
        bu_opid_str(&op, opid, sizeof(opid));
        bu_str(&op, "ns", ns, sizeof(ns));
        bu_int64(&op, "secs_running", &secs);

        int64_t txn = bson_iter_as_int64(&tit);
        snprintf(txnnum, sizeof(txnnum), "%lld", (long long)txn);

        bool ac = true;
        bu_bool(&op, "autocommit", &ac);
        snprintf(autocommit, sizeof(autocommit), "%s", ac ? "true" : "false");

        printf("  %-10s  %-35s  %7lld  %-10s  %s\n",
               opid, bu_or_dash(ns), (long long)secs, txnnum, autocommit);
        count++;
    }

    if (count == 0) print_info("No in-flight transactions.");
    printf("\n  Total: %d\n", count);
    bson_destroy(&reply);
}

void cmd_transactions(Conn *c, const Args *a) {
    print_header("In-Flight Transactions  [equiv: db2pd -transactions]");

    bson_t *cmd = BCON_NEW("serverStatus", BCON_INT32(1),
                           "repl", BCON_INT32(0));
    bson_t reply; bson_error_t err;
    if (conn_admin_cmd(c, cmd, &reply, &err)) {
        print_tx_counters(&reply);
        bson_destroy(&reply);
    }
    bson_destroy(cmd);

    print_active_txns(c, a);
    print_footer();
}
