#!/bin/sh
# Run a DOS batch file under DOSBox-X against the DASTUB harness.
# Usage: run-dosbox-test.sh <test.bat> [extra files...]
# Collects build/ binaries + images + the batch file into a scratch dir,
# runs DOSBox-X headless-ish, and prints every *.TXT the batch produced.
set -e
cd "$(dirname "$0")/.."
BAT="$1"; shift || true
TD=build/testdir
rm -rf "$TD"; mkdir -p "$TD"
cp build/DAPING.COM build/DASTUB.COM build/GOTEKHDD.SYS "$TD"/
cp build/card.img "$TD"/CARD.IMG
cp "$BAT" "$TD"/TEST.BAT
for f in "$@"; do cp "$f" "$TD"/; done
sed "s#TESTDIR#$PWD/$TD#" test/dosbox-test.conf > build/dosbox-run.conf
dosbox-x -conf build/dosbox-run.conf -fastlaunch -nolog >/dev/null 2>&1 || true
for f in "$TD"/*.TXT; do
    [ -f "$f" ] || continue
    echo "===== $f ====="
    tr -d '\r' < "$f"
done
