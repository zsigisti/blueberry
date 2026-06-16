/* cmd.c — command implementations. */
#include "bpm.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <unistd.h>
#include <sys/stat.h>

int cmd_install(int argc, char **argv) {
    if (argc < 1) die("usage: bpm install <name|file.pkg.tar.zst>...");
    for (int i = 0; i < argc; i++) {
        if (strstr(argv[i], ".pkg.tar.")) install_file(argv[i]);
        else                              install_name_explicit(argv[i]);
    }
    run_ldconfig();
    return 0;
}

int cmd_remove(int argc, char **argv) {
    if (argc < 1) die("usage: bpm remove <name>...");
    for (int i = 0; i < argc; i++) {
        char *dir = xasprintf("%s/%s", g_db, argv[i]);
        if (!file_exists(dir)) { free(dir); die("%s is not installed", argv[i]); }
        logmsg("removing %s", argv[i]);
        db_remove_files(argv[i]);
        rm_rf(dir);
        logmsg("removed %s", argv[i]);
        free(dir);
    }
    return 0;
}

int cmd_update(int argc, char **argv) {
    (void)argc; (void)argv;
    if (!file_exists(g_conf)) die("no repo config: %s", g_conf);
    mkparents(g_index);

    Buf idx; buf_init(&idx);
    char *tmp = xasprintf("%s.repo", g_index);
    char *sigtmp = xasprintf("%s.sig", g_index);

    FILE *f = fopen(g_conf, "r");
    if (!f) die("cannot read %s", g_conf);
    char *line = NULL; size_t cap = 0; ssize_t len;
    while ((len = getline(&line, &cap, f)) > 0) {
        char *s = str_trim(line);
        if (!*s || *s == '#') continue;
        /* first token = repo name; remaining = mirror urls */
        char *save = NULL;
        char *repo = strtok_r(s, " \t", &save);
        if (!repo) continue;
        int got = 0;
        char *url;
        while ((url = strtok_r(NULL, " \t", &save)) != NULL) {
            logmsg("syncing '%s' from %s", repo, url);
            char *u = xasprintf("%s/bpm.index", url);
            int rc = http_get(u, tmp);
            free(u);
            if (rc != 0) { warn("mirror unreachable: %s", url); continue; }

            size_t rl; char *body = read_file(tmp, &rl);
            if (!body) { warn("empty index from %s", url); continue; }

            /* Verify the detached ECDSA signature over the raw index bytes
             * (before we append the repo column). The sig sits next to the
             * index as bpm.index.sig. */
            if (sig_required()) {
                char *su = xasprintf("%s/bpm.index.sig", url);
                int src = http_get(su, sigtmp);
                free(su);
                size_t sl = 0; char *sig = src == 0 ? read_file(sigtmp, &sl) : NULL;
                int ok = sig && sig_verify_index(body, rl, sig, sl);
                free(sig);
                if (!ok) {
                    warn("signature verification FAILED for '%s' from %s", repo, url);
                    free(body);
                    continue;   /* try next mirror; never trust an unsigned index */
                }
            }

            /* append each line with the repo as the 6th field */
            char *bsv = NULL;
            for (char *p = strtok_r(body, "\n", &bsv); p; p = strtok_r(NULL, "\n", &bsv)) {
                if (!*p) continue;
                buf_append(&idx, p, strlen(p));
                buf_putc(&idx, '|');
                buf_append(&idx, repo, strlen(repo));
                buf_putc(&idx, '\n');
            }
            free(body);
            got = 1; break;
        }
        if (!got) warn("all mirrors failed for repo '%s'", repo);
    }
    free(line); fclose(f);
    unlink(tmp); free(tmp);
    unlink(sigtmp); free(sigtmp);

    /* atomic swap */
    char *itmp = xasprintf("%s.tmp", g_index);
    if (write_file(itmp, idx.data ? idx.data : "", idx.len) != 0)
        die("cannot write index %s", itmp);
    if (rename(itmp, g_index) != 0) die("cannot replace index %s", g_index);
    free(itmp);

    /* count lines */
    int count = 0;
    for (size_t i = 0; i < idx.len; i++) if (idx.data[i] == '\n') count++;
    buf_free(&idx);
    logmsg("%d packages in index", count);
    return 0;
}

int cmd_search(int argc, char **argv) {
    if (argc < 1) die("usage: bpm search <term>");
    if (!file_exists(g_index)) die("no index; run 'bpm update' first");
    const char *term = argv[0];
    FILE *f = fopen(g_index, "r");
    if (!f) return 1;
    char *line = NULL; size_t cap = 0; ssize_t len;
    while ((len = getline(&line, &cap, f)) > 0) {
        if (line[len-1] == '\n') line[--len] = '\0';
        char *bar = strchr(line, '|');
        if (!bar) continue;
        *bar = '\0';
        char *ver = bar + 1; char *bar2 = strchr(ver, '|'); if (bar2) *bar2 = '\0';
        if (strstr(line, term)) printf("%s %s\n", line, ver);
    }
    free(line); fclose(f);
    return 0;
}

