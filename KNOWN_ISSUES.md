# Known issues

Limits of veins that come from Caqti 3.1 and its drivers, what veins does about each, and what is still open
upstream ([paurkedal/ocaml-caqti](https://github.com/paurkedal/ocaml-caqti/issues)).

Costs below were measured on 2026-11-20 against the devcontainer databases, about 45 µs per round trip. In
production, anything counted in round trips grows with the real network latency.

## Filed upstream

Until a fixed Caqti release is out, veins keeps these workarounds:

| Upstream                                                    | Issue                                                                       | Workaround in veins                                                                                    |
|-------------------------------------------------------------|-----------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------|
| [#147](https://github.com/paurkedal/ocaml-caqti/issues/147) | caqti-driver-mariadb: `rollback` leaves `autocommit` off                    | `SET autocommit = 1` after every rollback on MariaDB connections; a commit is that statement alone     |
| [#148](https://github.com/paurkedal/ocaml-caqti/issues/148) | caqti-driver-postgresql: `connect` blocks the event loop (`PQconnectdb`)    | adds `connect_timeout=5` to PostgreSQL URLs that don't set one (see [below](#postgresql-connects-block-the-event-loop)) |
| [#149](https://github.com/paurkedal/ocaml-caqti/issues/149) | caqti-driver-mariadb: `populate` leaves a transaction open when a row fails | inserts the rows itself on MariaDB, 100 per statement, in a transaction rolled back on error           |
| [#150](https://github.com/paurkedal/ocaml-caqti/issues/150) | an `Error` from a custom type's encoder escapes as `Row_type.Reject`        | none: callers get the exception; the "custom row type" test accepts it                                 |

## Performance

### MariaDB: a round trip to check each borrowed connection

When a statement takes a connection from the pool (every statement on a `label_ctx`, every `Pool.use`), Caqti's
pool first checks it: the MariaDB driver's `validate` is a `COM_PING` to the server. PostgreSQL's `validate` only
looks at the local connection state.

| µs per operation                                      | MariaDB | PostgreSQL |
|-------------------------------------------------------|---------|------------|
| Borrow a connection, no statement                     | 45      | 0.7        |
| One statement on a held connection (`connection_ctx`) | 101     | 48         |
| One statement, borrowing each time (`label_ctx`)      | 136     | 51         |

veins can't turn the check off: `Caqti_lwt_unix` neither exposes `Pool.create` nor takes a `validate` in
`connect_pool`. Avoiding it would take a pool of veins' own.

**What to do:** run a handler's statements on one `connection_ctx` or `transaction_ctx`, which pays the check once.
**Upstream (not filed):** ask for a `?validate` on `connect_pool`, or for checking only connections idle longer than
about a second.

### MariaDB: a round trip to reset each prepared statement

After running a prepared (`static` or `dynamic`) request, caqti-driver-mariadb resets the statement on the server
(`mysql_stmt_reset`, a `COM_STMT_RESET` round trip). That is why one statement on a held MariaDB connection costs
about two round trips. A `direct` request without parameters and without result rows is sent as text in one round
trip; veins builds its own transaction statements that way.

**Upstream (not filed):** skip or defer the reset when the statement returned all its rows.

### PostgreSQL connects block the event loop

caqti-driver-postgresql 3.1 connects with libpq's blocking `PQconnectdb` ([#148](https://github.com/paurkedal/ocaml-caqti/issues/148)):
while a connection is being opened, no other request of the process runs. veins bounds each connect with
`connect_timeout=5`, but can't make it non-blocking.

It shows when many connections open at once:

- after an outage, when the pools reconnect;
- after a quiet period: idle connections close after `Pool_options.max_idle_age` (300 s by default), and the next
  burst of traffic opens them again one blocking connect at a time.

**What to do:** where traffic is bursty after quiet periods, raise `max_idle_age` (or set it to `None`) so the
connections stay open.

### MariaDB transactions take more round trips than PostgreSQL's

The driver starts a transaction by turning `autocommit` off; veins commits by turning it back on (one round trip)
and rolls back with `ROLLBACK` plus `SET autocommit = 1` (two). With the check of the borrowed connection, a
`transaction_ctx` with one statement costs 225 µs on MariaDB, 148 µs on PostgreSQL. Sending `START TRANSACTION`
instead would save the rollback's second round trip, but would change what a rollback undoes after DDL (MariaDB
commits DDL implicitly), which migration steps rely on.

## Correctness traps

### `static` requests whose SQL varies leak prepared statements

Caqti keeps a `static` request's prepared statement on each connection for as long as the connection lives, one per
distinct SQL text, and never releases it. A request built per call with SQL that changes (a `Dynparam` filter, an
`IN (?, ?, …)` of varying length) adds one per call: 2000 such calls took MariaDB's `Prepared_stmt_count` from 1 to
2001, against 34 for `dynamic` requests, which Caqti releases least recently used first. Once the server holds
`max_prepared_stmt_count` (16382 by default, for the whole server), MariaDB refuses to prepare any statement.
veins' default `max_use_count = None` keeps connections open longer, so the leak grows further.

**What to do:** build such requests as `dynamic` or `direct` (documented in `Veins.Dynparam`). veins' own requests
are created once at top level or are `direct`.

### MariaDB `populate` and `max_allowed_packet`

On MariaDB, `populate` sends 100 rows per statement. Rows of the usual size stay well below the server's
`max_allowed_packet` (16 MiB by default); 100 rows with large `TEXT` or `BLOB` values may not, and the statement
fails. Insert such rows in smaller lists, or one `exec` per row.

### `connection_transaction` wraps a connection twice

`connection_transaction` fixes the connection it gets, which may come from outside veins. A connection veins handed
out is already fixed, so it gets wrapped twice, and a rollback through it sends `SET autocommit = 1` twice: one
round trip more, on rollback only. veins can't tell a fixed connection from a raw one: Caqti's connection signature
has no field to mark it with.

### Errors are read per driver

`Caqti.Error.cause` covers constraint violations and insufficient resources only. veins reads lost connections and
missing privileges from each driver's own error constructors, which is why `Veins_mariadb.Driver` and
`Veins_postgresql.Driver` exist. The issue below asks Caqti to classify both.

<details>
<summary>Issue text, not filed yet, ready to paste</summary>

**Title:** Classify "insufficient privilege" and "connection lost" in `Caqti.Error.cause`

`Caqti.Error.cause` lets applications react to a failed request without matching on driver-specific messages, but it
currently covers integrity constraint violations and insufficient resources only. Two other classes come up in every
pooling layer we've built on Caqti 3, and today they can only be detected by linking each driver and matching its
private message constructors:

1. **Insufficient privilege**: the server refused the statement because the user lacks a grant. This matters when an
   application connects as several database users with different grants (e.g. a read-only user for queries and a
   writing user for commands): the error is a configuration problem, not a data problem, and should be reported as
   such.

2. **Connection lost**: the statement failed because the connection is gone (server restart, idle timeout, killed
   session). A pool on top of Caqti has to drop and reconnect in this case, but must *not* do so for a constraint
   violation or a syntax error.

#### What we do today

```ocaml
(* MariaDB *)
match msg with
| Caqti_driver_mariadb.Error_msg { errno; _ } ->
  (errno >= 2000 && errno < 3000) || List.mem errno [ 1053; 1927; 4031 ]   (* lost *)
  (* or *) List.mem errno [ 1044; 1142; 1143; 1227; 1370 ]                  (* privilege *)

(* PostgreSQL *)
match msg with
| Caqti_driver_postgresql.Result_error_msg { sqlstate; _ } ->
  String.starts_with ~prefix:"08" sqlstate || List.mem sqlstate [ "57P01"; "57P02"; "57P03" ]
  (* or *) sqlstate = "42501"
| Caqti_driver_postgresql.Connection_error_msg { connection_status; _ } -> connection_status = Bad
```

This forces a library that is otherwise driver-agnostic to ship one package per driver only to read errors; the SQL
itself can already be made dialect-aware with `Caqti.Template.Request.create`.

#### Proposal

Extend `cause` with two cases, following the existing `__don't_match` convention so the change is source
compatible:

```ocaml
type access_violation = [
  | `Insufficient_privilege
  | `Access_violation__don't_match
]

type connection_failure = [
  | `Connection_lost
  | `Connection_failure__don't_match
]

type cause = [
  | integrity_constraint_violation
  | insufficient_resources
  | access_violation
  | connection_failure
  | `Unspecified__don't_match
]
```

Suggested mappings:

| Cause                    | MariaDB / MySQL errno                                | PostgreSQL                                   | SQLite3                       |
|--------------------------|------------------------------------------------------|----------------------------------------------|-------------------------------|
| `Insufficient_privilege` | 1044, 1142, 1143, 1227, 1370                         | SQLSTATE 42501                               | `SQLITE_AUTH` / `SQLITE_PERM` |
| `Connection_lost`        | 2006, 2013, 2055 (client); 1053, 1927, 4031 (server) | SQLSTATE class 08, 57P01–57P03; status `Bad` | —                             |

For the connection case a predicate may fit better (`Caqti.Error.is_connection_lost : [< t] -> bool`), since some
drivers report it outside `Request_failed` / `Response_failed`. Happy to adjust to whatever suits Caqti's design.

We'd be glad to send a PR for the MariaDB and PostgreSQL drivers if this direction is acceptable.

</details>
