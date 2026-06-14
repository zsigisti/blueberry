/* bpm — Blueberry Package Manager (C implementation)
 *
 * A small, self-contained package manager for Arch-format binary packages
 * (.pkg.tar.zst). Drop-in replacement for the original shell script: same CLI,
 * same on-disk layout, same repo/index formats, so mkrepo.sh, blueberry-repo-sync
 * and the mirror tooling keep working unchanged.
 *
 * Links only libc and libzstd. tar (ustar+pax), HTTP, and SHA-256 are all
 * implemented in-tree — no child processes, no external runtime dependencies.
 *
 *   Database:   <root>/var/lib/bpm/db/<name>/{desc,files}
 *   Repo index: <root>/var/lib/bpm/index     (written by `bpm update`)
 *   Cache:      <root>/var/lib/bpm/cache/
 *   Repos:      <root>/etc/bpm/repos.conf     ("<name> <url> [mirror...]")
 *   Provided:   <root>/etc/bpm/provided       (extra base packages to skip)
 */
#ifndef BPM_H
#define BPM_H

#include <stddef.h>
#include <stdint.h>

#define BPM_VERSION "1.0"

/* Resolved, absolute paths for the active root (see paths_init). */
extern char *g_root;   /* "" for "/", else "/some/where" (no trailing slash) */
extern char *g_db;     /* <root>/var/lib/bpm/db   */
extern char *g_cache;  /* <root>/var/lib/bpm/cache */
extern char *g_index;  /* <root>/var/lib/bpm/index */
extern char *g_conf;   /* <root>/etc/bpm/repos.conf */
extern char *g_prov;   /* <root>/etc/bpm/provided */
extern char *g_dest;   /* filesystem root to extract into ("/" when g_root="") */

void paths_init(void);

/* ── util.c ─────────────────────────────────────────────────────────────── */
void  die(const char *fmt, ...);
void  logmsg(const char *fmt, ...);
void  warn(const char *fmt, ...);
void *xmalloc(size_t n);
void *xrealloc(void *p, size_t n);
char *xstrdup(const char *s);
char *xasprintf(const char *fmt, ...);     /* malloc'd; caller frees */
int   mkdirs(const char *path);            /* mkdir -p; 0 ok, -1 err */
int   mkparents(const char *path);         /* mkdir -p on dirname(path) */
int   file_exists(const char *path);
int   write_file(const char *path, const void *buf, size_t n);
char *read_file(const char *path, size_t *len_out); /* malloc'd, NUL-terminated */
char *str_trim(char *s);                   /* trim in place, returns s */
int   rm_rf(const char *path);

/* A growable byte buffer. */
typedef struct { char *data; size_t len, cap; } Buf;
void  buf_init(Buf *b);
void  buf_append(Buf *b, const void *p, size_t n);
void  buf_putc(Buf *b, char c);
void  buf_free(Buf *b);

/* ── sha256.c ───────────────────────────────────────────────────────────── */
/* Lowercase hex digest (64 chars + NUL) into out[65]. */
void sha256_hex(const void *data, size_t len, char out[65]);
int  sha256_file_hex(const char *path, char out[65]); /* 0 ok, -1 on read err */

/* ── archive.c ──────────────────────────────────────────────────────────── */
/* Decompress a .zst file fully into memory. Returns malloc'd buffer, sets
 * *len. NULL on error. */
char *zst_decompress_file(const char *path, size_t *len);

/* One tar member. name/linkname point into caller-managed storage valid only
 * during the callback. data points into the tar buffer. */
typedef struct {
    const char *name;
    const char *linkname;
    const char *data;
    size_t      size;
    unsigned    mode;
    char        type;       /* '0' file, '5' dir, '2' symlink, '1' hardlink */
} TarEntry;

/* Iterate ustar/pax members in an in-memory tar. cb returns 0 to continue,
 * non-zero to stop (that value is returned). Returns <0 on parse error. */
int tar_iterate(const char *buf, size_t len,
                int (*cb)(const TarEntry *, void *), void *ctx);

/* ── net.c ──────────────────────────────────────────────────────────────── */
/* HTTP GET <url> into <outpath>. Follows a few redirects. http:// only.
 * Returns 0 on 2xx + saved file, -1 otherwise. Quiet on failure. */
int http_get(const char *url, const char *outpath);

/* ── pkginfo.c ──────────────────────────────────────────────────────────── */
/* Extract a field value from .PKGINFO text ("key = value" lines). Returns
 * malloc'd value of the first match, or NULL. For repeated keys use
 * pkginfo_field_all. */
char  *pkginfo_field(const char *info, const char *key);
char **pkginfo_field_all(const char *info, const char *key, int *count);
void   strv_free(char **v, int n);

/* ── repo.c ─────────────────────────────────────────────────────────────── */
/* index line: name|version|filename|sha256|dep1,dep2,...|repo */
typedef struct {
    char *name, *version, *filename, *sha256, *deps, *repo;
} IndexEntry;
void index_entry_free(IndexEntry *e);
/* Look up a package by name in g_index. Returns 1 + fills e, or 0. */
int  index_lookup(const char *name, IndexEntry *e);
/* mirror list for a repo (from repos.conf): malloc'd argv-style, NULL-term. */
char **repo_mirrors(const char *repo, int *count);
/* Download <filename> from any mirror of <repo>, verify <sha256> (if non-empty),
 * into the cache. Returns malloc'd cache path or NULL. */
char *fetch_pkg(const char *filename, const char *sha256, const char *repo);

/* ── db.c ───────────────────────────────────────────────────────────────── */
/* Installed version (malloc'd) or NULL. */
char *db_installed_version(const char *name);
/* Remove a package's files from the filesystem (deepest first); keeps db. */
void  db_remove_files(const char *name);
/* Record desc + files for an installed package. */
int   db_record(const char *name, const char *info, char **files, int nfiles);

/* ── install.c ──────────────────────────────────────────────────────────── */
int  is_provided(const char *name);
void install_file(const char *path);       /* local .pkg.tar.zst */
void install_name(const char *name);       /* resolve from repos, recursive */
void seen_reset(void);

/* ── commands (cmd.c) ───────────────────────────────────────────────────── */
int cmd_install(int argc, char **argv);
int cmd_remove(int argc, char **argv);
int cmd_update(int argc, char **argv);
int cmd_upgrade(int argc, char **argv);
int cmd_search(int argc, char **argv);
int cmd_list(int argc, char **argv);
int cmd_info(int argc, char **argv);
int cmd_files(int argc, char **argv);
int cmd_owns(int argc, char **argv);

#endif /* BPM_H */
