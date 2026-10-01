#!/bin/bash
# ZIP, Furl, and 7-Zip on a fixed set of folders.
# Gap is how far Furl sits from the larger archive toward the smaller one.
# 100% matches the smaller tool. 0% matches the larger one. Above 100% beats
# both. Below 0% is worse than both.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FURL="${1:-$ROOT/.build/release/Furl}"
if [[ ! -x "$FURL" ]]; then
    FURL="$ROOT/Furl.app/Contents/MacOS/Furl"
fi
SEVEN=""
for c in /opt/homebrew/bin/7zz /opt/homebrew/bin/7z /usr/local/bin/7zz /usr/local/bin/7z; do
    if [[ -x "$c" ]]; then
        SEVEN="$c"
        break
    fi
done
THREADS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
LIST="$ROOT/Scripts/benchmark-corpora.txt"
WORK="$(mktemp -d /tmp/furl-bench.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

if [[ ! -x "$FURL" ]]; then
    echo "furl binary not found (pass it as the first argument)" >&2
    exit 1
fi

stage_source() {
    local src="$1" dest="$2"
    mkdir -p "$dest"
    rsync -a \
        --exclude '.build' \
        --exclude 'DerivedData' \
        --exclude '.git' \
        --exclude '.DS_Store' \
        --exclude '__MACOSX' \
        "$src"/ "$dest"/
}

bytes() {
    stat -f %z "$1"
}

gap_pct() {
    local zip="$1" furl="$2" seven="$3"
    python3 -c '
import sys
z, f, s = map(int, sys.argv[1:])
hi, lo = (z, s) if z >= s else (s, z)
span = hi - lo
# A few dozen bytes on an incompressible file is a tie, not a huge gap.
if span <= 0 or span * 100 < hi:
    print("flat")
else:
    print(f"{(hi - f) * 100.0 / span:.0f}%")
' "$zip" "$furl" "$seven"
}

run_one() {
    local name="$1" src="$2"
    local zipf="$WORK/out.zip" furlf="$WORK/out.furl" sevenf="$WORK/out.7z"
    rm -f "$zipf" "$furlf" "$sevenf"
    local zf sf ff ft
    if ! (cd "$src" && zip -r -X -9 -q "$zipf" . -x '*.DS_Store' -x '*__MACOSX*' >/dev/null); then
        printf '%-16s  zip failed\n' "$name"
        return
    fi
    zf="$(bytes "$zipf")"
    local t0 t1
    t0="$(python3 -c 'import time; print(time.time())')"
    if ! "$FURL" compress -l 9 "$src" "$furlf" >"$WORK/furl.txt" 2>"$WORK/furl.err"; then
        printf '%-16s  furl failed\n' "$name"
        cat "$WORK/furl.err" >&2
        return
    fi
    t1="$(python3 -c 'import time; print(time.time())')"
    ff="$(bytes "$furlf")"
    ft="$(python3 -c "print(f'{$t1 - $t0:.1f}')")"
    if [[ -n "$SEVEN" ]]; then
        if ! (cd "$src" && "$SEVEN" a -t7z -mx=9 -m0=lzma2 -mmt="$THREADS" -bd "$sevenf" . -xr'!.DS_Store' -xr'!__MACOSX' >/dev/null); then
            printf '%-16s  %10s  %10s  7z failed\n' "$name" "$zf" "$ff"
            return
        fi
        sf="$(bytes "$sevenf")"
    else
        sf=0
    fi
    local gap="n/a"
    if [[ "$sf" != 0 ]]; then
        gap="$(gap_pct "$zf" "$ff" "$sf")"
    fi
    printf '%-16s  %10s  %10s  %10s  %7ss  %8s\n' "$name" "$zf" "$ff" "${sf:-n/a}" "$ft" "$gap"
}

prepare_generated() {
    local base="$WORK/generated"
    mkdir -p "$base/redundant" "$base/random" "$base/tiny"
    python3 - << PY
from pathlib import Path
base = Path("$base")
line = b"The quick brown fox jumps over the lazy dog. " * 4 + b"\\n"
blob = line * 4000
(base / "redundant" / "log.txt").write_bytes(blob * 8)
(base / "random" / "noise.bin").write_bytes(__import__("os").urandom(512 * 1024))
tiny = base / "tiny"
for i in range(200):
    (tiny / f"n{i:03d}.txt").write_bytes(f"file {i}\\n".encode() * 20)
PY
}

printf '%-16s  %10s  %10s  %10s  %8s  %8s\n' "Corpus" "ZIP" "Furl" "7z" "Furl time" "Gap"
printf '%s\n' "--------------------------------------------------------------------------------"

prepare_generated
run_one "Redundant text" "$WORK/generated/redundant"
run_one "Random" "$WORK/generated/random"
run_one "Tiny files" "$WORK/generated/tiny"

while IFS=$'\t' read -r name path mode; do
    [[ -z "${name:-}" || "$name" == \#* ]] && continue
    if [[ ! -d "$path" ]]; then
        printf '%-16s  missing %s\n' "$name" "$path"
        continue
    fi
    if [[ "$mode" == "source" ]]; then
        dest="$WORK/stage"
        rm -rf "$dest"
        stage_source "$path" "$dest"
        run_one "$name" "$dest"
    else
        run_one "$name" "$path"
    fi
done < "$LIST"
