# Changelog

The format is based on [Keep a Changelog](http://keepachangelog.com/) and this project adheres to [Semantic Versioning](http://semver.org/).

## [unreleased](https://github.com/uzh/veins/tree/HEAD)

To be released as 0.2.0.

### 💥 Breaking: database contexts, typed roles and logins

The connection handling of the pool tool's database module moved here. The context design (`Veins.Ctx`: label,
held connection, transaction; phantom transaction marker; after-commit hooks) is the database refactoring by
Reynir Björnsson in [uzh/z-pool-tool#647](https://github.com/uzh/z-pool-tool/pull/647); the reconnect fixes come
from #624, #637 and #657 there.

#### Added

- `Veins.Ctx` and `label_ctx` / `connection_ctx` / `transaction_ctx` / `with_transaction`: statements run on a
  context instead of a label; held connections serialise their statements, nested transactions join the outer one,
  `Ctx.after_commit` hooks run once the transaction committed and are dropped on rollback. Only a pool builds
  contexts.
- Typed roles: `Veins.Need` (the rights a statement needs, as a lower bound of polymorphic variant tags chosen by
  the application), `Veins.Role` (the tags a part of the application grants, and the login it connects as) and
  `Veins.Request` (a Caqti request plus its needs). Contexts carry their role's type (`('txn, 'g) Ctx.t`), so a
  statement the role doesn't grant is a compile error, also in nested transactions and for `query`, `populate`
  and `transaction` (`~needs`). Every context names its role; `Role.owner` runs everything. `test/typing` checks
  that misuse doesn't compile.
- `Veins.Login` and per-login URLs: `Database.create ?logins label owner_url`. A login without a URL of its own
  connects with the owner's, on the owner's pool, so a database with a single user needs only its URL.
- `Error.Permission_denied` (label, login, role, declared needs): the database refused a statement the types
  allowed, i.e. a login lacks a grant its roles claim. `Dialect.is_permission_error` recognises it (MariaDB errnos
  1044, 1142, 1143, 1227, 1370; PostgreSQL SQLSTATE 42501, in the driver packages).
- `Error.Failed` carrying label, login, role and the untouched Caqti error, with `Error.cause` /
  `Error.cause_of_exn`.
- `Dialect.session_setup` (every session is pinned to UTC) and `Dialect.is_connection_error`; the driver packages
  recognise their driver's "connection lost" errors (MariaDB errnos, PostgreSQL SQLSTATE class 08).
- `Migration.Id.derive` for stable step ids of migrations written without ids.

#### Changed

- Query helpers take a context and a `Request.t`; `query`, `populate`, `transaction` and `transaction_iter` take
  `~needs`. The migration runner takes `?role` (default `Role.owner`) and runs on one held connection.
- `Database.create` takes the owner's URL and optional `~logins` instead of `Main` / `Multiple`; `Pool.fetch`,
  `Pool.connect` and `Pool.disconnect` take `?login` instead of `?role`.
- `Pool.drop`, `Pool.reset` and `Pool.disconnect` return `unit` and close connections in the background.
- Pools connect lazily, on first use.

#### Fixed

- Only a broken connection invalidates a pool; a constraint violation or syntax error used to drain and reconnect it.
- A failed pool tries to reconnect on the next call instead of failing forever.
- A pool is drained at most once and never awaited (a second drain used to hang its caller).
- `Pool.clear` closes the connections of the cleared pools.
- Databases with per-login URLs are listed by `Pool.find_all`, and adding one twice no longer replaces (and leaks)
  its pools.
- Turning off foreign key checks for a migration step runs on the same connection as the step.


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
