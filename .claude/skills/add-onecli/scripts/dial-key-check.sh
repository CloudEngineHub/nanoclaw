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
P="project ${ONECLI_PROJECT:-set in the onecli CLI}"
LIST='if type == "array" then . elif (type == "object") and ((.data | type) == "array") then .data else error("not a list") end'
# Only a plain release decides anything; sets V, and C=1 once the gateway is 1.44 or later.
read_version() {
  H=$(curl -fsS --max-time 10 "$GW/api/health") || stop "could not reach the gateway at $GW"
  V=$(printf '%s' "$H" | jq -er 'if (type == "object") and ((.version | type) == "string") and (.version | test("\\A[0-9]{1,4}\\.[0-9]{1,4}\\.[0-9]{1,6}\\z")) then .version else error("no version") end' 2>/dev/null) \
    || stop "the gateway at $GW does not report a release version, so it is unclear whether it has converted"
  M=${V%%.*}; m=${V#*.}; m=${m%%.*}
  if [ "$M" -gt 1 ] || { [ "$M" -eq 1 ] && [ "$m" -ge 44 ]; }; then C=1; else C=0; fi
}
read_version
if [ "$C" = 1 ]; then
  # A conversion that failed is retried on the next start, with every key, so it must be finished.
  A=$(onecli agents list --max 0) || stop "could not list the OneCLI agents at $GW"
  N=$(printf '%s' "$A" | jq -er "[($LIST)[] | select(.secretMode == \"all\")] | length") || stop "could not read the OneCLI agent list at $GW"
  [ "$N" = 0 ] || stop "the gateway at $GW runs $V, but $N agent(s) in the $P are still in all mode: its conversion has not finished, and the next start can give them every key, Dial included. Run the post-upgrade check"
  echo "keep: the gateway at $GW runs $V and the $P has converted, so grants decide which agents hold the Dial key"
  exit 0
fi
# Any key for the Dial host, whatever its name: the conversion would hand each one out.
L=$(onecli secrets list --max 0) && [ -n "$(printf '%s' "$L" | tr -d '[:space:]')" ] || stop "could not read the OneCLI secrets"
DIAL="($LIST)[] | select((.hostPattern | type) == \"string\" and (.hostPattern | ascii_downcase | test(\"(\\\\A|\\\\.)getdial\\\\.ai\\\\.?(:[0-9]+)?\\\\z\")))"
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
echo "delete: the gateway at $GW ($V) has not converted yet, and the conversion removes what is listed above, which may be what keeps agents away from Dial. Dial keys in the $P (id, name):"
printf '%s' "$L" | jq -r "$DIAL | \"\\(.id) \\(.name | tojson)\""
[ "${1:-}" = --delete ] || exit 1
for id in $ids; do
  # The gateway may have moved since the check: never delete on a converted one.
  read_version
  [ "$C" = 0 ] || stop "the gateway at $GW now runs $V, so it has converted; the Dial key $id was kept"
  onecli secrets delete --id "$id" >/dev/null || stop "could not delete the Dial key $id"
  echo "deleted Dial key $id"
done
