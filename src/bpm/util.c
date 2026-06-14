/* util.c — logging, allocation, strings, small filesystem helpers. */
#define _GNU_SOURCE
#include "bpm.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <errno.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <dirent.h>
#include <unistd.h>

void die(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    fputs("bpm: ", stderr); vfprintf(stderr, fmt, ap); fputc('\n', stderr);
    va_end(ap); exit(1);
}
void logmsg(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    fputs(":: ", stdout); vfprintf(stdout, fmt, ap); fputc('\n', stdout);
    va_end(ap); fflush(stdout);
}
void warn(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    fputs("bpm: warning: ", stderr); vfprintf(stderr, fmt, ap); fputc('\n', stderr);
    va_end(ap);
}

void *xmalloc(size_t n) {
    void *p = malloc(n ? n : 1);
    if (!p) die("out of memory");
    return p;
}
void *xrealloc(void *p, size_t n) {
    void *q = realloc(p, n ? n : 1);
    if (!q) die("out of memory");
    return q;
}
char *xstrdup(const char *s) {
    size_t n = strlen(s) + 1;
    char *p = xmalloc(n);
    memcpy(p, s, n);
    return p;
}
char *xasprintf(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    char *out = NULL;
    if (vasprintf(&out, fmt, ap) < 0) die("out of memory");
    va_end(ap);
    return out;
}

/* mkdir -p */
int mkdirs(const char *path) {
    if (!path || !*path) return 0;
    char *tmp = xstrdup(path);
    size_t n = strlen(tmp);
    if (n > 1 && tmp[n - 1] == '/') tmp[n - 1] = '\0';
    for (char *p = tmp + 1; *p; p++) {
        if (*p == '/') {
            *p = '\0';
            if (mkdir(tmp, 0755) < 0 && errno != EEXIST) { free(tmp); return -1; }
            *p = '/';
        }
    }
    int rc = (mkdir(tmp, 0755) < 0 && errno != EEXIST) ? -1 : 0;
    free(tmp);
    return rc;
}

int mkparents(const char *path) {
    char *tmp = xstrdup(path);
    char *slash = strrchr(tmp, '/');
    int rc = 0;
    if (slash && slash != tmp) { *slash = '\0'; rc = mkdirs(tmp); }
    free(tmp);
    return rc;
}

int file_exists(const char *path) {
    struct stat st;
    return stat(path, &st) == 0;
}

int write_file(const char *path, const void *buf, size_t n) {
    FILE *f = fopen(path, "wb");
    if (!f) return -1;
    size_t w = n ? fwrite(buf, 1, n, f) : 0;
    int rc = (w == n && fclose(f) == 0) ? 0 : -1;
    return rc;
}

char *read_file(const char *path, size_t *len_out) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    Buf b; buf_init(&b);
    char chunk[65536]; size_t r;
    while ((r = fread(chunk, 1, sizeof chunk, f)) > 0) buf_append(&b, chunk, r);
    fclose(f);
    buf_putc(&b, '\0');            /* NUL-terminate for text use */
    if (len_out) *len_out = b.len - 1;
    return b.data;
}

char *str_trim(char *s) {
    while (*s == ' ' || *s == '\t' || *s == '\n' || *s == '\r') s++;
    char *e = s + strlen(s);
    while (e > s && (e[-1] == ' ' || e[-1] == '\t' || e[-1] == '\n' || e[-1] == '\r'))
        *--e = '\0';
    return s;
}

int rm_rf(const char *path) {
    struct stat st;
    if (lstat(path, &st) < 0) return 0;
    if (S_ISDIR(st.st_mode)) {
        DIR *d = opendir(path);
        if (d) {
            struct dirent *de;
            while ((de = readdir(d))) {
                if (!strcmp(de->d_name, ".") || !strcmp(de->d_name, "..")) continue;
                char *child = xasprintf("%s/%s", path, de->d_name);
                rm_rf(child);
                free(child);
            }
            closedir(d);
        }
        return rmdir(path);
    }
    return unlink(path);
}

/* ── Buf ─────────────────────────────────────────────────────────────────── */
void buf_init(Buf *b) { b->data = NULL; b->len = b->cap = 0; }
void buf_append(Buf *b, const void *p, size_t n) {
    if (b->len + n > b->cap) {
        size_t cap = b->cap ? b->cap : 256;
        while (cap < b->len + n) cap *= 2;
        b->data = xrealloc(b->data, cap);
        b->cap = cap;
    }
    memcpy(b->data + b->len, p, n);
    b->len += n;
}
void buf_putc(Buf *b, char c) { buf_append(b, &c, 1); }
void buf_free(Buf *b) { free(b->data); buf_init(b); }
