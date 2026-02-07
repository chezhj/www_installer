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

echo All pre-bump checks passed!
exit /b 0