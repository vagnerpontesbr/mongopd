#include "args.h"
#include "output.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void args_init(Args *a) {
    memset(a, 0, sizeof(*a));
    a->authdb    = "admin";
    a->slowms    = 200;
    a->limit     = 20;
    a->interval  = 5;
    a->lines     = 5000;
    a->secs      = 0;
}

static const char *next_arg(int *i, int argc, char **argv, const char *flag) {
    if (*i + 1 >= argc) {
        fprintf(stderr, "error: %s requires a value\n", flag);
        exit(1);
    }
    return argv[++(*i)];
}

void args_parse(Args *a, int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        const char *arg = argv[i];

        /* ── connection ──────────────────────────────────── */
        if      (!strcmp(arg, "-uri"))    { a->uri      = next_arg(&i, argc, argv, "-uri");    }
        else if (!strcmp(arg, "-host"))   { a->host     = next_arg(&i, argc, argv, "-host");   }
        else if (!strcmp(arg, "-u"))      { a->username = next_arg(&i, argc, argv, "-u");      }
        else if (!strcmp(arg, "-p"))      { a->password = next_arg(&i, argc, argv, "-p");      }
        else if (!strcmp(arg, "-authdb")) { a->authdb   = next_arg(&i, argc, argv, "-authdb"); }
        else if (!strcmp(arg, "-db"))     { a->db_name  = next_arg(&i, argc, argv, "-db");     }

        /* ── diagnostic flags ────────────────────────────── */
        else if (!strcmp(arg, "-locks")) {
            a->flag_locks = true;
            a->dispatch_count++;
            /* peek at next arg: if it is "wait" consume it */
            if (i + 1 < argc && !strcmp(argv[i+1], "wait")) {
                a->flag_locks_wait = true;
                i++;
            }
        }
        else if (!strcmp(arg, "-wlocks"))       { a->flag_wlocks       = true; a->dispatch_count++; }
        else if (!strcmp(arg, "-applications")) { a->flag_applications  = true; a->dispatch_count++; }
        else if (!strcmp(arg, "-agents"))       { a->flag_agents        = true; a->dispatch_count++; }
        else if (!strcmp(arg, "-dynamic"))      { a->flag_dynamic       = true; a->dispatch_count++; }
        else if (!strcmp(arg, "-tcbstats")) {
            a->flag_tcbstats = true; a->dispatch_count++;
            if (i + 1 < argc && argv[i+1][0] != '-') a->collection = argv[++i];
        }
        else if (!strcmp(arg, "-tables")) {
            a->flag_tables = true; a->dispatch_count++;
            if (i + 1 < argc && argv[i+1][0] != '-') a->collection = argv[++i];
        }
        else if (!strcmp(arg, "-indexes")) {
            a->flag_indexes = true; a->dispatch_count++;
            if (i + 1 < argc && argv[i+1][0] != '-') a->collection = argv[++i];
        }
        else if (!strcmp(arg, "-mempools"))    { a->flag_mempools    = true; a->dispatch_count++; }
        else if (!strcmp(arg, "-transactions")){ a->flag_transactions = true; a->dispatch_count++; }
        else if (!strcmp(arg, "-utilities"))   { a->flag_utilities   = true; a->dispatch_count++; }
        else if (!strcmp(arg, "-reorgs"))      { a->flag_reorgs      = true; a->dispatch_count++; }
        else if (!strcmp(arg, "-hadr"))        { a->flag_hadr        = true; a->dispatch_count++; }
        else if (!strcmp(arg, "-stat"))        { a->flag_stat        = true; a->dispatch_count++; }
        else if (!strcmp(arg, "-kill")) {
            a->flag_kill  = true;
            a->kill_opid  = next_arg(&i, argc, argv, "-kill");
            a->dispatch_count++;
        }
        else if (!strcmp(arg, "-osinfo"))   { a->flag_osinfo   = true; a->dispatch_count++; }
        else if (!strcmp(arg, "-diag"))     { a->flag_diag     = true; a->dispatch_count++; }
        else if (!strcmp(arg, "-sharding")) { a->flag_sharding = true; a->dispatch_count++; }
        else if (!strcmp(arg, "-help") || !strcmp(arg, "--help") || !strcmp(arg, "-h")) {
            a->flag_help = true;
        }

        /* ── modifiers ────────────────────────────────────── */
        else if (!strcmp(arg, "-secs"))      { a->secs      = atoi(next_arg(&i, argc, argv, "-secs"));     }
        else if (!strcmp(arg, "-slowms"))    { a->slowms    = atoi(next_arg(&i, argc, argv, "-slowms"));   }
        else if (!strcmp(arg, "-profiling")) { a->profiling = next_arg(&i, argc, argv, "-profiling");      }
        else if (!strcmp(arg, "-limit"))     { a->limit     = atoi(next_arg(&i, argc, argv, "-limit"));    }
        else if (!strcmp(arg, "-scale"))     { a->scale     = next_arg(&i, argc, argv, "-scale");          }
        else if (!strcmp(arg, "-n"))         { a->interval  = atoi(next_arg(&i, argc, argv, "-n"));        }
        else if (!strcmp(arg, "-lines"))     { a->lines     = atoi(next_arg(&i, argc, argv, "-lines"));    }
        else if (!strcmp(arg, "--no-color")) { a->no_color  = true;                                        }
        else {
            fprintf(stderr, "warning: unknown option '%s' (ignored)\n", arg);
        }
    }
}

