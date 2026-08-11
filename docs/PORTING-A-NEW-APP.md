# Porting the automated deploy to a new app repo

Repeatable checklist for onboarding a Django app repo to this deploy system. Covers the
**repo side** (the files you add/edit in the app repo) and points at
[`BOOTSTRAP.md`](BOOTSTRAP.md) for the **server side** (one-time per-app setup on the box).

Throughout, `<app>` is the short application name (the first arg to `activate.sh`, e.g.
`swatchbook`, `simflow`) and `<domain>` is the production hostname / live directory (e.g.
`simflow.vdwaal.net`). The two worked examples in this repo's history are **swatchbook**
(has a frontend build) and **simflow** (no frontend build) — diff their `release-deploy.yaml`
and `<app>_config.sh` to see exactly what changes per app.

---

## What the deploy is made of

1. **`.github/workflows/release-deploy.yaml`** in the app repo — self-contained pipeline:
   test → GitHub release → rsync ship → activate/smoke/rollback. Depends on no other
   workflow; the only shared thing is the server-side scripts.
2. **`deploy/<app>_config.sh`** in the app repo — secret-free per-app config, rsynced to
   `~/domains/<app>_config.sh` each deploy and sourced by the server scripts.
3. **`~/deploy-tools/scripts/{activate,rollback}.sh`** on the server (this repo) —
   clone-bootstrapped by the workflow if missing.

---

## Step 1 — Copy the workflow and edit the per-repo values

Copy an existing `release-deploy.yaml` into `<app-repo>/.github/workflows/`, then edit:

| What | Value |
|---|---|
| `env.APP` | `<app>` |
| `env.VERSION_FILE` | file carrying `__version__ = "X.Y.Z"` (e.g. `config/__init__.py`, `smart_training_checklist/__init__.py`) |
| `env.TOOLS_REPO` | usually unchanged (`https://github.com/chezhj/www_installer`) |
| `test` + `ship` `setup-python` version | the app's Python (must match the server venv) |
| **Frontend build blocks** | keep the `actions/setup-node` + `Build frontend` steps only if the repo has a `frontend/` build; otherwise **delete them from both the `test` and `ship` jobs** |
| **Rsync exclude list** | adjust to the repo's layout — see below |

**Trigger** stays `on: push: tags: "v*"`. If the repo also uses other tag prefixes (e.g.
`plugin-v*`, `sop*`), confirm they do **not** start with `v` so they can't trigger a deploy.

**Rsync exclude list** — the goal is to ship the runtime tree and nothing else. Always
keep the Django app package(s), `manage.py`, `passenger_wsgi.py`, `requirements.txt`
(regenerated in CI), and the version file. Exclude VCS/editor/tooling dirs, tests, docs,
dev-only scripts, build artifacts, logs, and `db.sqlite3` (symlinked from `shared/` when
`DATABASE_SOURCE=production`). Start from an existing repo's list and adjust.

**Requirements**: the workflow runs `poetry export` to produce a fully-pinned
`requirements.txt`, which the server installs with `pip install -r requirements.txt --no-deps`.
Ensure the repo declares `poetry-plugin-export` (in `pyproject.toml` under
`[tool.poetry.requires-plugins]`), or the CI step installs it (`pip install poetry poetry-plugin-export`).

## Step 2 — Add `deploy/<app>_config.sh`

Secret-free, committed. Copy an existing one and set:

```bash
DOMAIN="<domain>"
DOMAIN_BASE_DIR="/home/<acct>/domains/"           # trailing slash required
VERSION_FILE="<path to __version__ file>"
PYTHON_ENV="/home/<acct>/virtualenv/domains/<domain>/<pyver>/bin/activate"
# Only needed if the app's settings module differs from activate.sh's default
# (config.settings.prod):
DJANGO_SETTINGS_MODULE="<app.settings.prod module path>"

DATABASE_ENGINE="sqlite"          # sqlite | mysql
DATABASE_SOURCE="production"      # production = persist server DB + migrate;
                                  # repository = ship repo DB each deploy, no migrate

# "release_path:shared_name" symlinks (uploads/media etc.); db.sqlite3 + .env are
# handled automatically. Empty if the app has no such paths:
SHARED_PATHS=()

# Optional "manage.py <args>" run once after migrate. Each is skipped (not an error)
# if the activated release lacks that command. Use for content that ships with the app:
# POST_MIGRATE_COMMANDS=("<mgmt command> ...")

SMOKE_URL="https://<domain>/"
```

