#!/usr/bin/env python3
"""Blueberry Recipe Hub — a self-hostable site for sharing bpm recipes (PKGBUILDs).

Accounts are required to upload. The first registered user becomes the admin;
the admin can grant other users the "publish" right and approve recipes.
Approved (published) recipes are also written out as plain PKGBUILD files under
$DATA/published/<name>/PKGBUILD so a build pipeline can pick them up.

Single turnkey image: SQLite + uploaded content live under $DATA (default
/data), served by waitress. No external services.
"""
import os
import re
import sqlite3
import secrets
from datetime import datetime, timezone
from functools import wraps
from pathlib import Path

from flask import (Flask, g, redirect, render_template, request, session,
                   url_for, flash, abort, Response)
from werkzeug.security import generate_password_hash, check_password_hash

DATA = Path(os.environ.get("RECIPE_HUB_DATA", "/data"))
DATA.mkdir(parents=True, exist_ok=True)
DB_PATH = DATA / "recipe-hub.db"
PUBLISHED = DATA / "published"

app = Flask(__name__)
# Persist the session secret so logins survive restarts.
_secret = DATA / "secret_key"
if not _secret.exists():
    _secret.write_text(secrets.token_hex(32))
app.secret_key = _secret.read_text().strip()
app.config["MAX_CONTENT_LENGTH"] = 512 * 1024  # 512 KiB per PKGBUILD

NAME_RE = re.compile(r"^[a-z0-9][a-z0-9._+-]{0,63}$")


# ── database ──────────────────────────────────────────────────────────────────
def db():
    if "db" not in g:
        g.db = sqlite3.connect(DB_PATH)
        g.db.row_factory = sqlite3.Row
        g.db.execute("PRAGMA foreign_keys=ON")
    return g.db


@app.teardown_appcontext
def _close(_exc):
    d = g.pop("db", None)
    if d is not None:
        d.close()


def init_db():
    con = sqlite3.connect(DB_PATH)
    con.executescript(
        """
        CREATE TABLE IF NOT EXISTS users (
            id INTEGER PRIMARY KEY,
            username TEXT UNIQUE NOT NULL,
            pwhash TEXT NOT NULL,
            is_admin INTEGER NOT NULL DEFAULT 0,
            can_publish INTEGER NOT NULL DEFAULT 0,
            created TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS recipes (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL,
            pkgver TEXT NOT NULL DEFAULT '',
            owner_id INTEGER NOT NULL REFERENCES users(id),
            content TEXT NOT NULL,
            description TEXT NOT NULL DEFAULT '',
            published INTEGER NOT NULL DEFAULT 0,
            created TEXT NOT NULL,
            updated TEXT NOT NULL
        );
        """
    )
    con.commit()
    con.close()


def now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")


# ── auth helpers ──────────────────────────────────────────────────────────────
def current_user():
    uid = session.get("uid")
    if uid is None:
        return None
    return db().execute("SELECT * FROM users WHERE id=?", (uid,)).fetchone()


@app.context_processor
def inject_user():
    return {"user": current_user()}


def login_required(f):
    @wraps(f)
    def wrap(*a, **kw):
        if current_user() is None:
            flash("Please log in.", "warn")
            return redirect(url_for("login", next=request.path))
        return f(*a, **kw)
    return wrap


def admin_required(f):
    @wraps(f)
    def wrap(*a, **kw):
        u = current_user()
        if u is None or not u["is_admin"]:
            abort(403)
        return f(*a, **kw)
    return wrap


# ── PKGBUILD parsing/validation ───────────────────────────────────────────────
def parse_pkgbuild(text):
    """Pull pkgname/pkgver/pkgdesc out of a PKGBUILD; validate it looks real."""
    if "pkgname=" not in text or ("package()" not in text and "package ()" not in text):
        return None, "Not a PKGBUILD (needs pkgname= and a package() function)."

    def field(key):
        m = re.search(rf"^{key}=([^\n]+)", text, re.MULTILINE)
        if not m:
            return ""
        return m.group(1).strip().strip("'\"")

    name = field("pkgname")
    if not NAME_RE.match(name):
        return None, f"Invalid pkgname: {name!r}"
    return {"name": name, "pkgver": field("pkgver"), "desc": field("pkgdesc")}, None


def write_published(name, content):
    d = PUBLISHED / name
    d.mkdir(parents=True, exist_ok=True)
    (d / "PKGBUILD").write_text(content)


def unwrite_published(name):
    p = PUBLISHED / name / "PKGBUILD"
    if p.exists():
        p.unlink()


# ── routes ────────────────────────────────────────────────────────────────────
@app.route("/")
def index():
    rows = db().execute(
        """SELECT r.*, u.username AS owner FROM recipes r
           JOIN users u ON u.id=r.owner_id
           ORDER BY r.published DESC, r.updated DESC"""
    ).fetchall()
    return render_template("index.html", recipes=rows)


@app.route("/register", methods=["GET", "POST"])
def register():
    if request.method == "POST":
        username = (request.form.get("username") or "").strip().lower()
        password = request.form.get("password") or ""
        if not NAME_RE.match(username):
            flash("Username: lowercase letters/digits/._+- , up to 64 chars.", "error")
        elif len(password) < 8:
            flash("Password must be at least 8 characters.", "error")
        else:
            con = db()
            first = con.execute("SELECT COUNT(*) c FROM users").fetchone()["c"] == 0
            try:
                con.execute(
                    "INSERT INTO users(username,pwhash,is_admin,can_publish,created)"
                    " VALUES(?,?,?,?,?)",
                    (username, generate_password_hash(password),
                     1 if first else 0, 1 if first else 0, now()),
                )
                con.commit()
            except sqlite3.IntegrityError:
                flash("That username is taken.", "error")
                return render_template("register.html")
            flash("Account created — the first user is the admin." if first
                  else "Account created. Log in to upload recipes.", "ok")
            return redirect(url_for("login"))
    return render_template("register.html")


