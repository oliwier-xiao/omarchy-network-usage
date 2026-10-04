#!/usr/bin/env bash
# Deterministic fixture tests for `net-usage validate` (protocol v1).
# Offline: no network, no nethogs, no docker. A fixture feeds
# NET_USAGE_FIXTURE_DIR with proc_before / proc_after (the /proc/net/dev
# shape) and stream.txt (the `nethogs -t -v 2 -C` shape).
#
# validate1: kernel RX delta is 10,000,000 B; counted-down deltas sum to
# 30,097,000 B, so counted/kernel is ~3.0 -> verdict tier OVERSHOOT (>2.5).
#
# validate2: the totals nethogs prints past a megabyte, in scientific notation
# (9.5e+06). Counted 9,533,000 B against a kernel delta of 10,000,000 B: RATIO
# 0.95, verdict OK. It also runs under a comma-decimal locale, where 1.2.0 read
# 9.5e+06 as 9 under mawk; the collector now works in the C locale throughout.
#
# Everything runs once per awk this machine has. The collector's awk program has
# to read the same under gawk (Arch, and so every Omarchy install) and mawk
# (Debian's and Ubuntu's default): 1.2.0 shipped a pipe that mawk parsed
# differently, and the loop it sat in never ended. Each run is timeboxed, so a
# hang fails the test instead of spinning until the CI job is killed.
set -u

cd "$(dirname "$0")/.." || exit 1

impls=()
for a in gawk mawk; do command -v "$a" >/dev/null 2>&1 && impls+=("$a"); done
[ "${#impls[@]}" -gt 0 ] || impls=(awk)

# bin/net-usage calls `awk` by name, so a directory at the front of PATH holding
# one `awk` decides which implementation every awk in the run is.
work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/shim" "$work/locales"

# A comma-decimal locale: installed, or built for this run when the system has
# the sources (a bare CI image has only C). Skipped, and said, when neither.
comma=""
if locale -a 2>/dev/null | grep -qix 'pl_PL.utf-\{0,1\}8'; then
  comma=pl_PL.UTF-8
elif command -v localedef >/dev/null 2>&1 &&
     localedef -i pl_PL -f UTF-8 "$work/locales/pl_PL.UTF-8" >/dev/null 2>&1; then
  comma=pl_PL.UTF-8
  export LOCPATH="$work/locales"
fi

rc=0
run() { # <awk> <fixture> <locale>
  ln -sf "$(command -v "$1")" "$work/shim/awk"
  out=$(PATH="$work/shim:$PATH" LC_ALL="$3" NET_USAGE_FIXTURE_DIR="tests/fixtures/$2" \
    timeout 60 bin/net-usage validate 2>&1)
  status=$?
}
fail() { echo "FAIL ($1): $2"; echo "--- output ---"; printf '%s\n' "$out"; rc=1; }
has() { printf '%s\n' "$out" | grep -qF -- "$1"; }

for a in "${impls[@]}"; do
  run "$a" validate1 C
  if [ "$status" -eq 124 ]; then fail "$a" "timed out after 60s"
  elif [ "$status" -ne 0 ]; then fail "$a" "exit status $status, expected 0"
  elif ! has KERNEL || ! has RATIO || ! has VERDICT; then fail "$a" "no KERNEL, RATIO or VERDICT line"
  elif ! has OVERSHOOT; then fail "$a" "expected OVERSHOOT tier for ratio ~3.0"
  else echo "OK ($a): validate1 validates, verdict OVERSHOOT as crafted"
  fi

  for loc in C ${comma:+"$comma"}; do
    run "$a" validate2 "$loc"
    if [ "$status" -ne 0 ]; then fail "$a, $loc" "exit status $status, expected 0"
    elif ! has "RATIO 0.95 (counted 9.1 MB / kernel 9.5 MB)" || ! has "VERDICT OK"; then
      fail "$a, $loc" "expected RATIO 0.95 and VERDICT OK from 9.5e+06"
    else echo "OK ($a, $loc): validate2 reads scientific notation, RATIO 0.95"
    fi
  done
done
[ -n "$comma" ] || echo "SKIP: no comma-decimal locale here, and none could be built"
exit $rc
