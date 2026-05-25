#include "cmd_indexes.h"
#include "output.h"
#include "bsonutil.h"
#include <stdio.h>
#include <string.h>

/*
 * -indexes [collection]
 *
 * Index footprint by collection: name, size, access count since last restart.
 *
 * Equivalent:
 *   db.collection.aggregate([{ $collStats: { storageStats: {} } }])
 *     → storageStats.indexSizes
 *   db.collection.aggregate([{ $indexStats: {} }])
 */

static void print_index_rows(mongoc_client_t *mc, const char *db_name,
                              const char *coll_name, const char *scale) {
    /* ── $indexStats for access counts ───────────────────────────────── */
    mongoc_collection_t *coll =
        mongoc_client_get_collection(mc, db_name, coll_name);

    bson_t ipipe, istage, iop;
    bson_init(&ipipe);
    bson_append_document_begin(&ipipe, "0", -1, &istage);
    bson_append_document_begin(&istage, "$indexStats", -1, &iop);
    bson_append_document_end(&istage, &iop);
    bson_append_document_end(&ipipe, &istage);

    mongoc_cursor_t *cursor =
        mongoc_collection_aggregate(coll, MONGOC_QUERY_NONE, &ipipe, NULL, NULL);
    bson_destroy(&ipipe);

    const bson_t *doc;
    while (mongoc_cursor_next(cursor, &doc)) {
        char name[256] = "";
        int64_t ops_cnt = 0;
        bu_str(doc, "name", name, sizeof(name));
        bu_nested_int64(doc, "accesses", "ops", &ops_cnt);

        /* try to get size from parent's storageStats.indexSizes.<name> later */
        printf("  %-35s  %-35s  %10lld\n",
               coll_name,
               bu_or_dash(name),
               (long long)ops_cnt);
    }

    mongoc_cursor_destroy(cursor);

    /* ── $collStats for per-index sizes ──────────────────────────────── */
    bson_t cpipe, cstage, ccs, css;
    bson_init(&cpipe);
    bson_append_document_begin(&cpipe, "0", -1, &cstage);
    bson_append_document_begin(&cstage, "$collStats", -1, &ccs);
    bson_append_document_begin(&ccs, "storageStats", -1, &css);
    bson_append_document_end(&ccs, &css);
    bson_append_document_end(&cstage, &ccs);
    bson_append_document_end(&cpipe, &cstage);

    cursor = mongoc_collection_aggregate(coll, MONGOC_QUERY_NONE, &cpipe, NULL, NULL);
    bson_destroy(&cpipe);

    while (mongoc_cursor_next(cursor, &doc)) {
        bson_t ss;
        if (!bu_subdoc(doc, "storageStats", &ss)) continue;

        bson_t idx_sizes;
        if (!bu_subdoc(&ss, "indexSizes", &idx_sizes)) continue;

        bson_iter_t it;
        bson_iter_init(&it, &idx_sizes);

        print_section("  Index sizes");
        while (bson_iter_next(&it)) {
            const char *iname = bson_iter_key(&it);
            int64_t sz = bson_iter_as_int64(&it);
            char sbuf[32];
            bu_fmt_bytes((double)sz, scale, sbuf, sizeof(sbuf));
            printf("    %-32s  %s\n", iname, sbuf);
        }
    }

    mongoc_cursor_destroy(cursor);
    mongoc_collection_destroy(coll);
}

void cmd_indexes(Conn *c, const Args *a) {
    const char *db = (a->db_name && a->db_name[0]) ? a->db_name : "test";

    print_header("Index Footprint  [equiv: db2pd -indexes]");

    printf("\n  %-35s  %-35s  %10s\n", "Collection", "Index", "accesses");
    print_sep();

    if (a->collection && a->collection[0]) {
        print_index_rows(c->client, db, a->collection, a->scale);
    } else {
        mongoc_database_t *dbh = mongoc_client_get_database(c->client, db);
        bson_error_t err;
        char **names = mongoc_database_get_collection_names_with_opts(dbh, NULL, &err);
        if (!names) {
            print_error("Cannot list collections: %s", err.message);
        } else {
            for (int i = 0; names[i]; i++) {
                if (!strncmp(names[i], "system.", 7)) continue;
                print_index_rows(c->client, db, names[i], a->scale);
            }
            bson_strfreev(names);
        }
        mongoc_database_destroy(dbh);
    }

    print_footer();
}
