#!/usr/bin/env bash
# Dumps live resources into argo-cd's resource_customizations layout.
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

OUT="out/resource_customizations/gateway.kgateway.dev"

# extract <namespace> <resource/name> <Kind> <state>
extract() {
  local ns="$1" res="$2" kind="$3" state="$4"
  local dir="${OUT}/${kind}/testdata"
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

  echo "wrote ${dir}/${state}.yaml"
}

# NOTE: tp-degraded targets an HTTPRoute in httpbin (TrafficPolicy
# targetRefs have no namespace field, so the policy must be co-located with
# its target route) -- it lives in DEMO_NS, not SCENARIOS_NS. See
# SCENARIOS.md "Where each resource actually lives".
extract "${DEMO_NS}"      backend/httpbin-static        Backend       healthy
extract "${SCENARIOS_NS}" backend/backend-degraded      Backend       degraded
extract "${DEMO_NS}"      trafficpolicy/add-demo-header TrafficPolicy healthy
extract "${DEMO_NS}"      trafficpolicy/tp-degraded     TrafficPolicy degraded
extract "${SCENARIOS_NS}" trafficpolicy/tp-progressing  TrafficPolicy progressing

# Copy authored content (health.lua, health_test.yaml) in beside the captured
# fixtures, so out/ is a complete resource_customizations tree ready to drop
# into an argo-cd clone. Authored files live under healthchecks/; out/ is
# generated and gitignored.
for kind in Backend TrafficPolicy; do
  for f in health.lua health_test.yaml; do
    if [ -f "healthchecks/lua/${kind}/${f}" ]; then
      cp "healthchecks/lua/${kind}/${f}" "${OUT}/${kind}/${f}"
    fi
  done
done

echo
echo "Extraction complete. Review each file before use:"
find "${OUT}" -type f | sort
