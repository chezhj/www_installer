git push origin --tags

@echo off
REM Navigate to the project root (parent of the build directory)
cd /d "%~dp0.."

echo Pushing changes and tags to remote...
REM --follow-tags pushes the commit and any tags attached to it (created by commitizen)
git push --follow-tags
