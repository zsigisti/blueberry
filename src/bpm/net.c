/* net.c — minimal HTTP/1.1 GET over TCP. http:// only (LAN repo; no TLS).
 * Handles Content-Length, chunked transfer-encoding, connection-close bodies,
 * and a few redirects. Writes the body to a file. */
#define _GNU_SOURCE
#include "bpm.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/socket.h>
#include <netdb.h>

/* Parse http://host[:port]/path -> malloc'd host, path; *port set. 0 ok. */
static int parse_url(const char *url, char **host, char **port, char **path) {
    if (strncmp(url, "http://", 7) != 0) return -1;
    const char *p = url + 7;
    const char *slash = strchr(p, '/');
    const char *hostend = slash ? slash : p + strlen(p);
    const char *colon = memchr(p, ':', (size_t)(hostend - p));

    size_t hlen = colon ? (size_t)(colon - p) : (size_t)(hostend - p);
    *host = xmalloc(hlen + 1);
    memcpy(*host, p, hlen); (*host)[hlen] = '\0';

    if (colon) {
        size_t plen = (size_t)(hostend - (colon + 1));
        *port = xmalloc(plen + 1);
        memcpy(*port, colon + 1, plen); (*port)[plen] = '\0';
    } else {
        *port = xstrdup("80");
    }
    *path = xstrdup(slash ? slash : "/");
    return 0;
}

static int tcp_connect(const char *host, const char *port) {
    struct addrinfo hints, *res, *rp;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host, port, &hints, &res) != 0) return -1;
    int fd = -1;
    for (rp = res; rp; rp = rp->ai_next) {
        fd = socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
        if (fd < 0) continue;
        if (connect(fd, rp->ai_addr, rp->ai_addrlen) == 0) break;
        close(fd); fd = -1;
    }
    freeaddrinfo(res);
    return fd;
}

static int read_all(int fd, void *buf, size_t n) {
    char *p = buf; size_t got = 0;
    while (got < n) {
        ssize_t r = read(fd, p + got, n - got);
        if (r < 0) { if (errno == EINTR) continue; return -1; }
        if (r == 0) break;
        got += (size_t)r;
    }
    return (int)got;
}

static int write_all(int fd, const void *buf, size_t n) {
    const char *p = buf; size_t put = 0;
    while (put < n) {
        ssize_t w = write(fd, p + put, n - put);
        if (w < 0) { if (errno == EINTR) continue; return -1; }
        put += (size_t)w;
    }
    return 0;
}

/* Read into b until "\r\n\r\n"; leftover body bytes stay in b after headers. */
static int read_headers(int fd, Buf *b, size_t *hdr_end) {
    char c;
    for (;;) {
        ssize_t r = read(fd, &c, 1);
        if (r < 0) { if (errno == EINTR) continue; return -1; }
        if (r == 0) return -1;
        buf_putc(b, c);
        if (b->len >= 4 && memcmp(b->data + b->len - 4, "\r\n\r\n", 4) == 0) {
            *hdr_end = b->len; return 0;
        }
        if (b->len > 65536) return -1;     /* runaway headers */
    }
}

/* case-insensitive header lookup within the header block [buf,end). */
static const char *hdr_find(const char *buf, size_t end, const char *name) {
    size_t nlen = strlen(name);
    for (size_t i = 0; i + nlen < end; i++) {
        if ((i == 0 || buf[i-1] == '\n') && strncasecmp(buf + i, name, nlen) == 0
            && buf[i + nlen] == ':') {
            const char *v = buf + i + nlen + 1;
            while (*v == ' ' || *v == '\t') v++;
            return v;
        }
    }
    return NULL;
}

#define MAX_REDIRECTS 5

