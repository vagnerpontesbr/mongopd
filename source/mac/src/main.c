#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "args.h"
#include "connection.h"
#include "output.h"
#include "bsonutil.h"

#include "cmd_locks.h"
#include "cmd_wlocks.h"
#include "cmd_applications.h"
#include "cmd_agents.h"
#include "cmd_dynamic.h"
#include "cmd_tcbstats.h"
#include "cmd_tables.h"
#include "cmd_indexes.h"
#include "cmd_mempools.h"
#include "cmd_transactions.h"
#include "cmd_utilities.h"
#include "cmd_reorgs.h"
#include "cmd_hadr.h"
#include "cmd_stat.h"
#include "cmd_kill.h"
#include "cmd_osinfo.h"
#include "cmd_diag.h"
#include "cmd_sharding.h"

int main(int argc, char **argv) {
    Args a;
    args_init(&a);
    args_parse(&a, argc, argv);

    /* Apply --no-color early */
    g_no_color = a.no_color;

    if (a.flag_help || a.dispatch_count == 0) {
        args_print_help();
        return 0;
    }

    /* -stat replaces the process with mongostat — no MongoDB connection needed */
    if (a.flag_stat) {
        cmd_stat(NULL, &a);
        /* not reached */
        return 0;
    }

    Conn c = conn_open(&a);

    if (a.flag_locks)        cmd_locks(&c, &a);
    if (a.flag_wlocks)       cmd_wlocks(&c, &a);
    if (a.flag_applications) cmd_applications(&c, &a);
    if (a.flag_agents)       cmd_agents(&c, &a);
    if (a.flag_dynamic)      cmd_dynamic(&c, &a);
    if (a.flag_tcbstats)     cmd_tcbstats(&c, &a);
    if (a.flag_tables)       cmd_tables(&c, &a);
    if (a.flag_indexes)      cmd_indexes(&c, &a);
    if (a.flag_mempools)     cmd_mempools(&c, &a);
    if (a.flag_transactions) cmd_transactions(&c, &a);
    if (a.flag_utilities)    cmd_utilities(&c, &a);
    if (a.flag_reorgs)       cmd_reorgs(&c, &a);
    if (a.flag_hadr)         cmd_hadr(&c, &a);
    if (a.flag_kill)         cmd_kill(&c, &a);
    if (a.flag_osinfo)       cmd_osinfo(&c, &a);
    if (a.flag_diag)         cmd_diag(&c, &a);
    if (a.flag_sharding)     cmd_sharding(&c, &a);

    conn_close(&c);
    return 0;
}
