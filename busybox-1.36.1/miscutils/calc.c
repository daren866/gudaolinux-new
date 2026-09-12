/* vi: set sw=4 ts=4: */
/*
 * calc - evaluate math expressions (Gudao Linux built-in)
 *
 * Copyright (C) 2026 Gudao Linux project
 * Licensed under GPLv2, see file LICENSE in this source tree.
 */
//config:config CALC
//config:       bool "calc"
//config:       default y
//config:       help
//config:       calc evaluates a math expression and prints the result.
//config:
//config:         calc 2*(2+2)   -> 8
//config:         calc 10/4      -> 2.5
//config:
//config:       Supported: + - * / % ( ) and decimals

//applet:IF_CALC(APPLET(calc, BB_DIR_USR_BIN, BB_SUID_DROP))

//kbuild:lib-$(CONFIG_CALC) += calc.o

//usage:#define calc_trivial_usage
//usage:       "EXPRESSION"
//usage:#define calc_full_usage "\n\n"
//usage:       "Evaluate a math expression and print the result"
//usage:       "\n    calc 2*(2+2) -> 8"

#include "libbb.h"
#include <ctype.h>

static const char *p;

static void skipws(void)
{
        while (*p == ' ' || *p == '\t')
                p++;
}

static double parse_expr(void);

static double parse_primary(void)
{
        double v;

        skipws();
        if (*p == '(') {
                p++;
                v = parse_expr();
                skipws();
                if (*p != ')')
                        bb_error_msg_and_die("syntax error: missing ')'");
                p++;
        } else if (isdigit((unsigned char)*p) || *p == '.') {
                char *end;

                v = strtod(p, &end);
                if (end == p)
                        bb_error_msg_and_die("syntax error at '%s'", p);
                p = end;
        } else {
                bb_error_msg_and_die("syntax error at '%s'", p);
        }
        return v;
}

static double parse_unary(void)
{
        double v;

        skipws();
        if (*p == '-') {
                p++;
                v = -parse_unary();
        } else if (*p == '+') {
                p++;
                v = parse_unary();
        } else {
                v = parse_primary();
        }
        return v;
}

static double parse_term(void)
{
        double v = parse_unary();

        for (;;) {
                skipws();
                if (*p == '*') {
                        p++;
                        v *= parse_unary();
                } else if (*p == '/') {
                        double d;

                        p++;
                        d = parse_unary();
                        if (d == 0)
                                bb_error_msg_and_die("division by zero");
                        v /= d;
                } else if (*p == '%') {
                        double d;

                        p++;
                        d = parse_unary();
                        if ((long) d == 0)
                                bb_error_msg_and_die("division by zero");
                        v = (double)((long) v % (long) d);
                } else {
                        break;
                }
        }
        return v;
}

static double parse_expr(void)
{
        double v = parse_term();

        for (;;) {
                skipws();
                if (*p == '+') {
                        p++;
                        v += parse_term();
                } else if (*p == '-') {
                        p++;
                        v -= parse_term();
                } else {
                        break;
                }
        }
        return v;
}

int calc_main(int argc, char **argv) MAIN_EXTERNALLY_VISIBLE;
int calc_main(int argc UNUSED_PARAM, char **argv)
{
        char joined[1024];
        double v;
        const char *s;
        size_t len = 0;
        int i;

        if (!argv[1])
                bb_show_usage();

        /* join all args into one expression string */
        joined[0] = '\0';
        for (i = 1; argv[i]; i++) {
                size_t alen = strlen(argv[i]);

                if (len + alen + 2 >= sizeof(joined))
                        bb_error_msg_and_die("expression too long");
                if (len)
                        joined[len++] = ' ';
                memcpy(joined + len, argv[i], alen);
                len += alen;
                joined[len] = '\0';
        }

        /* safety: only digits, operators, parentheses, dot, spaces */
        for (s = joined; *s; s++) {
                if (!isdigit((unsigned char)*s) && !strchr("+-*/%(). \t", *s))
                        bb_error_msg_and_die("invalid character '%c'", *s);
        }

        p = joined;
        v = parse_expr();
        skipws();
        if (*p)
                bb_error_msg_and_die("syntax error at '%s'", p);

        printf("%.6g\n", v);
        return 0;
}
