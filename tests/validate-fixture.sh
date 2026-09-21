#!/usr/bin/env bash
# Deterministic fixture test for `net-usage validate` (protocol v1).
# Offline: no network, no nethogs, no docker. The fixture feeds
# NET_USAGE_FIXTURE_DIR with proc_before / proc_after (the /proc/net/dev
# shape) and stream.txt (the `nethogs -t -v 2 -C` shape).
#
# Fixture math: kernel RX delta is 10,000,000 B; counted-down deltas sum to
# 30,097,000 B, so counted/kernel is ~3.0 -> verdict tier OVERSHOOT (>2.5).
set -u

cd "$(dirname "$0")/.." || exit 1

out=$(NET_USAGE_FIXTURE_DIR="tests/fixtures/validate1" bin/net-usage validate 2>&1)
status=$?

fail() { echo "FAIL: $1"; echo "--- output ---"; printf '%s\n' "$out"; exit 1; }

[ "$status" -eq 0 ] || fail "exit status $status, expected 0"
printf '%s\n' "$out" | grep -q "KERNEL" || fail "no KERNEL line"
printf '%s\n' "$out" | grep -q "RATIO" || fail "no RATIO line"
printf '%s\n' "$out" | grep -q "VERDICT" || fail "no VERDICT line"
printf '%s\n' "$out" | grep -q "OVERSHOOT" || fail "expected OVERSHOOT tier for ratio ~3.0"

echo "OK: fixture validates, verdict OVERSHOOT as crafted"
