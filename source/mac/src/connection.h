#ifndef CONNECTION_H
#define CONNECTION_H

#include <mongoc/mongoc.h>
#include "args.h"

typedef struct {
    mongoc_client_t *client;
} Conn;

/* Initialise libmongoc, build connection URI and return a connected client.
   Exits the process on failure. */
Conn conn_open(const Args *a);

/* Destroy the client and clean up libmongoc. */
void conn_close(Conn *c);

/* Run a command on the "admin" database. Returns false on error and prints it. */
bool conn_admin_cmd(Conn *c, const bson_t *cmd, bson_t *reply, bson_error_t *err);

/* Run a command on a named database. */
bool conn_db_cmd(Conn *c, const char *db_name, const bson_t *cmd,
                 bson_t *reply, bson_error_t *err);

#endif /* CONNECTION_H */
