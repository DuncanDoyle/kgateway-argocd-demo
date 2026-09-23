# kgateway + ArgoCD demo — design

**Date:** 2026-09-22
**Status:** Revised after review (2026-09-23); awaiting approval. Implementation not started.
**Drives:** [kgateway#13871](https://github.com/kgateway-dev/kgateway/issues/13871) — Add ArgoCD health checks for `gateway.kgateway.dev` CRDs
**Repo:** `DuncanDoyle/kgw-argocd-demo` (to be created, public)

## Purpose

Build a minimal kgateway + ArgoCD demo whose primary job is to act as a **test-data harness** for the ArgoCD health checks requested in kgateway#13871, and whose secondary job is to be a presentable GitOps demo.

Harness first: the concrete output is a set of cluster-extracted manifests with complete `status` subresources, one per health state per CRD, laid out exactly as `argoproj/argo-cd` expects under `resource_customizations/`, plus the Lua that consumes them. The demo narrative is built on top of that, not the other way round.

The health checks themselves are not written blind against the API types — they are developed against a live cluster in this demo, then contributed upstream.

## Background: how ArgoCD health checks work

A health check is a Lua script that receives the live resource as the global `obj` and returns `{status, message}`, where status is one of `Healthy`, `Progressing`, `Degraded`, `Suspended`. There is no registration or plugin mechanism. Two delivery vehicles exist for the same script:

1. **Bundled upstream** — `resource_customizations/<group>/<Kind>/{health.lua,health_test.yaml,testdata/}` in `argoproj/argo-cd`. Ships with an ArgoCD release.
2. **`argocd-cm` ConfigMap** — `resource.customizations.health.<group>_<Kind>`. Applied by the user, works on any ArgoCD version.

Resolution order, confirmed in `util/lua/lua.go:GetHealthScript` (argo-cd `a770f6f`, 2026-09-22): `argocd-cm` exact match → `argocd-cm` wildcard → embedded exact match → embedded wildcard. **The ConfigMap overrides the bundled script**, which is why (2) is both the stopgap before upstream merges and a permanent escape hatch afterwards.

This demo uses (2) as its development loop and emits (1) as an artifact.

## kgateway status shapes

**The inventory is version-dependent.** v2.4.5 (what this demo pins) ships **eight** CRDs in `gateway.kgateway.dev`; `main` ships **seven**, `HTTPListenerPolicy` having been folded into `ListenerPolicy.httpSettings`. Verified against both on 2026-09-23.

| Shape | Kinds (v2.4.5) |
|---|---|
| `status.ancestors[].conditions[]` | `TrafficPolicy`, `ListenerPolicy`, `HTTPListenerPolicy`†, `BackendConfigPolicy`, `DirectResponse` |
| `status.conditions[]` | `Backend`, `GatewayExtension` |
| No status | `GatewayParameters` |

† `HTTPListenerPolicy` is deprecated in v2.4.5 — its CRD says *"Deprecated: Use the httpSettings field on ListenerPolicy instead"* — and is absent from `main`. **Do not write a health check for it** unless users on it turn up: upstream would ship a check for a kind that no longer exists one minor later.

This corrects the table in kgateway#13871, which was written against 2.3.0 and is now wrong in three ways: `DirectResponse` does populate `PolicyStatus` (`pkg/kgateway/extensions2/plugins/directresponse/direct_response_plugin.go:93`); `GatewayParameters` has no status at all (`GatewayParametersStatus` is an empty struct, and the CRD schema says "This is not currently implemented"); and `BackendConfigPolicy` and `GatewayExtension` are missing from the issue entirely. **The issue should be updated before implementation starts.**

Two facts that shape the Lua, traced in `pkg/kgateway/translator/irtranslator/policy.go:42-58`:

- kgateway sets `observedGeneration` on policy ancestor conditions, so generation-gating works as intended.
- A policy that attaches to nothing produces **no ancestor entry at all** — status stays empty rather than going false. The Lua must not read that as healthy.
- **`Accepted=False` alone does not mean rejected.** Policies carry three states, not two: `True/Valid`, `False/Invalid` (rejected) and `False/Pending` (encountered, not yet decided). `pkg/reports/policy.go:207-223` defaults both the `Accepted` and `Attached` conditions to `False/Pending` when translation set no condition. A health check must branch on `reason`, not on `status` alone: `Invalid` → `Degraded`, `Pending` → `Progressing`. `Pending` describes the controller's own progress, not a prediction that a missing referent will appear — see *Ordering during sync, and why it is not a status problem*.

## Scope

**This phase is an explicit partial contribution. It does not close kgateway#13871.**

**In scope for v1:** `TrafficPolicy` (ancestors shape) and `Backend` (conditions shape) — one CRD per status shape, the smallest set that proves both Lua patterns end to end. Settling the aggregation semantics on two kinds before replicating them across six is the point of stopping here.

**Named follow-up deliverables**, to be recorded on the issue when the v1 PR opens so it is clear what remains:

| Kind | Shape | Note |
|---|---|---|
| `ListenerPolicy` | ancestors | mechanical once `TrafficPolicy` lands |
| `BackendConfigPolicy` | ancestors | mechanical |
| `DirectResponse` | ancestors | mechanical |
| `GatewayExtension` | conditions | needs an ext-auth/ext-proc service to produce meaningful status |
| `GatewayParameters` | — | blocked: no status implemented |
| `HTTPListenerPolicy` | ancestors | deprecated in v2.4.5, absent from `main` — cover only on demand |

## Architecture

kgateway is installed out-of-band by a setup script; ArgoCD manages only the demo resources, so its resource tree contains exactly the objects whose health we care about.

```
setup.sh ──> kubectl apply Gateway API v1.6.1 Standard CRDs   ← REQUIRED, see below
         ──> helm install kgateway CRDs + controller   (NOT in ArgoCD's tree)
         ──> helm install argo-cd
         ──> kubectl apply argocd/app-*.yaml

ArgoCD ──> repo/manifests/demo       (automated sync, always green)
       ──> repo/manifests/scenarios  (manual sync, deliberately broken)
```

Two Applications rather than one: the demo starts all-green and stays that way, while failure states are summoned on demand by syncing the second app. They never interfere, and with both synced the extraction script captures every state in one pass.

**The Gateway API CRDs must be installed first.** No kgateway chart bundles them — verified across the whole of `install/helm/` at v2.4.5 — so applying a `Gateway` or `HTTPRoute` on a clean cluster fails discovery without them. kgateway 2.4.x is built against Gateway API **v1.6.1**; install that exact minor, Standard channel.

Because this repo generates upstream test fixtures, every external input is pinned so a rerun produces byte-comparable status:

| Artifact | Pin |
|---|---|
| Gateway API CRDs | `v1.6.1`, Standard channel |
| `kgateway-crds` + `kgateway` Helm charts | `v2.4.5` |
| `argo-cd` Helm chart | exact chart version, recorded in `env.sh` at implementation time |
| workload image | `mccutchen/go-httpbin` by digest, not a floating tag |
| argo-cd clone used for `go test ./util/lua/` | commit SHA recorded in the README alongside the test run |

ArgoCD is installed with `timeout.reconciliation: 10s` so health changes surface quickly during Lua development.

Target cluster: minikube primary, but no minikube-specific assumptions. Gateway access is via `kubectl port-forward` by default, which works identically on minikube, kind and EKS; `minikube tunnel` is documented as the optional nicer path.

## Repository layout

```
kgw-argocd-demo/
├── README.md
├── env.sh                    # REPO_URL, REPO_REVISION, chart/kgateway versions.
│                             # The ONLY place to change when Gitea is swapped in.
├── setup.sh / teardown.sh
├── argocd/
│   ├── app-demo.yaml         # → manifests/demo, automated sync
│   └── app-scenarios.yaml    # → manifests/scenarios, manual sync
├── manifests/
│   ├── demo/                 # namespace, httpbin, Gateway, 2 HTTPRoutes,
│   │                         # Backend (static), TrafficPolicy
│   └── scenarios/            # broken TrafficPolicy + Backend, own namespace
├── healthchecks/
│   ├── lua/{TrafficPolicy,Backend}/health.lua
│   └── argocd-cm-patch.yaml  # generated from the Lua above
└── hack/
    ├── render-argocd-cm.sh   # lua/ → argocd-cm-patch.yaml
    └── extract-testdata.sh   # cluster → out/resource_customizations/…
```

`healthchecks/` lives in this repo because the development loop is here: edit Lua, apply the ConfigMap, watch the badge change within ~10s. Restructuring into `resource_customizations/` layout happens only at PR time. This repo also remains the source of truth for the `argocd-cm` delivery vehicle, which is how SEFK customers and anyone on an older ArgoCD will consume these checks.

## Demo manifests

Namespace `httpbin`. One workload (`mccutchen/go-httpbin` — maintained and multi-arch, which matters on Apple Silicon minikube), reached two ways.

```yaml
# Gateway — kgateway GatewayClass, single HTTP listener.
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata: { name: demo-gateway, namespace: httpbin }
spec:
  gatewayClassName: kgateway
  listeners:
  - name: http
    port: 8080
    protocol: HTTP
    allowedRoutes: { namespaces: { from: Same } }
---
# Route A — ordinary Service backendRef. The TrafficPolicy attaches here.
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: { name: httpbin-via-service, namespace: httpbin }
spec:
  parentRefs: [{ name: demo-gateway }]
  rules:
  - matches: [{ path: { type: PathPrefix, value: /headers } }]
    backendRefs: [{ name: httpbin, port: 8000 }]
---
# Backend — static, pointing at httpbin's own in-cluster DNS name.
# Contrived on purpose: exercises the Backend CRD's status without needing
# an off-cluster endpoint or any network access.
apiVersion: gateway.kgateway.dev/v1alpha1
kind: Backend
metadata: { name: httpbin-static, namespace: httpbin }
spec:
  static:
    hosts: [{ host: httpbin.httpbin.svc.cluster.local, port: 8000 }]
---
# Route B — same workload, reached through the Backend CR instead of the Service.
# URLRewrite so /via-backend lands on httpbin's /headers and returns something real.
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: { name: httpbin-via-backend, namespace: httpbin }
spec:
  parentRefs: [{ name: demo-gateway }]
  rules:
  - matches: [{ path: { type: PathPrefix, value: /via-backend } }]
    filters:
    - type: URLRewrite
      urlRewrite: { path: { type: ReplacePrefixMatch, replacePrefixMatch: /headers } }
    backendRefs:
    - group: gateway.kgateway.dev
      kind: Backend
      name: httpbin-static
---
# TrafficPolicy — simplest visible effect: add a request header that httpbin
# echoes straight back in its /headers response body.
apiVersion: gateway.kgateway.dev/v1alpha1
kind: TrafficPolicy
metadata: { name: add-demo-header, namespace: httpbin }
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: httpbin-via-service
  headerModifiers:
    request:
      set: [{ name: X-Kgateway-Demo, value: hello-from-trafficpolicy }]
```

The whole demo is one curl: `/headers` shows `X-Kgateway-Demo` echoed back (TrafficPolicy working); `/via-backend` returns the same body without that header (Backend working, policy correctly scoped to route A only).

`headerModifiers` is used rather than `transformation` deliberately — it is declarative, has no templating syntax to explain, and keeps the reader's attention on ArgoCD. Confirmed present in v2.4.5 (`api/v1alpha1/kgateway/traffic_policy_types.go:89`).

## Scenarios

Namespace `scenarios`, synced on demand.

**Governing constraint: broken manifests must pass CRD admission but fail translation.** If a manifest is invalid in a way CEL or the OpenAPI schema catches, ArgoCD reports `SyncFailed`, the resource never exists, and there is no status to capture — the wrong failure mode entirely. Every scenario must therefore be semantically wrong, not structurally wrong. This rules out most obvious tricks: `static.go:52-55` rejects an empty host or port, but the schema already enforces `MinLength=1` and requires `port`, so those never reach the translator.

| Fixture | Mechanism | Expected |
|---|---|---|
| `trafficpolicy-progressing` | `targetRefs` → an HTTPRoute that does not exist | no ancestors, or an ancestor with `Accepted=False/Pending` → `Progressing` either way |
| `trafficpolicy-degraded` | attached to a real route, `extAuth.extensionRef` → non-existent GatewayExtension | `Accepted=False/Invalid` → `Degraded` |
| `backend-degraded` | `priorityGroups` referencing a Backend that does not exist | `Accepted=False/Invalid` → `Degraded` |
| `backend-stale` | `observedGeneration` mismatch, captured by watch if possible | `Progressing` (generation gating) |

`backend-degraded` in full:

```yaml
# Schema-valid (the ref is just a name), so it passes admission; fails at
# translation with: priority group 0: backend "no-such-backend" not found in
# namespace "scenarios"  →  Accepted=False / Reason=Invalid
apiVersion: gateway.kgateway.dev/v1alpha1
kind: Backend
metadata: { name: backend-degraded, namespace: scenarios }
spec:
  priorityGroups:
  - backends:
    - name: no-such-backend
```

Error path: `pkg/kgateway/extensions2/plugins/backend/priority_groups.go:62`, aggregated into the `Accepted` condition by `pkg/kgateway/extensions2/pluginutils/status.go:14`. `priorityGroups` confirmed present in the v2.4.5 CRD.

Note: `priorityGroups` is marked experimental in the API and may change shape between kgateway versions. That is a maintenance cost on the demo manifest only — the resulting status is an ordinary `Accepted=False/Invalid` condition identical to any other Backend error, so the Lua and the upstream fixture are unaffected. **Fallback if the probe shows otherwise:** an AWS backend with a missing `auth.secretRef` (`plugin.go:284`), at the cost of dragging AWS concepts into an otherwise self-contained demo.

### Probe-first

The mechanisms above are code-traced predictions, not observations. Implementation therefore **begins with a probe step**: apply each candidate, dump the resulting status, and record what actually happened in a table in the README. Fixtures that do not produce their intended state are replaced or dropped.

Confidence is uneven and should be treated that way: the two `TrafficPolicy` cases are traced end to end through `policy.go`; `backend-degraded` is traced to the error string but the surfacing has not been observed. `Backend` has no natural sustained `Progressing` state, which is why its third fixture is the stale one — that is a consequence of translation always reaching a verdict, not a defect.

If a state turns out to be unreachable for a CRD, record it as a finding rather than papering over it with a hand-written fixture — but check first whether unreachable is simply *correct* for that CRD before calling it a kgateway bug.

`backend-stale` is the awkward one. A generation mismatch — `metadata.generation` already incremented by a spec edit while the status still carries the previous `observedGeneration` — is a real state of the object in the API server, not a write-time artifact, so it *is* capturable: a `kubectl get -o yaml --watch` stream sees every version. It is just short-lived, and whether you catch it is a race between reconcile latency and watch delivery.

So: **attempt capture first** (watch while applying a spec change; repeat, or batch several edits, to widen the odds). Only if capture proves unreliable, hand-author it from a real dump with `observedGeneration` decremented — and say so in the upstream PR.

For calibration, upstream's `gateway.envoyproxy.io/BackendTrafficPolicy/testdata/stale.yaml` is plainly hand-authored (`generation: 2` against `observedGeneration: 1`, a round `2024-01-01T00:00:00Z` timestamp, no `uid`/`resourceVersion`/`creationTimestamp`) — as are its sibling fixtures, `healthy.yaml` included. None of them is labelled synthetic. So argo-cd's documented requirement for real `kubectl get -oyaml` output is not uniformly enforced, and a hand-authored fixture will not be rejected on sight. Capturing the real thing is still the point of having a harness.

## Health checks

Both checks follow the same three rules: **aggregate over every recognised condition** rather than returning on the first one; **branch on `reason`, never on `status` alone**; and **treat stale conditions as unknown**. Returning early on a single `True` is the specific bug to avoid — it lets a later failing condition go unseen.

### Condition semantics

`Backend` — `status.conditions[]`, two condition types (`api/v1alpha1/kgateway/backend_types.go:394-435`):

| Condition | Status / Reason | Health |
|---|---|---|
| `Accepted` | `True` / `Accepted` | contributes Healthy |
| `Accepted` | `False` / `Invalid` | `Degraded` |
| `EndpointsDiscovered` | `True` / `Discovered` | contributes Healthy |
| `EndpointsDiscovered` | `False` / `NoMatchingInstances`, `CredentialError`, `AuthorizationError`, `DiscoveryError`, `Degraded` | `Degraded` |

`EndpointsDiscovered` is a **runtime** condition: a Backend can be `Accepted=True` and still be failing discovery. This is why aggregation is mandatory — a first-match return on `Accepted=True` reports a broken EC2 backend as Healthy.

Policies (`TrafficPolicy` et al.) — `status.ancestors[].conditions[]`, two condition types with the reasons in `api/v1alpha1/shared/policy_types.go:22-60`:

| Condition | Reason | Health |
|---|---|---|
| `Accepted` | `Valid` | contributes Healthy |
| `Accepted` | `PartiallyValid` | `Degraded` — part of the policy was rejected, surface the message |
| `Accepted` | `Invalid` | `Degraded` |
| `Accepted` | `Pending` | `Progressing` |
| `Attached` | `Attached`, `Merged` | contributes Healthy |
| `Attached` | `Overridden` | `Degraded` — the policy exists but is not in effect |
| `Attached` | `Invalid` | `Degraded` |
| `Attached` | `Pending` | `Progressing` |

Precedence when an ancestor yields several verdicts: `Degraded` > `Progressing` > `Healthy`.

### Controller scoping is required

`pkg/pluginsdk/statussync/writer.go:267` — `MergePolicyAncestorStatuses` "preserves PolicyStatus ancestors owned by other controllers": the written status can carry foreign ancestor entries alongside kgateway's. The check must therefore evaluate only ancestors whose `controllerName` is `kgateway.dev/kgateway` and ignore the rest, or it will report another controller's verdict as kgateway's.

This reverses an earlier draft of this spec, which dismissed scoping as noise on the grounds that only kgateway reconciles these CRDs. The merge code explicitly anticipates otherwise. It also aligns us with argo-cd#29823, which is fixing exactly this bug class in `BackendTLSPolicy` — so the PR should note that we scope deliberately, not that we skip it.

### Divergence from the upstream model

`resource_customizations/gateway.envoyproxy.io/BackendTrafficPolicy/health.lua` remains the structural model for walking ancestors and handling generation staleness, but it checks `status == "False"` alone. That is correct for Envoy Gateway, which has no `Pending` reason, and wrong for kgateway. The divergence needs a comment in the script and a line in the PR description.

### Test cases

Beyond the demo's own fixtures, the check must be pinned against: a stale runtime condition; an ancestor owned by a foreign controller; a mix of foreign and kgateway ancestors; each `Attached` reason; `PartiallyValid`; and a resource with no status at all.

`EndpointsDiscovered` failure fixtures cannot be produced by this demo — those conditions come from EC2 discovery, which needs real AWS credentials, and the demo is deliberately offline. The aggregation logic covers them; the fixtures will not, and the upstream PR must say so plainly rather than shipping hand-written data presented as cluster-extracted. Closing that gap is a recorded follow-up.

## Extraction and verification

`hack/extract-testdata.sh` dumps each resource with `kubectl get -oyaml`, strips `managedFields`, `uid`, `resourceVersion` and `selfLink` (noise; upstream's existing fixtures do not carry them), keeps `status` completely intact, and writes argo-cd's own layout:

```
out/resource_customizations/gateway.kgateway.dev/
├── Backend/{health.lua,health_test.yaml,testdata/{healthy,degraded,stale}.yaml}
└── TrafficPolicy/{health.lua,health_test.yaml,testdata/{healthy,degraded,progressing}.yaml}
```

It generates `health_test.yaml` from the observed status as well, so expected messages match what the controller actually wrote rather than what we assumed it wrote.

**Verification is not "the badge looks right in the UI"** — that is the demo. It is copying `out/resource_customizations/` into a local `argoproj/argo-cd` clone and running `go test -v ./util/lua/`, the same gate the upstream PR must pass. The README documents this as the final step, so the PR is mechanical by the time we reach it.

## Ordering during sync, and why it is not a status problem

A reference to a resource that has not been created *yet* and a reference to one that will *never* exist are indistinguishable at any point in time — telling them apart requires knowledge of the future. This is intrinsic to level-triggered reconciliation, not a kgateway shortcoming, so a `Backend` with an unresolvable reference reporting `Accepted=False/Invalid` is correct, and a health check mapping it to `Degraded` is correct too.

Policies' `Pending` reason does **not** span this case, despite appearing to. An ancestor slot exists only if that `ancestorRef` was encountered during translation (`getAncestorRefOrNil`); `Pending` is then set when a slot exists but translation reached no verdict for it (`pkg/reports/policy.go:207-223`). It describes the controller's own progress — "seen, not yet decided" — which is locally knowable. It says nothing about whether a referent will later appear. `Backend` needs no equivalent: `BuildCondition` always reaches a verdict at the end of translation, and before that there is no status at all, which the health check already treats as `Progressing`.

The real problem — ArgoCD applying resources within a sync wave in no guaranteed order, so a reference is transiently unresolvable — is therefore solved by **ordering, not by status semantics**: `argocd.argoproj.io/sync-wave` places a `Backend` in an earlier wave than anything referencing it, and the transient never occurs. The demo should use sync waves for exactly this reason and the README should say why.

Time-bounding the transient (Kubernetes' `progressDeadlineSeconds` approach) is not available to us: ArgoCD health checks must be pure functions of the object so they are deterministic and pinnable by `health_test.yaml` fixtures. Exactly one bundled `health.lua` upstream references `os.time` (`apps.kruise.io/AdvancedCronJob`, where schedule time is intrinsic to the resource).

**What the probe should still establish:** whether `Accepted=False/Reason=Pending` is ever *observable* on a policy. The defaulting branch fires only when an ancestor slot exists — i.e. translation encountered that `parentRef` — but set no condition for it, so the question is whether that window is ever wide enough for a client to catch a status write carrying it.

Probe: `kubectl get trafficpolicy -A -o yaml --watch` while applying and mutating the demo policies, then grep the captured stream for `reason: Pending`.

- Observed → the Lua branch is load-bearing and the upstream PR needs a real `pending.yaml` fixture.
- Never observed → the branch is defensive; keep it (it costs nothing) but **do not fabricate a fixture for it**. `backend-stale` is the only fixture that may end up hand-authored, and only if capture fails.

Either way this is not evidence of a `Backend` status gap — an earlier draft of this spec claimed one, and that claim was wrong.

## Deferred

- **Gitea as the git source.** v1 points ArgoCD straight at the public GitHub repo; broken variants are committed up front, so no pushes happen at demo time. Gitea earns its place later for air-gapped demos (cf. `ent-kgw-airgapped-demo`), for workshops where attendees need push rights without GitHub accounts, and — most importantly — to show the real GitOps loop: edit a TrafficPolicy, commit, watch the health badge flip. Switching Application paths demonstrates the health check but not the loop. `env.sh` isolates `REPO_URL`/`REPO_REVISION` so this is a config change, not a rewrite.
- **The remaining five CRDs** — `ListenerPolicy`, `BackendConfigPolicy`, `DirectResponse` (ancestors shape, mechanical once `TrafficPolicy` works), `GatewayExtension` (conditions shape, needs an ext-auth/ext-proc service), `GatewayParameters` (blocked: no status).
- **SEFK health checks.** `enterprisekgateway.solo.io` and `portal.solo.io` reuse the same two shapes, so the Lua transfers nearly verbatim: `EnterpriseKgatewayTrafficPolicy` is ancestors-shaped; `EnterpriseKgatewayParameters`, `EnterpriseKgatewayDestinationSelector`, `Portal`, `ApiProduct`, `ApiDoc` are conditions-shaped; `PortalParameters` has no status. `ApiProduct` needs extra thought — it has nested `status.versions[].conditions[]`, so a per-version failure should surface rather than hide behind top-level conditions. Being commercial is not a barrier to contributing upstream: a health check is Lua over a public status shape, and upstream already carries checks for commercial products (`datadoghq.com`, `coralogix.com`, `astra.netapp.io`).
- **AWS/EC2 Backend coverage.** `EndpointsDiscovered` failure modes (`CredentialError`, `AuthorizationError`, `DiscoveryError`, `NoMatchingInstances`, `Degraded`) are handled by the Lua but have no fixtures, because producing them needs real AWS credentials and this demo is offline by design. Add an AWS/EC2 path — either an optional flag in the demo or a dump sourced from a cluster that runs one — so ArgoCD health support genuinely covers those Backend types.
- **Update kgateway#13871** before implementation: the status table is wrong (see above), and the inventory is version-dependent. Record the v1 scope as a partial contribution with the follow-up kinds named, so the issue stays open with a clear remainder.

## Resolved questions

- **Repo location on disk.** The demo repo lives at `~/Development/github/kgw-argocd-demo`, alongside the other demo repos. The design doc moves with it.
- **Gateway health on plain minikube — not an issue.** `Programmed` defaults to `True` unless translation explicitly sets it False (`pkg/reports/status.go:630`); the only False paths are listener/filter-chain validation errors and misuse of `spec.addresses`, and `AddressNotAssigned` appears nowhere in kgateway. The LoadBalancer address populates `status.addresses` only (`pkg/kgateway/controller/gw_controller.go:390-410`), and ArgoCD's built-in Gateway check reads only `ResolvedRefs`, `Accepted` and `Programmed` — never `addresses`. The Gateway therefore reports Healthy on plain minikube with the Service pending; `minikube tunnel` affects reachability, not status.
