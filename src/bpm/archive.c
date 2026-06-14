/* archive.c — zstd decompression (libzstd) + a ustar/pax/GNU tar reader.
 *
 * makepkg's bsdtar output is ustar with pax extended headers (type 'x') for
 * long paths and high-resolution mtimes, and occasionally GNU long-name records
 * ('L'/'K'). We honour pax "path"/"linkpath" overrides and GNU long names; all
 * other extended records (mtime, uid, ...) are ignored.
 */
#include "bpm.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zstd.h>

char *zst_decompress_file(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;

    ZSTD_DStream *ds = ZSTD_createDStream();
    if (!ds) { fclose(f); return NULL; }
    ZSTD_initDStream(ds);

    size_t in_cap = ZSTD_DStreamInSize();
    size_t out_cap = ZSTD_DStreamOutSize();
    char *in = xmalloc(in_cap);
    char *out = xmalloc(out_cap);
    Buf result; buf_init(&result);
    int ok = 1;

    size_t r;
    while ((r = fread(in, 1, in_cap, f)) > 0) {
        ZSTD_inBuffer ib = { in, r, 0 };
        while (ib.pos < ib.size) {
            ZSTD_outBuffer ob = { out, out_cap, 0 };
            size_t ret = ZSTD_decompressStream(ds, &ob, &ib);
            if (ZSTD_isError(ret)) { ok = 0; break; }
            buf_append(&result, out, ob.pos);
        }
        if (!ok) break;
    }
    if (ferror(f)) ok = 0;

    ZSTD_freeDStream(ds);
    free(in); free(out); fclose(f);
    if (!ok) { buf_free(&result); return NULL; }
    if (len) *len = result.len;
    return result.data;   /* caller frees */
}

/* ── tar ──────────────────────────────────────────────────────────────────── */

static unsigned parse_octal(const char *p, size_t n) {
    unsigned v = 0;
    while (n && (*p == ' ' || *p == '\0')) { p++; n--; }
    while (n && *p >= '0' && *p <= '7') { v = v * 8 + (unsigned)(*p - '0'); p++; n--; }
    return v;
}

/* Extract "path=" or "linkpath=" value from a pax extended-header block.
 * Records are "<len> <key>=<value>\n". Returns malloc'd value or NULL. */
static char *pax_value(const char *blk, size_t blksz, const char *key) {
    size_t keylen = strlen(key);
    const char *p = blk, *end = blk + blksz;
    while (p < end) {
        const char *sp = memchr(p, ' ', (size_t)(end - p));
        if (!sp) break;
        long reclen = strtol(p, NULL, 10);
        if (reclen <= 0 || p + reclen > end) break;
        const char *kv = sp + 1;                 /* "key=value\n" */
        const char *rec_end = p + reclen;
        const char *eq = memchr(kv, '=', (size_t)(rec_end - kv));
        if (eq && (size_t)(eq - kv) == keylen && !memcmp(kv, key, keylen)) {
            size_t vlen = (size_t)(rec_end - (eq + 1));
            if (vlen && eq[1 + vlen - 1] == '\n') vlen--;   /* drop trailing \n */
            char *v = xmalloc(vlen + 1);
            memcpy(v, eq + 1, vlen); v[vlen] = '\0';
            return v;
        }
        p = rec_end;
    }
    return NULL;
}

int tar_iterate(const char *buf, size_t len,
                int (*cb)(const TarEntry *, void *), void *ctx) {
    size_t off = 0;
    char *next_path = NULL;     /* pending name override (pax/GNU) */
    char *next_link = NULL;
    int empty = 0;

    while (off + 512 <= len) {
        const char *h = buf + off;

        /* End of archive: two consecutive zero blocks. */
        int zero = 1;
        for (int i = 0; i < 512; i++) if (h[i]) { zero = 0; break; }
        if (zero) { if (++empty >= 2) break; off += 512; continue; }
        empty = 0;

        unsigned size = parse_octal(h + 124, 12);
        char type = h[156];
        size_t data_off = off + 512;
        size_t blocks = (size + 511) / 512;
        if (data_off + blocks * 512 > len + 511) return -1; /* truncated */

        if (type == 'x' || type == 'g') {           /* pax extended header */
            char *pp = pax_value(buf + data_off, size, "path");
            char *lp = pax_value(buf + data_off, size, "linkpath");
            if (pp) { free(next_path); next_path = pp; }
            if (lp) { free(next_link); next_link = lp; }
            off = data_off + blocks * 512;
            continue;
        }
        if (type == 'L') {                           /* GNU long name */
            free(next_path);
            next_path = xmalloc(size + 1);
            memcpy(next_path, buf + data_off, size); next_path[size] = '\0';
            off = data_off + blocks * 512;
            continue;
        }
        if (type == 'K') {                           /* GNU long link */
            free(next_link);
            next_link = xmalloc(size + 1);
            memcpy(next_link, buf + data_off, size); next_link[size] = '\0';
            off = data_off + blocks * 512;
            continue;
        }

        /* Regular member. Build the name: prefix + name (ustar), or override. */
        char namebuf[260];   /* 155 prefix + '/' + 100 name + NUL */
        const char *name;
        if (next_path) {
            name = next_path;
        } else {
            const char *prefix = h + 345;
            if (prefix[0]) snprintf(namebuf, sizeof namebuf, "%.155s/%.100s", prefix, h);
            else           snprintf(namebuf, sizeof namebuf, "%.100s", h);
            name = namebuf;
        }
        char linkbuf[101];
        const char *link;
        if (next_link) { link = next_link; }
        else { snprintf(linkbuf, sizeof linkbuf, "%.100s", h + 157); link = linkbuf; }

        TarEntry e;
        e.name = name;
        e.linkname = link;
        e.data = buf + data_off;
        e.size = size;
        e.mode = parse_octal(h + 100, 8) & 07777;
        e.type = (type == '\0') ? '0' : type;

        int rc = cb(&e, ctx);
        free(next_path); next_path = NULL;
        free(next_link); next_link = NULL;
        if (rc) { return rc; }

        off = data_off + blocks * 512;
    }
    free(next_path); free(next_link);
    return 0;
}
