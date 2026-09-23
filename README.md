# www_installer

Deploy tooling for the Python/Django web apps hosted as `app.vdwaal.net` on CloudLinux.
This repo is the **canonical, versioned home** of the deploy scripts (`activate.sh` /
`rollback.sh`) and a **copy-me** deploy workflow template. It is cloned onto the deploy host
as `~/deploy-tools` and both CI and manual operations run the scripts from there.

Each app repo carries its **own, self-contained** deploy workflow (a copy of the template)
with its own secrets — there is deliberately **no** cross-repo reusable workflow, so the
pattern works for private repos and repos owned by other people, which cannot reference a
reusable workflow living here.

## New CI-driven model (current)

Move-based, non-interactive ("Option B"). Each release is rsynced into
`releases/<app>_<tag>/`, then `activate.sh` stops the app, parks the current release,
promotes the new one, installs deps, migrates, and restarts — with `rollback.sh` to revert.

- `scripts/activate.sh` — bring a release live. `activate.sh <app> <tag>`.
- `scripts/rollback.sh` — revert a failed activate using its state file.
  `rollback.sh <app> [--restore-db [--force-restore]]`.
- `scripts/sqlite_lib.sh` — sourced by both: consistent, WAL-safe SQLite backup/restore
  through the `sqlite3` CLI's online backup API (never a plain `cp`), plus backup
  retention (`SQLITE_BACKUP_KEEP`). Requires `sqlite3` on the server.
- `tests/sqlite_backup_test.sh` — run `bash tests/sqlite_backup_test.sh` before
  releasing a change to the scripts; drives the library under a live writer and
  `activate.sh` / `rollback.sh` end to end against a stubbed server tree.
- `scripts/app_config.sh.example` — per-app config template. The real `<app>_config.sh`
  is owned by the **app repo** (`deploy/<app>_config.sh`) and shipped to `~/domains/`.
- `docs/BOOTSTRAP.md` — one-time, by-hand server setup (shared state, tool checkout).
- `.github/workflows/sync-tools.yml` — this repo's own workflow; ships/updates
  `~/deploy-tools` on the server to a released tag (on `cz bump` tag push).
- `.github/workflow-templates/release-deploy.yaml` — the self-contained deploy workflow to
  copy into an app repo (test / release / ship / activate / smoke / rollback, all inline).

### Server layout
- `~/deploy-tools/` — this repo, checked out. Generic scripts + `app_config.sh.example`.
- `~/domains/` — the live apps: `releases/`, `shared/<app>/`, the live `<domain>` dirs,
  and each `<app>_config.sh`. Deploy commands run from here.

### How another app repo adopts it
1. Bootstrap the server once per app (see [docs/BOOTSTRAP.md](docs/BOOTSTRAP.md)) — shared
   state (db/.env/media). `~/deploy-tools` is created automatically — by `sync-tools.yml`
   on the first tooling release, or clone-if-missing on the app's first deploy — so no
   manual clone is needed.
2. Copy `.github/workflow-templates/release-deploy.yaml` into the app repo's
   `.github/workflows/`, edit the marked per-repo values (`APP`, `VERSION_FILE`, build
   stack, rsync excludes, and `TOOLS_REPO` if this repo ever moves).
3. Add the app's filled-in config as `deploy/<app>_config.sh` (secret-free; secrets live
   in `shared/<app>/.env`).
4. Add the `SSH_*` secrets to the app repo (see Secrets below).
5. Push a `v*` tag → test → release → ship → activate + smoke-test, with automatic
   rollback on failure. All jobs run from the one workflow file in that repo.

### Secrets
Deploy needs `SSH_HOST`, `SSH_USER`, `SSH_PRIVATE_KEY`, `SSH_KNOWN_HOSTS`, and optionally
`SSH_PORT`. Because each repo's workflow is self-contained, secrets are defined **per
repository** under *Settings → Secrets and variables → Actions* — it is the same deploy
key/values in each one:
- in `www_installer` — used by `sync-tools.yml`;
- in each app repo — used directly by that repo's own deploy workflow.

No organization is required, and nothing here references another repo's workflow, so the
private-repo / cross-owner reusable-workflow access rules do not apply.

### Releasing a new version of this tooling
`cz bump` (commitizen; config in `.cz.toml`) bumps the version, writes the changelog, and
creates a `v<version>` tag:

```bash
cz bump
git push
git push origin v<version>
```

Push the tag by name: commitizen creates a lightweight tag, which `git push --follow-tags`
silently skips (it only pushes annotated tags).

The tag push triggers `sync-tools.yml`, which pins `~/deploy-tools` on the server to that
tag — so all apps run that version's scripts on their next deploy. Without commitizen,
`git tag vX.Y.Z && git push --tags` does the same. To pin the server manually or roll the
tooling back, dispatch `sync-tools.yml` with a `ref`, or on the host:
`git -C ~/deploy-tools fetch --tags --prune && git -C ~/deploy-tools checkout <tag>`.

## Deprecated: interactive model

`scripts/deploy.sh`, `scripts/install.sh`, and `scripts/parse_env.sh` are the older,
interactive (prompt-driven), copy-based deploy scripts that read env from
`public_html/.htaccess`. They are kept for apps not yet migrated to the CI model above, but
are **deprecated** — new apps should use `activate.sh`/`rollback.sh` + the self-contained
deploy workflow template. `build/` and `add_to_path.cmd` are Windows helpers for the local
`cz bump` flow of the app repos and are unrelated to server deploys.
