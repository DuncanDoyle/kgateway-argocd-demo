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
source ./hack/kind-shapes.sh

# extract <namespace> <resource/name> <Kind> <state>
# Captures a live resource and overwrites the TRACKED fixture at
# healthchecks/lua/<Kind>/testdata/<state>.yaml. Only call this for a
# fixture known to be reproducible from a live capture -- see the header
# above for the fixed list of five.
extract() {
  local ns="$1" res="$2" kind="$3" state="$4"
  local dir="${SRC}/${kind}/testdata"
  mkdir -p "$dir"

  local json target header
  target="${dir}/${state}.yaml"
  json="$(kubectl -n "$ns" get "$res" -o json)"

  # Preserve a hand-written provenance header: the leading run of '#' lines
  # in the existing fixture (if any) is re-emitted ahead of the fresh capture,
  # so annotating a fixture does not make it un-refreshable.
  header=""
  if [ -f "$target" ]; then
    header="$(awk '/^#/ {print; next} {exit}' "$target")"
  fi

  {
    [ -n "$header" ] && printf '%s\n' "$header"
    echo "$json" | yq -P eval '
      del(.metadata.managedFields) |
      del(.metadata.uid) |
      del(.metadata.resourceVersion) |
      del(.metadata.creationTimestamp) |
      del(.metadata.selfLink) |
      del(.metadata.annotations)
    ' -
  } > "${target}.tmp"
  mv "${target}.tmp" "$target"

  # An ABSENT status is a legitimate state (e.g. tp-progressing): a policy
  # that attaches to nothing never gets a status subresource written at
  # all -- not an empty ancestors list. Warn rather than fail, but make the
  # absence loud so it is never silently mistaken for a dump error.
  if ! echo "$json" | yq -e '.status' - >/dev/null 2>&1; then
    local name
    name="$(echo "$json" | yq '.metadata.name' -)"
    echo "WARNING: no status on ${name}" >&2
  fi

  echo "refreshed ${target}"
}

echo "==> Refreshing the 12 live-captured fixtures from the cluster (tracked source, not just out/)"
# NOTE: tp-degraded targets an HTTPRoute in httpbin (TrafficPolicy
# targetRefs have no namespace field, so the policy must be co-located with
# its target route) -- it lives in DEMO_NS, not SCENARIOS_NS. See
# SCENARIOS.md "Where each resource actually lives".
extract "${DEMO_NS}"      backend/httpbin-static        Backend       healthy
extract "${SCENARIOS_NS}" backend/backend-degraded      Backend       degraded
extract "${DEMO_NS}"      trafficpolicy/add-demo-header TrafficPolicy healthy
extract "${DEMO_NS}"      trafficpolicy/tp-degraded     TrafficPolicy degraded
extract "${SCENARIOS_NS}" trafficpolicy/tp-progressing  TrafficPolicy progressing

# Kinds from the coverage probe (see COVERAGE.md). Each second fixture is named
# after the state actually observed: no_status where the controller writes no
# status at all, degraded where it is genuinely rejected. lp-degraded-ca is
# deliberately NOT captured: it is Accepted=True despite its dangling reference.
extract "${DEMO_NS}" listenerpolicy/lp-healthy            ListenerPolicy      healthy
extract "${DEMO_NS}" listenerpolicy/lp-degraded-accesslog ListenerPolicy      degraded
extract "${DEMO_NS}" listenerpolicy/lp-unattached         ListenerPolicy      no_status
extract "${DEMO_NS}" backendconfigpolicy/bcp-healthy      BackendConfigPolicy healthy
extract "${DEMO_NS}" backendconfigpolicy/bcp-degraded     BackendConfigPolicy degraded
extract "${DEMO_NS}" directresponse/dr-healthy            DirectResponse      healthy
extract "${DEMO_NS}" directresponse/dr-unreferenced       DirectResponse      no_status

echo
echo "==> Assembling ${OUT} from ${SRC}/ (health.lua, health_test.yaml, testdata/ -- all fixtures: 12 just-refreshed captures + tracked, derived fixtures, untouched above)"
rm -rf "$OUT"
install_shape() {
  local shape="$1"; shift
  for kind in "$@"; do
    mkdir -p "${OUT}/${kind}"
    cp "healthchecks/lua/${shape}/health.lua" "${OUT}/${kind}/health.lua"
    cp "healthchecks/lua/${kind}/health_test.yaml" "${OUT}/${kind}/health_test.yaml"
    # testdata/ MUST be copied: health_test.yaml's inputPath entries are
    # relative to the kind's directory in the generated tree, so omitting it
    # leaves every test pointing at a file that does not exist.
    cp -R "healthchecks/lua/${kind}/testdata" "${OUT}/${kind}/testdata"
  done
}
install_shape ancestors ${ANCESTORS_KINDS}
install_shape conditions ${CONDITIONS_KINDS}

# Guard against a kind being added to healthchecks/lua/ but forgotten in the
# mapping. Iterate the AUTHORED source directories, not the generated ones:
# a kind missing from the mapping creates no output directory, so checking
# the output cannot see it. argo-cd's harness generates no subtests for a
# directory without health.lua and reports a vacuous pass, so this is the
# only thing standing between a forgotten kind and silent non-coverage.
MAPPED=" ${ANCESTORS_KINDS} ${CONDITIONS_KINDS} "
for src in healthchecks/lua/*/; do
  kind=$(basename "$src")
  # Shape directories hold scripts, not fixtures; skip them.
  [ -f "${src}/health_test.yaml" ] || continue
  case "${MAPPED}" in
    *" ${kind} "*) ;;
    *) echo "ERROR: ${kind} has fixtures but is missing from the shape mapping in hack/kind-shapes.sh" >&2; exit 1 ;;
  esac
  for required in health.lua health_test.yaml testdata; do
    [ -e "${OUT}/${kind}/${required}" ] || { echo "ERROR: ${OUT}/${kind}/${required} missing" >&2; exit 1; }
  done
done

echo
echo "Extraction complete. Review each file before use:"
find "${OUT}" -type f | sort
