-- Runs once (via psql), when the database volume is created.
CREATE DATABASE test;

-- One user per role for the role tests (see README "Roles"). The tests also run with a
-- single all-rights user, these only make "which user ran it" checks meaningful.
CREATE ROLE veins_reader LOGIN PASSWORD 'reader';
CREATE ROLE veins_writer LOGIN PASSWORD 'writer';
CREATE ROLE veins_migrator LOGIN PASSWORD 'migrator';

-- Grants are per database; tables created later by the owner or the migrator inherit them.
\connect development
GRANT USAGE ON SCHEMA public TO veins_reader, veins_writer;
GRANT USAGE, CREATE ON SCHEMA public TO veins_migrator;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO veins_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO veins_writer;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO veins_writer;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO veins_migrator;
ALTER DEFAULT PRIVILEGES FOR ROLE veins_migrator IN SCHEMA public GRANT SELECT ON TABLES TO veins_reader;
ALTER DEFAULT PRIVILEGES FOR ROLE veins_migrator IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO veins_writer;
ALTER DEFAULT PRIVILEGES FOR ROLE veins_migrator IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO veins_writer;

\connect test
GRANT USAGE ON SCHEMA public TO veins_reader, veins_writer;
GRANT USAGE, CREATE ON SCHEMA public TO veins_migrator;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO veins_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO veins_writer;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO veins_writer;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO veins_migrator;
ALTER DEFAULT PRIVILEGES FOR ROLE veins_migrator IN SCHEMA public GRANT SELECT ON TABLES TO veins_reader;
ALTER DEFAULT PRIVILEGES FOR ROLE veins_migrator IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO veins_writer;
ALTER DEFAULT PRIVILEGES FOR ROLE veins_migrator IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO veins_writer;
