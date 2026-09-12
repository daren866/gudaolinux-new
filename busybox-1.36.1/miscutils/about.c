/* vi: set sw=4 ts=4: */
/*
 * about - show Gudao Linux system information
 *
 * Copyright (C) 2026 Gudao Linux project
 * Licensed under GPLv2, see file LICENSE in this source tree.
 */
//config:config ABOUT
//config:	bool "about"
//config:	default y
//config:	help
//config:	about prints Gudao Linux system information:
//config:	system name, kernel, RAM size and CPU model.

//applet:IF_ABOUT(APPLET(about, BB_DIR_USR_BIN, BB_SUID_DROP))

//kbuild:lib-$(CONFIG_ABOUT) += about.o

//usage:#define about_trivial_usage
//usage:       ""
//usage:#define about_full_usage "\n\n"
//usage:       "Show Gudao Linux system information"

#include "libbb.h"
#include <sys/utsname.h>

static void squeeze_spaces(char *s)
{
	char *r = s, *w = s;

	while (*r) {
		if (*r == ' ' && (w == s || w[-1] == ' ')) {
			r++;
			continue;
		}
		*w++ = *r++;
	}
	while (w > s && w[-1] == ' ')
		w--;
	*w = '\0';
}

static void clean_cpu_name(char *s)
{
	char *r = s, *w = s, *q;
	int depth = 0;

	/* remove parenthesized chunks: Intel(R) Core(TM) -> Intel Core */
	while (*r) {
		if (*r == '(') {
			depth++;
			r++;
			continue;
		}
		if (*r == ')') {
			if (depth)
				depth--;
			r++;
			continue;
		}
		if (!depth)
			*w++ = *r;
		r++;
	}
	*w = '\0';

	/* cut " @ 2.50GHz" tail */
	q = strstr(s, " @ ");
	if (q)
		*q = '\0';

	/* cut trailing " CPU" */
	q = s + strlen(s);
	if (q - s >= 4 && strncmp(q - 4, " CPU", 4) == 0)
		q[-4] = '\0';

	squeeze_spaces(s);
}

int about_main(int argc, char **argv) MAIN_EXTERNALLY_VISIBLE;
int about_main(int argc UNUSED_PARAM, char **argv UNUSED_PARAM)
{
	struct utsname uts;
	char line[512];
	char cpu[160] = "unknown";
	unsigned long mem_kb = 0;
	unsigned long mb, gb;
	FILE *f;
	int major = 0;

	puts("system: Gudao Linux");

	if (uname(&uts) == 0) {
		sscanf(uts.release, "%d", &major);
		printf("kernel: Linux%d (%s)\n", major, uts.release);
	} else {
		puts("kernel: unknown");
	}

	f = fopen_for_read("/proc/meminfo");
	if (f) {
		while (fgets(line, sizeof(line), f)) {
			if (sscanf(line, "MemTotal: %lu kB", &mem_kb) == 1)
				break;
		}
		fclose(f);
	}
	if (mem_kb > 0) {
		mb = mem_kb / 1024;
		gb = (mb + 1023) / 1024; /* round up to next GB */
		if (gb > 0)
			printf("ram: %lumb(%luGB)\n", mb, gb);
		else
			printf("ram: %lumb\n", mb);
	} else {
		puts("ram: unknown");
	}

	f = fopen_for_read("/proc/cpuinfo");
	if (f) {
		while (fgets(line, sizeof(line), f)) {
			char *val;

			if (strncmp(line, "model name", 10) != 0)
				continue;
			val = strchr(line, ':');
			if (!val)
				continue;
			val++;
			while (*val == ' ' || *val == '\t')
				val++;
			val[strcspn(val, "\r\n")] = '\0';
			safe_strncpy(cpu, val, sizeof(cpu));
			break;
		}
		fclose(f);
	}
	clean_cpu_name(cpu);
	printf("cpu: %s\n", cpu);

	return 0;
}
