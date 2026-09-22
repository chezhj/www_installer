#!/bin/bash
#
# rollback.sh - revert a failed activate.sh run using the state file it wrote.
# Usage: ./rollback.sh <application> [--restore-db [--force-restore]]
#
# Directory model matches activate.sh (Option B, move-based): the live path
# is always a real directory, never a symlink. On a failed deploy that got
# past the move step, the previous release is sitting parked at
# releases/<app>_<previous_version> - restoring it is a move back, not a
# symlink repoint.
#
# Default behavior is CODE-ONLY: stop, move the broken new release aside
# (parked, not deleted - inspectable), move the previous release back,
# reinstall its requirements.txt into the shared venv, start. Database is
# left untouched unless --restore-db is passed explicitly - see the warning
# this prints at the end for why that's a separate, deliberate step.
#
# --restore-db (sqlite) first takes a consistent safety copy of the current
# database (db.sqlite3.pre_rollback_<ts>), then restores the activate-time
# backup through SQLite's backup API - never a file copy, which would leave a
# stale -wal next to the restored file for SQLite to replay onto it. If the
# current database is too damaged to copy, the rollback stops; re-run with
# --force-restore to move db.sqlite3 and its -wal/-shm aside into
# db.sqlite3.pre_rollback_<ts>/ and put the backup in their place.

set -eEo pipefail

# shellcheck source-path=SCRIPTDIR source=sqlite_lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/sqlite_lib.sh"

APP=$1
RESTORE_DB=0
FORCE_RESTORE=0
for arg in "$@"; do
    [ "$arg" = "--restore-db" ] && RESTORE_DB=1
    [ "$arg" = "--force-restore" ] && FORCE_RESTORE=1
done

if [ -z "$APP" ] || [[ "$APP" == --* ]]; then
    echo "Usage: $0 <application> [--restore-db [--force-restore]]"
    exit 1
fi
if [ "${FORCE_RESTORE}" = "1" ] && [ "${RESTORE_DB}" != "1" ]; then
    echo "Error: --force-restore only makes sense together with --restore-db."
    exit 1
fi

CONFIG_FILE="${APP}_config.sh"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Configuration file $CONFIG_FILE does not exist in current directory."
    exit 1
fi
# shellcheck source=/dev/null
source "$CONFIG_FILE"
DATABASE_ENGINE="${DATABASE_ENGINE:-sqlite}"

STATE_FILE="${DOMAIN_BASE_DIR}.deploy_state_${APP}"
if [ ! -f "$STATE_FILE" ]; then
    echo "Error: no deploy state file at ${STATE_FILE}; nothing to roll back."
    exit 1
fi
# shellcheck source=/dev/null
source "$STATE_FILE"

if [ -z "${PARKED_PATH}" ]; then
    echo "Error: no PARKED_PATH recorded in state file - nothing to restore."
    exit 1
fi

LIVE_PATH="${DOMAIN_BASE_DIR}${DOMAIN}"
SHARED_DIR="${DOMAIN_BASE_DIR}shared/${APP}"

echo "Rollback plan:"
echo "  app             : ${APP}"
echo "  failed release  : ${RELEASE_TAG}"
echo "  restoring to    : ${PREVIOUS_VERSION} (${PARKED_PATH})"
echo "  last step done  : ${LAST_STEP}"
echo "  database engine : ${DATABASE_ENGINE}"
[ -n "${SQLITE_BACKUP}" ] && echo "  sqlite backup   : ${SQLITE_BACKUP}"
[ -n "${MYSQL_BACKUP}" ] && echo "  mysql backup    : ${MYSQL_BACKUP}"

# migrate only runs at LAST_STEP>=6 in activate.sh (see step numbering there)
migration_may_have_run=0
if [ "${LAST_STEP}" -ge 6 ]; then
    migration_may_have_run=1
fi

start_app() {
    echo "Starting the application..."
    set +e
    output=$(cloudlinux-selector start --json --interpreter python --app-root "${LIVE_PATH}" 2>&1)
    start_exit=$?
    set -e
    if [ "${start_exit}" -ne 0 ] || [[ "$output" != *"\"result\": \"success\""* ]]; then
        echo "Error: failed to start the application after rollback (exit ${start_exit})."
        echo "Output: $output"
        exit 1
    fi
}

TS=$(date +%Y%m%d%H%M%S)
LIVE_DB="${SHARED_DIR}/db.sqlite3"
PRE_ROLLBACK="${SHARED_DIR}/db.sqlite3.pre_rollback_${TS}"
while [ -e "${PRE_ROLLBACK}" ]; do
    # Second-resolution names can collide on a quick re-run; never reuse one.
    sleep 1
    TS=$(date +%Y%m%d%H%M%S)
    PRE_ROLLBACK="${SHARED_DIR}/db.sqlite3.pre_rollback_${TS}"
done

