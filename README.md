# veins

Database connection pooling and schema migration library for OCaml.

- **Connection pools** — label-based multi-database pool management backed by [Caqti](https://github.com/paurkedal/ocaml-caqti) and Lwt
- **Migrations** — roll-forward migrations in typed sets, each step tracked, failures recorded, a startup check and a read-only dry run for CI
- **MariaDB and PostgreSQL** — veins' SQL follows each connection's dialect; use the driver library you need
  (`veins.mariadb` or `veins.postgresql`)
- **Roles or a single user** — statements checked against typed roles at compile time, or `Plain` pools without
  roles for applications with one database user
- **`veins-gen`** — CLI tool to generate migration file boilerplate

API documentation: <https://uzh.github.io/veins/>

---

## Installation

```zsh
opam install veins caqti-driver-mariadb      # for MariaDB / MySQL
opam install veins caqti-driver-postgresql   # for PostgreSQL
```

There is one opam package, `veins`. Its driver libraries are installed when their Caqti driver is, so name both in
your opam file and the library in dune:

```dune
depends: [ "veins" "caqti-driver-mariadb" ]
```

```dune
(libraries veins veins.mariadb)
```

See [Package and libraries](#package-and-libraries).

---

## Quick start

### 1. Define a pool

```ocaml
open Veins

(* The URL is typically read from an environment variable. *)
let db () = Database.create (Label.create "root") (Url.create (Sys.getenv "DATABASE_URL"))

module Db = Veins_mariadb.Pools.Make (struct
  let database = db
  (* database_pool_size defaults to 10, expected_databases to 5 *)
end)

let () = Db.Pool.initialize ()
```

`database` is a function: `Pool.initialize` calls it, not the module's creation, so it may read a configuration that
is loaded at startup (an `.env` file, a test setup).

For custom pool sizes, or when you need to wire up the driver yourself:

```ocaml
module Db = Veins.Pools.Make (struct
  module Driver       = Veins_mariadb.Driver
  let database        = db
  let database_pool_size = 25
  let expected_databases = 1
end)
```

### 2. Declare roles and what statements need

A role is a part of your application with a type: the rights it has, as polymorphic variant tags you choose. A
statement's needs are a lower bound of those tags. Declare each once, with its type:

```ocaml
let read : [> `Read ] Need.t = Need.v "read"
let write : [> `Write ] Need.t = Need.v "write"

let query : [ `Read ] Role.t = Role.v "query"
let command : [ `Read | `Write ] Role.t = Role.v "command"

let find_user =
  {sql| SELECT name FROM users WHERE id = ? |sql}
  |> Caqti.Templater.(static T.(int -->? string))
  |> Request.create ~needs:read

let create_user =
  {sql| INSERT INTO users (name) VALUES (?) |sql}
  |> Caqti.Templater.(static T.(string -->. unit))
  |> Request.create ~needs:Need.(read & write)
```

`Need.none` declares no needs (e.g. `SELECT 1`, or code that hasn't declared them yet). `Role.owner` runs every
statement.

### 3. Run them on a context

A context says where statements run and as which role: `label_ctx` takes a fresh connection per statement,
`connection_ctx` holds one connection, `transaction_ctx` holds one connection inside a transaction.

```ocaml
let root = Label.create "root"

let%lwt name = Db.find_opt (Db.label_ctx ~role:query root) find_user 42

let%lwt () =
  Db.transaction_ctx ~role:command root (fun ctx ->
    Ctx.after_commit ctx (fun () -> Logs.info (fun m -> m "user created"));
    Db.exec ctx create_user "alice")
```

`Db.with_transaction ctx f` joins `ctx` when it is a transaction already, so functions can ask for a transaction
without knowing whether their caller opened one. Hooks registered with `Ctx.after_commit` run after the commit and
are dropped on rollback.

Errors the database reports raise `Error.Failed` with the label, login, role and untouched Caqti error; match on
`Error.cause_of_exn exn` (e.g. `` `Unique_violation ``) instead of on messages. Only errors that mean the connection
is gone drop and reconnect the pool.

