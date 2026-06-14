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
        else                              install_name(argv[i]);
    }
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
            /* append each line with the repo as the 6th field */
            size_t rl; char *body = read_file(tmp, &rl);
            if (body) {
                char *bsv = NULL;
                for (char *p = strtok_r(body, "\n", &bsv); p; p = strtok_r(NULL, "\n", &bsv)) {
                    if (!*p) continue;
                    buf_append(&idx, p, strlen(p));
                    buf_putc(&idx, '|');
                    buf_append(&idx, repo, strlen(repo));
                    buf_putc(&idx, '\n');
                }
                free(body);
            }
            got = 1; break;
        }
        if (!got) warn("all mirrors failed for repo '%s'", repo);
    }
    free(line); fclose(f);
    unlink(tmp); free(tmp);

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
    /* collect (name -> installed ver), compare to index, install newer */
    DIR *d = opendir(g_db);
    if (!d) return 0;
    char **names = NULL; int n = 0;
    struct dirent *de;
    while ((de = readdir(d))) {
        if (de->d_name[0] == '.') continue;
        names = xrealloc(names, (size_t)(n + 1) * sizeof *names);
        names[n++] = xstrdup(de->d_name);
    }
    closedir(d);

    for (int i = 0; i < n; i++) {
        char *iv = db_installed_version(names[i]);
        IndexEntry e;
        if (iv && index_lookup(names[i], &e)) {
            if (strcmp(iv, e.version) != 0) {
                seen_reset();
                install_name(names[i]);
            }
            index_entry_free(&e);
        }
        free(iv); free(names[i]);
    }
    free(names);
    return 0;
}
