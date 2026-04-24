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

export MARIADB_URL
export POSTGRES_URL

# Override: run the full test suite against both live database containers.
.PHONY: test
test:
	$(MAKE) -C $(ROOT) test

# Forward every other target to the root Makefile unchanged.
.PHONY: %
%:
	$(MAKE) -C $(ROOT) $@
