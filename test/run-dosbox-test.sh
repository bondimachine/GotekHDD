#!/bin/sh
# Run a DOS batch file under DOSBox-X against the DASTUB harness.
# Usage: [CPUTYPE=8086|80386] run-dosbox-test.sh <test.bat> [extra files...]
# Collects build/ binaries + images + the batch file into a scratch dir,
# runs DOSBox-X headless-ish, and prints every *.TXT the batch produced.
# CPUTYPE defaults to 8086 (strictest; DASTUB falls back to file mode);
# 80386 exercises DASTUB's XMS path.
set -e
CPUTYPE="${CPUTYPE:-8086}"
cd "$(dirname "$0")/.."
BAT="$1"; shift || true
TD=build/testdir
rm -rf "$TD"; mkdir -p "$TD"
cp build/DAPING.COM build/DASTUB.COM build/DRVTEST.COM build/GOTEKHDD.SYS "$TD"/
cp build/card.img "$TD"/CARD.IMG
cp "$BAT" "$TD"/TEST.BAT
for f in "$@"; do cp "$f" "$TD"/; done
sed -e "s#TESTDIR#$PWD/$TD#" -e "s#CPUTYPE#$CPUTYPE#" \
    test/dosbox-test.conf > build/dosbox-run.conf
dosbox-x -conf build/dosbox-run.conf -fastlaunch -nolog >/dev/null 2>&1 || true
for f in "$TD"/*.TXT; do
    [ -f "$f" ] || continue
    echo "===== $f ====="
    tr -d '\r' < "$f"
done
