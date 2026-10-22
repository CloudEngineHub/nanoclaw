#!/bin/sh
# Says whether docs/onecli-upgrades.md must delete the Dial key before the pull.
# OneCLI's one-time grant conversion (first start of 1.44+) gives every `all`-mode
# agent every secret and deletes the rules that kept agents away, such as the old
# /add-dial-tool `Dial: blocked agents`. Once converted, grants decide, and a delete
# only takes Dial from the agents that should have it. Asks the gateway at $GW, one
# project at a time (ONECLI_PROJECT, else the CLI's). Exit 0: keep; 1: delete
# (prints the keys); 2: cannot tell. Reads only; --delete deletes those keys.
set -u
case "${1:-}" in "" | --delete) ;; *) echo "usage: dial-key-check.sh [--delete]" >&2; exit 2 ;; esac
stop() { echo "STOP: $1; do not upgrade" >&2; exit 2; }
[ -n "${GW:-}" ] || stop "set GW to the gateway address, as in the Detect step"
export ONECLI_API_HOST="$GW"
PJ=${ONECLI_PROJECT:-$(onecli config get project 2>/dev/null | jq -r '.value // empty' 2>/dev/null)}
P="project ${PJ:-of the OneCLI API key}"
LIST='if type == "array" then . elif (type == "object") and ((.data | type) == "array") then .data else error("not a list") end'
# Only one plain release decides anything; sets V, and C=1 once the gateway is 1.44 or later.
read_version() {
  H=$(curl -fsS --max-time 10 "$GW/api/health") || stop "could not reach the gateway at $GW"
  V=$(printf '%s' "$H" | jq -ers 'if (length == 1) and (.[0] | type == "object") and (.[0].version | type == "string") and (.[0].version | test("\\A[0-9]{1,4}\\.[0-9]{1,4}\\.[0-9]{1,6}\\z")) then .[0].version else error("no version") end' 2>/dev/null) \
    || stop "the gateway at $GW does not report one release version, so it is unclear whether it has converted"
  M=${V%%.*}; m=${V#*.}; m=${m%%.*}
  if [ "$M" -gt 1 ] || { [ "$M" -eq 1 ] && [ "$m" -ge 44 ]; }; then C=1; else C=0; fi
}
read_version
if [ "$C" = 1 ]; then
  # OneCLI retries the conversion on every start while an agent is not selective.
  # Rules a failed conversion left are not readable on 1.44+; the post-upgrade check covers those.
  A=$(onecli agents list --max 0) || stop "could not list the OneCLI agents at $GW"
  N=$(printf '%s' "$A" | jq -er "[($LIST)[] | select((type != \"object\") or (.secretMode != \"selective\"))] | length") \
    || stop "could not read the OneCLI agent list at $GW"
  [ "$N" = 0 ] || stop "the gateway at $GW runs $V, but $N agent(s) in the $P are not in selective mode: its conversion has not finished, and the next start can give them every key, Dial included. Run the post-upgrade check"
  echo "keep: the gateway at $GW runs $V and every agent in the $P has converted, so grants decide which agents hold the Dial key"
  exit 0
fi
# A Dial key is any secret OneCLI injects on api.getdial.ai, whatever its name; this
# is the gateway's host matcher (split at the first `*`, case-insensitive).
DIAL="def hm(\$h): ascii_downcase as \$p | (\$h | ascii_downcase) as \$x | (\$p | index(\"*\")) as \$i | if \$i == null then \$p == \$x else \$p[:\$i] as \$a | \$p[\$i + 1:] as \$b | (\$x | length) >= (\$a | length) + (\$b | length) and (\$x | startswith(\$a)) and (\$x | endswith(\$b)) end; ($LIST)[] | select((type == \"object\") and ((.hostPattern | type) == \"string\") and (.hostPattern | hm(\"api.getdial.ai\")))"
L=$(onecli secrets list --max 0) && [ -n "$(printf '%s' "$L" | tr -d '[:space:]')" ] || stop "could not read the OneCLI secrets"
ids=$(printf '%s' "$L" | jq -r "$DIAL | .id | if (type == \"string\") and test(\"\\\\A[A-Za-z0-9_-]{1,128}\\\\z\") then . else error(\"bad secret id\") end") \
  || stop "could not read the OneCLI secrets"
[ -n "$ids" ] || { echo "keep: there is no Dial key at $GW in the $P"; exit 0; }
# The conversion widens Dial only through what it deletes or changes, which is
# exactly what the pre-upgrade check lists.
sh "$(dirname "$0")/pre-upgrade-check.sh"
case $? in
  0) echo "keep: the conversion deletes nothing at $GW in the $P, so no agent gains the Dial key"; exit 0 ;;
  1) ;;
  *) stop "could not read the policy at $GW" ;;
esac
# Only an exact host or `*.<...>.getdial.ai` stays inside Dial's domain.
other=$(printf '%s' "$L" | jq -r "$DIAL | select(.hostPattern | ascii_downcase | (index(\"*\") == null) or (.[index(\"*\") + 1:] | endswith(\".getdial.ai\")) | not) | \"\\(.id) \\(.hostPattern | tojson)\"") || stop "could not read the OneCLI secrets"
[ -z "$other" ] || stop "these secrets reach api.getdial.ai through a wider host pattern, so they are not only Dial keys; decide about them by hand: $other"
echo "delete: the gateway at $GW ($V) has not converted yet, and the conversion removes what is listed above, which may be what keeps agents away from Dial. Dial keys in the $P (id, name):"
printf '%s' "$L" | jq -r "$DIAL | \"\\(.id) \\(.name | tojson)\""
[ "${1:-}" = --delete ] || exit 1
# A gateway that converts between the last read and a delete had this Dial rule
# in place, so the delete is still the one the conversion called for.
for id in $ids; do
  read_version
  [ "$C" = 0 ] || stop "the gateway at $GW now runs $V, so it has converted; the Dial key $id was kept"
  onecli secrets delete --id "$id" >/dev/null \
    || stop "could not delete the Dial key $id. \`onecli secrets delete\` acts only in the API key's own project, so in another project delete it in the OneCLI console"
  echo "deleted Dial key $id"
done