Key decisions:
- **`DATABASE_SOURCE`** — `production` when the live DB holds real data that must persist
  (migrations run, DB backed up first, symlinked from `shared/<app>/`). `repository` when
  the repo's `db.sqlite3` is the source of truth and replaces the live DB each deploy.
- **`POST_MIGRATE_COMMANDS`** — use to bundle data/content with the app (e.g. a fixture
  import command). Guarded by a `manage.py help --commands` check, so it is safe on rollback.

## Step 3 — Make `passenger_wsgi.py` load prod

The Passenger runtime imports the app repo's `passenger_wsgi.py`; whatever it sets as the
default `DJANGO_SETTINGS_MODULE` is what the live app runs. Ensure it defaults to the prod
settings module **before** Django is imported, e.g.:

```python
os.environ.setdefault("DJANGO_SETTINGS_MODULE", "<app>.settings.prod")
```

Watch for repos where the WSGI module only defines its callable under certain settings
(check the imported `wsgi.py`) — set the env var before that import, not after.

## Step 4 — Repo secrets (once)

Add on the app repo (Settings → Secrets and variables → Actions), same values as any
other app on the same server:

```bash
gh secret set SSH_HOST        --repo <owner>/<repo>
gh secret set SSH_USER        --repo <owner>/<repo>
gh secret set SSH_PORT        --repo <owner>/<repo>
gh secret set SSH_PRIVATE_KEY --repo <owner>/<repo> < path/to/id_deploy
gh secret set SSH_KNOWN_HOSTS --repo <owner>/<repo> < path/to/known_hosts
gh secret list --repo <owner>/<repo>   # verify
```

## Step 5 — Server bootstrap

Follow [`BOOTSTRAP.md`](BOOTSTRAP.md) to set up `~/domains/shared/<app>/` (`.env`,
`db.sqlite3`) and confirm the live domain dir is a real directory. For an **already-running**
app, migrate its existing live state into `shared/`:

```bash
LIVE=~/domains/<domain>; SHARED=~/domains/shared/<app>
mkdir -p "$SHARED"
# move existing .env and db into shared, symlink back so the running app keeps working:
[ -f "$LIVE/.env" ] && [ ! -L "$LIVE/.env" ] && mv "$LIVE/.env" "$SHARED/.env" && ln -s "$SHARED/.env" "$LIVE/.env"
[ -f "$LIVE/db.sqlite3" ] && [ ! -L "$LIVE/db.sqlite3" ] && mv "$LIVE/db.sqlite3" "$SHARED/db.sqlite3" && ln -s "$SHARED/db.sqlite3" "$LIVE/db.sqlite3"
[ -L "$LIVE" ] && echo "SYMLINK - fix per BOOTSTRAP.md" || echo "OK real dir"
```

`~/deploy-tools` is clone-bootstrapped by the workflow's "Ensure deploy tools present" step.

## Step 6 — First deploy

Cut and push a `v*` tag (commitizen does both, and its `push_all` post-bump hook pushes):

```bash
cz bump
gh run watch --repo <owner>/<repo>
```

The smoke test hits `SMOKE_URL` and auto-rolls-back on failure, so a bad first deploy
won't leave the site down. Manual rollback: `cd ~/domains && ~/deploy-tools/scripts/rollback.sh <app>`
(add `--restore-db` to also revert data if a migration ran).

---

## Quick checklist

- [ ] `release-deploy.yaml` copied; `APP`, `VERSION_FILE`, python version set
- [ ] frontend build blocks kept/removed to match the repo
- [ ] rsync exclude list adjusted to the repo layout
- [ ] `poetry-plugin-export` available for the requirements export
- [ ] `deploy/<app>_config.sh` added; `DATABASE_SOURCE` and `POST_MIGRATE_COMMANDS` decided
- [ ] `passenger_wsgi.py` defaults to prod settings
- [ ] `SSH_*` secrets set on the repo
- [ ] server `shared/<app>/` seeded (`.env`, `db.sqlite3`); live dir is a real directory
- [ ] first `cz bump` deploy green; `SMOKE_URL` returns 200
