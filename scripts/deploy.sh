#!/bin/bash +x

# Version: 1.2.0
# Description: Deploy a targetted, tagged, version of the application
# Usage: ./deploy.sh <application> <tag> [stage=n | from-stage=n]
# 
# Stops, moves, migrates, prepares and starts the application

# Parse command-line arguments
STAGE_OPTION=""
STAGE_NUMBER=0
FROM_STAGE_NUMBER=0

for arg in "$@"; do
    if [[ "$arg" =~ ^stage=([0-9]+)$ ]]; then
        STAGE_OPTION="stage"
        STAGE_NUMBER="${BASH_REMATCH[1]}"
    elif [[ "$arg" =~ ^from-stage=([0-9]+)$ ]]; then
        STAGE_OPTION="from-stage"
        FROM_STAGE_NUMBER="${BASH_REMATCH[1]}"
    fi
done

if [[ "$STAGE_OPTION" == "stage" && "$STAGE_OPTION" == "from-stage" ]]; then
    echo "Error: Cannot use both 'stage=n' and 'from-stage=n' options at the same time."
    exit 1
fi


# Function to execute a stage
execute_stage() {
    local stage_2_execute=$1
    local stage_name=$2
    local stage_function=$3
    if [[ "$STAGE_OPTION" == "stage" && "$STAGE_NUMBER" -ne "$stage_2_execute" ]]; then
        return
    fi
    if [[ "$STAGE_OPTION" == "from-stage" && "$stage_2_execute" -lt "$FROM_STAGE_NUMBER" ]]; then
        return
    fi
    echo "Executing Stage $stage_2_execute: $stage_name..."
    $stage_function
}

# Initialization (always executed)
init() {
    # Check if both application and tag arguments are provided
    if [ -z "$1" ] || [ -z "$2" ]; then
        echo "Usage: $0 <application> <tag> [stage=n | from-stage=n]"
        echo "Available stages:"
        echo "  stage=1  : Verify source directory & source version"
        echo "  stage=2  : Stop current application"    
        echo "  stage=3  : Backup & move current application"
        echo "  stage=4  : Copy new application & database"
        echo "  stage=5  : Prepare the new application"
        echo "  stage=6  : Start the new application"

        exit 1
    fi

    APP=$1
    RELEASE_TAG=$2

    #check if ${DOMAIN_BASE_DIR} is set and exists
    if [ -z "${DOMAIN_BASE_DIR}" ]; then
        echo "Error: DOMAIN_BASE_DIR is not set. Please set it in the environment."
        exit 1
    fi  
    #check if ${DOMAIN_BASE_DIR} has a trailing slash
    if [[ "${DOMAIN_BASE_DIR}" != */ ]]; then
        echo "Error: DOMAIN_BASE_DIR should have a trailing slash. Please set it in the environment."
        exit 1
    fi

    # Source the configuration file based on the application
    CONFIG_FILE="${DOMAIN_BASE_DIR}${APP}_config.sh"
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

    # Verify directory app_$tag exists
    app_source_path="${DOMAIN_BASE_DIR}${APP}_${RELEASE_TAG}"
    
    current_version="v"$(grep -oP '__version__ = "\K\S+' "${DOMAIN_BASE_DIR}${DOMAIN}/${VERSION_FILE}" | tr -d '"' )
    echo "Found current version ${current_version}"
}
init "$@"	

# Stage 1: Verify source directory & source version
stage_1() {
    if [ ! -d $app_source_path ]; then
        echo "Error: directory $app_source_path does not exist"
        exit 1
    fi
    # Verify version
    local version="v"$(grep -oP '__version__ = "\K\S+' ${app_source_path}/${VERSION_FILE} | tr -d '"' )
    if [ "$version" != "${RELEASE_TAG}" ]; then
        echo "Error: directory ${app_source_path} does not contain version ${RELEASE_TAG}"
        exit 1
    else 
        echo "Found version, ${RELEASE_TAG} in ${app_source_path}"
    fi
}
execute_stage 1 "Verify source directory & source version" stage_1

