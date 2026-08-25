#!/usr/bin/env bash
# fix-hermes-desktop: repair Hermes Desktop after updates break chrome-sandbox perms.
# Usage: ./fix.sh [--check]
set -euo pipefail

UNPACKED="$HOME/.hermes/hermes-agent/apps/desktop/release/linux-unpacked"
SB="$UNPACKED/chrome-sandbox"
LAUNCHER="$HOME/.hermes/hermes-agent/venv/bin/hermes"
LOG="${TMPDIR:-/tmp}/hermes-fix-test.log"
CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

say()  { printf '[fix] %s\n' "$*"; }
die()  { printf '[fix] ERROR: %s\n' "$*" >&2; exit 1; }

[ -f "$SB" ] || die "chrome-sandbox not found at $SB (is Hermes installed?)"

# ── diagnose ────────────────────────────────────────────────────────────────
perms="$(stat -c '%U:%G %a' "$SB")"
say "current: chrome-sandbox -> $perms"
owner="$(stat -c %U "$SB")"; mode="$(stat -c %a "$SB")"
if [ "$owner" = "root" ] && [ "$mode" = "4755" ]; then
  say "permissions already correct; nothing to do"
  exit 0
fi
if [ "$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null || echo 0)" != "1" ]; then
  say "WARNING: apparmor userns restriction is off; crash may have another cause"
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
  say "--check: needs repair (expected root:root 4755, got $perms)"
  exit 1
fi

# ── repair ──────────────────────────────────────────────────────────────────
escalate() {
  if command -v pkexec >/dev/null 2>&1 && pkexec "$@"; then return 0; fi
  say "pkexec unavailable or refused; falling back to sudo (interactive TTY required)"
  sudo "$@"
}

say "restoring root ownership + setuid bit..."
escalate chown root:root "$SB"
escalate chmod 4755 "$SB"

perms="$(stat -c '%U:%G %a' "$SB")"
[ "$perms" = "root:root 4755" ] || die "repair failed, still: $perms"
say "repaired: $perms"

# ── verify ──────────────────────────────────────────────────────────────────
say "launching Hermes for verification (~40s)..."
(timeout 45 "$LAUNCHER" desktop >"$LOG" 2>&1 &)
sleep 38

fatal="$(grep -ciE 'fatal|isn.t usable' "$LOG" || true)"
alive="$(pgrep -cf "linux-unpacked/[H]ermes" || true)"

say "verification: fatal_errors=$fatal alive_processes=$alive"
if [ "$fatal" -eq 0 ] && [ "${alive:-0}" -ge 3 ]; then
  say "SUCCESS. Test instance will exit on its own; launch Hermes normally now."
  say "NOTE: this recurs after every Hermes update - just rerun ./fix.sh"
  exit 0
fi
die "still crashing. Log tail: $(tail -3 "$LOG")"
