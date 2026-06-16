/* install.c — install/remove a .pkg.tar.zst and resolve dependencies. */
#include "bpm.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/wait.h>

/* ── provided (base) packages ──────────────────────────────────────────────── */
static const char *const BASE[] = {
    "glibc","gcc-libs","bash","sh","dash","filesystem","busybox","coreutils",
    "util-linux","findutils","grep","sed","gawk","awk","gzip","procps-ng",
    "iproute2","iputils","dropbear","ld-linux","glibc-locales","tzdata", NULL
};

int is_provided(const char *name) {
    for (int i = 0; BASE[i]; i++)
        if (!strcmp(name, BASE[i])) return 1;
    /* extra names listed in /etc/bpm/provided */
    size_t len; char *txt = read_file(g_prov, &len);
    if (txt) {
        int hit = 0;
        char *sv = NULL;
        for (char *p = strtok_r(txt, "\n", &sv); p; p = strtok_r(NULL, "\n", &sv)) {
            char *s = str_trim(p);
            if (!*s || *s == '#') continue;
            if (!strcmp(s, name)) { hit = 1; break; }
        }
        free(txt);
        if (hit) return 1;
    }
    return 0;
}

/* Strip a dependency atom of version/provider syntax: "glibc>=2.38" -> "glibc". */
static char *dep_name(const char *atom) {
    size_t n = strcspn(atom, "<>=:");
    char *out = xmalloc(n + 1);
    memcpy(out, atom, n); out[n] = '\0';
    return out;
}

static int is_meta(const char *name) {
    if (name[0] == '.' && name[1] == '/') name += 2;
    return !strcmp(name, ".PKGINFO") || !strcmp(name, ".MTREE") ||
           !strcmp(name, ".BUILDINFO") || !strcmp(name, ".INSTALL") ||
           !strcmp(name, ".CHANGELOG");
}

/* ── scriptlets & ldconfig ─────────────────────────────────────────────────── */
/* Run a /bin/sh command inside the install root. When installing to an
 * alternate root (BPM_ROOT, e.g. the installer's /mnt) we chroot first so
 * scriptlets and ldconfig act on the target, never the host. chroot needs root;
 * if it fails the child exits non-zero and the caller treats it as best-effort.
 * Returns the command's exit status, or -1 if it couldn't be launched. */
static int run_root_sh(const char *cmd) {
    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        if (g_root && *g_root && strcmp(g_root, "/") != 0) {
            if (chdir(g_dest) != 0 || chroot(".") != 0 || chdir("/") != 0) _exit(127);
        }
        execl("/bin/sh", "sh", "-c", cmd, (char *)NULL);
        _exit(127);
    }
    int st = 0;
    if (waitpid(pid, &st, 0) < 0) return -1;
    return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
}

/* Refresh /etc/ld.so.cache so freshly-installed shared libraries are found.
 * Best-effort and quiet: skipped silently if ldconfig isn't present. Call once
 * per transaction, after everything is laid down. */
void run_ldconfig(void) {
    run_root_sh("command -v ldconfig >/dev/null 2>&1 && ldconfig 2>/dev/null");
}

/* ── extraction ────────────────────────────────────────────────────────────── */
struct ictx {
    char **files;   /* collected installed paths (no leading slash, no dirs) */
    int    n;
    int    failed;
    char  *info;        /* .PKGINFO text (first member in a makepkg tarball) */
    char  *name;        /* pkgname, resolved from .PKGINFO */
    char  *ver;         /* pkgver */
    char  *script;      /* .INSTALL scriptlet body, or NULL */
    char  *old_ver;     /* previous version on an upgrade, else NULL */
    int    upgrade;     /* 1 if a previous version was present */
    int    old_settled; /* old version's files removed before writing payload */
};

static void files_add(struct ictx *c, const char *rel) {
    c->files = xrealloc(c->files, (size_t)(c->n + 1) * sizeof *c->files);
    c->files[c->n++] = xstrdup(rel);
}

