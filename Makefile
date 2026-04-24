.PHONY: all build test clean fmt fmt-check doc lint-opam watch help

OPAM_EXEC := opam exec --

## Build the library and executables
all: build

build:
	$(OPAM_EXEC) dune build @all

## Run the full test suite
## Set MARIADB_URL / POSTGRES_URL to override the default connection strings
test:
	$(OPAM_EXEC) dune test

## Remove build artefacts
clean:
	$(OPAM_EXEC) dune clean

## Format all source files in-place
format:
	$(OPAM_EXEC) dune fmt

## Check formatting without modifying files (mirrors CI lint-fmt)
format-check:
	$(OPAM_EXEC) dune build @fmt

## Build odoc documentation
doc:
	$(OPAM_EXEC) dune build @doc
	@echo "Docs at _build/default/_doc/_html/index.html"

## Validate .opam files (mirrors CI lint-opam)
lint-opam:
	$(OPAM_EXEC) opam lint *.opam

## Install dependencies (including test dependencies)
deps:
	opam install . --deps-only --with-test

## Watch for file changes and rebuild continuously
watch:
	$(OPAM_EXEC) dune build @all --watch

help:
	@grep -E '^##' Makefile | sed 's/^## //'
