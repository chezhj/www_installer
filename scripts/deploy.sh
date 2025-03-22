#!/bin/bash +x

# Versioen: 1.1.0
# Description: Deploy a new version of the application
# Usage: ./deploy.sh <application> <tag>
# Stops, moves, migrates, prepares and starts the application

# Check if both application and tag arguments are provided
if [ -z "$1" ] || [ -z "$2" ]; then
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
echo "VERSION_FILE=${VERSION_FILE}"
echo "GITHUB_URL=${GITHUB_URL}"

#Verify directory app_$tag exists
newdir="${APP}_${RELEASE_TAG}"


if [ ! -d $newdir ]; then
    echo "Error: directory $newdir does not exist"
    exit 1
fi
#verify version
version="v"$(grep -oP '__version__ = "\K\S+' ${newdir}/${VERSION_FILE} | tr -d '"' )
if [ "$version" != "${RELEASE_TAG}" ]; then
    echo "Error: directory ${newdir} does not contain version ${RELEASE_TAG}"
    exit 1
else 
    echo "Found version, ${RELEASE_TAG} in ${newdir}"
fi


# Stop the current application
echo "Stopping the current application..."
output=$(cloudlinux-selector stop --json --interpreter python --app-root domains/${DOMAIN})
#expected = {"result": "success", "timestamp": 1715533882.345499}
# Check if the result is "success"
if [[ "$output" != *"\"result\": \"success\""* ]]; then
    echo "Error: Failed to stop the current application."
    exit 1
fi

echo "Creating backup of ${DOMAIN}"
tar -czf "${APP}_current.tar.gz" "$DOMAIN/"

#save the files in public_html directory
cp -r ${DOMAIN}/public_html ${newdir}/


cd ~
#get version information from  version file
old_version="v"$(grep -oP '__version__ = "\K\S+' domains/${DOMAIN}/${VERSION_FILE} | tr -d '"' )
echo "Found current version ${old_version}"

#let user confirm continue
echo "Moving ${DOMAIN} to ${APP}_${old_version}"
read -p "Are you sure you want to continue? (y/n) " -n 1 -r answer
if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
   echo
   echo "Aborting"
   exit 1
fi
echo
echo "continueing..."
# Move the old application
echo "Moving the old application..."
mv domains/${DOMAIN} "domains/${APP}_${old_version}"


# Copy the new application
echo "Copying the new application..."
mv "domains/${newdir}" "domains/${DOMAIN}"

if [ ${DATABASE_SOURCE}  = "production" ]; then

    # Copy the database
    if [ -f "domains/${DOMAIN}/db.sqlite3" ]; then
        echo "Moving database from ${RELEASE_TAG} to filestamped copy of the database..."
        today=$(date +%Y%m%d%H%M%S) 
        mv "domains/${DOMAIN}/db.sqlite3" "db.sqlite3.$today"
    fi
	 
    echo "Copying the production database to new production directory."
    cp "domains/${APP}_${old_version}/db.sqlite3" domains/${DOMAIN}
fi

# Zet virtual gebaseerd op variabelen in htaccess
source ~/domains/parse_env.sh ~/domains/${DOMAIN}/public_html/.htaccess

# Activate the virtual environment
if [ -z "$PASSENGER_PYTHON" ]; then
    echo "Error: PASSENGER_PYTHON is not set. Ensure it is defined in the .htaccess file."
    exit 1
fi
echo "Activating the virtual environment using $PASSENGER_PYTHON..."
source "$(dirname "$PASSENGER_PYTHON")/activate"


cd ~/domains/${DOMAIN}

# install new modules
pip install -r requirements.txt 

read -p "Did pip install run without errors (y/n) " -n 1 -r answer
if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
   echo
   echo "Aborting"
   exit 1
fi

if [ ${DATABASE_SOURCE}  = "production" ]; then
    # Migrate the database
    echo "Migrating the database..."
    python manage.py migrate
fi

# Collect static files
echo "Collecting static files..."
python manage.py collectstatic --no-input


read -p "Do you van to start the server? (y/n) " -n 1 -r answer
if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
   echo
   echo "Aborting"
   exit 1
fi

# Start the server
echo "Starting the server..."
output=$(cloudlinux-selector start --json --interpreter python --app-root domains/${DOMAIN})
# Check if the result is "success"
if [[ "$output" != *"\"result\": \"success\""* ]]; then
    echo "Error: Failed to stop the current application."
    exit 1
fi
