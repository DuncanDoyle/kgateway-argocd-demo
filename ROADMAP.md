# ArgoCD health checks for kgateway — roadmap

Programme-level view of the work tracked by
[kgateway-dev/kgateway#13871](https://github.com/kgateway-dev/kgateway/issues/13871).
Each phase gets its own design spec and implementation plan under
[`docs/superpowers/`](docs/superpowers/); this page says what ships to whom,
in what order, and as which product.

**Last updated:** 2026-10-06

## Two products, not one

This work is delivered as **two independently supported products**:

| | Product | Covers | Audience |
|---|---|---|---|
| **A** | kgateway ArgoCD support | `gateway.kgateway.dev` | kgateway OSS users — and SEFK customers, since SEFK ships these CRDs too |
| **B** | Solo Enterprise for kgateway ArgoCD support | `enterprisekgateway.solo.io`, `enterprise.solo.io`, `waf.solo.io`, later `portal.solo.io` | SEFK customers |

**B is an extension of A, not a superset.** It covers only the enterprise API
groups and never restates A's kinds. A SEFK customer applies **both** packages:
A for the kgateway CRDs their install ships, B for the enterprise ones. Each has
its own version stream, support matrix and documentation.

This works cleanly because `argocd-cm` keys are per group and kind
(`resource.customizations.health.<group>_<Kind>`), so two patches merge into the
one ConfigMap additively with no overlap.

Two consequences worth holding on to:

- **A must never reference B.** Product A's repo, docs and upstream PR are
  public OSS artifacts; they must not name SEFK, link to internal repos, or
  describe enterprise APIs.
- **B's home is not this repo.** This repo is public and is product A. Where B
  lives is an open decision (see below).

## The problem

ArgoCD has no built-in health checks for kgateway's CRDs, so resources managed
by an ArgoCD Application show `(none)` for health even when the controller has
written a clear status. Worse, an Application full of broken kgateway resources
reports **Healthy**, because ArgoCD has no opinion about resources it cannot
assess. Standard `gateway.networking.k8s.io` resources do have checks; the
`gateway.kgateway.dev` ones do not.

## Delivery model

Two vehicles for the same Lua, and the order matters:

1. **`argocd-cm` ConfigMap — ships first.** Works on any ArgoCD version with no
   upstream dependency, which makes it both the development loop (edit, apply,
   watch the badge change in ~10s) and the first thing users and customers get.
2. **Bundled upstream in `argoproj/argo-cd` — ships after.** Gets the checks in
   front of everyone by default, on ArgoCD's release cadence.

`argocd-cm` entries **override** bundled checks (`util/lua/lua.go`,
`GetHealthScript`: configmap exact → configmap wildcard → embedded exact →
embedded wildcard). So the ConfigMap is not merely a stopgap — it stays valid
after the upstream PR merges, and remains the escape hatch for anyone who needs
different semantics. Customer-facing docs must say when it is safe to remove.

## Status

### Product A — kgateway

| Phase | Scope | State |
|---|---|---|
| A1 | `Backend`, `TrafficPolicy` | **Complete.** 11 cluster-captured fixtures, passing argo-cd's own harness, proven on a live cluster |
| A2 | `ListenerPolicy`, `BackendConfigPolicy`, `DirectResponse`, `GatewayExtension` | [Design approved](docs/superpowers/specs/2026-10-06-phase2-design.md) 2026-10-06 — implementation plan next |

A2 completes `gateway.kgateway.dev` coverage and closes #13871. Product A then
ships as a documented ConfigMap package, followed by the upstream argo-cd PR.

### Product B — Solo Enterprise for kgateway

| Phase | Scope | State |
|---|---|---|
| B1 | `enterprisekgateway.solo.io`, `enterprise.solo.io`, `waf.solo.io` | Not designed |
| B2 | `portal.solo.io` | Not designed |

B1 cannot start until A2 is implemented — B extends A and should not be designed
against a moving target — and needs a **licensed SEFK cluster** to capture
fixtures.

### Currently supported

```
resource.customizations.health.gateway.kgateway.dev_Backend
resource.customizations.health.gateway.kgateway.dev_TrafficPolicy
```

### Excluded, with reasons

| Kind | Why |
|---|---|
| `GatewayParameters` | No status implemented — the CRD schema says so outright. Any check would be a constant. Revisit if kgateway implements status. |
| `HTTPListenerPolicy` | Deprecated in 2.4.x in favour of `ListenerPolicy.spec.httpSettings`, and already absent from `main`. A check would ship for a kind that disappears next minor. |
| `ratelimit.solo.io/RateLimitConfig` | Empty status — same case as `GatewayParameters`. Confirm against a live SEFK cluster during B1. |
| `extauth.solo.io/AuthConfig` | Empty status — as above. |

## Phases

### A2 — remaining kgateway OSS CRDs

Brings `gateway.kgateway.dev` coverage to six kinds and **closes #13871**.

Agreed so far: two byte-identical Lua scripts (one per status shape) using
`obj.kind` for messages, copied per kind with a drift test — argo-cd's Lua VM
has no module system, so this is the only way to avoid four hand-maintained
copies; a third ArgoCD Application `kgw-coverage` holds the new kinds so the
demo narrative stays minimal; eight new fixtures (healthy + degraded per kind),
19 total.

Also in scope: refactoring phase 1's two scripts onto the shared form. That
change is behaviour-preserving — the rendered messages are identical — so the
existing 11 fixtures are its regression test.

**Ships:** product A's ConfigMap package, then the upstream PR. Completes product A's current scope.

### B1 — Solo Enterprise for kgateway

`enterprisekgateway.solo.io` (TrafficPolicy, Parameters, DestinationSelector),
`enterprise.solo.io` (EnterpriseListenerSet), `waf.solo.io` (WAFPolicy). Same
two status shapes, so the Lua transfers nearly unchanged.

Two things make this unlike phases 1-2. It needs a **licensed SEFK cluster** to
capture fixtures, since the method is probe-first rather than written from
source. And whether these checks go upstream at all is a genuine question:
being commercial is no barrier (upstream already carries checks for
`datadoghq.com`, `coralogix.com`, `astra.netapp.io`, and Solo's own
`gateway.solo.io`/`gloo.solo.io`), but the ConfigMap may simply be the better
vehicle for a product with its own release cadence.

**Ships:** product B's first release — the enterprise-groups package, applied alongside product A.

### B2 — Portal

`portal.solo.io`: `Portal`, `ApiProduct`, `ApiDoc`, and possibly
`PortalConfig`, `PortalParameters`, `VisibilityPolicy` (several have no status
— confirm live).

The interesting one is `ApiProduct`, which nests `status.versions[].conditions[]`.
A per-version failure must surface rather than hide behind top-level
conditions, so this needs real aggregation design rather than a copy of what
exists.

## Before product A ships

Release gates, carried from phase 1 as known gaps rather than discovered late:

- [ ] **Verify `setup.sh` on a clean machine.** It has only ever run where the
      minikube node image and the kgateway/argo-cd OCI charts were already
      cached from other profiles, so the `registry.k8s.io` pull path is
      untested — and that is the path anyone reproducing from the README takes.
      Testing it means a full teardown and rebuild, so do it when the cluster is
      no longer needed as a fixture source.
- [ ] Regenerate `healthchecks/argocd-cm-patch.yaml` for all six kinds.
- [ ] Refresh `docs/evidence/` so the before/after capture covers six kinds.
- [ ] Write product A's package documentation (see below).

## Documentation deliverables

Not yet written, and not yet in any phase's plan. The repo's current docs
(`README.md`, `DEMO.md`, `SCENARIOS.md`) are written for us, not for consumers.

| Deliverable | Audience | When |
|---|---|---|
| Product A package docs — install, what each status means, how to remove once upstream ships | kgateway OSS users | end of A2 |
| Product B package docs — enterprise kinds, supported SEFK version matrix, and that product A must be applied too | SEFK customers | end of B1 |
| Upstream PR body + `#13871` closing comment | argo-cd maintainers, kgateway community | with the PR |
| Product docs entries — one per product | kgateway.dev (A), docs.solo.io (B) | after B1 — owner TBD |

## Method

Worth stating because it constrains scheduling, and because departing from it
caused every significant defect found so far:

- **Probe first.** Scenario behaviour is predicted from source, then verified on
  a live cluster before fixtures are built. Phase 1's probe caught two API
  errors that would otherwise have shipped.
- **Capture, don't author.** Fixtures are `kubectl get -o yaml` from a real
  cluster. Where a state cannot be produced, say so in the PR rather than
  fabricating it. Derived fixtures carry a header disclosing exactly what was
  substituted.
- **Verify shipped CRDs, not Go types.** The two differ. kgateway v2.4.5 ships
  8 CRDs where `main` ships 7; SEFK ships 14 across six groups where the Go
  types suggested three in one.

## Open decisions

- **Where product B lives.** This repo is public and is product A; B must not
  ship from it. Candidates: a repo under `solo-io`, or a private repo of its
  own. Needs deciding before B1's design.
- Exact timing of the upstream PR relative to product A's ConfigMap release —
  the PR is held at a local commit and folds in A2 before opening.
- Whether product B's checks go upstream at all, or stay ConfigMap-only. Being
  commercial is no barrier, but a product with its own release cadence may be
  better served by the ConfigMap it controls.
- Owner and location for the two product-docs entries.