### 4. Roles are checked by the compiler

A context carries its role's type, so a statement the role doesn't grant doesn't compile, and functions state the
rights they need in their signature:

```ocaml
let rename ctx name = Db.exec ctx create_user name
(* val rename : (_, [> `Read | `Write ]) Ctx.t -> string -> unit Lwt.t *)

rename (Db.label_ctx ~role:query root) "bob"
(* Error: ... The first variant type does not allow tag(s) `Write *)
```

This holds for nested transactions (`with_transaction` keeps the role) and for `query`, `populate` and
`transaction`, which take `~needs`. Nothing is checked at runtime.

Functions that get the Caqti connection itself (`query`, `transaction`) get a `Veins.Connection.fixed` one: on
MariaDB its `rollback`, `with_transaction` and `populate` work around caqti-driver-mariadb 3.1 (autocommit left off
after a rollback; `populate` not rolling back a failing row and committing the transaction it is called in), so
the whole `Caqti_lwt.CONNECTION` interface is safe to use. Only connections taken from `Pool.fetch`'s Caqti pool
are the driver's own; pass those through `Veins.Connection.fixed`.

`populate` inserts all rows or none, and joins the transaction of a transaction context. Its table and column
names go into the SQL as they are, like the fragments of `Veins.Dialect`: never build them from user input.

A label context checks its connection before every statement (on MariaDB a ping, i.e. one more round trip); code
running several statements is faster on one `connection_ctx` or transaction. Don't share a held context between
concurrent threads that use transactions: only statements are serialised, so one thread's statement would join
the transaction another has open.

### 5. Logins: one database user per role, or one for all

Each role connects as a `Login`, the database's own URL (`Login.owner`) unless it names another. A database has the
owner's URL and, optionally, a URL per login; a login without one connects with the owner's URL, on the owner's
pool:

```ocaml
let query_login = Login.create "query"
let command_login = Login.create "command"
let query : [ `Read ] Role.t = Role.v ~login:query_login "query"
let command : [ `Read | `Write ] Role.t = Role.v ~login:command_login "command"

(* one user for everything: the types separate the roles *)
let single = Database.create (Label.create "app") owner_url

(* one user per login: the database enforces each login's grants, too *)
let separated =
  Database.create (Label.create "app") owner_url
    ~strict_logins:true
    ~logins:[ query_login, Url.create query_url; command_login, Url.create command_url ]
```

A login without a URL runs with the owner's rights; veins logs that once per login. For a database meant to
separate its users, pass `~strict_logins:true`: a role whose login has no URL (a misspelt login, a URL missing
from the configuration) then fails with `Error.Login_not_configured` instead of quietly running as the owner.

Several roles may share a login; the database then enforces only what the login is granted, and the types the rest.
A role claiming more than its login is granted passes the compiler, but the database refuses the statement:
`Error.Permission_denied` (MariaDB errors 1044, 1142, 1143, 1227, 1370; PostgreSQL SQLSTATE 42501, recognised by
the driver libraries) names the label, login, role and declared needs.

### 6. Without roles: one database user for everything

An application that connects with a single user and doesn't separate rights takes the `Plain` pools: contexts
have no role, statements are plain Caqti requests, and nothing takes `~role` or `~needs`.

```ocaml
module Db = Veins_mariadb.Plain.Make (struct
  let database = db
end)

let find_user =
  {sql| SELECT name FROM users WHERE id = ? |sql}
  |> Caqti.Templater.(static T.(int -->? string))

let%lwt name = Db.find_opt (Db.label_ctx root) find_user 42

let%lwt () =
  Db.transaction_ctx root (fun ctx ->
    Plain.Ctx.after_commit ctx (fun () -> Logs.info (fun m -> m "user created"));
    Db.exec ctx create_user "alice")

let rename ctx name = Db.exec ctx create_user name
(* val rename : _ Plain.Ctx.t -> string -> unit Lwt.t *)
```

These are the same pools underneath (`Db.With_roles`), every context being one of `Role.owner`: reconnects,
transactions, errors and `Pool` behave as above. Two bridges to code written with roles:

- `Veins.Migration.App.Make (Db.With_roles)` runs the migrations (leave its `?role` out).
- `Plain.Ctx.with_roles ctx` is the same context for functions that state their needs, e.g. those of a library:
  the single user grants whatever is asked for, and the statements join `ctx`'s transaction.

For another pool size or `Pool_options`, use `Veins_mariadb.Plain.Make_with_options` (or the PostgreSQL one), whose
configuration adds `database_pool_size`; over pools of your own, `Veins.Plain.Make (Veins.Pools.Make_with_options
(Config) (Options))`.

## Migrations

Migrations are **roll-forward only**: there are no downs and no rollbacks, a mistake is fixed by a new migration.
Each step runs on its own, a failed step is recorded and blocks further runs until an admin repairs it by hand, and
the application refuses to start on a database whose migration state isn't clean. Both dialects behave the same.

### Generating a migration file

```zsh
veins-gen "add users table"
# → migration_20260424140314_add_users_table.ml
```

Set `VEINS_MIGRATION_DIR` to write the file to a specific directory (defaults to the current directory):

```zsh
VEINS_MIGRATION_DIR=lib/migrations veins-gen "add users table"
# → lib/migrations/migration_20260424140314_add_users_table.ml
```

`--steps N` writes `N` steps (default 1), each with a fresh id. `--dialect mariadb` or `--dialect postgresql` writes
SQL placeholders for that dialect only (`Sql.only`), the default `both` writes one for each (`Sql.v`). Options are
read only before the description, so `veins-gen "fix --steps bug"` is a description; put `--` before a description
that starts with `-`.

The generated file defines each step on its own, then adds them to the migration and registers it into the default
set (the files in [`test/gen`](test/gen) are complete examples, compiled and linked by the tests):

```ocaml
open Veins

let step_1 =
  let up =
    Migration.Sql.v
      ~mariadb:{sql|TODO: forward SQL|sql}
      ~postgresql:{sql|TODO: forward SQL|sql}
      ()
  in
  Migration.Step.create
    ~id:(Migration.Id.create "30d5a1e5-81eb-4de6-b81e-6f0695ab3421")
    ~label:"TODO: describe step 1"
    up
;;

let migration =
  let namespace = Migration.Namespace.create "add_users_table" in
  let written_at = Migration.ptime_of_string "2026-04-24T14:03:14Z" in
  Migration.create namespace ~written_at |> Migration.add_step step_1
;;

let () = Migration.register migration
```

Rename the steps after what they do and fill in the SQL; write one statement per step where possible. Every
statement names the dialects it is written for: `Sql.v ~mariadb ~postgresql ()` for one statement each (leave one
out if the application never runs on it), `Sql.only kind sql` for a single dialect, `Sql.any sql` for SQL that runs
anywhere. Before a run applies anything, veins checks that every pending step has SQL for the connection's dialect,
so a MariaDB-only migration fails up front on PostgreSQL instead of half way. SQL that starts with `TODO:`, the
generator's placeholder (`Sql.is_placeholder`), fails that check like missing SQL.

`~id` may be left out: the step then gets `Id.derive` of the namespace and its position, which is stable as long as
steps are only ever appended.

**Linking.** A migration file registers itself when its module is initialised, and nothing references it: the
linker drops it unless its library is linked whole. Put `(library_flags (-linkall))` on the library holding the
migrations (or `(link_flags (-linkall))` on the executable).

### Migrations in an application

An application registers its migrations, then calls one function to migrate and one to check at startup. With one
kind of database, register into the default set (`Migration.register`, as the generated files do) and use
`Migration.App.Make`:

```ocaml
module Migrate = Migration.App.Make (Db)

(* the application's "migrate" command: up, dry-run, status, check *)
let migrate args = Migrate.command_exit [ root ] args

(* at startup: raises unless the database is clean *)
let start () = Migrate.ensure_clean ~skip:(is_test ()) [ root ]
```

With several kinds of databases, say a root database and tenants, give each kind a typed set and tell veins which
set each database uses. `register` requires `~sets`, so a migration can't land in every set by accident, and a tag
that isn't one of the sets doesn't compile:

```ocaml
module Sets =
  Migration.Sets.Make
    (struct
      type t = [ `Root | `Tenant ]

      let all = [ `Root; `Tenant ]
      let name = function `Root -> "root" | `Tenant -> "tenant"
      let out_of_order = function `Root -> `Fail | `Tenant -> `Warn
    end)
    (Db)

module Migrate = Sets.App (struct
    let set_for label = if Label.equal label root then `Root else `Tenant
  end)

(* in a migration file *)
let () = Sets.register ~sets:[ `Tenant ] migration
```

The same namespace twice in one set raises when it is registered; the same namespace in different sets is fine.
Registration can happen at module initialisation or later: a set is read when it is used.

**Order.** `written_at` is the one timeline: a set runs in `written_at` order, ties broken by namespace
(`Migration.order`). A migration that depends on another is written after it; when that isn't so, out-of-order
detection (below) says so.

**`migrate`** orders the set, takes the migration lock, then refuses if a pending step has no SQL for the dialect,
if the database is uninitialized (no state table, but other tables: import first, see below), if a step has failed, or
if a migration is out of order under `` `Fail ``. Otherwise it creates or upgrades the state table if needed, runs the
pending steps in order, each on its own, and stops at the first failure (a lost connection leaves no `failed` row: the
step stays pending). Errors, also an unreachable database,
are returned, not raised.

