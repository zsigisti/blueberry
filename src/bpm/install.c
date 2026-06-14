/* install.c — install/remove a .pkg.tar.zst and resolve dependencies. */
#include "bpm.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>

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

/* ── extraction ────────────────────────────────────────────────────────────── */
struct ictx {
    char **files;   /* collected installed paths (no leading slash, no dirs) */
    int    n;
    int    failed;
};

static void files_add(struct ictx *c, const char *rel) {
    c->files = xrealloc(c->files, (size_t)(c->n + 1) * sizeof *c->files);
    c->files[c->n++] = xstrdup(rel);
}

static int extract_cb(const TarEntry *e, void *p) {
    struct ictx *c = p;
    const char *rel = e->name;
    if (rel[0] == '.' && rel[1] == '/') rel += 2;
    if (!*rel || is_meta(rel)) return 0;

    char *full = xasprintf("%s/%s", g_dest, rel);

    if (e->type == '5') {                       /* directory */
        mkdirs(full);
    } else if (e->type == '2') {                /* symlink */
        mkparents(full);
        unlink(full);
        if (symlink(e->linkname, full) != 0) c->failed = 1;
        /* record without trailing slash */
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
        if (write_file(full, e->data, e->size) != 0) c->failed = 1;
        else chmod(full, e->mode ? e->mode : 0644);
        files_add(c, rel);
    }
    free(full);
    return 0;
}

struct finfo { char *info; };
static int find_pkginfo(const TarEntry *e, void *p) {
    const char *nm = e->name;
    if (nm[0] == '.' && nm[1] == '/') nm += 2;
    if (!strcmp(nm, ".PKGINFO")) {
        struct finfo *c = p;
        c->info = xmalloc(e->size + 1);
        memcpy(c->info, e->data, e->size); c->info[e->size] = '\0';
        return 1;
    }
    return 0;
}

void install_file(const char *path) {
    if (!file_exists(path)) die("no such package file: %s", path);

    size_t tlen; char *tar = zst_decompress_file(path, &tlen);
    if (!tar) die("not a package (cannot decompress): %s", path);

    struct finfo fi = { NULL };
    tar_iterate(tar, tlen, find_pkginfo, &fi);
    if (!fi.info) { free(tar); die("not a package (no .PKGINFO): %s", path); }

    char *name = pkginfo_field(fi.info, "pkgname");
    char *ver  = pkginfo_field(fi.info, "pkgver");
    if (!name) { free(tar); free(fi.info); die("package has no pkgname: %s", path); }

    char *old = db_installed_version(name);
    if (old) {
        logmsg("reinstall/upgrade %s %s -> %s", name, old, ver ? ver : "?");
        db_remove_files(name);
    } else {
        logmsg("installing %s %s", name, ver ? ver : "?");
    }

    struct ictx c = { NULL, 0, 0 };
    mkdirs(g_dest);
    tar_iterate(tar, tlen, extract_cb, &c);
    if (c.failed) warn("%s: some files could not be written", name);

    db_record(name, fi.info, c.files, c.n);
    logmsg("installed %s %s", name, ver ? ver : "?");

    for (int i = 0; i < c.n; i++) free(c.files[i]);
    free(c.files);
    free(old); free(name); free(ver); free(fi.info); free(tar);
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

void install_name(const char *name) {
    if (seen(name)) return;
    mark(name);
    if (is_provided(name)) return;

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
            if (*dn) install_name(dn);
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
