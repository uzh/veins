.PHONY: all build test clean fmt fmt-check doc lint-opam watch help version version-patch version-minor version-major release-check opam-release

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
	@echo "Docs at _build/default/_doc/_html/veins/index.html"

## Validate .opam files (mirrors CI lint-opam)
lint-opam:
	$(OPAM_EXEC) opam lint *.opam

## Install dependencies (including test dependencies)
deps:
	opam install . --deps-only --with-test

## Watch for file changes and rebuild continuously
watch:
	$(OPAM_EXEC) dune build @all --watch

## Release: bump dune-project/veins.opam, date the CHANGELOG section, commit and tag (on main)
## make version-{patch|minor|major}, or make version V=X.Y.Z for an explicit version
version:
	@if [ -n "$(V)" ]; then ./scripts/bump-version.sh "$(V)"; else echo "Usage: make version-{patch|minor|major} or make version V=X.Y.Z"; fi

version-patch:
	./scripts/bump-version.sh --patch

version-minor:
	./scripts/bump-version.sh --minor

version-major:
	./scripts/bump-version.sh --major

## Check what dune-release checks before a release: lint, build and tests of the package, the CHANGELOG
release-check:
	$(OPAM_EXEC) dune-release check

## Publish the tagged HEAD on opam, once CI created its GitHub release: builds the archive, uploads it to the
## release and opens the pull request on opam-repository (the docs are published by CI, not by dune-release);
## first checks that HEAD is tagged and that the tag's section is the first of CHANGELOG.md
opam-release:
	./scripts/check-release-tag.sh
	$(OPAM_EXEC) dune-release distrib
	$(OPAM_EXEC) dune-release publish distrib
	$(OPAM_EXEC) dune-release opam pkg
	$(OPAM_EXEC) dune-release opam submit

help:
	@grep -E '^##' Makefile | sed 's/^## //'
