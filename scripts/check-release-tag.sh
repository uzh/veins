#!/usr/bin/env bash

# dune-release builds the tag on HEAD and takes the release notes of the opam-repository pull request from the
# first section of CHANGELOG.md: that section must be the tag's.
#
# Usage: $0            (the tag on HEAD, before dune-release)
#        $0 X.Y.Z      (a version not tagged yet, from bump-version.sh)

set -euo pipefail

cd "$(dirname "$0")/.."

if [[ $# -gt 0 ]]; then
  TAG=$1
elif ! TAG=$(git describe --exact-match --tags HEAD 2> /dev/null); then
  echo "GIT: HEAD has no tag: check out the release tag first."
  exit 1
fi

FIRST=$(sed -n 's/^## \[\([^]]*\)\].*/\1/p' CHANGELOG.md | head -n 1)

if [[ "$FIRST" != "$TAG" ]]; then
  if grep -qF -- "## [${TAG}]" CHANGELOG.md; then
    echo "CHANGELOG.md: the section for ${TAG} isn't the first one (${FIRST:-none} is), dune-release reads the first."
  else
    echo "CHANGELOG.md has no section '## [${TAG}]' (the first one is ${FIRST:-none})."
  fi
  exit 1
fi

if ! awk '/^## / { if (found) exit; found = 1; next } found && /[^[:space:]]/ { ok = 1 } END { exit !ok }' \
  CHANGELOG.md; then
  echo "CHANGELOG.md's section for ${TAG} is empty."
  exit 1
fi

echo "${TAG} has its CHANGELOG.md section."
