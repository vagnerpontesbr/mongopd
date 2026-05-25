#include "cmd_mempools.h"
#include "output.h"
#include "bsonutil.h"
#include <stdio.h>
#include <string.h>
#include <math.h>

/*
 * -mempools
 *
 * WiredTiger cache metrics and operation latency percentiles.
 *
 * Equivalent: db.adminCommand({ serverStatus: 1 })
 *   → wiredTiger.cache.*
 *   → opLatencies.reads/writes/commands
 */

/* ── latency percentile from opLatencies histogram ────────────────────── */

typedef struct { int64_t micros; int64_t count; } Bucket;
#define MAX_BUCKETS 512

static int collect_buckets(const bson_t *op_doc, Bucket *buckets) {
    bson_iter_t it;
    if (!bson_iter_init_find(&it, op_doc, "histogram") ||
        !BSON_ITER_HOLDS_ARRAY(&it)) return 0;

    bson_iter_t arr;
    if (!bson_iter_recurse(&it, &arr)) return 0;

    int n = 0;
    while (bson_iter_next(&arr) && n < MAX_BUCKETS) {
        if (!BSON_ITER_HOLDS_DOCUMENT(&arr)) continue;
        uint32_t len; const uint8_t *data;
        bson_iter_document(&arr, &len, &data);
        bson_t b; bson_init_static(&b, data, len);
        int64_t micros = 0, cnt = 0;
        bu_int64(&b, "micros", &micros);
        bu_int64(&b, "count",  &cnt);
        if (cnt <= 0) continue;
        buckets[n].micros = micros;
        buckets[n].count  = cnt;
        n++;
    }
    return n;
}

static double compute_pct(Bucket *buckets, int n, int64_t total, double pct) {
    if (n == 0 || total == 0) return -1.0;
    int64_t target = (int64_t)ceil((double)total * pct / 100.0);
    int64_t cumul = 0;
    for (int i = 0; i < n; i++) {
        cumul += buckets[i].count;
        if (cumul >= target) return (double)buckets[i].micros / 1000.0;
    }
    return (double)buckets[n-1].micros / 1000.0;
}

static void print_latency_section(const bson_t *status) {
    bson_t op_lat;
    if (!bu_subdoc(status, "opLatencies", &op_lat)) return;

    print_section("Latency Percentiles");
    printf("\n  %-12s  %10s  %10s  %10s  %10s  %10s\n",
           "opType", "avg(ms)", "p50(ms)", "p95(ms)", "p99(ms)", "totalOps");
    print_sep();

    const char *op_types[] = {"reads", "writes", "commands"};
    for (int i = 0; i < 3; i++) {
        bson_t od;
        if (!bu_subdoc(&op_lat, op_types[i], &od)) continue;

        int64_t ops = 0, latency = 0;
        bu_int64(&od, "ops",     &ops);
        bu_int64(&od, "latency", &latency);

        double avg_ms = (ops > 0) ? (double)latency / (double)ops / 1000.0 : 0.0;

        Bucket buckets[MAX_BUCKETS];
        int nb = collect_buckets(&od, buckets);

        double p50 = compute_pct(buckets, nb, ops, 50.0);
        double p95 = compute_pct(buckets, nb, ops, 95.0);
        double p99 = compute_pct(buckets, nb, ops, 99.0);

        printf("  %-12s  %10.3f  %10.3f  %10.3f  %10.3f  %10lld\n",
               op_types[i],
               avg_ms,
               p50 >= 0 ? p50 : 0.0,
               p95 >= 0 ? p95 : 0.0,
               p99 >= 0 ? p99 : 0.0,
               (long long)ops);
    }
}

void cmd_mempools(Conn *c, const Args *a) {
    (void)a;
    print_header("WiredTiger Cache and Latency Percentiles  [equiv: db2pd -mempools]");

    bson_t *cmd = BCON_NEW("serverStatus", BCON_INT32(1),
                           "repl",    BCON_INT32(0),
                           "metrics", BCON_INT32(0));
    bson_t reply; bson_error_t err;
    if (!conn_admin_cmd(c, cmd, &reply, &err)) {
        bson_destroy(cmd); print_footer(); return;
    }
    bson_destroy(cmd);

    /* ── WiredTiger cache ─────────────────────────────────────────────── */
    bson_t wt, cache;
    if (bu_subdoc(&reply, "wiredTiger", &wt) &&
        bu_subdoc(&wt, "cache", &cache)) {

        print_section("WiredTiger Cache");

        int64_t max_bytes = 0, cur_bytes = 0, dirty_bytes = 0;
        int64_t read_into = 0, written_from = 0, evicted = 0, evicted_unmod = 0;
        bu_int64(&cache, "maximum bytes configured",            &max_bytes);
        bu_int64(&cache, "bytes currently in the cache",        &cur_bytes);
        bu_int64(&cache, "tracked dirty bytes in the cache",    &dirty_bytes);
        bu_int64(&cache, "pages read into cache",               &read_into);
        bu_int64(&cache, "pages written from cache",            &written_from);
        bu_int64(&cache, "unmodified pages evicted",            &evicted_unmod);
        bu_int64(&cache, "modified pages evicted",              &evicted);

        double pct_used  = (max_bytes > 0) ? (double)cur_bytes   * 100.0 / (double)max_bytes : 0.0;
        double pct_dirty = (max_bytes > 0) ? (double)dirty_bytes  * 100.0 / (double)max_bytes : 0.0;

        char sbuf[32];
        bu_fmt_bytes((double)max_bytes,  "mb", sbuf, sizeof(sbuf));
        printf("  %-40s  %s\n",   "Max configured", sbuf);
        bu_fmt_bytes((double)cur_bytes,  "mb", sbuf, sizeof(sbuf));
        printf("  %-40s  %s  (%.1f%%)\n", "Currently in cache", sbuf, pct_used);
        bu_fmt_bytes((double)dirty_bytes,"mb", sbuf, sizeof(sbuf));
        printf("  %-40s  %s  (%.1f%%)\n", "Dirty bytes",        sbuf, pct_dirty);
        printf("  %-40s  %lld\n", "Pages read into cache",      (long long)read_into);
        printf("  %-40s  %lld\n", "Pages written from cache",   (long long)written_from);
        printf("  %-40s  %lld\n", "Modified pages evicted",     (long long)evicted);
        printf("  %-40s  %lld\n", "Unmodified pages evicted",   (long long)evicted_unmod);

        /* ── WiredTiger connection stats ─────────────────────────── */
        bson_t conn_stats;
        if (bu_subdoc(&wt, "connection", &conn_stats)) {
            int64_t files_open = 0;
            bu_int64(&conn_stats, "files currently open", &files_open);
            printf("  %-40s  %lld\n", "Files currently open", (long long)files_open);
        }
    } else {
        print_warn("WiredTiger cache stats not available (non-WT storage engine?).");
    }

    /* ── Latency percentiles ─────────────────────────────────────────── */
    print_latency_section(&reply);

    /* ── Memory summary ──────────────────────────────────────────────── */
    bson_t mem;
    if (bu_subdoc(&reply, "mem", &mem)) {
        print_section("Process Memory");
        int64_t res = 0, virt = 0;
        bu_int64(&mem, "resident", &res);
        bu_int64(&mem, "virtual",  &virt);
        printf("  %-28s  %lld MB\n", "Resident",  (long long)res);
        printf("  %-28s  %lld MB\n", "Virtual",   (long long)virt);
    }

    bson_destroy(&reply);
    print_footer();
}
