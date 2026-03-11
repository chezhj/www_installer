git push origin --tags

@echo off

echo Pushing changes and tags to remote...
REM --follow-tags pushes the commit and any tags attached to it (created by commitizen)
git push --follow-tags
