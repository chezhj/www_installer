## v1.3.0 (2026-09-22)

### Feat

- **sqlite**: WAL-safe backup and restore via the SQLite backup API (#4)

## v1.2.6 (2026-08-13)

### Fix

- **activate**: pass --defaults-extra-file first so the mysql backup works

## v1.2.5 (2026-08-11)

### Fix

- **activate**: create public_html and record swap before .htaccess

## v1.2.4 (2026-08-09)

### Fix

- **deploy**: mark shell scripts executable

## v1.2.3 (2026-08-07)

## v1.2.0 (2026-08-06)

### Feat

- **deploy**: add CI-driven install tooling and release workflow
- **deploy**: load checklist content on production deploys
- :bug: fixed errormessaging
- Added add to path and updated readme
- Added npm build
- Added test tun to make_requirements
- Added build cmd
- **deploy**: Added no-deps to pip
- Added staged based execution
- **deploy**: Changed sourcing environment based on settings
- Removed version check, to complex

### Fix

- **deploy**: skip checklist import on releases without the command
- **config**: default DATABASE_SOURCE to production
- CHanged cd to reflect path
- **deploy**: Fixed database copy
- **deploy**: Moved database  copy to step 3
- **delploy**: Added domains base directory
- Small fixes

## v1.1.0 (2025-03-22)

### Feat

- Added upgrade env with requirements

## v1.0.0 (2025-03-22)

### Feat

- Added version and check
- Moved script from projects
