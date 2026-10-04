#!/usr/bin/env bash
# `net-usage stream`, the loop around nethogs, with a stand-in for nethogs.
# bin/net-usage is sourced so the stand-in can be named; nothing in the script
# reads a path to nethogs from the environment.
set -u

cd "$(dirname "$0")/.." || exit 1
for t in setsid pgrep timeout; do
  command -v "$t" >/dev/null 2>&1 || { echo "SKIP: $t is not installed"; exit 0; }
done

work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT
rc=0
check() { # <label> <condition result 0/1> <detail>
  if [ "$2" -eq 0 ]; then echo "OK   $1"; else printf 'FAIL %s\n  %s\n' "$1" "$3"; rc=1; fi
}

# stream <seconds> <stand-in> : run the loop in a session of its own, the way it
# runs under Quickshell once it has made one, so no re-exec is involved.
stream() {
  NET_USAGE_IFACE=lo NET_USAGE_CONTAINERS=0 timeout "$1" setsid bash -c \
    'source bin/net-usage; SELF=$PWD/bin/net-usage; NETHOGS=$1; stream 1' _ "$2"
}

# --- a nethogs that cannot start says so, and is not restarted every 2 s ----
printf '#!/bin/sh\nexit 1\n' > "$work/nethogs-dies"
chmod +x "$work/nethogs-dies"
out=$(stream 9 "$work/nethogs-dies")
ready=$(grep -c '^ready' <<<"$out")
waits=$(grep -c $'^wait\tnethogs stopped right after starting' <<<"$out")
[ "$waits" -ge 1 ] && [ "$ready" -le 2 ]
check "nethogs that dies at once: wait and back off" $? "ready $ready times, wait $waits times in 9 s"

# --- TERM to the stream takes nethogs and awk with it -----------------------
cat > "$work/nethogs-runs" <<EOF
#!/bin/sh
echo \$\$ > "$work/nethogs.pid"
while :; do printf 'Refreshing:\n'; sleep 0.3; done
EOF
chmod +x "$work/nethogs-runs"
NET_USAGE_IFACE=lo NET_USAGE_CONTAINERS=0 setsid bash -c \
  'source bin/net-usage; SELF=$PWD/bin/net-usage; NETHOGS=$1; stream 1' _ "$work/nethogs-runs" \
  > "$work/out" 2>&1 &
pid=$!
for _ in $(seq 50); do [ -s "$work/nethogs.pid" ] && break; sleep 0.1; done
sleep 1
nh=$(cat "$work/nethogs.pid" 2>/dev/null)
kill -TERM "$pid" 2>/dev/null
sleep 1.5
left=$(pgrep -g "$pid" 2>/dev/null | tr '\n' ' ')
alive=0; [ -n "$nh" ] && kill -0 "$nh" 2>/dev/null && alive=1
[ -n "$nh" ] && [ "$alive" -eq 0 ] && [ -z "$left" ]
check "TERM to the stream ends nethogs and awk too" $? "nethogs pid ${nh:-none} alive=$alive, group left: ${left:-nothing}"
[ -n "$left" ] && kill -KILL $left 2>/dev/null
grep -q '^snap' "$work/out"
check "the stand-in's snapshots reached the output" $? "$(head -5 "$work/out")"

exit $rc
