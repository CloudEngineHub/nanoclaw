#!/bin/sh
# Says whether docs/onecli-upgrades.md must delete the Dial key before the pull.
# OneCLI's one-time grant conversion (first start of 1.44+) gives every `all`-mode
# agent every secret and deletes the rules that kept agents away, such as the old
# /add-dial-tool `Dial: blocked agents`. On a converted gateway grants decide, so a
# delete only takes Dial from the agents that should have it. Exit 0: keep;
# 1: delete (prints the ids); 2: cannot tell. Reads only; --delete deletes them.
set -u
case "${1:-}" in "" | --delete) ;; *) echo "usage: dial-key-check.sh [--delete]" >&2; exit 2 ;; esac
: "${GW:?set GW to the gateway address, as in the Detect step}"
export ONECLI_API_HOST="$GW"
stop() { echo "STOP: $1; do not upgrade" >&2; exit 2; }
H=$(curl -fsS --max-time 10 "$GW/api/health") || stop "could not reach the gateway at $GW"
V=$(printf '%s' "$H" | jq -er 'if type == "object" then (.version // "unknown" | tostring) else error("not a health answer") end') \
  || stop "could not read the gateway version at $GW"
case "$V" in
  1.4[4-9].* | 1.[5-9][0-9].* | 1.[1-9][0-9][0-9]*.* | [2-9].* | [1-9][0-9]*.*)
    echo "keep: the gateway at $GW runs $V, so it has already converted and grants decide who holds the Dial key"
    exit 0 ;;
  0.* | 1.[0-9].* | 1.[1-3][0-9].* | 1.4[0-3].* | unknown) ;;
  *) stop "the gateway at $GW reports version '$V', so it is unclear whether it has converted" ;;
esac
L=$(onecli secrets list --max 0) && [ -n "$(printf '%s' "$L" | tr -d '[:space:]')" ] || stop "could not read the OneCLI secrets"
ids=$(printf '%s' "$L" | jq -r '(if type == "array" then . elif (type == "object") and ((.data | type) == "array") then .data else error("not a secret list") end)[] | select(.hostPattern == "api.getdial.ai" and ((.name | type) == "string") and (.name | test("(?i)dial"))) | .id | if (type == "string") and test("\\A[A-Za-z0-9_-]+\\z") then . else error("bad secret id") end') \
  || stop "could not read the OneCLI secrets"
[ -n "$ids" ] || { echo "keep: there is no Dial key at $GW"; exit 0; }
# The conversion widens Dial only through what it deletes or changes, which is
# exactly what the pre-upgrade check lists.
sh "$(dirname "$0")/pre-upgrade-check.sh"
case $? in
  0) echo "keep: the conversion deletes nothing at $GW, so no agent gains the Dial key"; exit 0 ;;
  1) ;;
  *) stop "could not read the policy at $GW" ;;
esac
echo "delete: the gateway at $GW ($V) has not converted yet, and the conversion removes what is listed above, which may be what keeps agents away from Dial. Dial keys:"
printf '%s\n' "$ids"
[ "${1:-}" = --delete ] || exit 1
for id in $ids; do onecli secrets delete --id "$id" >/dev/null || stop "could not delete the Dial key $id"; done
echo "Dial keys deleted:" $ids
