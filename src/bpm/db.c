/* db.c — the local installed-package database.
 *   <root>/var/lib/bpm/db/<name>/desc   = the package's .PKGINFO text
 *   <root>/var/lib/bpm/db/<name>/files  = installed paths, one per line
 */
#include "bpm.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>

char *db_installed_version(const char *name) {
    char *desc = xasprintf("%s/%s/desc", g_db, name);
    size_t len; char *txt = read_file(desc, &len);
    free(desc);
    if (!txt) return NULL;
    char *ver = pkginfo_field(txt, "pkgver");
    free(txt);
    return ver;
}

/* qsort comparator: descending strcmp, so deepest paths come first. */
static int cmp_desc(const void *a, const void *b) {
    return -strcmp(*(const char *const *)a, *(const char *const *)b);
}

void db_remove_files(const char *name) {
    char *flist = xasprintf("%s/%s/files", g_db, name);
    size_t len; char *txt = read_file(flist, &len);
    free(flist);
    if (!txt) return;

    /* Collect lines. */
    char **lines = NULL; int n = 0;
    char *sv = NULL;
    for (char *p = strtok_r(txt, "\n", &sv); p; p = strtok_r(NULL, "\n", &sv)) {
        if (!*p) continue;
        lines = xrealloc(lines, (size_t)(n + 1) * sizeof *lines);
        lines[n++] = p;
    }
    qsort(lines, (size_t)n, sizeof *lines, cmp_desc);

    for (int i = 0; i < n; i++) {
        char *full = xasprintf("%s/%s", g_dest, lines[i]);
        struct stat st;
        if (lstat(full, &st) == 0) {
            if (S_ISDIR(st.st_mode)) rmdir(full);   /* only if empty */
            else unlink(full);
        }
        /* best-effort: prune now-empty parent directories */
        char *slash;
        while ((slash = strrchr(full, '/')) && slash != full) {
            *slash = '\0';
            if (rmdir(full) != 0) break;             /* stop at first non-empty */
        }
        free(full);
    }
    free(lines);
    free(txt);
}

int db_record(const char *name, const char *info, char **files, int nfiles) {
    char *dir = xasprintf("%s/%s", g_db, name);
    if (mkdirs(dir) != 0) { free(dir); return -1; }

    char *desc = xasprintf("%s/desc", dir);
    int rc = write_file(desc, info, strlen(info));
    free(desc);

    char *flist = xasprintf("%s/files", dir);
    Buf b; buf_init(&b);
    for (int i = 0; i < nfiles; i++) {
        buf_append(&b, files[i], strlen(files[i]));
        buf_putc(&b, '\n');
    }
    if (write_file(flist, b.data ? b.data : "", b.len) != 0) rc = -1;
    buf_free(&b);
    free(flist);
    free(dir);
    return rc;
}
