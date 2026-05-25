#include "output.h"
#include <stdio.h>
#include <stdarg.h>
#include <time.h>
#include <string.h>

bool g_no_color = false;

const char *C_RESET(void)  { return g_no_color ? "" : "\033[0m";    }
const char *C_BOLD(void)   { return g_no_color ? "" : "\033[1m";    }
const char *C_CYAN(void)   { return g_no_color ? "" : "\033[36m";   }
const char *C_YELLOW(void) { return g_no_color ? "" : "\033[33m";   }
const char *C_RED(void)    { return g_no_color ? "" : "\033[31m";   }

/* Box width (inner): border is 80 ═ wide; content is "  %-*s" so pad = 80-2 = 78 */
#define BOX_INNER 78
#define BOX_BORDER \
    "════════════════════════════════════════════════════════════════════════════════"

/* Extra bytes added by multi-byte UTF-8 sequences (printf pads by bytes, not columns) */
static int utf8_extra_bytes(const char *s) {
    int extra = 0;
    for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
        if      ((*p & 0xE0) == 0xC0) extra += 1; /* 2-byte seq */
        else if ((*p & 0xF0) == 0xE0) extra += 2; /* 3-byte seq */
        else if ((*p & 0xF8) == 0xF0) extra += 3; /* 4-byte seq */
    }
    return extra;
}

void print_header(const char *title) {
    time_t now = time(NULL);
    struct tm *t = localtime(&now);
    char ts[64];
    strftime(ts, sizeof(ts), "%Y-%m-%dT%H:%M:%S%z", t);

    char line1[128];
    snprintf(line1, sizeof(line1), "mongopd \xe2\x80\x94 %s", title);

    printf("\n%s%s╔" BOX_BORDER "╗%s\n",  C_BOLD(), C_CYAN(), C_RESET());
    printf("%s%s║  %-*s║%s\n", C_BOLD(), C_CYAN(), BOX_INNER + utf8_extra_bytes(line1), line1, C_RESET());
    printf("%s%s║  %-*s║%s\n", C_BOLD(), C_CYAN(), BOX_INNER + utf8_extra_bytes(ts),    ts,    C_RESET());
    printf("%s%s╚" BOX_BORDER "╝%s\n",  C_BOLD(), C_CYAN(), C_RESET());
}

void print_footer(void) {
    printf("%s  ──────────────────────────────────────────────────────────────────────────────────────────────%s\n\n",
           C_CYAN(), C_RESET());
}

void print_section(const char *name) {
    printf("  ── %s ", name);
    /* pad with dashes to column 70 */
    int used = 6 + (int)strlen(name);
    for (int i = used; i < 70; i++) printf("─");
    printf("\n");
}

void print_sep(void) {
    printf("  ──────────────────────────────────────────────────────────────────────────────────────────────\n");
}

void print_info(const char *fmt, ...) {
    printf("%s[INFO]%s ", C_YELLOW(), C_RESET());
    va_list ap; va_start(ap, fmt); vprintf(fmt, ap); va_end(ap);
    printf("\n");
}

void print_warn(const char *fmt, ...) {
    printf("%s[WARN]%s ", C_YELLOW(), C_RESET());
    va_list ap; va_start(ap, fmt); vprintf(fmt, ap); va_end(ap);
    printf("\n");
}

void print_error(const char *fmt, ...) {
    printf("%s[ERROR]%s ", C_RED(), C_RESET());
    va_list ap; va_start(ap, fmt); vprintf(fmt, ap); va_end(ap);
    printf("\n");
}
