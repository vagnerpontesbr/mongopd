#ifndef ARGS_H
#define ARGS_H

#include <stdbool.h>

typedef struct {
    /* connection */
    const char *uri;
    const char *host;
    const char *username;
    const char *password;
    const char *authdb;
    const char *db_name;

    /* diagnostic flags */
    bool flag_locks;
    bool flag_locks_wait;   /* -locks wait */
    bool flag_wlocks;
    bool flag_applications;
    bool flag_agents;
    bool flag_dynamic;
    bool flag_tcbstats;
    bool flag_tables;
    bool flag_indexes;
    bool flag_mempools;
    bool flag_transactions;
    bool flag_utilities;
    bool flag_reorgs;
    bool flag_hadr;
    bool flag_stat;
    bool flag_kill;
    bool flag_osinfo;
    bool flag_diag;
    bool flag_sharding;
    bool flag_help;

    /* modifiers */
    int    secs;           /* -secs <n>      */
    int    slowms;         /* -slowms <ms>   */
    const char *profiling; /* -profiling on|off */
    int    limit;          /* -limit <n>     */
    const char *scale;     /* -scale mb|gb   */
    int    interval;       /* -n <seconds>   */
    int    lines;          /* -lines <n>     */
    const char *kill_opid; /* -kill <opid>   */
    const char *collection;/* optional collection for tcbstats/tables/indexes */

    bool no_color;

    int dispatch_count;
} Args;

void args_init(Args *a);
void args_parse(Args *a, int argc, char **argv);
void args_print_help(void);

#endif /* ARGS_H */
