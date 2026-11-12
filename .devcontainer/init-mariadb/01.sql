-- Runs once, when the database volume is created.
CREATE DATABASE IF NOT EXISTS `test`;
GRANT ALL ON `test`.* TO 'admin'@'%';

-- One user per role for the role tests (see README "Roles"). The tests also run with a
-- single all-rights user, these only make "which user ran it" checks meaningful.
CREATE USER IF NOT EXISTS 'veins_reader'@'%' IDENTIFIED BY 'reader';
CREATE USER IF NOT EXISTS 'veins_writer'@'%' IDENTIFIED BY 'writer';
CREATE USER IF NOT EXISTS 'veins_migrator'@'%' IDENTIFIED BY 'migrator';

GRANT SELECT ON `development`.* TO 'veins_reader'@'%';
GRANT SELECT ON `test`.* TO 'veins_reader'@'%';
GRANT SELECT, INSERT, UPDATE, DELETE ON `development`.* TO 'veins_writer'@'%';
GRANT SELECT, INSERT, UPDATE, DELETE ON `test`.* TO 'veins_writer'@'%';
GRANT ALL ON `development`.* TO 'veins_migrator'@'%';
GRANT ALL ON `test`.* TO 'veins_migrator'@'%';
