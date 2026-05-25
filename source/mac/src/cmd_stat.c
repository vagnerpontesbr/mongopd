#include "cmd_stat.h"
#include "output.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/*
 * -stat
 *
 * Real-time throughput monitor.  Delegates to the `mongostat` binary via
 * execvp(), replacing the current process.
 *
 * Equivalent: mongostat --uri=<uri> <interval>
 */

void cmd_stat(Conn *c, const Args *a) {
    (void)c;

    /* build argv for mongostat */
    const char *argv_buf[32];
    int ai = 0;
    char uri_buf[2048];
    char interval_buf[16];

    argv_buf[ai++] = "mongostat";

    /* URI flag */
    if (a->uri && a->uri[0]) {
        snprintf(uri_buf, sizeof(uri_buf), "--uri=%s", a->uri);
        argv_buf[ai++] = uri_buf;
    } else {
        const char *env_uri = getenv("MONGODB_URI");
        if (env_uri && env_uri[0]) {
            snprintf(uri_buf, sizeof(uri_buf), "--uri=%s", env_uri);
            argv_buf[ai++] = uri_buf;
        } else if (a->host && a->host[0]) {
            argv_buf[ai++] = "--host";
            argv_buf[ai++] = a->host;
            if (a->username && a->username[0]) {
                argv_buf[ai++] = "-u"; argv_buf[ai++] = a->username;
            }
            if (a->password && a->password[0]) {
                argv_buf[ai++] = "-p"; argv_buf[ai++] = a->password;
            }
            if (a->authdb && a->authdb[0]) {
                argv_buf[ai++] = "--authenticationDatabase";
                argv_buf[ai++] = a->authdb;
            }
        }
    }

    /* interval as positional argument */
    snprintf(interval_buf, sizeof(interval_buf), "%d", a->interval);
    argv_buf[ai++] = interval_buf;
    argv_buf[ai]   = NULL;

    execvp("mongostat", (char *const *)argv_buf);

    /* only reached if exec fails */
    perror("execvp(mongostat)");
    fprintf(stderr,
            "error: 'mongostat' not found in PATH.\n"
            "Install MongoDB Database Tools: https://www.mongodb.com/try/download/database-tools\n");
    exit(1);
}