/* Drain a member's payload to disk in bounded chunks. */
static int write_member(ZReader *zr, const char *full, unsigned mode) {
    FILE *of = fopen(full, "wb");
    if (!of) return -1;
    unsigned char buf[65536];
    size_t got;
    int rc = 0;
    while ((got = zr_read(zr, buf, sizeof buf)) > 0)
        if (fwrite(buf, 1, got, of) != got) { rc = -1; break; }
    if (fclose(of) != 0) rc = -1;
    if (rc == 0) chmod(full, mode ? mode : 0644);
    return rc;
}

/* Before writing the first real payload file, settle any previously installed
 * version: remove its files so an upgrade doesn't leave orphans behind. Called
 * lazily because .PKGINFO (which gives us the name) precedes the payload. */
static void settle_old(struct ictx *c) {
    if (c->old_settled) return;
    c->old_settled = 1;
    if (!c->name) return;
    char *old = db_installed_version(c->name);
    if (old) {
        logmsg("reinstall/upgrade %s %s -> %s", c->name, old,
               c->ver ? c->ver : "?");
        c->upgrade = 1;
        c->old_ver = old;          /* kept for the post_upgrade scriptlet */
        db_remove_files(c->name);
    } else {
        logmsg("installing %s %s", c->name, c->ver ? c->ver : "?");
    }
}

static int extract_cb(const TarEntry *e, ZReader *zr, void *p) {
    struct ictx *c = p;
    const char *rel = e->name;
    if (rel[0] == '.' && rel[1] == '/') rel += 2;
    if (!*rel) return 0;

    if (is_meta(rel)) {
        /* capture .PKGINFO and .INSTALL; other metadata is skipped */
        if (!strcmp(rel, ".PKGINFO") && !c->info) {
            Buf b; buf_init(&b);
            unsigned char tmp[8192]; size_t got;
            while ((got = zr_read(zr, tmp, sizeof tmp)) > 0) buf_append(&b, tmp, got);
            buf_putc(&b, '\0');
            c->info = b.data;
            c->name = pkginfo_field(c->info, "pkgname");
            c->ver  = pkginfo_field(c->info, "pkgver");
        } else if (!strcmp(rel, ".INSTALL") && !c->script) {
            Buf b; buf_init(&b);
            unsigned char tmp[8192]; size_t got;
            while ((got = zr_read(zr, tmp, sizeof tmp)) > 0) buf_append(&b, tmp, got);
            buf_putc(&b, '\0');
            c->script = b.data;
        }
        return 0;
    }

    settle_old(c);              /* first payload member → clear old version */
    char *full = xasprintf("%s/%s", g_dest, rel);

    if (e->type == '5') {                       /* directory */
        mkdirs(full);
    } else if (e->type == '2') {                /* symlink */
        mkparents(full);
        unlink(full);
        if (symlink(e->linkname, full) != 0) c->failed = 1;
        size_t L = strlen(rel);
        char *r = xstrdup(rel); if (L && r[L-1] == '/') r[L-1] = '\0';
        files_add(c, r); free(r);
    } else if (e->type == '1') {                /* hardlink */
        mkparents(full);
        char *target = xasprintf("%s/%s", g_dest, e->linkname);
        unlink(full);
        if (link(target, full) != 0) c->failed = 1;
        free(target);
        files_add(c, rel);
    } else {                                    /* regular file */
        mkparents(full);
        unlink(full);
        if (write_member(zr, full, e->mode) != 0) c->failed = 1;
        files_add(c, rel);
    }
    free(full);
    return 0;
}

