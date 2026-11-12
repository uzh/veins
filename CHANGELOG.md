# Changelog

The format is based on [Keep a Changelog](http://keepachangelog.com/) and this project adheres to [Semantic Versioning](http://semver.org/).

## [unreleased](https://github.com/uzh/veins/tree/HEAD)

💥 The start of using the changelog. Preparations for our pilot version 0.1.0.

### Added

- Devcontainer on the pool tool's base image (OCaml 5.5.2, GitButler CLI, PAT-based git access), with one
  database user per role and both servers in `Europe/Zurich`.

### Changed

- Require caqti >= 3.0 (`caqti.classic` for the `Caqti_type` / `Caqti_request` modules), as pool and guardian do.
- Rename the remaining `vena` names: the migration state table defaults to `veins_migration_state`, overridable
  with `VEINS_MIGRATION_TABLE`.

### Fixed

- The test suites are `tests` stanzas now, so `dune test` (and CI) runs them; before, they were plain
  executables and never ran. Each dialect suite links only its own driver.
- CI connects to its service containers on `127.0.0.1` (the job runs on the runner host).
- The PostgreSQL init script used MariaDB syntax.
