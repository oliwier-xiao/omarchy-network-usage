#!/usr/bin/env bash
# The collector's awk program (ACCUMULATE in bin/net-usage), run on its own
# against crafted nethogs captures, under every awk this machine has.
#
# Each case states what the reader (Service.qml) would record from the rows the
# program prints, using the reader's own rule: a running total that rose adds
# the difference, one that fell is a fresh total and adds all of itself.
set -u

cd "$(dirname "$0")/.." || exit 1
PROG=$(sed -n "/^read -r -d '' ACCUMULATE <<'AWK'\$/,/^AWK\$/p" bin/net-usage | sed '1d;$d')
[ -n "$PROG" ] || { echo "FAIL: no ACCUMULATE program in bin/net-usage"; exit 1; }

impls=()
for a in gawk mawk; do command -v "$a" >/dev/null 2>&1 && impls+=("$a"); done
[ "${#impls[@]}" -gt 0 ] || impls=(awk)

work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT

# acc <awk> <mingap> <probe_every> <helper>, the capture on stdin. Timeboxed: a
# probe loop that never ends (mawk, 1.2.0) fails here instead of hanging. mawk
# gets -W interactive, as bin/net-usage gives it: without it mawk reads a pipe in
# 4 KiB blocks, every line of a slow capture arrives at once, and the boundary
# times the program reads from /proc/uptime are all the same moment.
acc() {
  local flags=()
  case "$("$1" -W version 2>&1)" in mawk*) flags=(-W interactive) ;; esac
  NU_HELPER="$4" timeout 30 "$1" "${flags[@]}" -v MINGAP="$2" -v IFACE=eth0 -v PROBE_EVERY="$3" \
    -v PROCDEV=/dev/null -v MAX_LINE=4096 -v MAX_ROWS=2000 -v MAX_APPS=512 \
    -v MAX_NAME=128 -v MAX_KEYS=8000 -- "$PROG"
}

# What the reader records: per kind and name, the sum of its deltas. The name is
# every field after the kind, as Model.parseRow reads it.
recorded() {
  awk -F'\t' '$1 == "row" {
    k = $4; for (i = 5; i <= NF; i++) k = k "\t" $i
    d = $3 - last[k]; if (!(k in last) || d < 0) d = $3
    last[k] = $3; tot[k] += d
  }
  END { for (k in tot) printf "%s\t%.0f\n", k, tot[k] }' | sort
}

rc=0
check() { # <label> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "OK   $1"
  else printf 'FAIL %s\n  expected: %s\n  got:      %s\n' "$1" "$2" "$3"; rc=1; fi
}

for A in "${impls[@]}"; do
  # --- names: an absolute path with a space in it is one path ----------------
  out=$(printf '%s\n' "Refreshing:" \
    $'/opt/Google Chrome/chrome --type=renderer/100/1000\t1000\t2.5e+06' \
    $'/usr/bin/python3 /home/u/tool.py/101/1000\t1\t2' \
    $'/home/u/Counter-Strike Global Offensive/csgo_linux64 -steam/102/1000\t3\t4' \
    "Refreshing:" | acc "$A" 0 1000 true | recorded)
  check "$A: names with spaces" \
    "$(printf 'proc\tchrome\t2500000\nproc\tcsgo_linux64\t4\nproc\tpython3\t2')" "$out"

  # --- rows any process can write: from the right, plain decimals only ------
  out=$(printf '%s\n' "Refreshing:" \
    $'tabby\tname/11821/0\t919690\t5.6e+09' \
    $'hex/1/1000\t0x7fffffff\t1' $'inf/2/1000\tinf\t1' $'nan/3/1000\tnan\tnan' \
    $'neg/4/1000\t-5\t1' $'peta/5/1000\t1e16\t1' $'words/6/1000\tone\ttwo' \
    "Refreshing:" | acc "$A" 0 1000 true | recorded)
  check "$A: a tab in a name is counted, forged numbers are not" \
    "$(printf 'proc\ttabby\tname\t5600000000')" "$out"

  # --- nethogs forgets a quiet process and counts it again from zero ---------
  out=$(printf '%s\n' "Refreshing:" $'app/7/1000\t0\t1000000' \
    "Refreshing:" $'app/7/1000\t0\t1000000' \
    "Refreshing:" $'other/8/1000\t0\t10' \
    "Refreshing:" $'app/7/1000\t0\t3000000' $'other/8/1000\t0\t10' \
    "Refreshing:" | acc "$A" 0 1000 true | recorded)
  check "$A: a process that comes back is counted from zero" \
    "$(printf 'proc\tapp\t4000000\nproc\tother\t10')" "$out"

  # --- containers: carved out of (unknown TCP) once, never handed back ------
  # A container 'web' answers the first four probes, its counter 10 MB further
  # on each time, then is gone. (unknown TCP) grows 6 MB a snapshot. Whatever
  # the probe lag, the reader must end up with exactly what crossed the wire:
  # 60 MB, the container's share under its name and the rest unattributed.
  mkdir -p "$work/sp ace"
  helper="$work/sp ace/helper"
  printf '%s\n' '#!/bin/sh' 'n=$(cat "$(dirname "$0")/n" 2>/dev/null || echo 0); n=$((n + 1))' \
    'echo "$n" > "$(dirname "$0")/n"' 'printf "iface\teth0\nday\t2026-10-04\n"' \
    '[ "$n" -le 4 ] && printf "ctr\tweb\t%s\t0\n" $((1000000000 + n * 10000000))' 'exit 0' > "$helper"
  chmod +x "$helper"
  rm -f "$work/sp ace/n"
  capture=""
  for k in 1 2 3 4 5 6 7 8 9 10; do capture+=$'Refreshing:\n'"unknown TCP/0/0"$'\t0\t'"$((k * 6000000))"$'\n'; done
  out=$(printf '%s' "$capture" | acc "$A" 0 2 "$helper")
  rows=$(printf '%s\n' "$out" | recorded)
  check "$A: container bytes are counted once (helper path has a space)" \
    "$(printf 'container\tweb\t30000000\nunattributed\t(unknown TCP)\t30000000')" "$rows"
  falls=$(printf '%s\n' "$out" | awk -F'\t' '$1 == "row" && $4 == "unattributed" {
    if ($3 < last) n++; last = $3 } END { print n + 0 }')
  check "$A: the unattributed total never falls between probes" 0 "$falls"

  # --- a process that prints the boundary line itself ------------------------
  # Three real boundaries a second apart; between the first two, one process's
  # name carries forty more. MINGAP 0.5 lets the real ones through only.
  gen() {
    printf 'Refreshing:\n'
    for _ in $(seq 40); do printf 'evil\nRefreshing:\n'; done
    printf 'forged/1/1000\t1\t1\n'
    sleep 1; printf 'Refreshing:\nplain/2/1000\t1\t1\n'
    sleep 1; printf 'Refreshing:\n'
  }
  snaps=$(gen | acc "$A" 0.5 1000 true | grep -c '^snap')
  check "$A: forged boundaries are not snapshots" 3 "$snaps"
done

exit $rc