@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        username = (request.form.get("username") or "").strip().lower()
        password = request.form.get("password") or ""
        row = db().execute("SELECT * FROM users WHERE username=?", (username,)).fetchone()
        if row and check_password_hash(row["pwhash"], password):
            session["uid"] = row["id"]
            return redirect(request.args.get("next") or url_for("index"))
        flash("Invalid username or password.", "error")
    return render_template("login.html")


@app.route("/logout")
def logout():
    session.clear()
    return redirect(url_for("index"))


@app.route("/upload", methods=["GET", "POST"])
@login_required
def upload():
    if request.method == "POST":
        content = ""
        f = request.files.get("file")
        if f and f.filename:
            content = f.read().decode("utf-8", "replace")
        else:
            content = request.form.get("content") or ""
        content = content.replace("\r\n", "\n").strip() + "\n"
        meta, err = parse_pkgbuild(content)
        if err:
            flash(err, "error")
            return render_template("upload.html", content=content)
        con = db()
        u = current_user()
        existing = con.execute(
            "SELECT * FROM recipes WHERE name=? AND owner_id=?", (meta["name"], u["id"])
        ).fetchone()
        if existing:
            con.execute(
                "UPDATE recipes SET pkgver=?,content=?,description=?,updated=?,published=0"
                " WHERE id=?",
                (meta["pkgver"], content, meta["desc"], now(), existing["id"]),
            )
            unwrite_published(meta["name"])  # re-review after an edit
            rid = existing["id"]
        else:
            cur = con.execute(
                "INSERT INTO recipes(name,pkgver,owner_id,content,description,created,updated)"
                " VALUES(?,?,?,?,?,?,?)",
                (meta["name"], meta["pkgver"], u["id"], content, meta["desc"], now(), now()),
            )
            rid = cur.lastrowid
        con.commit()
        flash("Recipe saved. An admin must publish it before it ships.", "ok")
        return redirect(url_for("recipe", rid=rid))
    return render_template("upload.html", content="")


@app.route("/recipe/<int:rid>")
def recipe(rid):
    row = db().execute(
        """SELECT r.*, u.username AS owner FROM recipes r
           JOIN users u ON u.id=r.owner_id WHERE r.id=?""", (rid,)
    ).fetchone()
    if not row:
        abort(404)
    return render_template("recipe.html", r=row)


@app.route("/recipe/<int:rid>/raw")
def recipe_raw(rid):
    row = db().execute("SELECT * FROM recipes WHERE id=?", (rid,)).fetchone()
    if not row:
        abort(404)
    return Response(row["content"], mimetype="text/plain",
                    headers={"Content-Disposition": "attachment; filename=PKGBUILD"})


@app.route("/recipe/<int:rid>/publish", methods=["POST"])
@login_required
def publish(rid):
    u = current_user()
    if not (u["is_admin"] or u["can_publish"]):
        abort(403)
    row = db().execute("SELECT * FROM recipes WHERE id=?", (rid,)).fetchone()
    if not row:
        abort(404)
    new = 0 if row["published"] else 1
    db().execute("UPDATE recipes SET published=? WHERE id=?", (new, rid))
    db().commit()
    if new:
        write_published(row["name"], row["content"])
        flash(f"Published {row['name']} → {PUBLISHED}/{row['name']}/PKGBUILD", "ok")
    else:
        unwrite_published(row["name"])
        flash(f"Unpublished {row['name']}.", "ok")
    return redirect(url_for("recipe", rid=rid))


@app.route("/recipe/<int:rid>/delete", methods=["POST"])
@login_required
def delete(rid):
    u = current_user()
    row = db().execute("SELECT * FROM recipes WHERE id=?", (rid,)).fetchone()
    if not row:
        abort(404)
    if not (u["is_admin"] or row["owner_id"] == u["id"]):
        abort(403)
    db().execute("DELETE FROM recipes WHERE id=?", (rid,))
    db().commit()
    unwrite_published(row["name"])
    flash("Recipe deleted.", "ok")
    return redirect(url_for("index"))


@app.route("/admin", methods=["GET", "POST"])
@admin_required
def admin():
    con = db()
    if request.method == "POST":
        uid = int(request.form["uid"])
        if uid != session["uid"]:  # don't let admin demote themselves by accident
            field = request.form["field"]
            if field in ("can_publish", "is_admin"):
                val = 1 if request.form.get("value") == "1" else 0
                con.execute(f"UPDATE users SET {field}=? WHERE id=?", (val, uid))
                con.commit()
        return redirect(url_for("admin"))
    users = con.execute("SELECT * FROM users ORDER BY id").fetchall()
    return render_template("admin.html", users=users)


@app.route("/healthz")
def healthz():
    return "ok\n"


init_db()

if __name__ == "__main__":
    from waitress import serve
    port = int(os.environ.get("PORT", "8000"))
    print(f"Blueberry Recipe Hub on :{port} (data: {DATA})")
    serve(app, host="0.0.0.0", port=port)