int http_get(const char *url, const char *outpath) {
    char *cur = xstrdup(url);
    int rc = -1;

    for (int hop = 0; hop < MAX_REDIRECTS; hop++) {
        char *host = NULL, *port = NULL, *path = NULL;
        if (parse_url(cur, &host, &port, &path) != 0) break;

        int fd = tcp_connect(host, port);
        if (fd < 0) { free(host); free(port); free(path); break; }

        char *req = xasprintf(
            "GET %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: bpm/%s\r\n"
            "Accept: */*\r\nConnection: close\r\n\r\n",
            path, host, BPM_VERSION);
        int wr = write_all(fd, req, strlen(req));
        free(req); free(host); free(port); free(path);
        if (wr < 0) { close(fd); break; }

        Buf hb; buf_init(&hb);
        size_t hdr_end = 0;
        if (read_headers(fd, &hb, &hdr_end) != 0) { close(fd); buf_free(&hb); break; }

        /* Status line: "HTTP/1.1 NNN ..." */
        int status = 0;
        if (hb.len > 12) status = atoi(hb.data + 9);

        if (status >= 300 && status < 400) {
            const char *loc = hdr_find(hb.data, hdr_end, "Location");
            if (loc) {
                const char *e = strpbrk(loc, "\r\n");
                size_t llen = e ? (size_t)(e - loc) : strlen(loc);
                char *next = xmalloc(llen + 1);
                memcpy(next, loc, llen); next[llen] = '\0';
                free(cur); cur = next;
                close(fd); buf_free(&hb);
                continue;                   /* follow redirect */
            }
            close(fd); buf_free(&hb); break;
        }
        if (status < 200 || status >= 300) { close(fd); buf_free(&hb); break; }

        int chunked = 0;
        const char *te = hdr_find(hb.data, hdr_end, "Transfer-Encoding");
        if (te && strncasecmp(te, "chunked", 7) == 0) chunked = 1;
        long clen = -1;
        const char *cl = hdr_find(hb.data, hdr_end, "Content-Length");
        if (cl) clen = atol(cl);

        FILE *out = fopen(outpath, "wb");
        if (!out) { close(fd); buf_free(&hb); break; }

        /* Body bytes already buffered past the headers. */
        Buf body; buf_init(&body);
        if (hb.len > hdr_end) buf_append(&body, hb.data + hdr_end, hb.len - hdr_end);
        buf_free(&hb);

        int ok = 1;
        if (chunked) {
            /* Decode chunked: pull more from fd as needed. */
            size_t pos = 0;
            for (;;) {
                /* ensure a line is available */
                char *nl;
                while (!(nl = memchr(body.data + pos, '\n', body.len - pos))) {
                    char tmp[65536];
                    int r = read(fd, tmp, sizeof tmp);
                    if (r <= 0) { ok = 0; break; }
                    buf_append(&body, tmp, (size_t)r);
                }
                if (!ok) break;
                long csz = strtol(body.data + pos, NULL, 16);
                pos = (size_t)(nl - body.data) + 1;
                if (csz == 0) break;
                while (body.len - pos < (size_t)csz + 2) {
                    char tmp[65536];
                    int r = read(fd, tmp, sizeof tmp);
                    if (r <= 0) { ok = 0; break; }
                    buf_append(&body, tmp, (size_t)r);
                }
                if (!ok) break;
                fwrite(body.data + pos, 1, (size_t)csz, out);
                pos += (size_t)csz + 2;     /* skip data + trailing CRLF */
            }
        } else {
            if (body.len) fwrite(body.data, 1, body.len, out);
            long remaining = (clen >= 0) ? clen - (long)body.len : -1;
            char tmp[65536];
            for (;;) {
                if (remaining == 0) break;
                int want = sizeof tmp;
                if (remaining > 0 && remaining < want) want = (int)remaining;
                int r = read_all(fd, tmp, (size_t)want);
                if (r < 0) { ok = 0; break; }
                if (r == 0) break;          /* connection closed */
                fwrite(tmp, 1, (size_t)r, out);
                if (remaining > 0) remaining -= r;
                if (r < want && remaining < 0) { /* keep reading until close */ }
            }
        }
        buf_free(&body);
        fclose(out);
        close(fd);
        rc = ok ? 0 : -1;
        break;
    }
    free(cur);
    return rc;
}
