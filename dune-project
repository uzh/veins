(lang dune 3.17)

(name veins)

(version 0.1.0)

(generate_opam_files true)

(authors "Department of Economics, University of Zurich")

(source
 (github uzh/veins))

(license MIT)

(maintainers "Econ IT <it@econ.uzh.ch>")

(homepage "https://github.com/uzh/veins")

(bug_reports "https://github.com/uzh/veins")

(package
 (name veins)
 (synopsis "Database connection pooling and migration library for OCaml")
 (description
  "Veins provides a database connection pooling library with support for MariaDB and PostgreSQL via functors. It includes migration handling with up/down tracking, transaction management with setup/cleanup hooks, auto-reconnect on connection drop, and a clean label-based interface. The veins-gen tool generates migration file boilerplate.")
 (depends
  (alcotest
   (and
    :with-test
    (>= 1.7.0)))
  (alcotest-lwt
   (and
    :with-test
    (>= 1.7.0)))
  (caqti
   (>= 2.1.0))
  (caqti-driver-mariadb
   (and
    :with-test
    (>= 2.1.0)))
  (caqti-driver-postgresql
   (and
    :with-test
    (>= 2.1.0)))
  (caqti-lwt
   (>= 2.1.0))
  (containers
   (>= 3.13.0))
  (dune
   (>= 3.17))
  (fmt
   (>= 0.9.0))
  (logs
   (>= 0.7.0))
  (lwt
   (>= 5.7.0))
  (lwt_ppx
   (>= 2.1.0))
  (ocaml
   (>= 5.0.0))
  (ocaml-lsp-server :with-dev-setup)
  (ocamlformat
   (and
    (>= 0.18.0)
    (or :with-dev-setup :with-test)))
  (ptime
   (>= 1.1.0))
  (uri
   (>= 4.4.0))))

(package
 (name veins-mariadb)
 (synopsis "MariaDB driver convenience package for Veins")
 (description
  "Depends on veins and caqti-driver-mariadb. Provides Veins_mariadb.Dialect for use in pool configs. Adding (veins-mariadb ...) to your opam deps is all you need for a MariaDB-backed Veins application.")
 (depends
  (ocaml
   (>= 5.0.0))
  (veins
   (= :version))
  (caqti-driver-mariadb
   (>= 2.1.0))))

(package
 (name veins-postgresql)
 (synopsis "PostgreSQL driver convenience package for Veins")
 (description
  "Depends on veins and caqti-driver-postgresql. Provides Veins_postgresql.Dialect for use in pool configs. Adding (veins-postgresql ...) to your opam deps is all you need for a PostgreSQL-backed Veins application.")
 (depends
  (ocaml
   (>= 5.0.0))
  (veins
   (= :version))
  (caqti-driver-postgresql
   (>= 2.1.0))))
