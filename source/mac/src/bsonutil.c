#include "bsonutil.h"
#include <stdio.h>
#include <string.h>

/* ── numeric ─────────────────────────────────────────────────────────────── */

bool bu_int64(const bson_t *doc, const char *key, int64_t *out) {
    bson_iter_t it;
    if (!bson_iter_init_find(&it, doc, key)) return false;
    *out = bson_iter_as_int64(&it);
    return true;
}

bool bu_double(const bson_t *doc, const char *key, double *out) {
    bson_iter_t it;
    if (!bson_iter_init_find(&it, doc, key)) return false;
    bson_type_t t = bson_iter_type(&it);
    if (t == BSON_TYPE_DOUBLE)  { *out = bson_iter_double(&it); return true; }
    if (t == BSON_TYPE_INT32)   { *out = (double)bson_iter_int32(&it); return true; }
    if (t == BSON_TYPE_INT64)   { *out = (double)bson_iter_int64(&it); return true; }
    return false;
}

/* ── string ──────────────────────────────────────────────────────────────── */

bool bu_str(const bson_t *doc, const char *key, char *buf, size_t sz) {
    bson_iter_t it;
    if (!bson_iter_init_find(&it, doc, key)) return false;
    if (!BSON_ITER_HOLDS_UTF8(&it)) return false;
    uint32_t len;
    const char *s = bson_iter_utf8(&it, &len);
    if (!s) return false;
    snprintf(buf, sz, "%.*s", (int)len, s);
    return true;
}

/* ── bool ────────────────────────────────────────────────────────────────── */

bool bu_bool(const bson_t *doc, const char *key, bool *out) {
    bson_iter_t it;
    if (!bson_iter_init_find(&it, doc, key)) return false;
    if (!BSON_ITER_HOLDS_BOOL(&it)) {
        /* also accept int truthy */
        *out = (bson_iter_as_int64(&it) != 0);
        return true;
    }
    *out = bson_iter_bool(&it);
    return true;
}

/* ── nested helpers ──────────────────────────────────────────────────────── */

static bool _descend(const bson_t *doc, const char *k, bson_iter_t *child_out) {
    bson_iter_t it;
    if (!bson_iter_init_find(&it, doc, k)) return false;
    if (!BSON_ITER_HOLDS_DOCUMENT(&it)) return false;
    return bson_iter_recurse(&it, child_out);
}

bool bu_nested_int64(const bson_t *doc, const char *k1, const char *k2, int64_t *out) {
    bson_iter_t child;
    if (!_descend(doc, k1, &child)) return false;
    if (!bson_iter_find(&child, k2)) return false;
    *out = bson_iter_as_int64(&child);
    return true;
}

bool bu_nested_double(const bson_t *doc, const char *k1, const char *k2, double *out) {
    bson_iter_t child;
    if (!_descend(doc, k1, &child)) return false;
    if (!bson_iter_find(&child, k2)) return false;
    bson_type_t t = bson_iter_type(&child);
    if (t == BSON_TYPE_DOUBLE) { *out = bson_iter_double(&child); return true; }
    if (t == BSON_TYPE_INT32)  { *out = (double)bson_iter_int32(&child); return true; }
    if (t == BSON_TYPE_INT64)  { *out = (double)bson_iter_int64(&child); return true; }
    return false;
}

bool bu_nested_str(const bson_t *doc, const char *k1, const char *k2,
                   char *buf, size_t sz) {
    bson_iter_t child;
    if (!_descend(doc, k1, &child)) return false;
    if (!bson_iter_find(&child, k2)) return false;
    if (!BSON_ITER_HOLDS_UTF8(&child)) return false;
    uint32_t len;
    const char *s = bson_iter_utf8(&child, &len);
    if (!s) return false;
    snprintf(buf, sz, "%.*s", (int)len, s);
    return true;
}

bool bu_nested_bool(const bson_t *doc, const char *k1, const char *k2, bool *out) {
    bson_iter_t child;
    if (!_descend(doc, k1, &child)) return false;
    if (!bson_iter_find(&child, k2)) return false;
    *out = (bson_iter_as_int64(&child) != 0);
    return true;
}

bool bu_deep_int64(const bson_t *doc, const char *k1, const char *k2, const char *k3,
                   int64_t *out) {
    bson_iter_t it1, it2, it3;
    if (!bson_iter_init_find(&it1, doc, k1)) return false;
    if (!BSON_ITER_HOLDS_DOCUMENT(&it1)) return false;
    if (!bson_iter_recurse(&it1, &it2)) return false;
    if (!bson_iter_find(&it2, k2)) return false;
    if (!BSON_ITER_HOLDS_DOCUMENT(&it2)) return false;
    if (!bson_iter_recurse(&it2, &it3)) return false;
    if (!bson_iter_find(&it3, k3)) return false;
    *out = bson_iter_as_int64(&it3);
    return true;
}

/* ── subdoc ──────────────────────────────────────────────────────────────── */

bool bu_subdoc(const bson_t *doc, const char *key, bson_t *subdoc) {
    bson_iter_t it;
    if (!bson_iter_init_find(&it, doc, key)) return false;
    if (!BSON_ITER_HOLDS_DOCUMENT(&it)) return false;
    uint32_t len; const uint8_t *data;
    bson_iter_document(&it, &len, &data);
    bson_init_static(subdoc, data, len);
    return true;
}

bool bu_nested_subdoc(const bson_t *doc, const char *k1, const char *k2, bson_t *subdoc) {
    bson_t parent;
    if (!bu_subdoc(doc, k1, &parent)) return false;
    return bu_subdoc(&parent, k2, subdoc);
}

/* ── opid ────────────────────────────────────────────────────────────────── */

void bu_opid_str(const bson_t *op, char *buf, size_t sz) {
    bson_iter_t it;
    if (!bson_iter_init_find(&it, op, "opid")) { snprintf(buf, sz, "—"); return; }
    bson_type_t t = bson_iter_type(&it);
    if (t == BSON_TYPE_INT32)   snprintf(buf, sz, "%d",   bson_iter_int32(&it));
    else if (t == BSON_TYPE_INT64)  snprintf(buf, sz, "%lld", (long long)bson_iter_int64(&it));
    else if (t == BSON_TYPE_UTF8) {
        uint32_t len;
        const char *s = bson_iter_utf8(&it, &len);
        snprintf(buf, sz, "%.*s", (int)len, s);
    } else snprintf(buf, sz, "?");
}

/* ── format bytes ────────────────────────────────────────────────────────── */

void bu_fmt_bytes(double bytes, const char *scale, char *buf, size_t sz) {
    if (!scale || !strcmp(scale, "")) {
        snprintf(buf, sz, "%.0f", bytes);
    } else if (!strcmp(scale, "mb")) {
        snprintf(buf, sz, "%.4f MB", bytes / 1024.0 / 1024.0);
    } else if (!strcmp(scale, "gb")) {
        snprintf(buf, sz, "%.4f GB", bytes / 1024.0 / 1024.0 / 1024.0);
    } else {
        snprintf(buf, sz, "%.0f", bytes);
    }
}

/* ── misc ────────────────────────────────────────────────────────────────── */

const char *bu_or_dash(const char *s) {
    return (s && s[0]) ? s : "\xe2\x80\x94"; /* — */
}

char *bu_to_json(const bson_t *doc) {
    return bson_as_relaxed_extended_json(doc, NULL);
}
