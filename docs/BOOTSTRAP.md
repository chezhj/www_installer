# Bootstrap: setting up the release layout (Option B — move-based)

Run once, by hand, over SSH. Not scripted on purpose — what needs moving differs per
app, and this touches the live site directly. Throughout, `<app>` is the application
name (the first argument to `activate.sh`, e.g. `swatchbook`) and `<domain>` is the
production hostname / live directory (e.g. `swatchbook.vdwaal.net`). Paths below assume
the CloudLinux account home holds a `domains/` directory; adjust to your `DOMAIN_BASE_DIR`.

## 0. Install the deploy tooling on the server

The deploy scripts are not copied per release — they live in a checkout of this repo
(`~/deploy-tools`) and are run from there, both by CI and by hand.

You normally do **not** need to clone it by hand: the `sync-tools.yml` workflow is
self-bootstrapping — the first `www_installer` version-tag push (or a manual dispatch)
clones `~/deploy-tools` if it is missing, then pins it to the tag. To seed it before the
first release, or to inspect it, the equivalent manual commands are:

```bash
git clone https://github.com/chezhj/www_installer ~/deploy-tools   # only if not present yet
git -C ~/deploy-tools fetch --tags --prune && git -C ~/deploy-tools checkout <tag>
git -C ~/deploy-tools describe --tags   # shows exactly which version is live
```

From then on, deploy actions run as (always from the domains dir, which is where the
per-app `<app>_config.sh` lives):

```bash
cd ~/domains && ~/deploy-tools/scripts/activate.sh <app> <tag>
cd ~/domains && ~/deploy-tools/scripts/rollback.sh <app>
```

## Why the live domain dir must be a real directory (not a symlink)

`cloudlinux-selector` resolves `--app-root` via `realpath()` and re-derives the expected
venv path from the resolved target on every `stop`/`start`/`restart` call — if the domain
path is a symlink pointing at a release directory, the derived venv path never matches the
real one (registered against the domain name), and every stop/start fails with
`"No such application or it's broken"`. Confirmed directly against this account via
`cloudlinux-selector get`: the registry's own stored venv path is correct — it's the
re-derivation on every call that's broken, for any symlinked app-root. `activate.sh`
refuses to run if it finds a symlink at the live path, specifically to catch this.

All `ln -s` commands below use absolute targets deliberately — that's what lets shared
state keep resolving correctly no matter which directory it ends up inside after a `mv`.

## 1. SQLite app (worked example: swatchbook)

If the domain path is currently a real directory already (a brand new app, never touched
by any of this), skip straight to "Both cases" below.

**If it's currently a symlink** (e.g. from earlier testing), convert it back first:

```bash
cd ~/domains

# 1. Confirm current state before touching anything
ls -la <domain>
readlink <domain>
test -L <domain> && echo "confirmed: currently a symlink"

# 2. Remove the symlink (removes only the link, not its target)
rm <domain>

# 3. Move the real release directory into its place
mv releases/<app>_<tag> <domain>

# 4. Confirm it's now a real directory
test -L <domain> && echo "still a symlink - stop here" || echo "confirmed: real directory"

# 5. Confirm shared-state symlinks survived the move (absolute paths - they should)
ls -la <domain>/db.sqlite3 <domain>/.env <domain>/public_html/media

# 6. Prove stop/start actually work now - don't just assume it
curl -I https://<domain>/
cloudlinux-selector stop  --json --interpreter python --app-root $HOME/domains/<domain>
cloudlinux-selector start --json --interpreter python --app-root $HOME/domains/<domain>
curl -I https://<domain>/
```

Both `cloudlinux-selector` calls must return `"result": "success"`, and the site must load
after, before trusting this in the pipeline.

### Both cases (first-time setup of shared state)

```bash
cd ~/domains
mkdir -p releases shared/<app>
SHARED="$HOME/domains/shared/<app>"
CURRENT="$HOME/domains/<domain>"   # must be a real directory by now

# Database
mv "${CURRENT}/db.sqlite3" "${SHARED}/db.sqlite3"
ln -s "${SHARED}/db.sqlite3" "${CURRENT}/db.sqlite3"

# Media. DJANGO_MEDIA_ROOT stays pointed at public_html/media - the web server serves
# uploads directly from that path in production, so MEDIA_ROOT can't point elsewhere.
# What changes is what public_html/media *is*: a symlink to shared storage, not a plain
# directory wiped every deploy. (This corresponds to a SHARED_PATHS entry
# "public_html/media:media" in <app>_config.sh.)
mkdir -p "${SHARED}/media"
mv "${CURRENT}/public_html/media/"* "${SHARED}/media/" 2>/dev/null || true
rm -rf "${CURRENT}/public_html/media"
ln -s "${SHARED}/media" "${CURRENT}/public_html/media"

# Env - pull real values from wherever they currently live (e.g.
# grep -i SetEnv <live>/public_html/.htaccess) rather than guessing
cat > "${SHARED}/.env" << 'EOF'
DJANGO_SECRET_KEY=...
DJANGO_ALLOWED_HOSTS=<domain>
EMAIL_HOST_PASSWORD=...
EOF
chmod 600 "${SHARED}/.env"
ln -sf "${SHARED}/.env" "${CURRENT}/.env"

# Sanity check + restart so the running process picks all of this up
ls -la "${CURRENT}/db.sqlite3" "${CURRENT}/public_html/media" "${CURRENT}/.env"
touch "${CURRENT}/tmp/restart.txt"
```

Note: `DJANGO_SETTINGS_MODULE` does NOT need to be in `.env` — `activate.sh` exports it
directly (from `<app>_config.sh`, falling back to `config.settings.prod`) before calling
`manage.py`, and `passenger_wsgi.py` sets it for the live app. It has to work that way:
`manage.py` defaults to `config.settings.dev` before `.env` is ever parsed.

## 2. MySQL app

```bash
cd ~/domains
mkdir -p releases shared/<app>
SHARED="$HOME/domains/shared/<app>"

# Create the credentials file mysqldump/mysql will use (never commit this, never let CI
# create it). This is the file MYSQL_CNF_PATH in <app>_config.sh points at:
cat > .my_<app>.cnf << 'EOF'
[client]
user=cpanel_db_user
password=REPLACE_ME
host=localhost
EOF
chmod 600 .my_<app>.cnf

# No database file to move - MySQL already lives outside any release directory. If the
# app has media uploads that need to survive deploys:
CURRENT="$HOME/domains/<domain>"   # must be a real directory
mkdir -p "${SHARED}/media"
mv "${CURRENT}/media/"* "${SHARED}/media/" 2>/dev/null || true
rm -rf "${CURRENT}/media"
ln -s "${SHARED}/media" "${CURRENT}/media"
```

## 3. Wire up the per-app config

Copy `~/deploy-tools/scripts/app_config.sh.example` to `~/domains/<app>_config.sh`, fill in
the real values, and confirm `activate.sh <app> <existing-tag>` would find everything it
expects (`VERSION_FILE`, `PYTHON_ENV`, `SHARED_PATHS`, shared DB/media/.env) before wiring
up CI. In the CI flow the app's own release workflow ships `deploy/<app>_config.sh` to
`~/domains/<app>_config.sh` on each deploy, so the committed copy in the app repo is the
source of truth.