**`command`** is the application's migrate command, given its arguments; it prints, runs every label and returns the
worst exit code, so CI and deploy scripts see a failure without parsing output (`command_exit` calls `exit` with it):

| Arguments | Does | Exit code |
| --- | --- | --- |
| `[]`, `["up"]` | `migrate` every label | 0, or 1 if any fails |
| `["up"; "--allow-out-of-order"; ns; …]` | the same, allowing `ns` out of order; the flag can be repeated | 0, or 1 |
| `["dry-run"]` (same flags) | what `migrate` would do, read-only | 0, or 1 if `migrate` would refuse on any label |
| `["status"]` | each label's report, failed steps with UUID, `last_error` and the repair SQL | 0 |
| `["check"]` | the same | 0, or 1 unless every label is clean |
| anything else | the usage | 2 |

An error that prevents the answer (an unreachable database) is 1 too: CI never passes because the database couldn't
be reached.

#### When a step fails

The failed step gets a row with `status = 'failed'`, the error in `last_error` and `run_at`; the steps before it stay
applied, nothing after it runs. On PostgreSQL the step's transaction reverts what it did; on MariaDB DDL commits
implicitly, so a step with several statements can be left half applied (one statement per step!). A missing
privilege is such a failure too: the database's error ends up in `last_error`.

