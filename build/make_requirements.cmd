@echo off
REM Change directory to project root (parent of this script's directory)
cd /d "%~dp0..\.."


echo Exporting requirements to requirements.txt...
poetry export -f requirements.txt --output requirements.txt --without-hashes


set SETTINGS_MODULE=%1
if not "%SETTINGS_MODULE%"=="" (
    echo Running Django tests with %SETTINGS_MODULE%...
    python manage.py test --settings=%SETTINGS_MODULE%
    if %ERRORLEVEL% NEQ 0 (
        echo Tests failed! Aborting bump.
        exit /b 1
    )
)

set NPM_DIR=
for %%d in (frontend client web) do (
    if exist "%%d\package.json" set NPM_DIR=%%d
)

if not "%NPM_DIR%"=="" (
    echo Found package.json in %NPM_DIR%, running npm build...
    pushd "%NPM_DIR%"
    npm run build
    if %ERRORLEVEL% NEQ 0 (
        popd
        echo npm build failed! Aborting.
        exit /b 1
    )
    popd
) else (
    echo No package.json found in frontend/client/web, skipping npm build.
)

echo All pre-bump checks passed!
exit /b 0