# Everything that can refuse a sqlite --restore-db runs here, before anything is
# stopped or moved: a refusal then leaves the deploy exactly as it was, and the
# same command can simply be re-run (e.g. with --force-restore).
if [ "${RESTORE_DB}" = "1" ] && [ "${migration_may_have_run}" = "1" ] \
        && [ "${DATABASE_ENGINE}" = "sqlite" ]; then
    if [ -z "${SQLITE_BACKUP}" ] || [ ! -f "${SQLITE_BACKUP}" ]; then
        echo "Error: sqlite backup ${SQLITE_BACKUP} not found."
        exit 1
    fi
    _sqlite_verify "${SQLITE_BACKUP}"
    if [ "${FORCE_RESTORE}" != "1" ]; then
        # Safety copy of the current (migrated) data, so the restore itself can
        # be undone. Taken with the backup API, so it is consistent even though
        # the app may still be running at this point.
        if ! sqlite_backup "${LIVE_DB}" "${PRE_ROLLBACK}"; then
            echo "Error: could not take a safety copy of the current database."
            echo "Nothing was stopped, moved or restored. If the database is"
            echo "damaged and you want the backup regardless, re-run with:"
            echo "  ./rollback.sh ${APP} --restore-db --force-restore"
            exit 1
        fi
    fi
fi

if [ "${LAST_STEP}" -lt 4 ]; then
    # Nothing was moved - the live directory is still the original release.
    echo "No directories were moved. Restarting the current release."
    start_app
    rm -f "$STATE_FILE"
    echo "Rollback complete (restart only)."
    exit 0
fi

if [ ! -d "${PARKED_PATH}" ]; then
    echo "Error: parked release ${PARKED_PATH} not found. Cannot roll back automatically."
    exit 1
fi

echo "Stopping the application..."
set +e
cloudlinux-selector stop --json --interpreter python --app-root "${LIVE_PATH}" >/dev/null 2>&1
set -e

FAILED_PARK_PATH="${DOMAIN_BASE_DIR}releases/${APP}_failed_${RELEASE_TAG}_${TS}"
echo "Parking failed release at ${FAILED_PARK_PATH}"
mv "${LIVE_PATH}" "${FAILED_PARK_PATH}"

echo "Restoring ${PARKED_PATH} to ${LIVE_PATH}"
mv "${PARKED_PATH}" "${LIVE_PATH}"

if [ "${LAST_STEP}" -ge 5 ] && [ -n "${PYTHON_ENV}" ]; then
    echo "Reinstalling requirements for ${PREVIOUS_VERSION} (shared virtualenv was modified)..."
    # shellcheck source=/dev/null
    source "${PYTHON_ENV}"
    cd "${LIVE_PATH}"
    pip install -r requirements.txt --no-deps
fi

if [ "${RESTORE_DB}" = "1" ] && [ "${migration_may_have_run}" = "1" ]; then
    if [ "${DATABASE_ENGINE}" = "sqlite" ]; then
        if [ "${FORCE_RESTORE}" = "1" ]; then
            # The current database may be unreadable, so no backup API here:
            # move it aside together with its sidecars. Moving the -wal/-shm
            # is the point - left behind, they would be replayed onto the
            # restored file.
            mkdir "${PRE_ROLLBACK}"
            for f in "${LIVE_DB}" "${LIVE_DB}-wal" "${LIVE_DB}-shm" "${LIVE_DB}-journal"; do
                if [ -e "$f" ]; then mv "$f" "${PRE_ROLLBACK}/"; fi
            done
            echo "Current database moved aside to ${PRE_ROLLBACK}/"
            cp "${SQLITE_BACKUP}" "${LIVE_DB}.restoring"
            mv "${LIVE_DB}.restoring" "${LIVE_DB}"
            _sqlite_verify "${LIVE_DB}"
            echo "SQLite restored from ${SQLITE_BACKUP} (forced)."
        elif ! sqlite_restore "${SQLITE_BACKUP}" "${LIVE_DB}"; then
            # .restore is one transaction: on failure the database is as it was.
            echo "Error: restore failed. The code is rolled back to ${PREVIOUS_VERSION}"
            echo "but the app is STOPPED and the database still holds ${RELEASE_TAG}'s data"
            echo "(safety copy: ${PRE_ROLLBACK}). Fix the cause, then either restore by"
            echo "hand or start the app as-is."
            exit 1
        fi
    elif [ "${DATABASE_ENGINE}" = "mysql" ]; then
        if [ -z "${MYSQL_BACKUP}" ] || [ ! -f "${MYSQL_BACKUP}" ]; then
            echo "Error: mysql backup ${MYSQL_BACKUP} not found."
            exit 1
        fi
        gunzip -c "${MYSQL_BACKUP}" | mysql --defaults-extra-file="${MYSQL_CNF_PATH}" "${MYSQL_DB_NAME}"
        echo "MySQL restored from ${MYSQL_BACKUP}."
    fi
fi

start_app
rm -f "$STATE_FILE"
echo "Rollback to ${PREVIOUS_VERSION} complete. Failed release kept at ${FAILED_PARK_PATH}."

if [ "${migration_may_have_run}" = "1" ] && [ "${RESTORE_DB}" != "1" ]; then
    echo "----------------------------------------------------------"
    echo "MIGRATION_MAY_HAVE_RUN"
    echo "Code was rolled back. The database was left untouched and may still"
    echo "reflect ${RELEASE_TAG}'s schema. To also restore it (this discards any"
    echo "writes made since the migration), run:"
    echo "  ./rollback.sh ${APP} --restore-db"
    echo "----------------------------------------------------------"
fi
