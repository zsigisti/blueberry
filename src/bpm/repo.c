/* repo.c — repos.conf, the repo index, and package downloads.
 *
 * repos.conf line:  <name> <url1> [url2 ...]   (extra urls are mirrors)
 * index line:       name|version|filename|sha256|dep1,dep2,...|repo
 *
 * Repos serve a plain `bpm.index` (written by tools/mkrepo.sh / blueberry-repo-sync).
 */
#include "bpm.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

void index_entry_free(IndexEntry *e) {
    free(e->name); free(e->version); free(e->filename);
    free(e->sha256); free(e->deps); free(e->repo);
    memset(e, 0, sizeof *e);
}

/* Split "a|b|c|..." into up to 6 fields (malloc'd copies). Missing -> "". */
static void split6(const char *line, IndexEntry *e) {
    char **slots[6] = { &e->name, &e->version, &e->filename,
                        &e->sha256, &e->deps, &e->repo };
    const char *p = line;
    for (int i = 0; i < 6; i++) {
        const char *bar = strchr(p, '|');
        size_t n = bar ? (size_t)(bar - p) : strlen(p);
        char *v = xmalloc(n + 1);
        memcpy(v, p, n); v[n] = '\0';
        *slots[i] = v;
        if (!bar) { for (int j = i + 1; j < 6; j++) *slots[j] = xstrdup(""); return; }
        p = bar + 1;
    }
}

int index_lookup(const char *name, IndexEntry *e) {
    FILE *f = fopen(g_index, "r");
    if (!f) return 0;
    char *line = NULL; size_t cap = 0; ssize_t len;
    size_t nlen = strlen(name);
    int found = 0;
    while ((len = getline(&line, &cap, f)) > 0) {
        if ((size_t)len > nlen && !strncmp(line, name, nlen) && line[nlen] == '|') {
            if (line[len-1] == '\n') line[len-1] = '\0';
            split6(line, e);
            found = 1; break;
        }
    }
    free(line); fclose(f);
    return found;
}

/* Mirror URLs for a repo. Returns malloc'd NULL-terminated argv; *count set. */
char **repo_mirrors(const char *repo, int *count) {
    *count = 0;
    FILE *f = fopen(g_conf, "r");
    if (!f) return NULL;
    char **out = NULL; int n = 0;
    char *line = NULL; size_t cap = 0; ssize_t len;
    size_t rlen = strlen(repo);
    while ((len = getline(&line, &cap, f)) > 0) {
        char *s = str_trim(line);
        if (!*s || *s == '#') continue;
        if (strncmp(s, repo, rlen) != 0 || (s[rlen] != ' ' && s[rlen] != '\t'))
            continue;
        char *p = s + rlen;
        char *tok, *sv = NULL;
        while ((tok = strtok_r(p, " \t", &sv)) != NULL) {
            p = NULL;
            out = xrealloc(out, (size_t)(n + 2) * sizeof *out);
            out[n++] = xstrdup(tok);
        }
        break;
    }
    free(line); fclose(f);
    if (out) out[n] = NULL;
    *count = n;
    return out;
}

/* Download <filename> from a mirror of <repo>, verify sha, into the cache. */
char *fetch_pkg(const char *filename, const char *sha256, const char *repo) {
    char *out = xasprintf("%s/%s", g_cache, filename);

    if (file_exists(out) && sha256 && *sha256) {
        char have[65];
        if (sha256_file_hex(out, have) == 0 && !strcmp(have, sha256))
            return out;   /* already cached and current */
    }
    mkdirs(g_cache);

    int n; char **mirrors = repo_mirrors(repo, &n);
    int got = 0;
    for (int i = 0; i < n; i++) {
        char *url = xasprintf("%s/%s", mirrors[i], filename);
        int rc = http_get(url, out);
        free(url);
        if (rc == 0) { got = 1; break; }
        warn("mirror unreachable: %s", mirrors[i]);
    }
    strv_free(mirrors, n);
    if (!got) { free(out); die("all mirrors failed for %s (repo '%s')", filename, repo); }

    if (sha256 && *sha256) {
        char have[65];
        if (sha256_file_hex(out, have) != 0 || strcmp(have, sha256) != 0) {
            free(out); die("checksum mismatch for %s", filename);
        }
    }
    return out;
}
