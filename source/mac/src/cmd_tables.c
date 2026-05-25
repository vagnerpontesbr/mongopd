#include "cmd_tables.h"
#include "output.h"
#include "bsonutil.h"
#include <stdio.h>
#include <string.h>

/*
 * -tables [collection]
 *
 * Collection footprint: data size, index size, document count.
 *
 * Equivalent: db.collection.aggregate([{ $collStats: { storageStats: {}, count: {} } }])
 */

static void print_table_row(mongoc_client_t *mc, const char *db_name,
                             const char *coll_name, const char *scale) {
    mongoc_collection_t *coll =
        mongoc_client_get_collection(mc, db_name, coll_name);

    bson_t pipeline, stage, cs, ss, cnt_doc;
    bson_init(&pipeline);
    bson_append_document_begin(&pipeline, "0", -1, &stage);
    bson_append_document_begin(&stage, "$collStats", -1, &cs);
    bson_append_document_begin(&cs, "storageStats", -1, &ss);
    bson_append_document_end(&cs, &ss);
    bson_append_document_begin(&cs, "count", -1, &cnt_doc);
    bson_append_document_end(&cs, &cnt_doc);
    bson_append_document_end(&stage, &cs);
    bson_append_document_end(&pipeline, &stage);

    mongoc_cursor_t *cursor =
        mongoc_collection_aggregate(coll, MONGOC_QUERY_NONE, &pipeline, NULL, NULL);
    bson_destroy(&pipeline);

    const bson_t *doc;
    while (mongoc_cursor_next(cursor, &doc)) {
        bson_t ss_doc;
        if (!bu_subdoc(doc, "storageStats", &ss_doc)) continue;

        int64_t data_sz = 0, idx_sz = 0, cnt = 0, avg = 0, free_sz = 0;
        bu_int64(&ss_doc, "size",           &data_sz);
        bu_int64(&ss_doc, "totalIndexSize", &idx_sz);
        bu_int64(&ss_doc, "count",          &cnt);
        bu_int64(&ss_doc, "avgObjSize",     &avg);
        bu_int64(&ss_doc, "freeStorageSize",&free_sz);

        char d[32], ix[32], av[32], fr[32];
        bu_fmt_bytes((double)data_sz,  scale, d,  sizeof(d));
        bu_fmt_bytes((double)idx_sz,   scale, ix, sizeof(ix));
        bu_fmt_bytes((double)avg,      scale, av, sizeof(av));
        bu_fmt_bytes((double)free_sz,  scale, fr, sizeof(fr));

        printf("  %-35s  %10s  %10s  %10lld  %10s  %10s\n",
               coll_name,
               d, ix,
               (long long)cnt,
               av, fr);
    }

    mongoc_cursor_destroy(cursor);
    mongoc_collection_destroy(coll);
}

void cmd_tables(Conn *c, const Args *a) {
    const char *db = (a->db_name && a->db_name[0]) ? a->db_name : "test";

    print_header("Collection Footprint  [equiv: db2pd -tables]");

    printf("\n  %-35s  %10s  %10s  %10s  %10s  %10s\n",
           "Collection", "dataSize", "indexSize", "count", "avgObjSz", "freeSz");
    print_sep();

    if (a->collection && a->collection[0]) {
        print_table_row(c->client, db, a->collection, a->scale);
    } else {
        mongoc_database_t *dbh = mongoc_client_get_database(c->client, db);
        bson_error_t err;
        char **names = mongoc_database_get_collection_names_with_opts(dbh, NULL, &err);
        if (!names) {
            print_error("Cannot list collections: %s", err.message);
        } else {
            for (int i = 0; names[i]; i++) {
                print_table_row(c->client, db, names[i], a->scale);
            }
            bson_strfreev(names);
        }
        mongoc_database_destroy(dbh);
    }

    print_footer();
}
