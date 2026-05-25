#include "cmd_kill.h"
#include "output.h"
#include "bsonutil.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/*
 * -kill <opid>
 *
 * Terminate a running operation.
 *
 * Equivalent: db.adminCommand({ killOp: 1, op: <opid> })
 *
 * opid can be an integer or a string like "shard01:12345" on sharded clusters.
 */

void cmd_kill(Conn *c, const Args *a) {
    print_header("Kill Operation  [equiv: db2pd -kill]");

    if (!a->kill_opid || !a->kill_opid[0]) {
        print_error("No opid provided. Use: mongopd -kill <opid>");
        print_footer();
        return;
    }

    /* Confirm with user */
    printf("  Target opid: %s%s%s\n", C_YELLOW(), a->kill_opid, C_RESET());
    printf("  Proceed? [y/N] ");
    fflush(stdout);

    char ans[8];
    if (!fgets(ans, sizeof(ans), stdin)) {
        print_warn("Aborted (no input).");
        print_footer();
        return;
    }
    if (ans[0] != 'y' && ans[0] != 'Y') {
        print_warn("Aborted.");
        print_footer();
        return;
    }

    /* Build killOp command — opid may be integer or string */
    bson_t *cmd;
    char *end;
    long long int_opid = strtoll(a->kill_opid, &end, 10);
    if (*end == '\0') {
        /* numeric */
        cmd = BCON_NEW("killOp", BCON_INT32(1),
                       "op",     BCON_INT64(int_opid));
    } else {
        /* string (sharded: "shard:opid") */
        cmd = BCON_NEW("killOp", BCON_INT32(1),
                       "op",     BCON_UTF8(a->kill_opid));
    }

    bson_t reply; bson_error_t err;
    if (conn_admin_cmd(c, cmd, &reply, &err)) {
        int64_t info = 0;
        bu_int64(&reply, "info", &info);
        print_info("killOp sent for opid %s. Response: %lld",
                   a->kill_opid, (long long)info);
        bson_destroy(&reply);
    }
    bson_destroy(cmd);

    print_footer();
}
