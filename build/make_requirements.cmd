@echo off
REM Change directory to project root (parent of this script's directory)
cd /d "%~dp0.."

echo Exporting requirements to requirements.txt...
poetry export -f requirements.txt --output requirements.txt --without-hashes
