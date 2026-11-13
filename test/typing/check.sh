#!/bin/sh
# Compiles fixture.ml against veins, then every case in cases/, each of which
# must fail with a type error naming the tag its role doesn't grant.
set -eu
# CI forces colours, and their escape codes would break the grep below.
export OCAML_COLOR=never
objs=$1
shift
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
# Prints the compiler's messages; whether it compiled shows in the .cmo.
compile() {
  ocamlfind ocamlc -package caqti,caqti.classic,caqti-lwt,lwt,logs \
    -I "$objs" -I "$out" -c -o "$out/$(basename "$1" .ml)" "$1" 2>&1 \
    | grep -v 'ocamlfind: \[WARNING\]' || true
}
cp fixture.ml "$out/fixture.ml"
output=$(compile "$out/fixture.ml")
[ -f "$out/fixture.cmo" ] || { echo "fixture.ml doesn't compile:"; echo "$output"; exit 1; }
failed=0
for case in "$@"; do
  name=$(basename "$case" .ml)
  cp "$case" "$out/$name.ml"
  output=$(compile "$out/$name.ml")
  if [ -f "$out/$name.cmo" ]; then
    echo "FAIL $name: compiled, but its role doesn't grant what it runs"
    failed=1
  elif echo "$output" | grep -q 'does not allow tag(s) `Write'; then
    echo "ok   $name"
  else
    echo "FAIL $name: unexpected error:"
    echo "$output"
    failed=1
  fi
done
exit $failed
