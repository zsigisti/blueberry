//! Minimal HTTP/1.1 plumbing — pure std, no web framework.
//!
//! One request per connection (`Connection: close`), with hard size limits, so
//! the parser stays small and auditable. TLS and internet exposure are a reverse
//! proxy's job (see doc/WEBUI.md); this daemon binds localhost.

use std::collections::HashMap;
use std::io::{BufRead, Write};

const MAX_HEADERS: usize = 32 * 1024;
const MAX_BODY: usize = 2 * 1024 * 1024; // 2 MiB request cap
const MAX_LINE: usize = 8 * 1024; // per-line cap (request line / one header)

/// Read one line (up to and including '\n') without letting a newline-less flood
/// grow the buffer unbounded — `BufRead::read_line` would allocate the whole
/// thing before any size check. Returns "" at EOF, None on overflow or error.
fn read_line_capped<R: BufRead>(r: &mut R, max: usize) -> Option<String> {
    let mut buf: Vec<u8> = Vec::new();
    loop {
        let chunk = match r.fill_buf() {
            Ok(c) => c,
            Err(ref e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(_) => return None,
        };
        if chunk.is_empty() {
            break; // EOF
        }
        if let Some(i) = chunk.iter().position(|&b| b == b'\n') {
            buf.extend_from_slice(&chunk[..=i]);
            r.consume(i + 1);
            break;
        }
        let n = chunk.len();
        buf.extend_from_slice(chunk);
        r.consume(n);
        if buf.len() > max {
            return None;
        }
    }
    if buf.len() > max {
        return None;
    }
    String::from_utf8(buf).ok()
}

pub struct Request {
    pub method: String,
    pub path: String,
    pub query: String,
    pub headers: HashMap<String, String>,
    pub body: Vec<u8>,
}

impl Request {
    pub fn header(&self, k: &str) -> Option<&str> {
        self.headers.get(&k.to_ascii_lowercase()).map(String::as_str)
    }

    /// Value of a cookie by name from the `Cookie` header.
    pub fn cookie(&self, name: &str) -> Option<String> {
        let raw = self.header("cookie")?;
        for part in raw.split(';') {
            let part = part.trim();
            if let Some((k, v)) = part.split_once('=') {
                if k == name {
                    return Some(v.to_string());
                }
            }
        }
        None
    }

    /// Parse the JSON body, or None if it isn't valid JSON.
    pub fn json(&self) -> Option<serde_json::Value> {
        serde_json::from_slice(&self.body).ok()
    }
}

/// Read exactly one request from any buffered stream (plain TCP or TLS).
/// Returns None on EOF or a malformed/oversized request.
pub fn read_request<R: BufRead>(reader: &mut R) -> Option<Request> {
    let line = read_line_capped(reader, MAX_LINE)?;
    if line.is_empty() {
        return None; // EOF before a request line
    }
    let mut it = line.trim_end().split_whitespace();
    let method = it.next()?.to_string();
    let target = it.next()?.to_string();
    let (path, query) = match target.split_once('?') {
        Some((p, q)) => (p.to_string(), q.to_string()),
        None => (target, String::new()),
    };

    let mut headers = HashMap::new();
    let mut total = 0usize;
    loop {
        let h = read_line_capped(reader, MAX_LINE)?;
        if h.is_empty() {
            break; // EOF
        }
        total += h.len();
        if total > MAX_HEADERS {
            return None;
        }
        let t = h.trim_end();
        if t.is_empty() {
            break;
        }
        if let Some((k, v)) = t.split_once(':') {
            headers.insert(k.trim().to_ascii_lowercase(), v.trim().to_string());
        }
    }

    let len: usize = headers
        .get("content-length")
        .and_then(|v| v.parse().ok())
        .unwrap_or(0);
    if len > MAX_BODY {
        return None;
    }
    let mut body = vec![0u8; len];
    if len > 0 {
        reader.read_exact(&mut body).ok()?;
    }

    Some(Request { method, path, query, headers, body })
}

pub struct Response {
    pub status: u16,
    pub content_type: String,
    pub body: Vec<u8>,
    pub extra: Vec<(String, String)>,
}

impl Response {
    pub fn json(status: u16, v: serde_json::Value) -> Response {
        Response {
            status,
            content_type: "application/json".into(),
            body: v.to_string().into_bytes(),
            extra: vec![],
        }
    }

    pub fn error(status: u16, msg: &str) -> Response {
        Response::json(status, serde_json::json!({ "error": msg }))
    }

    pub fn bytes(status: u16, content_type: &str, body: Vec<u8>) -> Response {
        Response { status, content_type: content_type.into(), body, extra: vec![] }
    }

    pub fn with_header(mut self, k: &str, v: &str) -> Response {
        self.extra.push((k.into(), v.into()));
        self
    }

    pub fn write<W: Write>(&self, stream: &mut W) {
        let reason = match self.status {
            200 => "OK",
            201 => "Created",
            400 => "Bad Request",
            401 => "Unauthorized",
            403 => "Forbidden",
            404 => "Not Found",
            405 => "Method Not Allowed",
            429 => "Too Many Requests",
            500 => "Internal Server Error",
            501 => "Not Implemented",
            _ => "OK",
        };
        let mut head = format!(
            "HTTP/1.1 {} {}\r\nContent-Type: {}\r\nContent-Length: {}\r\nConnection: close\r\n",
            self.status,
            reason,
            self.content_type,
            self.body.len()
        );
        // Security headers on every response.
        head.push_str("X-Content-Type-Options: nosniff\r\n");
        head.push_str("X-Frame-Options: DENY\r\n");
        head.push_str("Referrer-Policy: no-referrer\r\n");
        // Always-HTTPS: pin the browser to TLS for a year.
        head.push_str("Strict-Transport-Security: max-age=31536000\r\n");
        // No inline styles/scripts anywhere (pure external app.js, no CSS), so the
        // CSP can stay tight: self-only, no framing, no base-tag hijack.
        head.push_str(
            "Content-Security-Policy: default-src 'self'; frame-ancestors 'none'; base-uri 'none'\r\n",
        );
        for (k, v) in &self.extra {
            head.push_str(&format!("{k}: {v}\r\n"));
        }
        head.push_str("\r\n");
        let _ = stream.write_all(head.as_bytes());
        let _ = stream.write_all(&self.body);
        let _ = stream.flush();
    }
}
