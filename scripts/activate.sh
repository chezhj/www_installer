#!/bin/bash
#
# activate.sh - bring a release, already placed on disk by CI via rsync, live.
# Usage: ./activate.sh <application> <tag>
#
# Directory model (Option B - move-based, NOT symlink-based):
#   ${DOMAIN_BASE_DIR}<domain>/             - ALWAYS a real directory, never a
#                                              symlink. This is what makes
#                                              cloudlinux-selector stop/start/
#                                              restart work: it resolves
#                                              --app-root via realpath() and
#                                              re-derives the expected venv
#                                              path from THAT - if <domain> is
#                                              a symlink to a release dir, the
#                                              derived path never matches the
#                                              real venv (registered against
#                                              the domain name), and stop/start
#                                              fail with "No such application".
#                                              Confirmed via cloudlinux-selector
#                                              get: the registry's own stored
#                                              venv path is correct - it's the
#                                              re-derivation on stop/start that's
#                                              broken, for any symlinked app-root.
#   ${DOMAIN_BASE_DIR}releases/<app>_<tag>/ - CI's rsync target (not-yet-live),
#                                              and after a successful deploy,
#                                              the PARKING spot for the
#                                              previous live release.
#   ${DOMAIN_BASE_DIR}shared/<app>/         - persistent state, unaffected by
#                                              any of the above: db.sqlite3,
#                                              .env, media. Symlinked into
#                                              each release with ABSOLUTE
#                                              targets specifically so they
#                                              keep resolving correctly no
#                                              matter which directory they get
#                                              moved into.

set -eEo pipefail

APP=$1
RELEASE_TAG=$2

if [ -z "$APP" ] || [ -z "$RELEASE_TAG" ]; then
    echo "Usage: $0 <application> <tag>"
    exit 1
fi

CONFIG_FILE="${APP}_config.sh"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Configuration file $CONFIG_FILE does not exist in current directory."
    exit 1
fi
# shellcheck source=/dev/null
source "$CONFIG_FILE"

if [[ "${DOMAIN_BASE_DIR}" != */ ]]; then
    echo "Error: DOMAIN_BASE_DIR must have a trailing slash."
    exit 1
fi
DATABASE_ENGINE="${DATABASE_ENGINE:-sqlite}"
SHARED_PATHS=("${SHARED_PATHS[@]:-}")
POST_MIGRATE_COMMANDS=("${POST_MIGRATE_COMMANDS[@]:-}")

NEW_RELEASE_PATH="${DOMAIN_BASE_DIR}releases/${APP}_${RELEASE_TAG}"
LIVE_PATH="${DOMAIN_BASE_DIR}${DOMAIN}"
SHARED_DIR="${DOMAIN_BASE_DIR}shared/${APP}"
STATE_FILE="${DOMAIN_BASE_DIR}.deploy_state_${APP}"
CURRENT_STAGE="init"
SQLITE_BACKUP=""
MYSQL_BACKUP=""

on_error() {
    local code=$?
    echo "----------------------------------------------------------"
    echo "ACTIVATE FAILED during: ${CURRENT_STAGE} (exit ${code})"
    echo "If the app was stopped or the live directory was moved, run:"
    echo "  ./rollback.sh ${APP}"
    echo "----------------------------------------------------------"
    exit "$code"
}
trap on_error ERR

record_state() {
    cat > "$STATE_FILE" <<EOF
APP=${APP}
DOMAIN=${DOMAIN}
RELEASE_TAG=${RELEASE_TAG}
PREVIOUS_VERSION=${current_version}
PARKED_PATH=${parked_path}
DATABASE_ENGINE=${DATABASE_ENGINE}
DATABASE_SOURCE=${DATABASE_SOURCE:-}
SQLITE_BACKUP=${SQLITE_BACKUP}
MYSQL_BACKUP=${MYSQL_BACKUP}
LAST_STEP=$1
UPDATED_AT=$(date -Iseconds)
EOF
}

echo "Loaded configuration: DOMAIN=${DOMAIN} DATABASE_ENGINE=${DATABASE_ENGINE}"

# --- Step 0: validate everything before touching anything live ---
CURRENT_STAGE="validate"
if [ ! -d "${NEW_RELEASE_PATH}" ]; then
    echo "Error: ${NEW_RELEASE_PATH} does not exist. Did the rsync step run?"
    exit 1
