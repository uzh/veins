# Changelog

The format is based on [Keep a Changelog](http://keepachangelog.com/) and this project adheres to [Semantic Versioning](http://semver.org/).

## [unreleased](https://github.com/uzh/veins/tree/HEAD)

To be released as 0.2.0.

### 💥 Breaking: one opam package

- The packages `veins-mariadb` and `veins-postgresql` are gone: their libraries are part of `veins`, as
  `veins.mariadb` and `veins.postgresql` (modules `Veins_mariadb` / `Veins_postgresql`, unchanged). They are built
  and installed when their Caqti driver is in the switch: `caqti-driver-mariadb` and `caqti-driver-postgresql` are
  optional dependencies of `veins`. In an application, depend on `veins` and the driver in the opam file, and name
  `veins.mariadb` / `veins.postgresql` in dune.

### 💥 Breaking: migration statements per dialect

- `Migration.Step.create` takes `Migration.Sql.t` instead of strings, for `up` and `~down`: `Sql.v ~mariadb
  ~postgresql ()` (one statement per dialect, either may be left out), `Sql.only kind sql` or `Sql.any sql` (the
  same SQL everywhere, stated explicitly). `run_all` and `up` check every pending step against the connection's
  dialect before they apply any and fail with `Error.Migration_failed` naming the steps without SQL; `down` does
  the same for its `down` statements. A wrapped string becomes `Sql.any "…"`, or `Sql.only Dialect.Mariadb "…"`
  where it is MariaDB's SQL.
- SQL that starts with `TODO` (what `veins-gen` writes) is a placeholder, `Sql.is_placeholder`: the check treats
  it as missing, so a step left half filled in fails before anything is applied. `Sql.written` tells both apart.
- `Runner.verify` runs that check alone (read only), and `Runner.check` reports such steps as the new drift
  `Unsupported { namespace; dialect; steps }`.
- `Step.create ?id`: without an id, a step gets `Id.derive` of its migration's namespace and its position, so
  `Step.t.id` is an option and `Step.id` returns one. `Migration.step_ids` gives the effective ids.
- `run_all ~migrations` runs them in the order given (only registered migrations are sorted by `written_at`).
- `veins-gen` writes one step by default; `--steps N` writes more, `--dialect mariadb|postgresql` writes `Sql.only`
  placeholders for one dialect instead of `Sql.v` with a TODO for each. Each step is a named binding with its `up`
  and `down` SQL as `{sql|…|sql}` strings; `migration` then adds the steps in order and the file registers it. The
  file no longer opens `Migration`: it names `Migration.create`, `Migration.register` etc. The tests compile its
  output (`test/gen`). Options are read only before the description (`--` ends them), and `--help` exits with 0.

### Added: importing a counter-based migration table

- `Migration.Counter_state.Make (Db)`: `import` marks the steps a counter table such as Sihl's
  `core_migration_state` counts as applied (by derived ids) and refuses dirty namespaces, `record` keeps the counter
  up to date. Both dialects. Deprecated from the start, for the time an application moves over.

### Added: pools without roles

- `Veins.Plain` (`Veins_mariadb.Plain.Make`, `Veins_postgresql.Plain.Make`, or `Veins.Plain.Make` over any
  pools): the pools for an application with one database user. Contexts carry no role (`'txn Plain.Ctx.t`),
  statements are plain Caqti requests, and nothing takes `~role`, `~login` or `~needs`. `Db.With_roles` are the
  pools underneath (e.g. for `Migration.Make`), and `Plain.Ctx.with_roles` passes a context to code that states
  its needs.

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
- `Veins.Caqti_encoders`: row types with custom encoders and decoders written as lists
  (`custom ~encode ~decode Schema.[ int; string ]`, encoders returning `Data.[ id; name ]`), moved from the pool
  tool's database module.
- `Veins.Login` and per-login URLs: `Database.create ?logins label owner_url`. A login without a URL of its own
  connects with the owner's, on the owner's pool, so a database with a single user needs only its URL.
- `Error.Permission_denied` (label, login, role, declared needs): the database refused a statement the types
  allowed, i.e. a login lacks a grant its roles claim. `Driver.is_permission_error` recognises it (MariaDB errnos
  1044, 1142, 1143, 1227, 1370; PostgreSQL SQLSTATE 42501, in the driver libraries).
- `Error.Failed` carrying label, login, role and the untouched Caqti error, with `Error.cause` /
  `Error.cause_of_exn`.
- Every session is pinned to UTC (`Dialect.set_utc`), and `Driver.is_connection_error`; the driver libraries
  recognise their driver's "connection lost" errors (MariaDB errnos, PostgreSQL SQLSTATE class 08).
- `Migration.Id.derive` for stable step ids of migrations written without ids, and
  `Runner.mark_applied` to import another engine's state; `run_all`, `status`, `pending` and `check`
  take an explicit `?migrations` list.
- `connection_transaction` for transactions on a raw connection (inside `query`).
- `Pool_options` and `Pools.Make_with_options`: recycling of connections (`max_use_count`, `max_idle_size`,
  `max_idle_age`), `statement_timeout`, `acquire_timeout` (how long a statement waits for a connection of an
  exhausted pool) and `reconnect_backoff`. `Pools.Make` uses `Pool_options.default`; `Db.options` tells them.
- Reconnect backoff: a pool that lost its database fails right away with the last connection error for a growing
  while, then lets a single statement try again, instead of a connection attempt per statement (which, on
  PostgreSQL, each blocked the process for the connect timeout).
- `Database.create ~strict_logins:true`: a role whose login has no URL fails with `Error.Login_not_configured`
  instead of connecting as the owner. Without it the fallback is logged once per login.
- `Veins.Connection.fixed`: a Caqti connection with caqti-driver-mariadb 3.1's `rollback`, `with_transaction` and
  `populate` worked around. Every connection veins passes to a function or holds in a context is one, so code
  using the raw `Caqti_lwt.CONNECTION` interface is safe without changes.
- `Pool.ping`: whether a database answers.
- Migrations take a lock on the database (MariaDB `GET_LOCK`, PostgreSQL advisory lock) while `run_all`, `up`,
  `down` or `mark_applied` run, so instances starting together apply each step once
  (`VEINS_MIGRATION_LOCK_TIMEOUT`, default 600 seconds).
- `Dialect.is_identifier`, `Dialect.table_exists`, `Dialect.try_lock` / `Dialect.unlock`.
- `Dialect.list_tables`, `Dialect.truncate` and `Dialect.drop` (PostgreSQL with `CASCADE`), and
  `Migration.state_table`, the name of the migration state table (`VEINS_MIGRATION_TABLE` honoured), for code that
  empties every table but that one.
- `Connection.without_fk_checks`: runs a function with a connection's foreign key checks off and turns them back on
  however it ends (a no-op on PostgreSQL). Migration steps with `check_fk:false` use it.
- `Connection.test`: connects once to a URL, without a pool, to check it before its database is registered; a
  failure is `Error.Connection_failed` with the URL shown without its password. `Pool.test` does so for every URL
  of a `Database.t` (the owner's and each login's), the way the pools connect, and keeps the status of the
  registered database: a failure turns `Active` into `ConnectionIssue`, a success turns it back.

#### Changed

- **No dialect configuration:** veins' SQL is rendered from the dialect of the connection it runs on (Caqti 3
  dialect-aware requests, `Dialect.request`), so the same pool code runs on MariaDB and PostgreSQL. `Dialect` is a
  set of SQL functions taking the connection's dialect; `Dialect.Sig`, `Dialect.Mariadb` / `Dialect.Postgresql`,
  `Dialect.of_url` and `insert_row` are gone. What stays per driver is reading its errors: `Driver.Sig`
  (`is_connection_error`, `is_permission_error`), implemented by `Veins_mariadb.Driver` /
  `Veins_postgresql.Driver`; `Pools_sig.ConfigSig` takes `module Driver` instead of `module Dialect`.
