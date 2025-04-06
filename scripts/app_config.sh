GITHUB_URL="https://github.com/chezhj/SmartTrainingChecklist.git"
DOMAIN="app.vdwaal.net"

DOMAIN_BASE_DIR="/home/user/domains/"

#python envoronment cmd 
PYTHON_ENV="/home/vdwanet/virtualenv/domains/${DOMAIN}/3.8/bin/activate"
#define where the script can find current version
VERSION_FILE="project_directory/__init__.py"

FILES_TO_COPY=(
    "app-directory"
    "project-directory"
)

#define wether database should be used from the repo, or the source 
#DATABASE_SOURCE="production"
DATABASE_SOURCE="repository"
