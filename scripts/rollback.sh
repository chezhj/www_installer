#!/bin/bash
#
# rollback.sh - revert a failed activate.sh run using the state file it wrote.
# Usage: ./rollback.sh <application> [--restore-db]
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

set -eEo pipefail

APP=$1
RESTORE_DB=0
for arg in "$@"; do
    [ "$arg" = "--restore-db" ] && RESTORE_DB=1
done

if [ -z "$APP" ]; then
    echo "Usage: $0 <application> [--restore-db]"
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

TS=$(date +%Y%m%d%H%M%S)
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
        if [ -z "${SQLITE_BACKUP}" ] || [ ! -f "${SQLITE_BACKUP}" ]; then
            echo "Error: sqlite backup ${SQLITE_BACKUP} not found."
            exit 1
        fi
        cp "${SHARED_DIR}/db.sqlite3" "${SHARED_DIR}/db.sqlite3.pre_rollback_${TS}" 2>/dev/null || true
        cp "${SQLITE_BACKUP}" "${SHARED_DIR}/db.sqlite3"
        echo "SQLite restored from ${SQLITE_BACKUP}."
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