While a step of the set has failed, `migrate` refuses and names it. An admin inspects the database and repairs it by
hand, addressing the row by the step's UUID (the same on every database, unlike the row's `id`); the refusal,
`report` and `command ["status"]` print both statements for the connection's dialect, ready to copy:

| The admin… | MariaDB | PostgreSQL | Next `migrate` |
| --- | --- | --- | --- |
| completed the step by hand | `UPDATE veins_migration_state SET status = 'applied' WHERE uuid = UNHEX(REPLACE('<uuid>', '-', ''))` | `UPDATE veins_migration_state SET status = 'applied' WHERE uuid = '<uuid>'` | continues after it |
| undid what the step left behind | `DELETE FROM veins_migration_state WHERE uuid = UNHEX(REPLACE('<uuid>', '-', ''))` | `DELETE FROM veins_migration_state WHERE uuid = '<uuid>'` | runs it again |

`last_error` stays after the `UPDATE`, as a record of what happened. Veins has no retry flag and no repair command.

#### Out of order

A pending migration is out of order when the set already has an applied migration that comes after it: what happens
when an older branch is merged after a newer migration was deployed (a step appended to an older migration counts
too). The policy is per set: `` `Fail `` (the default set's) refuses and names each one with the newest applied
migration; `` `Warn `` logs and runs it. `dry_run`, `report` and `check` list them under either policy.

