# Devcontainer Makefile — delegates to the workspace root Makefile with
# the database URLs pre-set to match the docker-compose service hostnames.
#
# Usage (from anywhere inside the container):
#
#   make -f .devcontainer/Makefile test
#
# Or add an alias to your shell profile:
#
#   alias make='make -f .devcontainer/Makefile'

ROOT := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))..

MARIADB_URL  ?= mariadb://admin:password@database-mariadb/development
POSTGRES_URL ?= postgresql://root:root@database-postgres/development

# One database user per role (created by init-*/01.sql). Unset, every role
# connects as the all-rights user above.
MARIADB_READER_URL   ?= mariadb://veins_reader:reader@database-mariadb/development
MARIADB_WRITER_URL   ?= mariadb://veins_writer:writer@database-mariadb/development
MARIADB_MIGRATOR_URL ?= mariadb://veins_migrator:migrator@database-mariadb/development
POSTGRES_READER_URL   ?= postgresql://veins_reader:reader@database-postgres/development
POSTGRES_WRITER_URL   ?= postgresql://veins_writer:writer@database-postgres/development
POSTGRES_MIGRATOR_URL ?= postgresql://veins_migrator:migrator@database-postgres/development

export MARIADB_URL POSTGRES_URL
export MARIADB_READER_URL MARIADB_WRITER_URL MARIADB_MIGRATOR_URL
export POSTGRES_READER_URL POSTGRES_WRITER_URL POSTGRES_MIGRATOR_URL

# Override: run the full test suite against both live database containers.
.PHONY: test
test:
	$(MAKE) -C $(ROOT) test

# Forward every other target to the root Makefile unchanged.
.PHONY: %
%:
	$(MAKE) -C $(ROOT) $@
