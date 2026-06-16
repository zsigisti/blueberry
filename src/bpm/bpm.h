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

#define BPM_VERSION "1.1"

/* Resolved, absolute paths for the active root (see paths_init). */
extern char *g_root;   /* "" for "/", else "/some/where" (no trailing slash) */
extern char *g_db;     /* <root>/var/lib/bpm/db   */
extern char *g_cache;  /* <root>/var/lib/bpm/cache */
extern char *g_index;  /* <root>/var/lib/bpm/index */
extern char *g_conf;   /* <root>/etc/bpm/repos.conf */
extern char *g_prov;   /* <root>/etc/bpm/provided */
extern char *g_dest;   /* filesystem root to extract into ("/" when g_root="") */
extern char *g_cafile; /* <root>/etc/ssl/certs/ca-certificates.crt (TLS roots) */

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
void sha256_raw(const void *data, size_t len, unsigned char out[32]);

/* ── vercmp.c ───────────────────────────────────────────────────────────── */
/* Compare [epoch:]ver[-rel] versions. <0 a<b, 0 equal, >0 a>b. */
int vercmp(const char *a, const char *b);
int  sha256_file_hex(const char *path, char out[65]); /* 0 ok, -1 on read err */

/* ── sig.c (BearSSL ECDSA P-256 index signing) ──────────────────────────── */
/* Verify a detached ECDSA-P256/SHA-256 signature (DER/asn1) over the bytes
 * in <data> against the baked-in repo public key. 1 = valid, 0 = invalid. */
int sig_verify_index(const void *data, size_t len,
                     const void *sig, size_t siglen);
/* Whether signature checking is enforced. Off if BPM_ALLOW_UNSIGNED is set in
 * the environment (dev/testing escape hatch). */
int sig_required(void);

/* ── archive.c ──────────────────────────────────────────────────────────── */
/* Pull-based reader over a streaming-decompressed package. Opaque. */
typedef struct ZReader ZReader;

/* One tar member. name/linkname point into caller-managed storage valid only
 * during the callback. Payload is streamed, not buffered: read it with
 * zr_read() inside the callback. */
typedef struct {
    const char *name;
    const char *linkname;
    size_t      size;
    unsigned    mode;
    char        type;       /* '0' file, '5' dir, '2' symlink, '1' hardlink */
} TarEntry;

/* Read up to n bytes of the current member's payload into dst. Returns bytes
 * read (0 once the member is exhausted). Only valid during the callback. */
size_t zr_read(ZReader *zr, void *dst, size_t n);

typedef int (*pkg_cb)(const TarEntry *, ZReader *, void *);

/* Stream a .pkg.tar.zst, invoking cb per member with a ZReader positioned at
 * the member's payload. Whatever the callback leaves unread is drained
 * automatically. cb returns 0 to continue, non-zero to stop (returned).
 * Returns <0 on open/decompress/parse error. Memory use is bounded regardless
 * of package size. */
int pkg_stream(const char *path, pkg_cb cb, void *ctx);

/* ── net.c ──────────────────────────────────────────────────────────────── */
/* HTTP(S) GET <url> into <outpath>. Follows a few redirects. http:// and
 * https:// (the latter via tls.c/BearSSL). 0 on 2xx + saved file, else -1. */
int http_get(const char *url, const char *outpath);
/* Connect a blocking TCP socket, IPv4-first, with a per-address timeout so a
 * dead (e.g. broken-IPv6) address fails fast instead of stalling. -1 on error. */
int tcp_connect(const char *host, const char *port);

/* ── tls.c (BearSSL) ────────────────────────────────────────────────────── */
/* Open a verified TLS connection (SNI=host, validated against g_cafile).
 * Returns an opaque handle or NULL. read/write/close mirror socket semantics:
 * tls_read returns bytes (0=EOF, <0 err); tls_write returns 0 ok / -1. */
void *tls_open(const char *host, const char *port);
int   tls_read(void *ctx, void *buf, size_t n);
int   tls_write(void *ctx, const void *buf, size_t n);
void  tls_close(void *ctx);

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
void install_name_explicit(const char *name); /* user-requested: ignore is_provided */
void seen_reset(void);
void run_ldconfig(void);                    /* refresh ld.so.cache after install */

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