- Built on the Caqti 3 API (`Caqti.Template`, `Caqti.Error`, `Caqti.Pool.Config`); veins and its driver libraries no
  longer link `caqti.classic`. Requests built with the Caqti 2 API still work: `Caqti_request.t` is
  `Caqti.Template.Request.t`.
- Query helpers take a context and a `Request.t`; `query`, `populate`, `transaction` and `transaction_iter` take
  `~needs`. The migration runner takes `?role` (default `Role.owner`) and runs on one held connection.
- `Database.create` takes the owner's URL and optional `~logins` instead of `Main` / `Multiple`; `Pool.fetch`,
  `Pool.connect` and `Pool.disconnect` take `?login` instead of `?role`. `Database.t` is a private record: its
  fields can be read, building one goes through `Database.create`, which checks the logins, and
  `Database.with_status` changes its status.
- **Breaking:** `Veins.Databases`, a global registry of databases nothing used, is gone: the pools keep their own (`Pool.add`, `Pool.find`, `Pool.find_all`).
- `Pool.drop`, `Pool.reset` and `Pool.disconnect` return `unit` and close connections in the background.
- Pools connect lazily, on first use. `Pool.fetch` ignores `?retries` (kept for compatibility).
- Connections are no longer closed after 100 uses (Caqti's default), and idle ones are closed after 5 minutes
  (`Pool_options`).
- `Runner.status`, `pending` and `check` only read: they no longer create the state table (a missing one means
  nothing is applied), so a read-only role can call them. Migrations run without the pools' statement timeout.
- `VEINS_MIGRATION_TABLE` must be a plain table name (letters, digits, `_`); anything else raises.
- Veins no longer sends `SET time_zone` on new connections: both Caqti drivers pin the session to UTC themselves
  (the suites check it). `Dialect.set_utc` stays.
- `ocamlformat` is a dev-setup dependency only; `mtime` is a dependency.

#### Fixed

- Only a broken connection invalidates a pool; a constraint violation or syntax error used to drain and reconnect it.
- A failed pool tries to reconnect on the next call instead of failing forever.
- A pool is drained at most once and never awaited (a second drain used to hang its caller).
- `Pool.clear` closes the connections of the cleared pools.
- Databases with per-login URLs are listed by `Pool.find_all`, and adding one twice no longer replaces (and leaks)
  its pools.
- Turning off foreign key checks for a migration step runs on the same connection as the step.
- `populate` on MariaDB inserts all rows or none and joins the transaction it runs in. caqti-driver-mariadb 3.1's
  own `populate` returned after a failing row without rolling back (the pooled connection kept an open transaction
  with autocommit off) and committed the transaction it was called in.
- A connection error only drops the pool it happened on: statements still under way on a pool that was replaced
  already used to tear down its healthy replacement when they failed.
- MariaDB's server-side network errors (1152, 1154-1161) count as lost connections.
- `Url.pp` / `Url.show` also mask a password given as a `password` or `sslpassword` query parameter.
- PostgreSQL URLs get `connect_timeout=5` unless they set their own: caqti-driver-postgresql connects blocking
  (libpq's `PQconnectdb`), and an unresponsive server used to freeze the whole process.


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
