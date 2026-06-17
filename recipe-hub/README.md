# Blueberry Recipe Hub

A small, self-hostable web app for sharing **bpm recipes** (`PKGBUILD` files) for
Blueberry Linux. Accounts are required to upload; an admin approves ("publishes")
recipes, and published recipes are written out as plain `PKGBUILD` files for a
build pipeline to pick up.

Single turnkey image — no external database or services (SQLite under a volume).

## Run

```sh
cd recipe-hub
docker build -t blueberry-recipe-hub .
docker run -d -p 8000:8000 -v bbrecipes:/data --name recipes blueberry-recipe-hub
```

Open <http://localhost:8000> and **register** — the first account becomes the
admin. (Compose alternative: `docker compose up -d`.)

## How it works

- **Accounts**: register / log in (passwords hashed with werkzeug/pbkdf2,
  session cookie). The first user is admin and may grant others the *publish*
  right or *admin* from the **Admin** page.
- **Upload**: paste or upload a `PKGBUILD`. It's validated (must have `pkgname=`
  and a `package()` function); `pkgname`/`pkgver`/`pkgdesc` are parsed out.
  Re-uploading your recipe with the same `pkgname` updates it and resets it to
  *draft*.
- **Publish**: an admin/publisher toggles a recipe to *published*, which also
  writes `"/data/published/<name>/PKGBUILD"`. Point your builder
  (`tools/build-pkgs.sh`) at that tree, or sync it into `packages/`.

## Configuration

| Env | Default | Meaning |
|-----|---------|---------|
| `RECIPE_HUB_DATA` | `/data` | DB, session key, and `published/` tree |
| `PORT` | `8000` | HTTP port |

## Data layout (in the volume)

```
/data/recipe-hub.db          SQLite (users + recipes)
/data/secret_key             persisted Flask session secret
/data/published/<name>/PKGBUILD   approved recipes for the build pipeline
```

## Local dev (without Docker)

```sh
pip install -r requirements.txt
RECIPE_HUB_DATA=./data python app.py   # http://localhost:8000
```
