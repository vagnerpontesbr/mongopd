#include "connection.h"
#include "output.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

Conn conn_open(const Args *a) {
    mongoc_init();

    /* URI priority: -uri flag > MONGODB_URI env var > -host flag > localhost */
    char uri_buf[2048];
    const char *final_uri = NULL;

    if (a->uri && a->uri[0]) {
        final_uri = a->uri;
    } else {
        const char *env_uri = getenv("MONGODB_URI");
        if (env_uri && env_uri[0]) {
            final_uri = env_uri;
        } else if (a->host && a->host[0]) {
            if (a->username && a->username[0] && a->password) {
                snprintf(uri_buf, sizeof(uri_buf),
                         "mongodb://%s:%s@%s/?authSource=%s",
                         a->username, a->password, a->host,
                         a->authdb ? a->authdb : "admin");
            } else {
                snprintf(uri_buf, sizeof(uri_buf), "mongodb://%s", a->host);
            }
            final_uri = uri_buf;
        } else {
            final_uri = "mongodb://localhost:27017";
        }
    }

    bson_error_t err;
    mongoc_uri_t *uri_obj = mongoc_uri_new_with_error(final_uri, &err);
    if (!uri_obj) {
        print_error("Invalid URI: %s", err.message);
        exit(1);
    }

    mongoc_client_t *client = mongoc_client_new_from_uri(uri_obj);
    mongoc_uri_destroy(uri_obj);
    if (!client) {
        print_error("Failed to create MongoDB client");
        exit(1);
    }

    /* Ping to verify connectivity */
    bson_t *ping = BCON_NEW("ping", BCON_INT32(1));
    bson_t reply;
    if (!mongoc_client_command_simple(client, "admin", ping, NULL, &reply, &err)) {
        print_error("Cannot connect: %s", err.message);
        bson_destroy(ping);
        mongoc_client_destroy(client);
        mongoc_cleanup();
        exit(1);
    }
    bson_destroy(&reply);
    bson_destroy(ping);

    Conn c = { .client = client };
    return c;
}

void conn_close(Conn *c) {
    if (c->client) {
        mongoc_client_destroy(c->client);
        c->client = NULL;
    }
    mongoc_cleanup();
}

bool conn_admin_cmd(Conn *c, const bson_t *cmd, bson_t *reply, bson_error_t *err) {
    bool ok = mongoc_client_command_simple(c->client, "admin", cmd, NULL, reply, err);
    if (!ok) print_error("%s", err->message);
    return ok;
}

bool conn_db_cmd(Conn *c, const char *db_name, const bson_t *cmd,
                 bson_t *reply, bson_error_t *err) {
    bool ok = mongoc_client_command_simple(c->client, db_name, cmd, NULL, reply, err);
    if (!ok) print_error("%s", err->message);
    return ok;
}