Under `` `Fail `` there are two ways out:

1. **Move its `written_at`** after the newest applied migration. That's the normal way. Keep the namespace, even one
   that holds a timestamp: step UUIDs derive from the namespace, not from `written_at`, so where the migration ran
   already it stays applied, and a fresh database runs it in the same place as every other one.
2. **Allow it by name** on the database that refuses it: `command ["up"; "--allow-out-of-order"; ns]`. A migration
   that is out of order and isn't named is still refused; once it ran, it's applied and never out of order again on
   that database. In CI, set the pipeline variable `ALLOW_OUT_OF_ORDER` (namespaces separated by commas or
   whitespace): `up` and `dry-run` both read it, so the preflight and the deploy check and apply the same allowance.
   A name that isn't out of order is ignored with a log line.

A migration allowed this way runs later on that database than on a fresh one, so it must not depend on the order; if
in doubt, move its `written_at`.

#### Startup

A database's `Status.t` is what `migrate` would do with it: `Ready` (nothing to run), `Pending` (`migrate` runs the
pending steps) or `Blocked (refusal, report)` (`migrate` refuses, a person has to act first; the `Refusal.t` is the
reason: a failed step, an uninitialized database, steps without SQL for the dialect, out-of-order migrations of a
`` `Fail `` set, a namespace twice).

`ensure_clean labels` reads every label's status and, unless each is `Ready`, logs what `migrate` would do and
raises `Error.Exn (Migration_not_clean _)`, so the application doesn't start. Rows outside the set (orphaned) and
out-of-order migrations of a `` `Warn `` set are logged, not raised. `~skip:true` reads nothing, for tests. An
application that must keep serving the other databases when one isn't ready (tenants) uses `ready` or
`check ~policy:(`Fail | `Warn | `Skip)` per database instead, e.g. `Pending` → maintenance until migrated,
`Blocked` → maintenance until repaired. `report` gives the full picture.

#### Dry run in CI

`dry_run` (`command ["dry-run"]`) answers "would `migrate` run, and what would it do?" without changing anything:
it reads the state table and `information_schema`, takes no lock and writes nothing, so it works with a read-only
login. A pipeline can run it on every merge request against the production database (read-only credentials as a CI
secret) and catch an out-of-order migration before it's merged, not at deploy time. CI uses the set's own policy,
the same as production.

#### Roll-forward: keep the previous release working

There are no rollbacks. An older release deployed in an emergency runs against the newer schema: it reports the
rows it doesn't know as orphaned and starts anyway, so the schema must work for it. Expand, then contract in a later
release: add a column nullable or with a default, drop the old one only once no release reads it, never rename in
place.

#### Importing another engine's state

A database migrated by another engine has tables but no veins state table, so `migrate` refuses it as uninitialized.
Import its state once per database (the import creates the state table, also when it has nothing to import), from a
command of the application's own (it needs the application's migrations):

```ocaml
Migrate.Import.run ~source:(Migration.Import.counter_state ()) root
```

