#!/usr/bin/env bash
set -euo pipefail

ORB_MACHINE="${ORB_MACHINE:-aosp-builder}"
ORB_USER="${ORB_USER:-robin}"
SOURCE_ROOT="${SOURCE_ROOT:-/home/robin/aosp/aosp}"
STAGING_ROOT="${STAGING_ROOT:-/home/robin/aosp/_trim_staging}"
MANIFEST_PATH="${MANIFEST_PATH:-$STAGING_ROOT/trim-manifest.log}"
RESTORE_ALL=0
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage:
  trim-restore.sh [--dry-run] [--all] [--from-file PATH] REL_PATH [REL_PATH...]

Restores paths from the staging tree back into the AOSP source tree.

Examples:
  trim-restore.sh device/google
  trim-restore.sh --all
  trim-restore.sh --dry-run --from-file candidates.txt
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
    --all)
      RESTORE_ALL=1
      shift
      ;;
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

if [[ "$RESTORE_ALL" != "1" && ${#paths[@]} -eq 0 ]]; then
  usage
  exit 1
fi

if [[ "$RESTORE_ALL" != "1" ]]; then
  for rel in "${paths[@]}"; do
    require_relpath "$rel" || {
      echo "Invalid relative path: $rel" >&2
      exit 1
    }
  done
fi

orb -m "$ORB_MACHINE" -u "$ORB_USER" bash -s -- \
  "$SOURCE_ROOT" "$STAGING_ROOT" "$MANIFEST_PATH" "$RESTORE_ALL" "$DRY_RUN" "${paths[@]}" <<'REMOTE'
set -euo pipefail

source_root="$1"
staging_root="$2"
manifest_path="$3"
restore_all="$4"
dry_run="$5"
shift 5

timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

collect_all_paths() {
  if [[ ! -d "$staging_root" ]]; then
    return 0
  fi
  find "$staging_root" -mindepth 1 -maxdepth 1 -print | sed "s#^$staging_root/##"
}

if [[ "$restore_all" == "1" ]]; then
  mapfile -t items < <(collect_all_paths)
else
  items=("$@")
fi

touch "$manifest_path"

for rel in "${items[@]}"; do
  [[ -n "$rel" ]] || continue
  src="$staging_root/$rel"
  dst="$source_root/$rel"

  if [[ ! -e "$src" ]]; then
    echo "SKIP not staged: $rel"
    continue
  fi

  if [[ -e "$dst" ]]; then
    echo "SKIP target exists: $rel"
    continue
  fi

  size="$(du -sh "$src" 2>/dev/null | cut -f1)"
  echo "RESTORE $rel ($size)"

  if [[ "$dry_run" == "1" ]]; then
    continue
  fi

  mkdir -p "$(dirname "$dst")"
  mv "$src" "$dst"
  printf '%s\trestore\t%s\t%s\n' "$(timestamp)" "$rel" "$size" >> "$manifest_path"

  staged_parent="$(dirname "$src")"
  while [[ "$staged_parent" != "$staging_root" ]]; do
    rmdir "$staged_parent" 2>/dev/null || break
    staged_parent="$(dirname "$staged_parent")"
  done
done

if [[ "$dry_run" == "1" ]]; then
  echo "Dry run only. No files restored."
else
  echo "Manifest: $manifest_path"
fi
REMOTE
