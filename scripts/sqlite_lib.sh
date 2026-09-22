#!/bin/bash
#
# sqlite_lib.sh - consistent, WAL-safe SQLite backup and restore.
# Sourced by activate.sh and rollback.sh; not meant to be run directly.
#
# Why not cp: a plain file copy of a database the app is writing to can catch a
# commit half-way (pages from before and after it), and under WAL it misses
# every commit still sitting in the -wal sidecar. Restoring with cp is worse:
# a stale -wal left next to the restored file gets replayed onto it the next
# time SQLite opens it. Both functions here go through SQLite's Online Backup
# API instead (the sqlite3 CLI's .backup / .restore), which reads and writes
# through a real connection: it takes SQLite's locks, includes WAL content, and
# works the same in rollback-journal and WAL mode.
#
# Only the sqlite3 CLI is used, deliberately - no second engine, and never a
# fallback to cp. If the CLI is missing the functions fail, and the caller's
# ERR trap stops the deploy before anything live is touched.

# Files above this size get PRAGMA quick_check instead of the full
# integrity_check, which is O(N log N) and slow on big databases.
SQLITE_FULL_CHECK_MAX_BYTES=$((200 * 1024 * 1024))

_sqlite_require_cli() {
    if ! command -v sqlite3 >/dev/null 2>&1; then
        echo "Error: sqlite3 CLI not found - cannot take a consistent backup or restore." >&2
        echo "       Refusing to fall back to a plain file copy." >&2
        return 1
    fi
}

# .backup / .restore take the filename as a quoted dot-command argument, which
# has no escape for a single quote. Our paths never contain one; refuse rather
# than mis-quote.
_sqlite_check_path() {
    if [[ "$1" == *"'"* ]]; then
        echo "Error: path contains a single quote, refusing: $1" >&2
        return 1
    fi
}

# _sqlite_verify <db_file> - prints nothing and returns 0 when the check says ok.
_sqlite_verify() {
    local db="$1" pragma="integrity_check" result
    if [ "$(stat -c %s "$db")" -gt "${SQLITE_FULL_CHECK_MAX_BYTES}" ]; then
        pragma="quick_check"
    fi
    result=$(sqlite3 -bail "$db" "PRAGMA ${pragma};" 2>&1) || true
    if [ "$result" != "ok" ]; then
        echo "Error: ${pragma} failed for ${db}: ${result}" >&2
        return 1
    fi
}

# sqlite_backup <src_db> <dest_file>
#   Online backup of src_db (live or not) to dest_file, verified before it is
#   given its final name. On any failure dest_file does not exist and the
#   function returns non-zero. The result is a self-contained rollback-journal
#   file: no -wal sidecar needed to read it.
sqlite_backup() {
    local src="$1" dest="$2"
    local tmp="${dest}.tmp" start
    _sqlite_require_cli || return 1
    _sqlite_check_path "$dest" || return 1
    if [ ! -f "$src" ]; then
        echo "Error: database ${src} not found." >&2
        return 1
    fi

    start=$(date +%s)
    rm -f "$tmp" "${tmp}-wal" "${tmp}-shm" "${tmp}-journal"

    # .timeout makes the backup wait out a concurrent writer instead of failing
    # with SQLITE_BUSY; the apps' writes take milliseconds.
    if ! sqlite3 -bail "$src" <<SQL
.timeout 30000
.backup '${tmp}'
SQL
    then
        echo "Error: sqlite3 .backup failed for ${src}" >&2
        rm -f "$tmp" "${tmp}-wal" "${tmp}-shm" "${tmp}-journal"
        return 1
    fi

    # A backup of a WAL database is itself marked WAL. Switch it to a plain
    # rollback-journal file so it is a single self-contained file on disk.
    if ! sqlite3 -bail "$tmp" "PRAGMA journal_mode=DELETE;" >/dev/null; then
        echo "Error: could not finalise backup ${tmp}" >&2
        rm -f "$tmp" "${tmp}-wal" "${tmp}-shm" "${tmp}-journal"
        return 1
    fi

    # Never trust a backup that has not been read back.
    if ! _sqlite_verify "$tmp"; then
        rm -f "$tmp" "${tmp}-wal" "${tmp}-shm" "${tmp}-journal"
        return 1
    fi

    mv "$tmp" "$dest"
    echo "backup ok: ${dest} ($(stat -c %s "$dest") bytes, $(( $(date +%s) - start )) s)"
}

# sqlite_restore <backup_file> <live_db>
#   Replaces the contents of live_db with backup_file through a connection on
#   live_db. SQLite rewrites the database and its WAL together, so a stale -wal
#   can never be replayed onto the restored data, and its locking keeps this
#   safe even if an app worker still has the database open.
sqlite_restore() {
    local backup="$1" live="$2" start
    _sqlite_require_cli || return 1
    _sqlite_check_path "$backup" || return 1
    if [ ! -f "$backup" ]; then
        echo "Error: backup ${backup} not found." >&2
        return 1
    fi
    if [ ! -f "$live" ]; then
        echo "Error: database ${live} not found." >&2
        return 1
    fi
    # Refuse to restore from a damaged backup - that would replace a working
    # database with a broken one.
    _sqlite_verify "$backup" || return 1

    start=$(date +%s)
    if ! sqlite3 -bail "$live" <<SQL
.timeout 30000
.restore '${backup}'
SQL
    then
        echo "Error: sqlite3 .restore from ${backup} into ${live} failed" >&2
        return 1
    fi

    _sqlite_verify "$live" || return 1
    echo "restore ok: ${live} from ${backup} ($(( $(date +%s) - start )) s)"
}

# sqlite_prune_backups <shared_dir> <keep> [protected_path]
#   Keeps the newest <keep> db.sqlite3.backup_* and, separately, the newest
#   <keep> db.sqlite3.pre_rollback_* entries in shared_dir; deletes the rest.
#   protected_path is never deleted. Leftover *.tmp files from an interrupted
#   backup are not counted and not touched.
sqlite_prune_backups() {
    local dir="$1" keep="$2" protected="${3:-}" prefix entry
    if ! [[ "$keep" =~ ^[1-9][0-9]*$ ]]; then
        echo "Error: SQLITE_BACKUP_KEEP must be a positive integer, got '${keep}'." >&2
        return 1
    fi
    for prefix in db.sqlite3.backup_ db.sqlite3.pre_rollback_; do
        # Names embed a %Y%m%d%H%M%S timestamp, so a reverse name sort is newest
        # first - and, unlike mtime, it survives a copy or touch.
        while IFS= read -r entry; do
            [ -z "$entry" ] && continue
            [ "$entry" = "$protected" ] && continue
            echo "Pruning old backup ${entry}"
            rm -rf -- "$entry"
        done < <(find "$dir" -maxdepth 1 -name "${prefix}*" ! -name '*.tmp' \
                    ! -name '*-wal' ! -name '*-shm' ! -name '*-journal' \
                    | sort -r | tail -n +"$((keep + 1))")
    done
}
