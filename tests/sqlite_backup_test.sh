#!/bin/bash
#
# sqlite_backup_test.sh - tests for scripts/sqlite_lib.sh and the sqlite paths
# of activate.sh / rollback.sh. Runs locally, no server needed.
#
#   bash tests/sqlite_backup_test.sh
#
# Needs: sqlite3 CLI, python3 (only as the concurrent test writer - the scripts
# under test never use Python). activate.sh / rollback.sh run end to end against
# a throwaway DOMAIN_BASE_DIR with cloudlinux-selector, pip and manage.py stubbed.

# Test-only style: short `cond && ok || bad` lines and ls|grep counts over names
# this file itself creates.
# shellcheck disable=SC2010,SC2012,SC2015

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="${REPO}/scripts"
WORK="$(mktemp -d)"
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$WORK"' EXIT

# shellcheck source-path=SCRIPTDIR source=../scripts/sqlite_lib.sh
source "${SCRIPTS}/sqlite_lib.sh"

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad()  { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

q() { sqlite3 -bail "$1" "$2"; }

new_wal_db() {
    rm -f "$1" "$1-wal" "$1-shm"
    sqlite3 "$1" "PRAGMA journal_mode=WAL; CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT);" >/dev/null
}

# Holds one connection open (so the WAL is never checkpointed away) and inserts a
# row every 10 ms; wal_autocheckpoint=0 keeps every commit in the -wal file.
# Prints nothing; the caller counts rows through its own connection.
start_writer() {
    python3 - "$1" <<'PY' &
import sqlite3, sys, time
c = sqlite3.connect(sys.argv[1], timeout=30, isolation_level=None)
c.execute("PRAGMA wal_autocheckpoint=0")
while True:
    c.execute("INSERT INTO t(v) VALUES (randomblob(2000))")
    time.sleep(0.01)
PY
    WRITER=$!
    sleep 0.5
}

# ---------------------------------------------------------------------------
echo "1. sqlite_backup of a WAL database under a live writer"
DB="$WORK/live.sqlite3"
new_wal_db "$DB"
start_writer "$DB"
before=$(q "$DB" "SELECT max(id) FROM t;")
sqlite_backup "$DB" "$WORK/b1" >/dev/null
after=$(q "$DB" "SELECT max(id) FROM t;")
kill -9 "$WRITER"; wait "$WRITER" 2>/dev/null
got=$(q "$WORK/b1" "SELECT max(id) FROM t;")
if [ "$got" -ge "$before" ] && [ "$got" -le "$after" ]; then
    ok "backup holds every row committed before it started ($before <= $got <= $after)"
else
    bad "backup max id $got not within [$before, $after]"
fi
check "backup passes integrity_check" "$(q "$WORK/b1" "PRAGMA integrity_check;")" "ok"
check "backup is a plain rollback-journal file" "$(q "$WORK/b1" "PRAGMA journal_mode;")" "delete"
check "no sidecar or tmp file left behind" "$(ls "$WORK" | grep -c '^b1')" "1"

# ---------------------------------------------------------------------------
echo "2. the old cp, same situation (evidence the change fixes something)"
new_wal_db "$DB"
start_writer "$DB"
committed=$(q "$DB" "SELECT count(*) FROM t;")
cp "$DB" "$WORK/cp_copy"
kill -9 "$WRITER"; wait "$WRITER" 2>/dev/null
copied=$(q "$WORK/cp_copy" "SELECT count(*) FROM t;" 2>&1)
if [ "$copied" != "$committed" ]; then
    ok "cp copy is missing WAL commits: $copied rows of $committed committed"
else
    bad "cp copy unexpectedly complete ($copied rows)"
fi

# ---------------------------------------------------------------------------
echo "3. sqlite_restore with a stale -wal next to the live database"
new_wal_db "$DB"
start_writer "$DB"
sleep 0.3
kill -9 "$WRITER"; wait "$WRITER" 2>/dev/null
sqlite_backup "$DB" "$WORK/b3" >/dev/null
want=$(q "$WORK/b3" "SELECT count(*) FROM t;")
# The "migration": more writes after the backup, then the worker is killed so
# its -wal stays on disk - what a Passenger stop leaves behind.
start_writer "$DB"
sleep 0.3
kill -9 "$WRITER"; wait "$WRITER" 2>/dev/null
[ -s "$DB-wal" ] && ok "stale -wal present before restore" || bad "test setup: no -wal on disk"
cp "$DB" "$WORK/cp_live"; cp "$DB-wal" "$WORK/cp_live-wal"   # for the cp comparison below
sqlite_restore "$WORK/b3" "$DB" >/dev/null
check "restored row count equals the backup" "$(q "$DB" "SELECT count(*) FROM t;")" "$want"
check "restored database passes integrity_check" "$(q "$DB" "PRAGMA integrity_check;")" "ok"

# Same situation restored the old way: copy the backup over the file, leave the -wal.
cp "$WORK/b3" "$WORK/cp_live"
cp_rows=$(q "$WORK/cp_live" "SELECT count(*) FROM t;" 2>&1)
cp_check=$(q "$WORK/cp_live" "PRAGMA integrity_check;" 2>&1 | head -1)
if [ "$cp_rows" != "$want" ] || [ "$cp_check" != "ok" ]; then
    ok "cp restore is wrong: $cp_rows rows (want $want), integrity: $cp_check"
else
    bad "cp restore unexpectedly correct"
fi

# ---------------------------------------------------------------------------
echo "4. refusals"
printf 'not a database, just junk %.0s' {1..200} > "$WORK/junk"
if sqlite_restore "$WORK/junk" "$DB" >/dev/null 2>&1; then bad "restored from a junk backup"; else ok "refuses to restore from a damaged backup"; fi
check "live database untouched by the refused restore" "$(q "$DB" "SELECT count(*) FROM t;")" "$want"
if sqlite_backup "$WORK/junk" "$WORK/b4" >/dev/null 2>&1; then bad "backed up a junk database"; else ok "refuses to back up a damaged database"; fi
check "no backup file created for it" "$(ls "$WORK" | grep -c '^b4')" "0"
if sqlite_backup "$WORK/missing" "$WORK/b5" >/dev/null 2>&1; then bad "backed up a missing file"; else ok "refuses a missing source"; fi

nocli="$WORK/nocli"; mkdir "$nocli"
for tool in stat date mv rm dirname cat; do ln -s "$(command -v $tool)" "$nocli/$tool"; done
if PATH="$nocli" sqlite_backup "$DB" "$WORK/b6" >/dev/null 2>&1; then bad "backup ran without sqlite3"; else ok "backup fails cleanly without the sqlite3 CLI"; fi
if PATH="$nocli" sqlite_restore "$WORK/b3" "$DB" >/dev/null 2>&1; then bad "restore ran without sqlite3"; else ok "restore fails cleanly without the sqlite3 CLI"; fi
check "no backup file created without the CLI" "$(ls "$WORK" | grep -c '^b6')" "0"

# ---------------------------------------------------------------------------
echo "5. sqlite_prune_backups"
P="$WORK/prune"; mkdir "$P"
for i in $(seq -w 1 13); do touch "$P/db.sqlite3.backup_202601010000$i"; done
for i in 1 2 3; do touch "$P/db.sqlite3.pre_rollback_2026010100000$i"; done
mkdir "$P/db.sqlite3.pre_rollback_20250101000000"          # a --force-restore directory
touch "$P/db.sqlite3.backup_20990101000000.tmp" "$P/db.sqlite3"
sqlite_prune_backups "$P" 10 "$P/db.sqlite3.backup_20260101000001" >/dev/null
check "keeps newest 10 backups plus the protected one" "$(ls "$P" | grep -c 'backup_[0-9]*$')" "11"
[ -e "$P/db.sqlite3.backup_20260101000001" ] && ok "protected backup kept" || bad "protected backup deleted"
[ -e "$P/db.sqlite3.backup_20260101000002" ] && bad "oldest unprotected backup kept" || ok "oldest unprotected backup deleted"
check "pre_rollback entries under the limit are all kept" "$(ls "$P" | grep -c pre_rollback)" "4"
sqlite_prune_backups "$P" 2 >/dev/null
check "pre_rollback pruned separately, directories too" "$(ls "$P" | grep -c pre_rollback)" "2"
[ -e "$P/db.sqlite3" ] && [ -e "$P/db.sqlite3.backup_20990101000000.tmp" ] && ok "live db and .tmp never pruned" || bad "pruned something it must not"
if sqlite_prune_backups "$P" 0 >/dev/null 2>&1; then bad "accepted keep=0"; else ok "rejects keep=0"; fi

# ---------------------------------------------------------------------------
echo "6. activate.sh + rollback.sh end to end (stubbed server)"
BASE="$WORK/domains/"
STUB="$WORK/stub"
mkdir -p "$BASE/shared/app" "$BASE/releases" "$STUB"
LIVE="$BASE/app.example.com"
mk_release() {
    mkdir -p "$1/pkg"
    echo "__version__ = \"$2\"" > "$1/pkg/__init__.py"
    : > "$1/requirements.txt"
}
mk_release "$LIVE" "1.0.0"
mk_release "$BASE/releases/app_v1.1.0" "1.1.0"
echo "SECRET=x" > "$BASE/shared/app/.env"
new_wal_db "$BASE/shared/app/db.sqlite3"
sqlite3 "$BASE/shared/app/db.sqlite3" "INSERT INTO t(v) VALUES ('before-deploy');"

cat > "$STUB/cloudlinux-selector" <<'SH'
#!/bin/bash
echo '{"result": "success"}'
SH
cat > "$STUB/pip" <<'SH'
#!/bin/bash
exit 0
SH
# manage.py stub: "migrate" changes the schema, like a real migration would.
cat > "$STUB/python" <<'SH'
#!/bin/bash
case "$2" in
    migrate) sqlite3 db.sqlite3 "ALTER TABLE t ADD COLUMN migrated INTEGER; INSERT INTO t(v) VALUES ('after-migrate');" ;;
    help) : ;;
