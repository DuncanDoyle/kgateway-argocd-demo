#!/usr/bin/env bash
# Assembles out/resource_customizations/gateway.kgateway.dev/ -- a
# drop-in-ready tree for an argo-cd clone -- from this repo's TRACKED
# content under healthchecks/lua/<Kind>/ (health.lua, health_test.yaml,
# testdata/), and refreshes the five LIVE-CAPTURED testdata fixtures from
# the current cluster before assembling.
#
# IMPORTANT -- what this script writes, and what it never touches:
#   - The `extract()` calls below overwrite the five TRACKED source files
#     healthchecks/lua/{Backend,TrafficPolicy}/testdata/{healthy,degraded,
#     progressing}.yaml directly (not just their copies in out/) -- those
#     tracked files ARE the source of truth for these fixtures, since out/
#     is gitignored and regenerated. Re-run this script any time the live
#     cluster's status for these five resources changes and you want the
#     tracked fixtures to reflect it.
#   - The other SIX fixtures (Backend/stale, TrafficPolicy/{stale,
#     foreign_controller,overridden,overridden_empty_message,
#     partially_valid}) are DERIVED/asserted content -- see each file's own
#     header comment and DRAFT-argocd-pr.md's "Fixture provenance" section.
#     They cannot be reproduced by capturing a live resource. This script
#     NEVER writes those six filenames -- only the five named in the
#     `extract` calls below -- so a re-run cannot silently destroy them.
#
# Strips managedFields/uid/resourceVersion/creationTimestamp/annotations --
# noise that upstream's existing fixtures do not carry -- but keeps the
# status subresource completely intact, which is the entire point of the
# fixture.
#
# YAML tooling note: this machine's python3 has no PyYAML module, so the
# original round-trip-through-python approach in the task brief doesn't
# work here. `yq` (mikefarah/yq, Go implementation) is installed, so we
# fetch each resource as JSON via `kubectl -o json` (guaranteed valid JSON,
# no YAML-parsing edge cases) and let `yq -P` convert JSON -> YAML while
# deleting the noisy fields with a single `del()` expression. Output stays
# YAML, as argo-cd's fixtures require.
set -euo pipefail

cd "$(dirname "$0")/.."
source ./env.sh

SRC="healthchecks/lua"
OUT="out/resource_customizations/gateway.kgateway.dev"

# extract <namespace> <resource/name> <Kind> <state>
# Captures a live resource and overwrites the TRACKED fixture at
# healthchecks/lua/<Kind>/testdata/<state>.yaml. Only call this for a
# fixture known to be reproducible from a live capture -- see the header
# above for the fixed list of five.
extract() {
  local ns="$1" res="$2" kind="$3" state="$4"
  local dir="${SRC}/${kind}/testdata"
  mkdir -p "$dir"

  local json
  json="$(kubectl -n "$ns" get "$res" -o json)"

  echo "$json" | yq -P eval '
    del(.metadata.managedFields) |
    del(.metadata.uid) |
    del(.metadata.resourceVersion) |
    del(.metadata.creationTimestamp) |
    del(.metadata.selfLink) |
    del(.metadata.annotations)
  ' - > "${dir}/${state}.yaml"

  # An ABSENT status is a legitimate state (e.g. tp-progressing): a policy
  # that attaches to nothing never gets a status subresource written at
  # all -- not an empty ancestors list. Warn rather than fail, but make the
  # absence loud so it is never silently mistaken for a dump error.
  if ! echo "$json" | yq -e '.status' - >/dev/null 2>&1; then
    local name
    name="$(echo "$json" | yq '.metadata.name' -)"
    echo "WARNING: no status on ${name}" >&2
  fi

  echo "refreshed ${dir}/${state}.yaml"
}

echo "==> Refreshing the 5 live-captured fixtures from the cluster (tracked source, not just out/)"
# NOTE: tp-degraded targets an HTTPRoute in httpbin (TrafficPolicy
# targetRefs have no namespace field, so the policy must be co-located with
# its target route) -- it lives in DEMO_NS, not SCENARIOS_NS. See
# SCENARIOS.md "Where each resource actually lives".
extract "${DEMO_NS}"      backend/httpbin-static        Backend       healthy
extract "${SCENARIOS_NS}" backend/backend-degraded      Backend       degraded
extract "${DEMO_NS}"      trafficpolicy/add-demo-header TrafficPolicy healthy
extract "${DEMO_NS}"      trafficpolicy/tp-degraded     TrafficPolicy degraded
extract "${SCENARIOS_NS}" trafficpolicy/tp-progressing  TrafficPolicy progressing

echo
echo "==> Assembling ${OUT} from ${SRC}/ (health.lua, health_test.yaml, testdata/ -- all 11 fixtures: 5 just-refreshed captures + 6 tracked, derived fixtures, untouched above)"
rm -rf "$OUT"
for kind in Backend TrafficPolicy; do
  mkdir -p "${OUT}/${kind}"
  cp "${SRC}/${kind}/health.lua" "${OUT}/${kind}/health.lua"
  cp "${SRC}/${kind}/health_test.yaml" "${OUT}/${kind}/health_test.yaml"
  cp -r "${SRC}/${kind}/testdata" "${OUT}/${kind}/testdata"
done

echo
echo "Extraction complete. Review each file before use:"
find "${OUT}" -type f | sort
