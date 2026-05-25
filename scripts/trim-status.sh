#!/usr/bin/env bash
set -euo pipefail

ORB_MACHINE="${ORB_MACHINE:-aosp-builder}"
ORB_USER="${ORB_USER:-robin}"
SOURCE_ROOT="${SOURCE_ROOT:-/home/robin/aosp/aosp}"
STAGING_ROOT="${STAGING_ROOT:-/home/robin/aosp/_trim_staging}"
MANIFEST_PATH="${MANIFEST_PATH:-$STAGING_ROOT/trim-manifest.log}"

orb -m "$ORB_MACHINE" -u "$ORB_USER" bash -s -- \
  "$SOURCE_ROOT" "$STAGING_ROOT" "$MANIFEST_PATH" <<'REMOTE'
set -euo pipefail

source_root="$1"
staging_root="$2"
manifest_path="$3"

echo "Source root:  $source_root"
echo "Staging root: $staging_root"
echo

if [[ ! -d "$staging_root" ]]; then
  echo "No staging directory yet."
  exit 0
fi

echo "Top-level staged paths:"
find "$staging_root" -mindepth 1 -maxdepth 1 -print | sed "s#^$staging_root/##" | sort
echo

echo "Staged sizes:"
du -sh "$staging_root"/* 2>/dev/null | sort -hr || true
echo

if [[ -f "$manifest_path" ]]; then
  echo "Recent manifest entries:"
  tail -n 40 "$manifest_path"
else
  echo "Manifest not created yet."
fi
REMOTE
