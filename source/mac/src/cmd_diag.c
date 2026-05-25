#include "cmd_diag.h"
#include "output.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <regex.h>
#include <errno.h>
#include <mongoc/mongoc.h>
#include "connection.h"
#include "bsonutil.h"

/*
 * -diag
 *
 * Scan the last N lines of the mongod log file for:
 *   - OOM / out-of-memory events
 *   - Segfaults / fatal errors
 *   - Election events
 *   - Replication state changes
 *   - Slow operations (millis > threshold)
 *   - WiredTiger eviction warnings
 *
 * The log path is discovered from serverStatus.systemLog.path.
 * Falls back to common macOS locations if not available.
 */

#define LOG_LINE_MAX 4096

typedef struct {
    const char *pattern;
    const char *label;
} Pattern;

static const Pattern patterns[] = {
    { "Out of memory",          "OOM" },
    { "oom",                    "OOM" },
    { "Segmentation fault",     "SEGFAULT" },
    { "Fatal assertion",        "FATAL" },
    { "BSONObj size",           "BSON_OVERSIZED" },
    { "election",               "ELECTION" },
    { "stepped down",           "STEP_DOWN" },
    { "became primary",         "PRIMARY" },
    { "became secondary",       "SECONDARY" },
    { "Slow query",             "SLOW_OP" },
    { "planSummary",            "SLOW_OP" },
    { "eviction server",        "WT_EVICTION" },
    { "cache overflow",         "WT_CACHE" },
    { "connection reset",       "CONN_RESET" },
    { "too many open files",    "FD_LIMIT" },
};
#define N_PATTERNS ((int)(sizeof(patterns) / sizeof(patterns[0])))

/* Discover log file path from serverStatus */
static bool get_log_path(Conn *c, char *buf, size_t sz) {
    bson_t *cmd = BCON_NEW("serverStatus", BCON_INT32(1),
                           "metrics", BCON_INT32(0));
    bson_t reply; bson_error_t err;
    bool found = false;

    if (conn_admin_cmd(c, cmd, &reply, &err)) {
        bson_t syslog;
        if (bu_subdoc(&reply, "systemLog", &syslog)) {
            if (bu_str(&syslog, "path", buf, sz) && buf[0]) {
                found = true;
            }
        }
        bson_destroy(&reply);
    }
    bson_destroy(cmd);

    if (!found) {
        /* fallback: common macOS brew path */
        const char *fallback[] = {
            "/usr/local/var/log/mongodb/mongo.log",
            "/opt/homebrew/var/log/mongodb/mongo.log",
            "/var/log/mongodb/mongod.log",
        };
        for (int i = 0; i < 3; i++) {
            FILE *f = fopen(fallback[i], "r");
            if (f) { fclose(f); snprintf(buf, sz, "%s", fallback[i]); return true; }
        }
    }
    return found;
}

/* Compile regex patterns */
static regex_t compiled[N_PATTERNS];

static void compile_patterns(void) {
    for (int i = 0; i < N_PATTERNS; i++) {
        regcomp(&compiled[i], patterns[i].pattern,
                REG_EXTENDED | REG_ICASE | REG_NOSUB);
    }
}

static void free_patterns(void) {
    for (int i = 0; i < N_PATTERNS; i++) regfree(&compiled[i]);
}

typedef struct {
    int oom, segfault, fatal, election, slow_op, wt_eviction, other;
    int total_matches;
} Counts;

void cmd_diag(Conn *c, const Args *a) {
    print_header("Log Diagnostic Scan  [equiv: db2pd -diag]");

    char log_path[1024] = "";
    if (!get_log_path(c, log_path, sizeof(log_path)) || !log_path[0]) {
        print_warn("Cannot determine mongod log path.");
        print_warn("Set systemLog.path in mongod.conf and restart, or pass -host with a local instance.");
        print_footer();
        return;
    }

    printf("  Log file : %s\n", log_path);
    printf("  Scanning : last %d lines\n\n", a->lines);

    FILE *fp = fopen(log_path, "r");
    if (!fp) {
        print_error("Cannot open log file '%s': %s", log_path, strerror(errno));
        print_footer();
        return;
    }

    /* Tail the file: collect last a->lines lines into a ring buffer */
    int max_lines = a->lines > 0 ? a->lines : 5000;
    char **ring = calloc((size_t)max_lines, sizeof(char *));
    if (!ring) { fclose(fp); print_error("out of memory"); return; }

    int head = 0, total_read = 0;
    char line[LOG_LINE_MAX];

    while (fgets(line, sizeof(line), fp)) {
        size_t ln = strlen(line);
        /* store a copy in the ring buffer */
        free(ring[head]);
        ring[head] = malloc(ln + 1);
        if (ring[head]) memcpy(ring[head], line, ln + 1);
        head = (head + 1) % max_lines;
        total_read++;
    }
    fclose(fp);

    /* Compile regex patterns */
    compile_patterns();

    /* Scan ring buffer in order */
    Counts counts = {0, 0, 0, 0, 0, 0, 0, 0};
    int start = (total_read >= max_lines) ? head : 0;
    int actual = (total_read < max_lines) ? total_read : max_lines;

    printf("  %-12s  %s\n", "Category", "Log line");
    print_sep();

    for (int i = 0; i < actual; i++) {
        int idx = (start + i) % max_lines;
        const char *l = ring[idx];
        if (!l) continue;

        for (int p = 0; p < N_PATTERNS; p++) {
            if (regexec(&compiled[p], l, 0, NULL, 0) == 0) {
                /* strip trailing newline for display */
                char disp[200];
                strncpy(disp, l, sizeof(disp) - 1);
                disp[sizeof(disp) - 1] = '\0';
                disp[strcspn(disp, "\n")] = '\0';

                printf("  %-12s  %.140s\n", patterns[p].label, disp);
                counts.total_matches++;

                /* tally by category */
                if (!strcmp(patterns[p].label, "OOM"))        counts.oom++;
                else if (!strcmp(patterns[p].label, "SEGFAULT") ||
                         !strcmp(patterns[p].label, "FATAL"))  counts.segfault++;
                else if (!strcmp(patterns[p].label, "ELECTION") ||
                         !strcmp(patterns[p].label, "PRIMARY")  ||
                         !strcmp(patterns[p].label, "SECONDARY")||
                         !strcmp(patterns[p].label, "STEP_DOWN"))counts.election++;
                else if (!strcmp(patterns[p].label, "SLOW_OP")) counts.slow_op++;
                else if (!strncmp(patterns[p].label, "WT_", 3)) counts.wt_eviction++;
                else counts.other++;

                break; /* only count first matching pattern per line */
            }
        }
    }

    free_patterns();
    for (int i = 0; i < max_lines; i++) free(ring[i]);
    free(ring);

    /* ── Summary ──────────────────────────────────────────────────────── */
    printf("\n");
    print_section("Summary");
    printf("  %-28s  %d\n", "Lines scanned",    actual);
    printf("  %-28s  %d\n", "Total matches",    counts.total_matches);
    printf("  %-28s  %d\n", "OOM events",       counts.oom);
    printf("  %-28s  %d\n", "Fatal/Segfaults",  counts.segfault);
    printf("  %-28s  %d\n", "Election events",  counts.election);
    printf("  %-28s  %d\n", "Slow operations",  counts.slow_op);
    printf("  %-28s  %d\n", "WT eviction",      counts.wt_eviction);

    if (counts.total_matches == 0) print_info("No notable events found in the last %d log lines.", actual);

    print_footer();
}
