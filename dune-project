(lang dune 3.17)

(name vena)

(version 0.1.0)

(generate_opam_files true)

(package
 (name vena)
 (synopsis "Database connection pooling and migration library for OCaml")
 (description
  "Vena provides a database connection pooling library with support for MariaDB and PostgreSQL via functors. It includes migration handling with up/down tracking, transaction management with setup/cleanup hooks, auto-reconnect on connection drop, and a clean label-based interface. The vena-gen tool generates migration file boilerplate.")
 (depends
  (ocaml
   (>= 5.0.0))
  (dune
   (>= 3.17))
  (caqti
   (>= 2.1.0))
  (caqti-lwt
   (>= 2.1.0))
  (lwt
   (>= 5.7.0))
  (lwt_ppx
   (>= 2.1.0))
  (containers
   (>= 3.13.0))
  (logs
   (>= 0.7.0))
  (fmt
   (>= 0.9.0))
  (uri
   (>= 4.4.0))
  (ptime
   (>= 1.1.0))
  (alcotest
   (and
    :with-test
    (>= 1.7.0)))
  (alcotest-lwt
   (and
    :with-test
    (>= 1.7.0)))
  (caqti-driver-mariadb
   (and
    :with-test
    (>= 2.1.0)))
  (caqti-driver-postgresql
   (and
    :with-test
    (>= 2.1.0)))))

(package
 (name vena-mariadb)
 (synopsis "MariaDB driver convenience package for Vena")
 (description
  "Depends on vena and caqti-driver-mariadb. Provides Vena_mariadb.Dialect for use in pool configs. Adding (vena-mariadb ...) to your opam deps is all you need for a MariaDB-backed Vena application.")
 (depends
  (ocaml
   (>= 5.0.0))
  (vena
   (= :version))
  (caqti-driver-mariadb
   (>= 2.1.0))))

(package
 (name vena-postgresql)
 (synopsis "PostgreSQL driver convenience package for Vena")
 (description
  "Depends on vena and caqti-driver-postgresql. Provides Vena_postgresql.Dialect for use in pool configs. Adding (vena-postgresql ...) to your opam deps is all you need for a PostgreSQL-backed Vena application.")
 (depends
  (ocaml
   (>= 5.0.0))
  (vena
   (= :version))
  (caqti-driver-postgresql
   (>= 2.1.0))))
