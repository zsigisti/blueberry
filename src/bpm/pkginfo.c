/* pkginfo.c — parse .PKGINFO text ("key = value" lines, repeated keys allowed). */
#include "bpm.h"
#include <stdlib.h>
#include <string.h>

/* Return malloc'd copy of the value for the first matching key, or NULL. */
char *pkginfo_field(const char *info, const char *key) {
    int n; char **all = pkginfo_field_all(info, key, &n);
    char *out = (n > 0) ? xstrdup(all[0]) : NULL;
    strv_free(all, n);
    return out;
}

/* Return all values for a (possibly repeated) key. *count set; free with
 * strv_free. */
char **pkginfo_field_all(const char *info, const char *key, int *count) {
    size_t klen = strlen(key);
    char **out = NULL; int n = 0;
    const char *line = info;
    while (line && *line) {
        const char *nl = strchr(line, '\n');
        size_t llen = nl ? (size_t)(nl - line) : strlen(line);
        /* match "<key> = " */
        if (llen > klen && !strncmp(line, key, klen)) {
            const char *p = line + klen;
            while (*p == ' ' || *p == '\t') p++;
            if (*p == '=') {
                p++;
                while (*p == ' ' || *p == '\t') p++;
                size_t vlen = (size_t)((line + llen) - p);
                char *v = xmalloc(vlen + 1);
                memcpy(v, p, vlen); v[vlen] = '\0';
                out = xrealloc(out, (size_t)(n + 1) * sizeof *out);
                out[n++] = v;
            }
        }
        line = nl ? nl + 1 : NULL;
    }
    *count = n;
    return out;
}

void strv_free(char **v, int n) {
    for (int i = 0; i < n; i++) free(v[i]);
    free(v);
}
