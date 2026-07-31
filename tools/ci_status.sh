#!/bin/sh
#
# One place to see CI across the whole blob* family.
#
#   tools/ci_status.sh           # latest run per repo
#   tools/ci_status.sh --watch   # refresh every 20s until everything settles
#   tools/ci_status.sh --urls    # just print the per-repo Actions URLs
#
# Forgejo has no cross-repository CI dashboard — its Actions view is per-repo —
# so this asks the API for each repo's latest run and prints one line each.
#
# Auth: the API token lives in ~/.git-credentials alongside the mTLS certs that
# dc1's HTTPS endpoint requires.
set -u

REPOS="blobzig blobsketches blobtemplates blobjs blobqueues blobgraphs \
blobfilters blobd2 blobodbc blobhttp blobsolver blobboxes"

WEB="http://dc1:3000/phrrngtn"          # browser; plain HTTP, no client cert
API="https://dc1:3443/api/v1/repos/phrrngtn"  # API; mTLS
CERT="$HOME/.config/forgejo-mtls/client.crt"
KEY="$HOME/.config/forgejo-mtls/client.key"
TOKEN=$(grep 'dc1%3a3443' "$HOME/.git-credentials" 2>/dev/null \
        | sed 's|.*://[^:]*:\([^@]*\)@.*|\1|')

if [ "${1:-}" = "--urls" ]; then
    for r in $REPOS; do printf '%-15s %s/%s/actions\n' "$r" "$WEB" "$r"; done
    exit 0
fi

fetch() {
    curl -sk --cert "$CERT" --key "$KEY" -H "Authorization: token $TOKEN" \
         "$API/$1/actions/tasks?limit=20" 2>/dev/null
}

report() {
    pending=0
    printf '%-15s %-10s %-22s %s\n' REPO STATUS WHEN URL
    printf '%s\n' "---------------------------------------------------------------------------"
    for r in $REPOS; do
        json=$(fetch "$r")
        line=$(printf '%s' "$json" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print('no-data|'); raise SystemExit
runs = d.get('workflow_runs') or []
if not runs:
    print('none|'); raise SystemExit
# The API returns one entry per job, newest first. Roll them up: a repo is
# green only when every job of its newest run succeeded.
newest = runs[0].get('run_number')
same = [r for r in runs if r.get('run_number') == newest]
sts = [(r.get('conclusion') or r.get('status') or '?') for r in same]
if any(s == 'failure' for s in sts):
    out = 'failure'
elif any(s in ('running', 'waiting', 'queued') for s in sts):
    out = 'running'
elif all(s == 'success' for s in sts):
    out = 'success'
else:
    out = sts[0]
when = (same[0].get('run_started_at') or same[0].get('created_at') or '')[:19]
print(out + '|' + when)
" 2>/dev/null)
        st=${line%%|*}
        when=${line#*|}
        case "$st" in
            success)  mark="\033[32m● success\033[0m" ;;
            failure)  mark="\033[31m● failure\033[0m"; ;;
            running|waiting|queued) mark="\033[33m● $st\033[0m"; pending=$((pending+1)) ;;
            none)     mark="  no runs" ;;
            *)        mark="  $st" ;;
        esac
        printf "%-15s $mark %-22s %s/%s/actions\n" "$r" "$when" "$WEB" "$r"
    done
    return $pending
}

if [ "${1:-}" = "--watch" ]; then
    while :; do
        clear
        date
        report && { echo; echo "everything settled"; break; }
        echo
        echo "still running — refreshing in 20s (Ctrl-C to stop)"
        sleep 20
    done
else
    report
fi
