#ifndef BSONUTIL_H
#define BSONUTIL_H

#include <bson/bson.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

/* Get numeric value (handles INT32, INT64, DOUBLE) */
bool bu_int64(const bson_t *doc, const char *key, int64_t *out);
bool bu_double(const bson_t *doc, const char *key, double *out);

/* Get string — copies at most buf_size-1 bytes */
bool bu_str(const bson_t *doc, const char *key, char *buf, size_t buf_size);

/* Get bool */
bool bu_bool(const bson_t *doc, const char *key, bool *out);

/* Nested: doc[k1][k2] */
bool bu_nested_int64(const bson_t *doc, const char *k1, const char *k2, int64_t *out);
bool bu_nested_double(const bson_t *doc, const char *k1, const char *k2, double *out);
bool bu_nested_str(const bson_t *doc, const char *k1, const char *k2, char *buf, size_t buf_size);
bool bu_nested_bool(const bson_t *doc, const char *k1, const char *k2, bool *out);

/* Deep: doc[k1][k2][k3] */
bool bu_deep_int64(const bson_t *doc, const char *k1, const char *k2, const char *k3, int64_t *out);

/* Get subdocument (caller must NOT call bson_destroy — points into parent memory) */
bool bu_subdoc(const bson_t *doc, const char *key, bson_t *subdoc);
bool bu_nested_subdoc(const bson_t *doc, const char *k1, const char *k2, bson_t *subdoc);

/* opid as printable string (handles INT32, INT64, UTF8) */
void bu_opid_str(const bson_t *op, char *buf, size_t buf_size);

/* Format bytes: scale=NULL → bytes, "mb" → MB, "gb" → GB */
void bu_fmt_bytes(double bytes, const char *scale, char *buf, size_t buf_size);

/* Return s if non-empty, otherwise "—" */
const char *bu_or_dash(const char *s);

/* BSON document → compact JSON string */
char *bu_to_json(const bson_t *doc);  /* caller must bson_free() the result */

#endif /* BSONUTIL_H */
