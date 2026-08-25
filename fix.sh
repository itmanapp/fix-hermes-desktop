#!/usr/bin/env bash
# fix-hermes-desktop: repair Hermes Desktop after updates break it.
#
# Mode A: chrome-sandbox lost setuid root -> GPU process FATAL crash.
# Mode B: .desktop Exec regenerated with uv BASE python (venv symlink
#         resolved away by hermes_cli/linux_desktop_entry.py) -> icon
#         silently fails with ModuleNotFoundError: hermes_cli.
#
# Usage: ./fix.sh [--check]
set -euo pipefail

HERMES_ROOT="$HOME/.hermes/hermes-agent"
UNPACKED="$HERMES_ROOT/apps/desktop/release/linux-unpacked"
SB="$UNPACKED/chrome-sandbox"
LAUNCHER="$HERMES_ROOT/venv/bin/hermes"
WRAPPER="$HOME/.local/bin/hermes"
DESKTOP_FILE="${XDG_DATA_HOME:-$HOME/.local/share}/applications/hermes.desktop"
GENERATOR="$HERMES_ROOT/hermes_cli/linux_desktop_entry.py"
LOG="${TMPDIR:-/tmp}/hermes-fix-test.log"
CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

say()  { printf '[fix] %s\n' "$*"; }
die()  { printf '[fix] ERROR: %s\n' "$*" >&2; exit 1; }
need_repair() { say "--check: needs repair - $*"; exit 1; }

[ -f "$SB" ] || die "chrome-sandbox not found at $SB (is Hermes installed?)"

exec_ok() {  # valid Exec forms: bare launcher/wrapper, or venv-python prefix on repo CLI
  case "$1" in
    "Exec=$LAUNCHER desktop"|"Exec=$WRAPPER desktop") return 0 ;;
    Exec=*)
      set -- ${1#Exec=}
      [ "$#" -eq 3 ] || return 1
      case "$1" in
        "$HERMES_ROOT/venv/bin/python"|"$HERMES_ROOT/venv/bin/python3") ;;
        *) return 1 ;;
      esac
      [ "$2" = "$HERMES_ROOT/hermes" ] && [ "$3" = "desktop" ]
      ;;
    *) return 1 ;;
  esac
}

# ── diagnose ────────────────────────────────────────────────────────────────
owner="$(stat -c %U "$SB")"; mode="$(stat -c %a "$SB")"
if [ "$owner" != "root" ] || [ "$mode" != "4755" ]; then
  need_repair "Mode A: chrome-sandbox is ${owner} ${mode}, expected root 4755"
fi
say "Mode A OK: chrome-sandbox is root 4755"

if grep -q 'Path(sys.executable)\.resolve()' "$GENERATOR" 2>/dev/null; then
  need_repair "Mode B(0): $GENERATOR still resolves venv-python symlinks; regenerates broken Exec on every launch"
fi
say "Mode B OK: desktop-entry generator keeps venv paths"

if [ -f "$DESKTOP_FILE" ]; then
  exec_line="$(grep '^Exec=' "$DESKTOP_FILE" | head -1)"
  exec_ok "$exec_line" || need_repair "Mode B: bad desktop Exec ($exec_line)"
  say "Mode B OK: desktop Exec is valid ($exec_line)"
else
  say "NOTE: $DESKTOP_FILE not found; skipping entry check"
fi

[ "$CHECK_ONLY" -eq 1 ] && { say "--check: all good"; exit 0; }

# ── repair ──────────────────────────────────────────────────────────────────
escalate() {
  if command -v pkexec >/dev/null 2>&1 && pkexec "$@"; then return 0; fi
  say "pkexec unavailable or refused; falling back to sudo (interactive TTY required)"
  sudo "$@"
}

owner="$(stat -c %U "$SB")"; mode="$(stat -c %a "$SB")"
if [ "$owner" != "root" ] || [ "$mode" != "4755" ]; then
  say "repairing Mode A: restoring root ownership + setuid bit..."
  escalate chown root:root "$SB"
  escalate chmod 4755 "$SB"
  perms="$(stat -c '%U:%G %a' "$SB")"
  [ "$perms" = "root:root 4755" ] || die "Mode A repair failed, still: $perms"
  say "Mode A repaired: $perms"
fi

if grep -q 'Path(sys.executable)\.resolve()' "$GENERATOR" 2>/dev/null; then
  say "repairing Mode B(0): patching generator to keep venv paths (.resolve -> .absolute)..."
  cp "$GENERATOR" "${GENERATOR}.pre-fixbak" 2>/dev/null || true
  sed -i 's|Path(sys\.executable)\.resolve()|Path(sys.executable).absolute()|g' "$GENERATOR"
fi

if [ -f "$DESKTOP_FILE" ]; then
  exec_line="$(grep '^Exec=' "$DESKTOP_FILE" | head -1)"
  if ! exec_ok "$exec_line"; then
    say "repairing Mode B: regenerating desktop entry with fixed generator..."
    rm -f "$DESKTOP_FILE"
    "$HERMES_ROOT/venv/bin/python" - "$HERMES_ROOT" <<'PY'
import sys
from pathlib import Path
from hermes_cli.linux_desktop_entry import install_desktop_entry
install_desktop_entry(Path(sys.argv[1]))
PY
    update-desktop-database "$HOME/.local/share/applications/" 2>/dev/null || true
    grep "^Exec=" "$DESKTOP_FILE"
  fi
fi

# ── verify ──────────────────────────────────────────────────────────────────
say "launching Hermes for verification (~40s)..."
rm -f "$HOME/.config/Hermes"/Singleton{Lock,Cookie,Socket} 2>/dev/null || true
(timeout 45 "$LAUNCHER" desktop >"$LOG" 2>&1 &)
sleep 38

fatal="$(grep -ciE 'fatal|isn.t usable|ModuleNotFoundError' "$LOG" || true)"
alive="$(pgrep -cf "linux-unpacked/[H]ermes" || true)"

say "verification: fatal_errors=$fatal alive_processes=$alive"
if [ "$fatal" -eq 0 ] && [ "${alive:-0}" -ge 3 ]; then
  say "SUCCESS. Test instance will exit on its own; launch Hermes normally now."
  say "NOTE: these issues recur after Hermes updates - just rerun ./fix.sh"
  exit 0
fi
die "still crashing. Log tail: $(tail -3 "$LOG")"
