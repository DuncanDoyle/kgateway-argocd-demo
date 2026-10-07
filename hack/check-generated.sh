#!/usr/bin/env bash
# Reproducibility guard: regenerates every generated artefact under
# healthchecks/ from its source and fails if the tracked copy differs.
# Phase 1 shipped an argocd-cm patch that silently disagreed with its own
# scripts for weeks because nothing compared them. Requires a live cluster
# (extract-testdata.sh captures fixtures from it) and a clean healthchecks/
# tree to start with, so uncommitted edits are not mistaken for drift.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! git diff --quiet -- healthchecks/; then
  echo "ERROR: healthchecks/ has uncommitted changes; commit or stash them first" >&2
  exit 1
fi

./hack/extract-testdata.sh >/dev/null
./hack/render-argocd-cm.sh >/dev/null

if ! git diff --exit-code -- healthchecks/; then
  echo "ERROR: generated artefacts under healthchecks/ have drifted from their source (diff above)" >&2
  exit 1
fi
echo "OK: healthchecks/ matches what the scripts generate"