`counter_state ?table ()` reads a counter table like Sihl's `core_migration_state` (namespace, version, dirty): the
first `version` steps of each namespace become `applied` rows, a dirty namespace's next step a `failed` row
(`last_error` `"<table>: marked dirty after <n> step(s)"`), repaired by hand like any failed step. The import runs
under the migration lock, never refuses, only writes rows for steps that have none and reports namespaces the set
doesn't know and counters larger than a migration's steps. Other engines fit the same `Import.Source` (entries of
namespace, applied count, failure).

An application that keeps another engine beside veins (one that creates its tables first, on a new database too) runs
the import once per new database before `migrate`: with nothing to import, it only creates the state table, which is
what tells `migrate` the database is veins'.

**Rolling back across the switch.** Veins doesn't write the previous engine's table. Rolled back to a release that
still runs that engine, the application re-runs every migration added since the switch, and the previous engine's
counters don't know the steps veins ran. Roll forward instead: fix a mistake with a new migration, also right after the
switch.

#### The state table

`veins_migration_state` (or the plain table name in `VEINS_MIGRATION_TABLE`) has one row per step: a numeric `id`,
the step's `uuid`, `namespace`, `label`, `status` (`applied` / `failed`), `last_error`, `run_at`, `created_at` and
`updated_at`. A step without a row is pending. Veins upgrades the table itself, under the migration lock, when a
`migrate` runs steps and on every import; reads without the upgrade (a read-only login first) understand every older
layout.

The upgrade to this layout is **one-way**: a release on an older veins version can't read the table any more, so
once a database ran this veins version, no release older than that may be deployed on it.

Migrating holds a lock on the database (MariaDB `GET_LOCK`, PostgreSQL advisory lock), so instances starting together
apply each step once; the others wait, at most `VEINS_MIGRATION_LOCK_TIMEOUT` seconds (default 600). Migrations run
as the database owner unless you pass `~role`, on one held connection, without the pools' statement timeout.

---

## Package and libraries

One opam package, `veins`, with three libraries:

| Library (dune)     | Module             | Needs                     | Purpose                                                              |
|--------------------|--------------------|---------------------------|----------------------------------------------------------------------|
| `veins`            | `Veins`            |                           | Pools, migrations, the SQL of both dialects (`Veins.Dialect`)        |
| `veins.mariadb`    | `Veins_mariadb`    | `caqti-driver-mariadb`    | `Driver`, and `Pools.Make` / `Plain.Make` with it pre-configured     |
| `veins.postgresql` | `Veins_postgresql` | `caqti-driver-postgresql` | `Driver`, and `Pools.Make` / `Plain.Make` with it pre-configured     |

The Caqti drivers are optional dependencies (`depopts`) of `veins`: a driver library is built and installed only
when its driver is in the switch, so nobody needs `libpq` for a MariaDB application. opam has no way to ask for a
part of a package, so an application names the driver itself, next to `veins`. Installing a driver later makes
opam rebuild `veins` with its library.

The driver libraries only exist to read their driver's errors: Caqti classifies constraint violations, but not a
lost connection or a missing privilege, which veins needs to reconnect pools and to raise
`Error.Permission_denied`. The SQL veins sends doesn't depend on them: Caqti 3 renders each request for the dialect
of the connection it runs on (`Veins.Dialect.request`).