void args_print_help(void) {
    printf("\n"
        "\033[1m\033[36mmongopd\033[0m 1.0.0 — MongoDB Problem & Determination\n"
        "Mirrors db2pd diagnostic flags. Each flag maps to the equivalent MongoDB command.\n\n"
        "\033[1mUSAGE\033[0m\n"
        "  mongopd -db <database> [connection] [diagnostic-flag] [modifiers]\n"
        "  mongopd -help\n\n"
        "\033[1mCONNECTION FLAGS\033[0m\n"
        "  -host <host:port>   Target host                  (default: localhost:27017)\n"
        "  -uri <uri>          Full MongoDB URI\n"
        "  -u <username>       Username\n"
        "  -p <password>       Password\n"
        "  -authdb <database>  Authentication database       (default: admin)\n\n"
        "\033[1mENVIRONMENT\033[0m\n"
        "  MONGODB_URI         Full URI used when -uri and -host are not set\n\n"
        "\033[1mDIAGNOSTIC FLAGS\033[0m\n"
        "  -locks [wait]       Lock waiters and blocked operations\n"
        "  -wlocks             All lock-related active operations\n"
        "  -applications       Active sessions and connections\n"
        "  -agents             Engine agent and thread activity\n"
        "  -dynamic            Active queries and profiler slow operations\n"
        "  -tcbstats [coll]    Per-collection storage, latency and index usage\n"
        "  -tables [coll]      Collection footprint and storage stats\n"
        "  -indexes [coll]     Index footprint by collection\n"
        "  -mempools           WiredTiger cache and latency percentiles\n"
        "  -transactions       In-flight transactions and counters\n"
        "  -utilities          Active utilities and long-running internal tasks\n"
        "  -reorgs             Background index builds and data movement\n"
        "  -hadr               Replica set health and replication state\n"
        "  -stat               Real-time throughput monitor (mongostat)\n"
        "  -kill <opid>        Terminate an operation\n"
        "  -osinfo             Host CPU, memory, disk and I/O metrics\n"
        "  -diag               Scan mongod log for OOM, crashes and elections\n"
        "  -sharding           Sharding topology, balancer state (requires mongos)\n\n"
        "\033[1mMODIFIERS\033[0m\n"
        "  -db <database>      Target database\n"
        "  -secs <n>           Filter ops running longer than N seconds\n"
        "  -slowms <ms>        Profiler threshold for -dynamic      (default: 200)\n"
        "  -profiling on|off   Enable/disable profiler\n"
        "  -limit <n>          Profiler result limit                (default: 20)\n"
        "  -scale mb|gb        Output scale for -tables and -indexes\n"
        "  -n <seconds>        Sampling interval for -stat          (default: 5)\n"
        "  -lines <n>          Log lines scanned by -diag           (default: 5000)\n"
        "  --no-color          Disable ANSI color output\n\n"
        "\033[1mDISCLAIMER\033[0m\n"
        "  This tool is NOT official MongoDB software and is NOT supported by MongoDB\n"
        "  Technical Support. It was created to assist DB2 DBAs in their transition\n"
        "  to MongoDB. USE IN PRODUCTION WITH CAUTION.\n\n");
}
