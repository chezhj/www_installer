@echo off
REM Run from the project directory (called as a pre-bump hook via PATH).
REM Do NOT cd — the hook runner already sets CWD to the project root.

REM --- Activate local venv if present (fixes missing poetry/python in hook env) ---
if exist ".venv\Scripts\activate.bat" (
    call ".venv\Scripts\activate.bat"
)

echo Exporting requirements to requirements.txt...
poetry export -f requirements.txt --output requirements.txt --without-hashes
if errorlevel 1 (
    echo poetry export failed! Aborting bump.
    exit /b 1
)

echo Running tests...
poetry run pytest
if errorlevel 1 (
    echo Tests failed! Aborting bump.
    exit /b 1
)

set NPM_DIR=
for %%d in (frontend client web) do (
    if exist "%%d\package.json" set NPM_DIR=%%d
)

if not "%NPM_DIR%"=="" (
    echo Found package.json in %NPM_DIR%, running npm build...
    pushd "%NPM_DIR%"
    npm run build
    if errorlevel 1 (
        popd
        echo npm build failed! Aborting.
        exit /b 1
    )
    popd
) else (
    echo No package.json found in frontend/client/web, skipping npm build.
)

REM Stage the regenerated artifacts so the following `cz bump` commit (and thus the
REM tag) ships them. Django hosts with no Node rely on the tracked web/static/dist.
echo Staging regenerated release artifacts...
if exist "requirements.txt" git add requirements.txt
if exist "web\static\dist" git add web\static\dist

echo All pre-bump checks passed!
exit /b 0
