#include "cmd_tcbstats.h"
#include "output.h"
#include "bsonutil.h"
#include <stdio.h>
#include <string.h>

/*
 * -tcbstats [collection]
 *
 * Per-collection storage stats, latency histograms and index usage.
 *
 * Equivalent:
 *   db.collection.aggregate([{ $collStats: {
 *       latencyStats: { histograms: true },
 *       storageStats: {},
 *       count: {}
 *   }}])
 *   db.collection.aggregate([{ $indexStats: {} }])
 */

/* Run $collStats on a single collection, print results */
static void print_coll_stats(mongoc_client_t *mc, const char *db_name,
                              const char *coll_name, const char *scale) {
    mongoc_collection_t *coll =
        mongoc_client_get_collection(mc, db_name, coll_name);

    /* build pipeline: [{ $collStats: { latencyStats: {histograms:true},
                                         storageStats: {}, count: {} } }] */
    bson_t pipeline;
    bson_t stage, collstats, lstats, sstats, cnt;
    bson_init(&pipeline);
    bson_append_document_begin(&pipeline, "0", -1, &stage);
    bson_append_document_begin(&stage, "$collStats", -1, &collstats);
    bson_append_document_begin(&collstats, "latencyStats", -1, &lstats);
    BSON_APPEND_BOOL(&lstats, "histograms", true);
    bson_append_document_end(&collstats, &lstats);
    bson_append_document_begin(&collstats, "storageStats", -1, &sstats);
    bson_append_document_end(&collstats, &sstats);
    bson_append_document_begin(&collstats, "count", -1, &cnt);
    bson_append_document_end(&collstats, &cnt);
    bson_append_document_end(&stage, &collstats);
    bson_append_document_end(&pipeline, &stage);

    mongoc_cursor_t *cursor =
        mongoc_collection_aggregate(coll, MONGOC_QUERY_NONE, &pipeline, NULL, NULL);
    bson_destroy(&pipeline);

    const bson_t *doc;
    bool got_doc = false;

    while (mongoc_cursor_next(cursor, &doc)) {
        got_doc = true;
        printf("\n  %s%s.%s%s\n", C_BOLD(), db_name, coll_name, C_RESET());

        /* storage stats */
        bson_t ss;
        if (bu_subdoc(doc, "storageStats", &ss)) {
            char sbuf[64];
            int64_t sz = 0, idx = 0, cnt_v = 0, avg = 0;
            bu_int64(&ss, "size",         &sz);
            bu_int64(&ss, "totalIndexSize", &idx);
            bu_int64(&ss, "count",        &cnt_v);
            bu_int64(&ss, "avgObjSize",   &avg);

            bu_fmt_bytes((double)sz,  scale, sbuf, sizeof(sbuf));
            printf("  %-30s  %s\n", "Data size",       sbuf);
            bu_fmt_bytes((double)idx, scale, sbuf, sizeof(sbuf));
            printf("  %-30s  %s\n", "Total index size", sbuf);
            bu_fmt_bytes((double)avg, scale, sbuf, sizeof(sbuf));
            printf("  %-30s  %s\n", "Avg object size",  sbuf);
            printf("  %-30s  %lld\n", "Document count", (long long)cnt_v);
        }

        /* latency stats */
        bson_t ls;
        if (bu_subdoc(doc, "latencyStats", &ls)) {
            const char *ops[] = {"reads", "writes", "commands"};
            for (int i = 0; i < 3; i++) {
                bson_t op_doc;
                if (!bu_subdoc(&ls, ops[i], &op_doc)) continue;
                int64_t ops_cnt = 0, latency = 0;
                bu_int64(&op_doc, "ops",     &ops_cnt);
                bu_int64(&op_doc, "latency", &latency);
                double avg_lat = (ops_cnt > 0) ? (double)latency / (double)ops_cnt : 0.0;
                printf("  %-30s  ops=%-10lld  avgLatency=%.2f µs\n",
                       ops[i],
                       (long long)ops_cnt, avg_lat);
            }
        }
    }

    bson_error_t cerr;
    if (!got_doc && mongoc_cursor_error(cursor, &cerr))
        printf("  [cursor error: %s]\n", cerr.message);
    else if (!got_doc)
        printf("  (no data)\n");

    mongoc_cursor_destroy(cursor);
    mongoc_collection_destroy(coll);

    /* ── $indexStats ──────────────────────────────────────────────────── */
    coll = mongoc_client_get_collection(mc, db_name, coll_name);
    bson_t ipipe;
    bson_t istage, iop;
    bson_init(&ipipe);
    bson_append_document_begin(&ipipe, "0", -1, &istage);
    bson_append_document_begin(&istage, "$indexStats", -1, &iop);
    bson_append_document_end(&istage, &iop);
    bson_append_document_end(&ipipe, &istage);

    cursor = mongoc_collection_aggregate(coll, MONGOC_QUERY_NONE, &ipipe, NULL, NULL);
    bson_destroy(&ipipe);

    printf("  %-30s  %-8s  %-10s  %s\n", "indexName", "accesses", "since", "key");
    print_sep();

    while (mongoc_cursor_next(cursor, &doc)) {
        char name[256] = "", since[64] = "";
        int64_t ops_cnt = 0;
        bu_str(doc, "name", name, sizeof(name));
        bu_nested_int64(doc, "accesses", "ops", &ops_cnt);
        bu_nested_str(doc, "accesses", "since", since, sizeof(since));
        printf("  %-30s  %-8lld  %-10s\n",
               bu_or_dash(name), (long long)ops_cnt, bu_or_dash(since));
    }

    mongoc_cursor_destroy(cursor);
    mongoc_collection_destroy(coll);
}

void cmd_tcbstats(Conn *c, const Args *a) {
    const char *db = (a->db_name && a->db_name[0]) ? a->db_name : "test";

    print_header("Per-Collection Storage and Latency Stats  [equiv: db2pd -tcbstats]");

    if (a->collection && a->collection[0]) {
        print_coll_stats(c->client, db, a->collection, a->scale);
    } else {
        /* iterate all collections in the database */
        mongoc_database_t *dbh = mongoc_client_get_database(c->client, db);
        bson_error_t err;
        char **names = mongoc_database_get_collection_names_with_opts(dbh, NULL, &err);
        if (!names) {
            print_error("Cannot list collections in '%s': %s", db, err.message);
        } else {
            for (int i = 0; names[i]; i++) {
                /* skip system collections */
                if (!strncmp(names[i], "system.", 7)) continue;
                print_coll_stats(c->client, db, names[i], a->scale);
            }
            bson_strfreev(names);
        }
        mongoc_database_destroy(dbh);
    }

    print_footer();
}