caqti-driver-postgresql connects blocking (libpq's `PQconnectdb`): the whole process waits until the server
answers, by default indefinitely. Veins adds `connect_timeout=5` (seconds) to PostgreSQL URLs that don't set it;
put `?connect_timeout=N` in the URL to choose another limit.

The `veins-gen` executable is installed as part of the `veins` package.

---

## Pool tuning and lost databases

`Pools.Make` (and the driver libraries' `Pools.Make`) use `Pool_options.default`. The driver libraries'
`Pools.Make_with_options` and `Plain.Make_with_options` take your own, and the pool size:

```ocaml
module Db =
  Veins_mariadb.Pools.Make_with_options
    (struct
      let database () = Database.create (Label.create "root") url
      let database_pool_size = 20
    end)
    (struct
      let options = Veins.Pool_options.{ default with statement_timeout = Some 30. }
    end)
```

`Veins.Pools.Make_with_options` is the same with every field of the configuration:

```ocaml
module Db =
  Veins.Pools.Make_with_options
    (struct
      let database () = Database.create (Label.create "root") url
      let database_pool_size = 10
      let expected_databases = 5

      module Driver = Veins_mariadb.Driver
    end)
    (struct
      let options =
        Veins.Pool_options.{ default with statement_timeout = Some 30.; acquire_timeout = Some 10. }
    end)
```

| Option              | Default       | Meaning                                                                             |
|---------------------|---------------|-------------------------------------------------------------------------------------|
| `max_use_count`     | `None`        | Close a connection after this many uses (Caqti's own default is 100)                |
| `max_idle_size`     | pool size     | Connections kept open while idle                                                    |
| `max_idle_age`      | `Some 300.`   | Seconds after which an idle connection is closed                                    |
| `statement_timeout` | `None`        | Seconds after which the database aborts a statement; migrations run without it      |
| `acquire_timeout`   | `None`        | Seconds a statement waits for a connection of an exhausted pool before it fails     |
| `reconnect_backoff` | `(0.5, 30.)`  | Initial and longest wait before a pool that lost its database tries to reconnect    |
| `on_failure`        | `None`        | Called with every error a statement raises, before it is raised                     |

**Reporting failures.** `on_failure` gets the label, the context's role, the request and its parameters (as Caqti
prints them, for `exec`, `collect`, `find` and `find_opt`) and the exception the statement raises right after
(`Error.Failed` or `Error.Exn`), e.g. to send it to an error tracker instead of wrapping every helper. Its
`connection_error` says whether the database was unreachable, so an outage can be logged instead of opening an issue
per statement. Each error is
reported once, where veins raises it, not again when it leaves `connection_ctx` or `transaction_ctx`; `Pool.ping`
and the other `Pool` functions don't report. The statement waits for it, and an exception of it is logged and
dropped.

Parameters of a type marked `redacted` print as `#redacted#`; everything else is printed as it is. Mark every
secret (passwords, tokens, keys) in the request's type before reporting parameters anywhere:

```ocaml
let login =
  {sql| SELECT id FROM users WHERE email = ? AND password_hash = ? |sql}
  |> Caqti.Templater.(static T.(t2 string (redacted string) -->? string))
(* reported as: "alice@example.com", #redacted# *)
```

**Connections.** There is one pool per label for the owner and one per login with a URL of its own, each opening
up to `database_pool_size` connections: with many databases, keep that product under the server's connection
limit. Idle connections are closed after `max_idle_age`.

**Lost databases.** A connection error drops the pool, and the next statement reconnects. If that fails too, the
pool backs off: statements fail right away with the last connection error, and after the wait a single statement
tries again. The wait doubles up to the maximum and resets once a statement reached the database.
`Db.is_connection_error exn` tells whether what a statement raised is such an error (the driver's lost or refused
connection, or `Error.Connection_failed`), e.g. to show "could not connect, try again later" instead of a failure.
A statement that waited `acquire_timeout` for a connection raises `Error.Acquire_timeout` instead, which is no
connection error: the pool is exhausted, not lost, and veins keeps it.
`Pool.ping label` tells whether a database answers; `Pool.connect` only sets the pool up. `Veins.Connection.test url`
checks a URL without a pool, and `Pool.test database` every URL of a database before (or after) it is registered: a
failed test of the registered database sets its status to `ConnectionIssue`, the next successful one back to `Active`.

**Timeouts.** PostgreSQL URLs get `connect_timeout=5` (see above). caqti-driver-mariadb takes no timeout from the
URL: set `connect-timeout` (and `read-timeout` / `write-timeout`) in the `[caqti]` group of the client's `my.cnf`,
or another group named with `?config-group=` in the URL.

**TLS.** Veins doesn't touch the transport: for a database on another host, require TLS in the URL
(`?sslmode=verify-full` on PostgreSQL) or, for MariaDB, in the `my.cnf` group (`ssl-ca`, `ssl-verify-server-cert`).
`Url.pp` / `Url.show` mask the password, also one given as a `password` or `sslpassword` query parameter.

**Sharing the pools.** Code that expects Caqti's results instead of veins' exceptions, e.g. a framework that runs
its own statements, borrows a connection with `Db.Pool.use label f` (`?login` with roles). `f` gets a fixed
connection (`Veins.Connection.fixed`) and its result comes back as it is, `(_, Caqti.Error.t) result`. A lost
connection drops the pool and a pool that waits to reconnect gives an `Error` right away, as for every statement.
Only an unknown label or login raises. These errors aren't reported to `on_failure`.

**Known issues.** What Caqti 3.1 and its drivers cost or get wrong, and what veins does about it (a round trip
per borrowed MariaDB connection, blocking PostgreSQL connects, `static` requests with varying SQL, …), is in
[KNOWN_ISSUES.md](KNOWN_ISSUES.md).

---

## Multiple databases

_NOTE: `initialize` initiates the main database passed via `Pools.Make(Config)`_

```ocaml
let analytics =
  Database.create (Label.create "analytics") (Url.create analytics_url)

let () =
  Db.Pool.initialize ~additional_pools:[ analytics ] ();
  (* later: *)
  let%lwt rows = Db.collect (Db.label_ctx ~role:query (Label.create "analytics")) req () in
  ...
```

---

## Credits

The context design (`Veins.Ctx`: label, held connection and transaction contexts, the phantom transaction marker,
after-commit hooks) is Reynir Björnsson's database refactoring of the
[pool tool](https://github.com/uzh/z-pool-tool) ([#647](https://github.com/uzh/z-pool-tool/pull/647)), moved here
together with the pool tool's reconnect fixes.

## Development

The devcontainer mirrors the pool tool's setup (same base image, GitButler CLI, PAT-based git access). Copy
`.devcontainer/.env.example` to `.devcontainer/.env` and fill it in, then reopen the folder in the container.

```bash
# inside the container (the `make` alias uses .devcontainer/Makefile with the database URLs)
make deps
make build
make test
```

Both database servers run in `Europe/Zurich` on purpose, so the tests prove that veins pins every session to UTC.
The init scripts (`.devcontainer/init-*/01.sql`) create a `test` database and one user per role
(`veins_reader`, `veins_writer`, `veins_migrator`); they only run when the database volume is created, so remove
the `db-mariadb` / `db-postgres` volumes after changing them.

Environment variables used by the test suite (defaults match the devcontainer):

| Variable                                         | Default                                                     |
|--------------------------------------------------|-------------------------------------------------------------|
| `MARIADB_URL`                                    | `mariadb://admin:password@database-mariadb/development`     |
| `POSTGRES_URL`                                   | `postgresql://root:root@database-postgres/development`      |
| `MARIADB_{READER,WRITER,MIGRATOR}_URL`           | `MARIADB_URL` (a single all-rights user)                    |
| `POSTGRES_{READER,WRITER,MIGRATOR}_URL`          | `POSTGRES_URL` (a single all-rights user)                   |

## Release a new version

1. Document the changes under `## [unreleased]` in `CHANGELOG.md`.
1. On an up-to-date, clean `main`, run `make version-{patch|minor|major}`, or `make version V=X.Y.Z` to release a
   version already set in `dune-project`. This sets the version in `dune-project` and `veins.opam`, turns the
   unreleased section into `## [X.Y.Z](…) - date` under a new empty one, commits and tags `X.Y.Z`.
1. Push the commit and the tag: `git push && git push origin X.Y.Z`.

CI runs on the tag; when every job passes, the `release` job checks that the tag matches the package version and
creates the GitHub release with that version's `CHANGELOG.md` section as its notes.
