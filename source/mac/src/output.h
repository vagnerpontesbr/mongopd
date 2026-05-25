#ifndef OUTPUT_H
#define OUTPUT_H

#include <stdbool.h>

extern bool g_no_color;

/* ANSI helpers — return empty string when --no-color is set */
const char *C_RESET(void);
const char *C_BOLD(void);
const char *C_CYAN(void);
const char *C_YELLOW(void);
const char *C_RED(void);

/* Formatted output */
void print_header(const char *title);
void print_footer(void);
void print_section(const char *name);
void print_sep(void);
void print_info(const char *fmt, ...);
void print_warn(const char *fmt, ...);
void print_error(const char *fmt, ...);

#endif /* OUTPUT_H */
