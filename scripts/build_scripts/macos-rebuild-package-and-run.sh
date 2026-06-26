#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ORB_MACHINE="${ORB_MACHINE:-aosp-builder}"
VM_SCRIPT_PATH="${VM_SCRIPT_PATH:-/Users/robin/Documents/Codex/2026-05-23/robin-aosp-builder-aosp-aosp-repo/android16_emulator/scripts/vm-build-emu64a-package.sh}"

command -v orb >/dev/null 2>&1 || {
  echo "ERROR: orb not found" >&2
  exit 1
}

echo "Running VM build/package step on $ORB_MACHINE ..."
orb -m "$ORB_MACHINE" -u robin bash "$VM_SCRIPT_PATH"

echo
echo "Running macOS pull/start step ..."
"$SCRIPT_DIR/run-aosp-emu64a-pkg.sh"
