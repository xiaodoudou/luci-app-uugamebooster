/*
 * uu-view-preload - hand the UU plugin a filtered view of the LAN.
 *
 * The plugin discovers devices from exactly four places, and reports what it
 * finds to NetEase, which is what makes every host on the network show up in
 * the phone app:
 *
 *     /proc/net/arp
 *     /tmp/dhcp.leases
 *     /tmp/nmp_client_list, /jffs/nmp_client_list
 *     ip -6 neigh show > /tmp/.uu.v6_neigh
 *
 * The three plain files can be bind-mounted over in a private mount namespace,
 * and uu-view does that. /proc/net/arp cannot: /proc/net is a symlink to
 * self/net and the table is regenerated from the network namespace on every
 * read, so a bind mount over it - or over /proc/net, or over /proc/<pid>/net -
 * is accepted and then silently ignored. The only namespace that would yield a
 * different table is a network namespace, and moving the plugin into one would
 * stop it steering other devices' traffic, which is its entire job.
 *
 * So instead we interpose the calls. The plugin is dynamically linked against
 * musl (it imports open, fopen, popen and system), and under qemu user-mode
 * emulation the guest's own loader honours LD_PRELOAD, so remapping the paths
 * here gives it our filtered copies without touching the real ARP table or
 * anything else on the router.
 *
 * Remapping only ever happens for read-only opens of paths we know, and only
 * when uu-view has actually produced the replacement. Anything else falls
 * through untouched, so a missing view degrades to the plugin's normal
 * behaviour rather than to a broken plugin.
 *
 * Build: see tools/build-preload.sh
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <string.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <stdarg.h>
#include <unistd.h>
#include <stdlib.h>
#include <sys/types.h>

#define VIEW_DIR "/var/run/uu-view"

/*
 * Everything the plugin shells out to - ip, brctl, uuclearnat - is a native
 * router binary, while this library is built for whichever architecture the
 * plugin itself is. Leaving LD_PRELOAD in the environment would point those
 * children at an object their loader cannot use, which musl treats as fatal and
 * would break UU's own routing commands. We are already mapped by the time this
 * runs, so dropping the variable costs us nothing.
 */
__attribute__((constructor))
static void uu_view_init(void)
{
	unsetenv("LD_PRELOAD");
}

static const char V_ARP[]    = VIEW_DIR "/arp";
static const char V_LEASES[] = VIEW_DIR "/dhcp.leases";
static const char V_NMP[]    = VIEW_DIR "/nmp_client_list";
static const char V_V6[]     = VIEW_DIR "/v6neigh";

/* The command the plugin runs to enumerate IPv6 neighbours. */
static const char V6_CMD[] = "ip -6 neigh show";

struct remap {
	const char *from;
	const char *to;
};

static const struct remap MAP[] = {
	{ "/proc/net/arp",         V_ARP    },
	{ "/proc/self/net/arp",    V_ARP    },  /* in case anything walks the symlink */
	{ "/tmp/dhcp.leases",      V_LEASES },
	{ "/tmp/nmp_client_list",  V_NMP    },
	{ "/jffs/nmp_client_list", V_NMP    },
	{ NULL, NULL }
};

/* Only substitute a view that exists; otherwise let the real path through. */
static int usable(const char *p)
{
	static int (*real_access)(const char *, int);

	if (!real_access)
		real_access = dlsym(RTLD_NEXT, "access");
	if (!real_access)
		return 0;
	return real_access(p, R_OK) == 0;
}

static const char *remap(const char *p)
{
	const struct remap *m;

	if (!p)
		return p;
	for (m = MAP; m->from; m++)
		if (strcmp(p, m->from) == 0)
			return usable(m->to) ? m->to : p;
	return p;
}

/* A write to one of these paths is not a device enumeration, and redirecting it
 * would corrupt the view (or the real file). Leave writes alone. */
static int readonly_flags(int flags)
{
	return (flags & (O_WRONLY | O_RDWR | O_CREAT | O_TRUNC | O_APPEND)) == 0;
}

static int readonly_mode(const char *mode)
{
	return mode && mode[0] == 'r' && !strchr(mode, '+');
}

int open(const char *path, int flags, ...)
{
	static int (*real)(const char *, int, ...);
	mode_t mode = 0;

	if (!real)
		real = dlsym(RTLD_NEXT, "open");
	if (flags & O_CREAT) {
		va_list ap;
		va_start(ap, flags);
		mode = va_arg(ap, int);
		va_end(ap);
	}
	return real(readonly_flags(flags) ? remap(path) : path, flags, mode);
}

int open64(const char *path, int flags, ...)
{
	static int (*real)(const char *, int, ...);
	mode_t mode = 0;

	if (!real)
		real = dlsym(RTLD_NEXT, "open64");
	if (!real)
		real = dlsym(RTLD_NEXT, "open");
	if (flags & O_CREAT) {
		va_list ap;
		va_start(ap, flags);
		mode = va_arg(ap, int);
		va_end(ap);
	}
	return real(readonly_flags(flags) ? remap(path) : path, flags, mode);
}

/* Absolute paths ignore dirfd, and every path we remap is absolute. */
int openat(int dirfd, const char *path, int flags, ...)
{
	static int (*real)(int, const char *, int, ...);
	mode_t mode = 0;

	if (!real)
		real = dlsym(RTLD_NEXT, "openat");
	if (flags & O_CREAT) {
		va_list ap;
		va_start(ap, flags);
		mode = va_arg(ap, int);
		va_end(ap);
	}
	return real(dirfd, readonly_flags(flags) ? remap(path) : path, flags, mode);
}

FILE *fopen(const char *path, const char *mode)
{
	static FILE *(*real)(const char *, const char *);

	if (!real)
		real = dlsym(RTLD_NEXT, "fopen");
	return real(readonly_mode(mode) ? remap(path) : path, mode);
}

FILE *fopen64(const char *path, const char *mode)
{
	static FILE *(*real)(const char *, const char *);

	if (!real)
		real = dlsym(RTLD_NEXT, "fopen64");
	if (!real)
		real = dlsym(RTLD_NEXT, "fopen");
	return real(readonly_mode(mode) ? remap(path) : path, mode);
}

/*
 * "ip -6 neigh show > /tmp/.uu.v6_neigh" is a shell command, not an open, so it
 * needs rewriting rather than remapping. Everything after the prefix is kept
 * verbatim, which preserves the redirection the plugin appended.
 */
static const char *rewrite_cmd(const char *cmd, char *buf, size_t n)
{
	size_t pre = sizeof(V6_CMD) - 1;

	if (!cmd || strncmp(cmd, V6_CMD, pre) != 0 || !usable(V_V6))
		return cmd;
	if ((size_t)snprintf(buf, n, "cat %s%s", V_V6, cmd + pre) >= n)
		return cmd;
	return buf;
}

FILE *popen(const char *cmd, const char *mode)
{
	static FILE *(*real)(const char *, const char *);
	char buf[512];

	if (!real)
		real = dlsym(RTLD_NEXT, "popen");
	return real(rewrite_cmd(cmd, buf, sizeof buf), mode);
}

int system(const char *cmd)
{
	static int (*real)(const char *);
	char buf[512];

	if (!real)
		real = dlsym(RTLD_NEXT, "system");
	return real(rewrite_cmd(cmd, buf, sizeof buf));
}