fi
found_version="v$(grep -oP '__version__ = "\K\S+' "${NEW_RELEASE_PATH}/${VERSION_FILE}" | tr -d '"')"
if [ "$found_version" != "${RELEASE_TAG}" ]; then
    echo "Error: ${NEW_RELEASE_PATH}/${VERSION_FILE} reports ${found_version}, expected ${RELEASE_TAG}"
    exit 1
fi

# The one invariant this whole architecture depends on.
if [ -L "${LIVE_PATH}" ]; then
    echo "Error: ${LIVE_PATH} is a symlink, not a real directory."
    echo "cloudlinux-selector cannot reliably stop/start an app whose --app-root"
    echo "resolves through a symlink (confirmed - see chat history). See"
    echo "BOOTSTRAP.md to convert it back to a real directory first."
    exit 1
fi
if [ ! -d "${LIVE_PATH}" ]; then
    echo "Error: ${LIVE_PATH} does not exist or is not a directory."
    exit 1
fi

current_version="v$(grep -oP '__version__ = "\K\S+' "${LIVE_PATH}/${VERSION_FILE}" | tr -d '"')"
if [ "$current_version" = "v" ]; then
    echo "Error: could not read current version from ${LIVE_PATH}/${VERSION_FILE}"
    exit 1
fi
if [ "$current_version" = "$RELEASE_TAG" ]; then
    echo "Error: ${RELEASE_TAG} is already the running version. Nothing to do."
    exit 1
fi
echo "Found current version ${current_version}"

parked_path="${DOMAIN_BASE_DIR}releases/${APP}_${current_version}"
if [ -e "${parked_path}" ]; then
    echo "Error: ${parked_path} already exists - refusing to overwrite it."
    echo "Investigate and clean it up by hand before retrying."
    exit 1
fi
record_state 0

# --- Step 1: symlink shared state into the new release (absolute targets -
# these keep resolving correctly regardless of which directory this release
# ends up moved into) ---
CURRENT_STAGE="link shared state"
mkdir -p "${SHARED_DIR}"

if [ ! -f "${SHARED_DIR}/.env" ]; then
    echo "Error: ${SHARED_DIR}/.env does not exist. See BOOTSTRAP.md to create it."
    exit 1
fi
rm -f "${NEW_RELEASE_PATH}/.env"
ln -s "${SHARED_DIR}/.env" "${NEW_RELEASE_PATH}/.env"

if [ "${DATABASE_ENGINE}" = "sqlite" ] && [ "${DATABASE_SOURCE}" = "production" ]; then
    if [ ! -f "${SHARED_DIR}/db.sqlite3" ]; then
        echo "Error: ${SHARED_DIR}/db.sqlite3 does not exist. See BOOTSTRAP.md to seed it once."
        exit 1
    fi
    rm -f "${NEW_RELEASE_PATH}/db.sqlite3"
    ln -s "${SHARED_DIR}/db.sqlite3" "${NEW_RELEASE_PATH}/db.sqlite3"
fi

for entry in "${SHARED_PATHS[@]}"; do
    [ -z "$entry" ] && continue
    release_path="${entry%%:*}"
    shared_name="${entry##*:}"
    mkdir -p "${SHARED_DIR}/${shared_name}"
    rm -rf "${NEW_RELEASE_PATH:?}/${release_path}"
    mkdir -p "$(dirname "${NEW_RELEASE_PATH}/${release_path}")"
    ln -s "${SHARED_DIR}/${shared_name}" "${NEW_RELEASE_PATH}/${release_path}"
done
record_state 1

run_migrations=0
if [ "${DATABASE_ENGINE}" = "mysql" ]; then
    run_migrations=1
elif [ "${DATABASE_ENGINE}" = "sqlite" ] && [ "${DATABASE_SOURCE}" = "production" ]; then
    run_migrations=1
fi

# --- Step 2: backup the database before anything touches it ---
CURRENT_STAGE="backup database"
if [ "${run_migrations}" = "1" ]; then
    TS=$(date +%Y%m%d%H%M%S)
    if [ "${DATABASE_ENGINE}" = "sqlite" ]; then
        SQLITE_BACKUP="${SHARED_DIR}/db.sqlite3.backup_${TS}"
        cp "${SHARED_DIR}/db.sqlite3" "${SQLITE_BACKUP}"
        echo "SQLite backed up to ${SQLITE_BACKUP}"
    elif [ "${DATABASE_ENGINE}" = "mysql" ]; then
        if [ -z "${MYSQL_DB_NAME}" ] || [ -z "${MYSQL_CNF_PATH}" ]; then
            echo "Error: DATABASE_ENGINE=mysql requires MYSQL_DB_NAME and MYSQL_CNF_PATH."
            exit 1
        fi
        if [ ! -f "${MYSQL_CNF_PATH}" ]; then
            echo "Error: MYSQL_CNF_PATH (${MYSQL_CNF_PATH}) not found. See BOOTSTRAP.md."
            exit 1
        fi
        MYSQL_BACKUP="${SHARED_DIR}/${MYSQL_DB_NAME}.backup_${TS}.sql.gz"
        mysqldump --single-transaction --quick \
            --defaults-extra-file="${MYSQL_CNF_PATH}" "${MYSQL_DB_NAME}" \
            | gzip > "${MYSQL_BACKUP}"
        echo "MySQL backed up to ${MYSQL_BACKUP}"
    fi