esac
exit 0
SH
chmod +x "$STUB"/*
echo "export PATH=\"$STUB:\$PATH\"" > "$STUB/activate"

cat > "$BASE/app_config.sh" <<EOF
DOMAIN="app.example.com"
DOMAIN_BASE_DIR="$BASE"
VERSION_FILE="pkg/__init__.py"
PYTHON_ENV="$STUB/activate"
DJANGO_SETTINGS_MODULE="x.settings"
DATABASE_ENGINE="sqlite"
DATABASE_SOURCE="production"
SHARED_PATHS=()
SQLITE_BACKUP_KEEP=3
EOF
for i in 1 2 3 4; do touch "$BASE/shared/app/db.sqlite3.backup_2020010100000$i"; done

out=$(cd "$BASE" && PATH="$STUB:$PATH" bash "$SCRIPTS/activate.sh" app v1.1.0 2>&1); rc=$?
check "activate.sh succeeds" "$rc" "0"
echo "$out" | grep -q "^backup ok: " && ok "activate logs 'backup ok'" || bad "no 'backup ok' in: $out"
# shellcheck source=/dev/null
source "$BASE/.deploy_state_app"
check "state file names the backup" "$(q "$SQLITE_BACKUP" "SELECT v FROM t;")" "before-deploy"
check "backup kept to SQLITE_BACKUP_KEEP=3" "$(ls "$BASE/shared/app" | grep -c 'backup_')" "3"
check "live database was migrated" "$(q "$BASE/shared/app/db.sqlite3" "SELECT count(*) FROM t;")" "2"

# Rollback with a stale -wal on the live database, as a killed worker leaves it.
start_writer "$BASE/shared/app/db.sqlite3"
sleep 0.2
kill -9 "$WRITER"; wait "$WRITER" 2>/dev/null
out=$(cd "$BASE" && PATH="$STUB:$PATH" bash "$SCRIPTS/rollback.sh" app --restore-db 2>&1); rc=$?
check "rollback.sh --restore-db succeeds" "$rc" "0"
LIVE_DB="$BASE/shared/app/db.sqlite3"
check "data restored to the pre-deploy backup" "$(q "$LIVE_DB" "SELECT group_concat(v) FROM t;")" "before-deploy"
check "migrated column gone" "$(q "$LIVE_DB" "SELECT count(*) FROM pragma_table_info('t') WHERE name='migrated';")" "0"
check "restored database passes integrity_check" "$(q "$LIVE_DB" "PRAGMA integrity_check;")" "ok"
pre=$(ls -d "$BASE"/shared/app/db.sqlite3.pre_rollback_* 2>/dev/null | head -1)
[ -f "$pre" ] && check "safety copy holds the migrated data" "$(q "$pre" "SELECT count(*) FROM pragma_table_info('t') WHERE name='migrated';")" "1" \
    || bad "no pre_rollback safety copy"
grep -q '1.0.0' "$LIVE/pkg/__init__.py" && ok "code rolled back to 1.0.0" || bad "code not rolled back"

# --- refusal before anything moves: damaged live database, no --force-restore
mk_release "$BASE/releases/app_v1.2.0" "1.2.0"
(cd "$BASE" && PATH="$STUB:$PATH" bash "$SCRIPTS/activate.sh" app v1.2.0 >/dev/null 2>&1)
rm -f "$LIVE_DB-wal" "$LIVE_DB-shm"
printf 'garbage%.0s' {1..500} > "$LIVE_DB"
out=$(cd "$BASE" && PATH="$STUB:$PATH" bash "$SCRIPTS/rollback.sh" app --restore-db 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "rollback refuses when the safety copy fails" || bad "rollback went ahead on a damaged db"
grep -q '1.2.0' "$LIVE/pkg/__init__.py" && ok "nothing moved by the refused rollback" || bad "refused rollback still moved code"
echo "$out" | grep -q -- "--force-restore" && ok "refusal points at --force-restore" || bad "refusal message: $out"

# --- the same command re-run with --force-restore
echo "stale" > "$LIVE_DB-wal"
out=$(cd "$BASE" && PATH="$STUB:$PATH" bash "$SCRIPTS/rollback.sh" app --restore-db --force-restore 2>&1); rc=$?
[ "$rc" -ne 0 ] && echo "$out"
check "rollback --force-restore succeeds" "$rc" "0"
check "force-restored data is the pre-deploy backup" "$(q "$LIVE_DB" "SELECT count(*) FROM pragma_table_info('t') WHERE name='migrated';")" "0"
[ -e "$LIVE_DB-wal" ] && bad "stale -wal left next to the restored file" || ok "stale -wal moved aside"
forced=$(find "$BASE/shared/app" -maxdepth 1 -type d -name 'db.sqlite3.pre_rollback_*' | head -1)
[ -f "$forced/db.sqlite3" ] && [ -f "$forced/db.sqlite3-wal" ] && ok "damaged db and its -wal kept in $(basename "$forced")/" || bad "force-restore did not keep the damaged files"
# 1.2.0 was activated on top of the 1.0.0 the first rollback restored.
grep -q '1.0.0' "$LIVE/pkg/__init__.py" && ok "code rolled back to 1.0.0 again" || bad "code not rolled back"

if (cd "$BASE" && bash "$SCRIPTS/rollback.sh" app --force-restore >/dev/null 2>&1); then bad "--force-restore accepted alone"; else ok "--force-restore without --restore-db is rejected"; fi

# ---------------------------------------------------------------------------
echo
echo "${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