int cmd_list(int argc, char **argv) {
    (void)argc; (void)argv;
    DIR *d = opendir(g_db);
    if (!d) return 0;
    struct dirent *de;
    while ((de = readdir(d))) {
        if (de->d_name[0] == '.') continue;
        char *desc = xasprintf("%s/%s/desc", g_db, de->d_name);
        size_t l; char *txt = read_file(desc, &l);
        free(desc);
        char *ver = txt ? pkginfo_field(txt, "pkgver") : NULL;
        printf("%s %s\n", de->d_name, ver ? ver : "");
        free(ver); free(txt);
    }
    closedir(d);
    return 0;
}

int cmd_info(int argc, char **argv) {
    if (argc < 1) die("usage: bpm info <name>");
    char *desc = xasprintf("%s/%s/desc", g_db, argv[0]);
    size_t l; char *txt = read_file(desc, &l);
    free(desc);
    if (!txt) die("%s is not installed", argv[0]);
    fputs(txt, stdout);
    free(txt);
    return 0;
}

int cmd_files(int argc, char **argv) {
    if (argc < 1) die("usage: bpm files <name>");
    char *fl = xasprintf("%s/%s/files", g_db, argv[0]);
    size_t l; char *txt = read_file(fl, &l);
    free(fl);
    if (!txt) die("%s is not installed", argv[0]);
    fputs(txt, stdout);
    free(txt);
    return 0;
}

int cmd_owns(int argc, char **argv) {
    if (argc < 1) die("usage: bpm owns <path>");
    const char *q = argv[0];
    while (*q == '/') q++;
    DIR *d = opendir(g_db);
    if (!d) die("no package owns /%s", q);
    struct dirent *de; int found = 0;
    while ((de = readdir(d))) {
        if (de->d_name[0] == '.') continue;
        char *fl = xasprintf("%s/%s/files", g_db, de->d_name);
        size_t l; char *txt = read_file(fl, &l);
        free(fl);
        if (txt) {
            char *sv = NULL;
            for (char *p = strtok_r(txt, "\n", &sv); p; p = strtok_r(NULL, "\n", &sv)) {
                if (!strcmp(p, q)) { printf("%s\n", de->d_name); found = 1; break; }
            }
            free(txt);
        }
    }
    closedir(d);
    if (!found) die("no package owns /%s", q);
    return 0;
}

int cmd_upgrade(int argc, char **argv) {
    (void)argc; (void)argv;
    if (!file_exists(g_index)) die("no index; run 'bpm update' first");

    /* collect installed package names */
    DIR *d = opendir(g_db);
    if (!d) { logmsg("nothing installed"); return 0; }
    char **names = NULL; int n = 0;
    struct dirent *de;
    while ((de = readdir(d))) {
        if (de->d_name[0] == '.') continue;
        names = xrealloc(names, (size_t)(n + 1) * sizeof *names);
        names[n++] = xstrdup(de->d_name);
    }
    closedir(d);

    /* Plan: collect packages whose index version is strictly newer. */
    char **up = NULL, **from = NULL, **to = NULL; int m = 0;
    for (int i = 0; i < n; i++) {
        char *iv = db_installed_version(names[i]);
        IndexEntry e;
        if (iv && index_lookup(names[i], &e)) {
            if (vercmp(e.version, iv) > 0) {
                up   = xrealloc(up,   (size_t)(m + 1) * sizeof *up);
                from = xrealloc(from, (size_t)(m + 1) * sizeof *from);
                to   = xrealloc(to,   (size_t)(m + 1) * sizeof *to);
                up[m] = xstrdup(names[i]); from[m] = xstrdup(iv);
                to[m] = xstrdup(e.version); m++;
            }
            index_entry_free(&e);
        }
        free(iv); free(names[i]);
    }
    free(names);

    if (m == 0) { logmsg("everything is up to date"); free(up); free(from); free(to); return 0; }

    /* Show the plan before doing anything. */
    logmsg("%d package%s to upgrade:", m, m == 1 ? "" : "s");
    for (int i = 0; i < m; i++)
        printf("    %-20s %s -> %s\n", up[i], from[i], to[i]);
    fflush(stdout);

    /* Apply: each upgrade downloads the new package; install_file removes the
     * old files and lays down the new (handles the version transition). Deps
     * of the new version are pulled too. */
    int ok = 0;
    for (int i = 0; i < m; i++) {
        seen_reset();
        IndexEntry e;
        if (!index_lookup(up[i], &e)) continue;
        char *pkg = fetch_pkg(e.filename, e.sha256, e.repo);
        install_file(pkg);
        free(pkg);
        /* pull any new dependencies the upgraded version introduced */
        if (e.deps && *e.deps) {
            char *deps = xstrdup(e.deps), *sv = NULL;
            for (char *t = strtok_r(deps, ",", &sv); t; t = strtok_r(NULL, ",", &sv)) {
                char *s = str_trim(t); if (!*s) continue;
                size_t k = strcspn(s, "<>=:"); char dn[128];
                snprintf(dn, sizeof dn, "%.*s", (int)k, s);
                if (*dn) install_name(dn);
            }
            free(deps);
        }
        index_entry_free(&e);
        ok++;
    }
    run_ldconfig();
    logmsg("upgraded %d/%d package%s", ok, m, m == 1 ? "" : "s");

    for (int i = 0; i < m; i++) { free(up[i]); free(from[i]); free(to[i]); }
    free(up); free(from); free(to);
    return 0;
}
