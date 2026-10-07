#!/usr/bin/env bash
# Install the generated health-check tree into the local argo-cd checkout.
#
# Mirrors out/resource_customizations/gateway.kgateway.dev/ into the argo-cd
# clone. rsync --delete removes only files that no longer exist in the
# generated tree, and only within this one destination directory; nothing
# outside it is ever touched. Replaces the old `rm -rf && cp -r` approach,
# which would destroy uncommitted work in the clone.
set -euo pipefail

# Run from the demo repo root regardless of where the script is invoked.
cd "$(dirname "$0")/.."

ARGOCD_DIR="${ARGOCD_DIR:-$HOME/Development/github/argo-cd}"
SRC="out/resource_customizations/gateway.kgateway.dev"
SUB="resource_customizations/gateway.kgateway.dev"
DEST="$ARGOCD_DIR/$SUB"

if [ ! -d "$SRC" ]; then
  echo "error: $SRC does not exist; generate the tree first" >&2
  exit 1
fi
# An existing but empty source is destructive, not merely useless: rsync
# --delete would wipe the whole destination, including uncommitted work. This
# happens after a half-failed generator run or a cleaned out/ directory.
if ! find "$SRC" -name health.lua -print -quit | grep -q .; then
  echo "error: $SRC contains no health.lua; refusing to --delete the destination with an empty source" >&2
  exit 1
fi
if [ ! -d "$ARGOCD_DIR/.git" ]; then
  echo "error: $ARGOCD_DIR is not a git checkout" >&2
  exit 1
fi

mkdir -p "$DEST"
# Trailing slashes: copy directory contents, not the directory itself.
rsync -a --delete "$SRC/" "$DEST/"

# Print what changed so the diff can be reviewed before running tests.
( cd "$ARGOCD_DIR" && git status --short -- "$SUB/" )
