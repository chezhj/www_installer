#!/bin/bash

# Check if both application and tag arguments are provided
if [ -z "$1" ] ; then
    echo "Usage: $0 <application> <tag>"
    exit 1
fi

APP=$1
RELEASE_TAG=$2

# Source the configuration file based on the application
CONFIG_FILE="${APP}_config.sh"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Configuration file $CONFIG_FILE does not exist"
    exit 1
fi
source "$CONFIG_FILE"

# Print the loaded variables for verification
echo "Loaded configuration:"
echo "DOMAIN=${DOMAIN}"
echo "APP=${APP}"
echo "VERSION_FILE=${VERSION_FILE}"
echo "GITHUB_URL=${GITHUB_URL}"


# Check if the release tag argument is provided
# If RELEASE_TAG is empty, show current tags from remote repository
if [ -z "$RELEASE_TAG" ]; then
    echo "Usage: $0 <application> <tag>"
    echo "Current tags:"
    git ls-remote --tags $GITHUB_URL | gawk '{print substr($2,11)}'
    exit 0
fi

NEW_PATH="./${APP}_${RELEASE_TAG}"
SRC_PATH="./${APP}_source_${RELEASE_TAG}"

cd ~/domains/ || exit

# Ensure the checklist_new directory exists
mkdir -p "$NEW_PATH"

# Clone the repository into CLONE_PATH with the specified RELEASE_TAG
git clone --branch "$RELEASE_TAG" "$GITHUB_URL" "$SRC_PATH"


# Copy the required files and directories from the cloned directory
for item in "${FILES_TO_COPY[@]}"; do
    cp -r "$SRC_PATH/$item" "$NEW_PATH/"
done

if [ ${DATABASE_SOURCE}  = "repository" ]; then
    echo "Copying database from repository"
    cp -r "$SRC_PATH/db.sqlite3" "$NEW_PATH/"
fi

cp "$SRC_PATH/passenger_wsgi.py" "$NEW_PATH/"
cp "$SRC_PATH/manage.py" "$NEW_PATH/"
cp "$SRC_PATH/requirements.txt" "$NEW_PATH/"