void install_file(const char *path) {
    if (!file_exists(path)) die("no such package file: %s", path);

    mkdirs(g_dest);
    struct ictx c = {0};
    if (pkg_stream(path, extract_cb, &c) < 0) {
        free(c.info); free(c.name); free(c.ver);
        for (int i = 0; i < c.n; i++) free(c.files[i]);
        free(c.files);
        die("not a package (cannot read): %s", path);
    }
    if (!c.info) die("not a package (no .PKGINFO): %s", path);
    if (!c.name) die("package has no pkgname: %s", path);
    if (c.failed) warn("%s: some files could not be written", c.name);

    db_record(c.name, c.info, c.files, c.n);

    /* Post-install/upgrade scriptlet. Trust comes from the signed index +
     * sha256 verification (repo installs) or from the admin naming a local file
     * explicitly. Set BPM_NO_SCRIPTLETS to skip. Convention matches pacman:
     * source the .INSTALL, then call post_install <ver> / post_upgrade <new>
     * <old> if defined. Run inside the root (chroot under BPM_ROOT). */
    if (c.script && !getenv("BPM_NO_SCRIPTLETS")) {
        char *tmp_full = xasprintf("%s/.bpm-scriptlet", g_dest);
        if (write_file(tmp_full, c.script, strlen(c.script)) == 0) {
            const char *hook = c.upgrade ? "post_upgrade" : "post_install";
            char *cmd = xasprintf(
                ". /.bpm-scriptlet 2>/dev/null; "
                "type %s >/dev/null 2>&1 && %s '%s' '%s'",
                hook, hook, c.ver ? c.ver : "", c.old_ver ? c.old_ver : "");
            logmsg("running %s scriptlet for %s", hook, c.name);
            run_root_sh(cmd);
            free(cmd);
        }
        unlink(tmp_full);
        free(tmp_full);
    }

    logmsg("installed %s %s", c.name, c.ver ? c.ver : "?");

    for (int i = 0; i < c.n; i++) free(c.files[i]);
    free(c.files);
    free(c.info); free(c.name); free(c.ver); free(c.script); free(c.old_ver);
}

/* ── dependency resolution ─────────────────────────────────────────────────── */
static char **g_seen; static int g_seen_n;
void seen_reset(void) {
    for (int i = 0; i < g_seen_n; i++) free(g_seen[i]);
    free(g_seen); g_seen = NULL; g_seen_n = 0;
}
static int seen(const char *name) {
    for (int i = 0; i < g_seen_n; i++) if (!strcmp(g_seen[i], name)) return 1;
    return 0;
}
static void mark(const char *name) {
    g_seen = xrealloc(g_seen, (size_t)(g_seen_n + 1) * sizeof *g_seen);
    g_seen[g_seen_n++] = xstrdup(name);
}

/* explicit: the user named this package on the command line, so install it even
 * if it's in the "provided" set (e.g. `bpm install glibc` for the dev SDK).
 * Transitive deps recurse with explicit=0 and still honour is_provided. */
static void install_name_impl(const char *name, int explicit) {
    if (seen(name)) return;
    mark(name);
    if (!explicit && is_provided(name)) return;

    char *iv = db_installed_version(name);
    if (iv) { logmsg("%s already installed", name); free(iv); return; }

    IndexEntry e;
    if (!index_lookup(name, &e)) {
        warn("%s not in repo index — assuming provided by the base system", name);
        return;
    }

    /* dependencies first */
    if (e.deps && *e.deps) {
        char *deps = xstrdup(e.deps);
        char *sv = NULL;
        for (char *tok = strtok_r(deps, ",", &sv); tok; tok = strtok_r(NULL, ",", &sv)) {
            char *s = str_trim(tok);
            if (!*s) continue;
            char *dn = dep_name(s);
            if (*dn) install_name_impl(dn, 0);
            free(dn);
        }
        free(deps);
    }

    logmsg("downloading %s %s", name, e.version);
    char *pkg = fetch_pkg(e.filename, e.sha256, e.repo);
    install_file(pkg);
    free(pkg);
    index_entry_free(&e);
}

void install_name(const char *name)          { install_name_impl(name, 0); }
void install_name_explicit(const char *name) { install_name_impl(name, 1); }
