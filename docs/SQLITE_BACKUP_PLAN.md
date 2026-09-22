# Plan: consistent, WAL-safe SQLite backup and restore

**Created**: 2026-09-22
**Requested by**: simflow `docs/PRE_RELEASE_PLAN.md`, step 0.2. That plan's step 4.1
(turning on WAL) stays blocked until this ships.
**Affects**: every SQLite app deployed with these scripts (simflow, swatchbook, …),
so each change must keep working for an app that never turns WAL on.

---

## What is wrong today

The pre-release plan is right about WAL, but the problem is wider than WAL. Four
places touch the database file, and all four go wrong:

| # | Where | What it does | Problem |
|---|---|---|---|
| A | `activate.sh` step 2 | `cp db.sqlite3 db.sqlite3.backup_<ts>` | **Runs before step 3 stops the app**, so it copies a database that is being written to. `cp` reads the file sequentially. If a transaction commits while the copy runs, the copy mixes pages from before and after the commit: a corrupt backup that nobody finds out about until they need it. This happens in rollback-journal mode too, and the plugin writes every second (every half second after simflow's step 3.5). Under WAL, commits are in `-wal` and `cp` misses them completely. |
| B | `activate.sh` step 2 | Nothing reads the backup back | A bad or empty backup still counts as success. The deploy goes on to `migrate` without a working way back. |
| C | `rollback.sh --restore-db` | `cp backup db.sqlite3` | **Dangerous under WAL.** The old `db.sqlite3-wal` / `-shm` files stay next to the file that was just copied in. When SQLite next opens it, it applies the WAL frames from the *migrated* database onto the *restored* one, which corrupts it. Passenger workers that were killed by `stop` leave a `-wal` file behind, so this is the usual situation, not a rare one. |
| D | `rollback.sh --restore-db` | `cp db.sqlite3 db.sqlite3.pre_rollback_<ts> \|\| true` | Same live-copy and missing-WAL problems as A. The `\|\| true` also hides a failure, so the safety copy can be missing without anyone noticing. |

Also: backups are never deleted. `shared/<app>/db.sqlite3.backup_*` gains one file
per deploy and never shrinks.

> **Correction for simflow PRE_RELEASE_PLAN 0.2**: that plan says a plain copy "is
> safe today". It is only safe while nothing is writing, and step 2 runs while the
> app is live. So this change is a fix for today, not only a condition for turning
> on WAL.

---

## The change

All of it goes in this repo. The simflow repo needs no code change, only the
plan update and the check in step 5.

### Step 1 — `scripts/sqlite_lib.sh`: one backup function and one restore function

A new file that both scripts `source`. It has two functions. Both go through a
real SQLite connection, so they include what is in the WAL, take SQLite's locks
properly, and work the same in journal mode and in WAL mode.

```bash
# sqlite_backup <src_db> <dest_file>
#   Online Backup API -> dest, then integrity_check on dest. Deletes dest on failure.
# sqlite_restore <backup_file> <live_db>
#   Online Backup API in the other direction (backup -> live), through a connection
#   on live_db. SQLite rewrites the live file and its WAL in one go, so a stale
#   -wal can never be applied on top of the restored file.
```

**Engine**: the `sqlite3` CLI only. It is confirmed present on the cPanel host,
and `.backup` / `.restore` have existed since 3.6.11. The library checks
`command -v sqlite3` first and fails with a clear message if it is missing. It
never falls back to `cp`, and there is no second engine: a fallback that never
runs on the real server is a code path nobody tests, and it would tie the
backup to `PYTHON_ENV` for nothing.

Rules both functions follow:
- Busy timeout of 30 s (`.timeout 30000`), so a writer that is
  busy right now delays the backup instead of making it fail.
- Write to `<dest>.tmp`, run `PRAGMA integrity_check` on it (or `quick_check` if
  the file is over about 200 MB), and only then `mv` it to `<dest>`. If a run is
  interrupted, all it leaves is a `.tmp` file, never something that looks like a
  good backup.
- Log the size and duration, e.g. `backup ok: … (N bytes, T s)`.

### Step 2 — `activate.sh` step 2: use `sqlite_backup`

Replace the `cp` with `sqlite_backup "${SHARED_DIR}/db.sqlite3" "${SQLITE_BACKUP}"`.
The `ERR` trap already stops the deploy when it fails. **Leave it before the stop.**
The backup API makes a copy from a live database safe. If the backup fails, the
deploy stops before any downtime. The only cost is the few seconds of plugin
heartbeat writes between the backup and the stop, which `--restore-db` would lose.

### Step 3 — `rollback.sh --restore-db`: use `sqlite_restore`

1. Take the pre-rollback safety copy with `sqlite_backup` and **drop `|| true`**.
   If the current database can't be read, stop and say so. Offer a flag
   (`--force-restore`) for the case where the database is actually corrupt,
   which is exactly when someone wants to restore.
2. Restore with `sqlite_restore "${SQLITE_BACKUP}" "${SHARED_DIR}/db.sqlite3"`, not `cp`.
3. `--force-restore` path, when the live file can't be opened: move `db.sqlite3`,
   `-wal` and `-shm` together into `pre_rollback_<ts>/` first, then copy the backup
   into place. Moving the WAL files as well is required: that is the fix for C.

`rollback.sh` does not check whether the stop worked (`set +e`, output thrown
away). That is one more reason to restore through a connection: SQLite's locking
makes the restore safe even if a worker is still running.

### Step 4 — Retention

After a successful backup in `activate.sh`, keep the newest
`SQLITE_BACKUP_KEEP` files (default **10**, can be set per app in
`<app>_config.sh`) and delete older `db.sqlite3.backup_*` and `pre_rollback_*`
files. Never delete the backup named in the current state file. Document the new
setting in `app_config.sh.example` and `PORTING-A-NEW-APP.md`.

### Step 5 — Test locally and on the server, then release

Local (this container, before pushing):
1. A throwaway `shared/` directory holding a WAL database, with a writer loop
   running (`INSERT` every 10 ms from a second process).
   Run `sqlite_backup` against it: it passes `integrity_check`, and the latest
   committed row is in the backup.
2. Do the same with the writer loop and the **old** `cp`: show it failing or
   missing rows under WAL. This is the evidence that the change fixes something.
3. Restore test: take a backup, write more rows (the `-wal` file stays because a
   connection is still open), kill the writer, run `sqlite_restore`, open the
   database again. It has exactly the rows in the backup and passes
   `integrity_check`. Repeat with `cp` to show that it corrupts or brings rows back.
4. With `sqlite3` removed from `PATH`: both functions fail cleanly, and `activate.sh` stops before the stop step.
5. `shellcheck scripts/*.sh`.

Release: `cz bump` in www_installer → `sync-tools.yml` updates `~/deploy-tools`
on the server.

Server (**[server]**, once):
- `sqlite3 --version`: write the version down here, once.
- The next simflow deploy logs `backup ok: …`. Copy that backup to a scratch
  path, open it, and check that recent rows are there.
- Before simflow's step 4.1, run `--restore-db` once as a dry run against a
  scratch copy (`DOMAIN_BASE_DIR` pointed at a test tree), not against the live app.

### Step 6 — Unblock simflow

Update simflow `docs/PRE_RELEASE_PLAN.md`: 0.2 → "backup API in www_installer
vX.Y.Z". Step 4.1 (WAL) can go ahead after that. Step 4.2's round trip is the
server check from step 5.

---

## Order and what each step unblocks

```
1 lib ─┬─ 2 activate ─┐
       └─ 3 rollback ─┼─ 4 retention ─ 5 verify + release ─ 6 simflow 4.1 (WAL)
```

Steps 2 and 3 go in **one release**. With a WAL-safe backup and the old `cp`
restore, `--restore-db` would still corrupt the database once WAL is on
(problem C).

## Out of scope

- `deploy.sh` / `install.sh`: the old manual flow, which the tag-triggered
  pipeline no longer calls. Leave them alone; delete them separately.
- Off-server copies. All backups sit on the same disk as the live database.
  That is fine for deploy rollback, but it is not disaster recovery. That needs
  a separate decision (e.g. a nightly cron job with `sqlite_backup` plus a
  download), and it can reuse `sqlite_lib.sh` as is.
- MySQL paths: `mysqldump --single-transaction` is already consistent.