fi
record_state 2

# --- Step 3: stop the app ---
CURRENT_STAGE="stop application"
echo "Stopping the application..."
set +e
output=$(cloudlinux-selector stop --json --interpreter python --app-root "${LIVE_PATH}" 2>&1)
stop_exit=$?
set -e
if [ "${stop_exit}" -ne 0 ] || [[ "$output" != *"\"result\": \"success\""* ]]; then
    echo "Error: failed to stop the application (exit ${stop_exit})."
    echo "Output: $output"
    exit 1
fi
record_state 3

# --- Step 4: park the current release, promote the new one ---
CURRENT_STAGE="move directories"
mv "${LIVE_PATH}" "${parked_path}"
mv "${NEW_RELEASE_PATH}" "${LIVE_PATH}"

# cloudlinux-selector's `start` reads public_html/.htaccess before rewriting
# it with its own PassengerAppRoot/SetEnv directives (from its own registry,
# not from the file's prior content) - and crashes with FileNotFoundError if
# it's missing entirely, rather than creating one fresh. A freshly-rsynced
# release always lacks it (never committed to git - purely a cPanel-managed
# artifact). Nothing of ours depends on its prior content: real secrets come
# from shared/.env, and DJANGO_SETTINGS_MODULE is hardcoded in
# passenger_wsgi.py - so an empty placeholder is enough.
[ -f "${LIVE_PATH}/public_html/.htaccess" ] || touch "${LIVE_PATH}/public_html/.htaccess"
record_state 4

# --- Step 5: install dependencies into the shared venv ---
CURRENT_STAGE="pip install"
if [ -z "${PYTHON_ENV}" ]; then
    echo "Error: PYTHON_ENV not set in ${CONFIG_FILE}."
    exit 1
fi
# shellcheck source=/dev/null
source "${PYTHON_ENV}"

# manage.py defaults DJANGO_SETTINGS_MODULE to config.settings.dev if nothing
# sets it first - it has to be a real exported var, since django-environ's
# .env parsing happens *inside* settings.py, after this default already won.
export DJANGO_SETTINGS_MODULE="${DJANGO_SETTINGS_MODULE:-config.settings.prod}"

cd "${LIVE_PATH}"
pip install -r requirements.txt --no-deps
record_state 5

# --- Step 6: migrate ---
CURRENT_STAGE="migrate"
if [ "${run_migrations}" = "1" ]; then
    python manage.py migrate
    for cmd in "${POST_MIGRATE_COMMANDS[@]}"; do
        [ -z "$cmd" ] && continue
        cmd_name="${cmd%% *}"
        if python manage.py help --commands 2>/dev/null | grep -qx "${cmd_name}"; then
            echo "Running post-migrate command: manage.py ${cmd}"
            # shellcheck disable=SC2086
            python manage.py ${cmd}
        else
            echo "Skipping 'manage.py ${cmd}': command '${cmd_name}' not available in this release."
        fi
    done
fi
record_state 6

# --- Step 7: collectstatic ---
CURRENT_STAGE="collectstatic"
python manage.py collectstatic --clear --no-input
record_state 7

# --- Step 8: start (this also correctly regenerates .htaccess, since
# --app-root now resolves to a real, non-symlinked directory) ---
CURRENT_STAGE="start application"
echo "Starting the application..."
set +e
output=$(cloudlinux-selector start --json --interpreter python --app-root "${LIVE_PATH}" 2>&1)
start_exit=$?
set -e
if [ "${start_exit}" -ne 0 ] || [[ "$output" != *"\"result\": \"success\""* ]]; then
    echo "Error: failed to start the application (exit ${start_exit})."
    echo "Output: $output"
    exit 1
fi
record_state 8

echo "Activated ${RELEASE_TAG} (${APP}). Previous release parked at ${parked_path}."
