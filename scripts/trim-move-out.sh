#!/usr/bin/env bash
set -euo pipefail

ORB_MACHINE="${ORB_MACHINE:-aosp-builder}"
ORB_USER="${ORB_USER:-robin}"
SOURCE_ROOT="${SOURCE_ROOT:-/home/robin/aosp/aosp}"
STAGING_ROOT="${STAGING_ROOT:-/home/robin/aosp/_trim_staging}"
MANIFEST_PATH="${MANIFEST_PATH:-$STAGING_ROOT/trim-manifest.log}"
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage:
  trim-move-out.sh [--dry-run] [--from-file PATH] REL_PATH [REL_PATH...]

Moves paths out of the AOSP source tree into a staging tree while preserving
their original relative paths.

Examples:
  trim-move-out.sh --dry-run device/google
  trim-move-out.sh cts test platform_testing
  trim-move-out.sh --from-file candidates.txt
EOF
}

require_relpath() {
  local path="$1"
  [[ -n "$path" ]] || return 1
  [[ "$path" != /* ]] || return 1
  [[ "$path" != *".."* ]] || return 1
}

paths=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --from-file)
      [[ $# -ge 2 ]] || { usage; exit 1; }
      while IFS= read -r line; do
        line="${line%%#*}"
        line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        [[ -n "$line" ]] || continue
        paths+=("$line")
      done < "$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      paths+=("$1")
      shift
      ;;
  esac
done

[[ ${#paths[@]} -gt 0 ]] || { usage; exit 1; }

for rel in "${paths[@]}"; do
  require_relpath "$rel" || {
    echo "Invalid relative path: $rel" >&2
    exit 1
  }
done

orb -m "$ORB_MACHINE" -u "$ORB_USER" bash -s -- \
  "$SOURCE_ROOT" "$STAGING_ROOT" "$MANIFEST_PATH" "$DRY_RUN" "${paths[@]}" <<'REMOTE'
set -euo pipefail

source_root="$1"
staging_root="$2"
manifest_path="$3"
dry_run="$4"
shift 4

timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

mkdir -p "$staging_root"
mkdir -p "$(dirname "$manifest_path")"
touch "$manifest_path"

for rel in "$@"; do
  src="$source_root/$rel"
  dst="$staging_root/$rel"

  if [[ ! -e "$src" ]]; then
    echo "SKIP missing: $rel"
    continue
  fi

  if [[ -e "$dst" ]]; then
    echo "SKIP already staged: $rel"
    continue
  fi

  size="$(du -sh "$src" 2>/dev/null | cut -f1)"
  echo "MOVE_OUT $rel ($size)"

  if [[ "$dry_run" == "1" ]]; then
    continue
  fi

  mkdir -p "$(dirname "$dst")"
  mv "$src" "$dst"
  printf '%s\tmove_out\t%s\t%s\n' "$(timestamp)" "$rel" "$size" >> "$manifest_path"
done

if [[ "$dry_run" == "1" ]]; then
  echo "Dry run only. No files moved."
else
  echo "Manifest: $manifest_path"
fi
REMOTE
