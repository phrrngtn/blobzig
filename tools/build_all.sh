#!/bin/sh
#
# Build every zig-ified blob* repo, one at a time, with the terminal attached
# so Zig's progress meter actually renders.
#
#   tools/build_all.sh              # rebuild the working checkouts (cold cache)
#   tools/build_all.sh --fresh      # clone from scratch, empty global cache
#   tools/build_all.sh --warm       # no cache clearing; shows incremental cost
#   tools/build_all.sh --pause      # wait for Enter between repos
#   tools/build_all.sh --fresh blobboxes blobhttp     # just these
#
# --fresh is the honest "what does a new contributor wait for" number: a real
# clone plus an empty --global-cache-dir, so every dependency is downloaded and
# compiled from nothing. Without the empty cache the timing is a lie, because
# ~/.cache/zig already holds every package.
#
# Cloning happens first, all repos in parallel, because it is network-bound and
# there is nothing to watch. Building is then strictly serial with the terminal
# attached, because there IS something to watch and twelve interleaved progress
# meters would be unreadable — and concurrent builds would contend for CPU and
# make every timing meaningless.
#
# Nothing is redirected during the build phase: zig writes straight to your
# terminal, which is the entire point of running this yourself.

set -u

ALL="blobzig blobsketches blobtemplates blobjs blobqueues blobgraphs \
blobfilters blobd2 blobodbc blobhttp blobsolver blobboxes"

MODE=local
PAUSE=no
REMOTE=${REMOTE:-https://dc1:3443/phrrngtn}
WORK=${WORK:-/tmp/blob_fresh}
REPOS=""

while [ $# -gt 0 ]; do
    case "$1" in
        --fresh) MODE=fresh ;;
        --warm)  MODE=warm ;;
        --local) MODE=local ;;
        --pause) PAUSE=yes ;;
        --help|-h)
            sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        -*) echo "unknown option: $1" >&2; exit 2 ;;
        *)  REPOS="$REPOS $1" ;;
    esac
    shift
done
[ -n "$REPOS" ] || REPOS="$ALL"

command -v zig >/dev/null || { echo "zig not on PATH" >&2; exit 1; }
echo "zig $(zig version)   mode=$MODE"

CACHE_ARG=""
if [ "$MODE" = fresh ]; then
    echo "fresh clones into $WORK, with an empty global cache"
    rm -rf "$WORK"
    mkdir -p "$WORK/_zigcache"
    CACHE_ARG="--global-cache-dir $WORK/_zigcache"
fi
echo

RESULTS=""
GRAND=0

# ── phase 1: clone everything, in parallel ───────────────────────────
if [ "$MODE" = fresh ]; then
    echo "cloning $(echo $REPOS | wc -w | tr -d ' ') repos in parallel..."
    clone_start=$(date +%s)
    for r in $REPOS; do
        ( git clone -q "$REMOTE/$r.git" "$WORK/$r" 2>"$WORK/$r.clone.err" \
            && echo "  ✓ $r" || echo "  ✗ $r (see $WORK/$r.clone.err)" ) &
    done
    wait
    clone_end=$(date +%s)
    echo "clone phase: $((clone_end - clone_start))s wall clock (parallel)"
    echo
fi

# ── phase 2: build, strictly one at a time ───────────────────────────
for r in $REPOS; do
    if [ "$MODE" = fresh ]; then
        dir="$WORK/$r"
        if [ ! -d "$dir" ]; then
            RESULTS="$RESULTS
$r	-	CLONE FAILED"
            continue
        fi
    else
        dir="$HOME/checkouts/$r"
        [ -d "$dir" ] || { echo "missing: $dir"; continue; }
        [ "$MODE" = local ] && rm -rf "$dir/.zig-cache" "$dir/zig-out"
    fi
    printf '\033[1m══ %s ══\033[0m\n' "$r"

    start=$(date +%s)
    # Deliberately unredirected: diagnostics and the progress meter go to the
    # terminal. --summary all prints the step tree, including which steps were
    # cached, which is the interesting part on a warm run.
    ( cd "$dir" && zig build --summary all $CACHE_ARG )
    code=$?
    end=$(date +%s)
    secs=$((end - start))
    GRAND=$((GRAND + secs))

    if [ $code -eq 0 ]; then
        n=$(ls "$dir/zig-out/lib" 2>/dev/null | wc -l | tr -d ' ')
        printf '\033[32m   OK\033[0m  %ss, %s artifacts\n\n' "$secs" "$n"
        RESULTS="$RESULTS
$r	${secs}s	OK ($n artifacts)"
    else
        printf '\033[31m   FAILED\033[0m  after %ss (exit %s)\n\n' "$secs" "$code"
        RESULTS="$RESULTS
$r	${secs}s	FAILED (exit $code)"
    fi

    if [ "$PAUSE" = yes ]; then
        printf 'press Enter for the next repo... '
        read _ignored
        echo
    fi
done

echo "═══════════════════════════════════════════════"
printf '%-16s %8s  %s\n' REPO TIME STATUS
# printf '%s\n' and not '%s': without the trailing newline `read` fails on the
# final line and silently drops the last repo from the summary. It did exactly
# that on the first run — blobsketches built fine and never appeared.
printf '%s\n' "$RESULTS" | while IFS="$(printf '\t')" read -r a b c; do
    [ -n "$a" ] && printf '%-16s %8s  %s\n' "$a" "$b" "$c"
done
echo "═══════════════════════════════════════════════"
printf '%-16s %8s\n' TOTAL "${GRAND}s"

if [ "$MODE" = fresh ]; then
    echo
    echo "downloaded packages: $(du -sh "$WORK/_zigcache" 2>/dev/null | cut -f1)"
    echo "clones left in $WORK — rm -rf when done"
fi
