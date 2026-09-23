git push origin --tags

@echo off

echo Pushing changes and tags to remote...
REM The tags are pushed by the first line: commitizen tags are lightweight, which
REM --follow-tags skips (it only pushes annotated tags)
git push --follow-tags