# Stage 2: Stop current application
stage_2() {
    echo "Stopping the current application..."
    local output=$(cloudlinux-selector stop --json --interpreter python --app-root "${DOMAIN_BASE_DIR}${DOMAIN}")
    if [[ "$output" != *"\"result\": \"success\""* ]]; then
        echo "Error: Failed to stop the current application."
        echo "Output: $output"
        exit 1
    fi
}
execute_stage 2 "Stop current application" stage_2

# Stage 3: Backup & move current application
stage_3() {
    echo "Creating backup of ${DOMAIN}"
    tar -czf "${APP}_current.tar.gz" "${DOMAIN_BASE_DIR}${DOMAIN}"

    # Copy the files in public_html directory to the new directory
    cp -r "${DOMAIN_BASE_DIR}${DOMAIN}/public_html" "${app_source_path}/"

    # copy database if needed

    echo "Moving ${DOMAIN} to ${APP}_${current_version}"
    read -p "Are you sure you want to continue? (y/n) " -n 1 -r answer
    if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
       echo
       echo "Aborting"
       exit 1
    fi
    echo
    echo "Continuing..."
    mv "${DOMAIN_BASE_DIR}${DOMAIN}" "${DOMAIN_BASE_DIR}${APP}_${current_version}"
}
execute_stage 3 "Backup & move current application" stage_3

# Stage 4: Copy new application & database
stage_4() {
    echo "Moving the new application to ${DOMAIN}..."
    mv "${app_source_path}" "${DOMAIN_BASE_DIR}${DOMAIN}"

    if [ ${DATABASE_SOURCE}  = "production" ]; then
        if [ -f "${DOMAIN_BASE_DIR}${DOMAIN}/db.sqlite3" ]; then
            echo "Moving database from ${RELEASE_TAG} to date-stamped copy of the database..."
            local today=$(date +%Y%m%d%H%M%S) 
            mv "${DOMAIN_BASE_DIR}${DOMAIN}/db.sqlite3" "${DOMAIN_BASE_DIR}${APP}_db.sqlite3.$today"
        fi
        echo "Copying the production database to new production directory."
        cp "${DOMAIN_BASE_DIR}${APP}_${current_version}/db.sqlite3" "${DOMAIN_BASE_DIR}${DOMAIN}"
    fi
}
execute_stage 4 "Copy new application & database" stage_4

# Stage 5: Prepare the new application
stage_5() {
    if [ -z "$PYTHON_ENV" ]; then
        echo "Error: PYTHON_ENV is not set. Ensure it is defined in the config file."
        exit 1
    fi
    echo "Activating the virtual environment using $PYTHON_ENV..."
    source ${PYTHON_ENV} 
    source "${DOMAIN_BASE_DIR}parse_env.sh" "${DOMAIN_BASE_DIR}${DOMAIN}/public_html/.htaccess"

    cd "${DOMAIN_BASE_DIR}${DOMAIN}"
    echo "Installing new modules..."
    pip install -r requirements.txt 

    read -p "Did pip install run without errors (y/n) " -n 1 -r answer
    if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
       echo
       echo "Aborting"
       exit 1
    fi

    if [ ${DATABASE_SOURCE}  = "production" ]; then
        echo "Migrating the database..."
        python manage.py migrate
    fi

    echo "Collecting static files..."
    python manage.py collectstatic --clear --no-input
}
execute_stage 5 "Prepare the new application" stage_5

# Stage 6: Start the new application
stage_6() {
    read -p "Do you want to start the server? (y/n) " -n 1 -r answer
    if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
       echo
       echo "Aborting"
       exit 1
    fi

    echo "Starting the server..."
    output=$(cloudlinux-selector start --json --interpreter python --app-root "${DOMAIN_BASE_DIR}${DOMAIN}")
    if [[ "$output" != *"\"result\": \"success\""* ]]; then
        echo "Error: Failed to start the current application."
        echo "Output: $output"
        exit 1
    fi
}
execute_stage 6 "Start the new application" stage_6


