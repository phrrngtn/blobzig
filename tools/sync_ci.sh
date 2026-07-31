#!/bin/sh
#
# Copy the canonical CI workflow into every blob* repo.
#
#   tools/sync_ci.sh            # write .forgejo/workflows/ci.yml everywhere
#   tools/sync_ci.sh --check    # report drift without writing
#
# tools/ci-workflow.yml is the source of truth. Nothing in it is repo-specific:
# the test step is discovered from `zig build --list-steps`, and the wheel job
# skips repos that have not moved to ctypes yet. So one file genuinely serves
# all of them, and a change here reaches every repo rather than twelve copies
# drifting apart.
#
# The old build-and-publish.yml workflows are removed where present: they built
# a wheel per Python version for nanobind, which is obsolete now that wheels are
# py3-none-<platform>.
set -u

SRC="$(cd "$(dirname "$0")" && pwd)/ci-workflow.yml"
[ -f "$SRC" ] || { echo "missing $SRC" >&2; exit 1; }

REPOS="blobzig blobsketches blobtemplates blobjs blobqueues blobgraphs \
blobfilters blobd2 blobodbc blobhttp blobsolver blobboxes"

CHECK=no
[ "${1:-}" = "--check" ] && CHECK=yes

drift=0
for r in $REPOS; do
    d="$HOME/checkouts/$r"
    [ -d "$d/.git" ] || { printf '%-15s missing\n' "$r"; continue; }
    dst="$d/.forgejo/workflows/ci.yml"

    if [ "$CHECK" = yes ]; then
        if [ ! -f "$dst" ]; then
            printf '%-15s ABSENT\n' "$r"; drift=$((drift + 1))
        elif ! cmp -s "$SRC" "$dst"; then
            printf '%-15s DRIFTED\n' "$r"; drift=$((drift + 1))
        else
            printf '%-15s ok\n' "$r"
        fi
        continue
    fi

    mkdir -p "$d/.forgejo/workflows"
    cp "$SRC" "$dst"
    note=""
    old="$d/.forgejo/workflows/build-and-publish.yml"
    if [ -f "$old" ]; then
        rm -f "$old"
        note=" (removed build-and-publish.yml)"
    fi
    printf '%-15s ci.yml written%s\n' "$r" "$note"
done

if [ "$CHECK" = yes ]; then
    echo "---"
    [ "$drift" = 0 ] && echo "all in sync" || echo "$drift repo(s) out of sync — run without --check"
    exit "$drift"
fi
