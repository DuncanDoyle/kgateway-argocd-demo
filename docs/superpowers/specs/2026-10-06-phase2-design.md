# Phase 2 — remaining kgateway OSS CRDs — design

**Status:** **APPROVED** (Sections 1-4, 2026-10-06). Implementation plan next;
nothing is implemented yet.
**Date:** 2026-10-06
**Programme context:** [ROADMAP.md](../../../ROADMAP.md)
**Builds on:** [phase 1 design](2026-09-22-kgateway-argocd-demo-design.md)

Phase 1 shipped health checks for `Backend` and `TrafficPolicy`. Phase 2 brings
`gateway.kgateway.dev` coverage to five of the group's eight kinds — every kind
that has a status to check — and closes
[kgateway#13871](https://github.com/kgateway-dev/kgateway/issues/13871).

This phase is **A2** — the second phase of **product A**, kgateway ArgoCD
support, which is delivered and supported independently of product B (Solo
Enterprise for kgateway ArgoCD support). A2 completes product A's current
scope. B extends A with the enterprise API groups and never restates A's kinds;
see [ROADMAP.md](../../../ROADMAP.md). Everything in this document is a public
OSS artifact and must not reference SEFK.

---

## Section 1 — Scope and architecture

Four new kinds:

| Kind | Status shape | Notes |
|---|---|---|
| `ListenerPolicy` | `status.ancestors[].conditions[]` | |
| `BackendConfigPolicy` | `status.ancestors[].conditions[]` | |
| `DirectResponse` | `status.ancestors[].conditions[]` | CRD declares `Accepted` and `Attached` printcolumns, same pair as `TrafficPolicy`. Wire field for the response code is `spec.status`, **not** `spec.statusCode` — the latter is only the Go field name |

Two kinds are excluded, and both exclusions are stated in the PR body and the
issue-closing comment rather than passed over silently:

- **`GatewayParameters`** — no status implemented; the CRD schema says so.
  A check could only ever return a constant.
- **`HTTPListenerPolicy`** — deprecated in 2.4.x in favour of
  `ListenerPolicy.spec.httpSettings`, and already absent from `main`. A check
  would ship for a kind that disappears one minor later.
- **`GatewayExtension`** — **writes no status at all.** Added to this list
  2026-10-06 after the claim was tested rather than assumed: a valid and an
  invalid `GatewayExtension` were created on a live kgateway v2.4.5 cluster and
  neither produced a `status` block after 30s, while the controller logged
  `GatewayExtension handler sync complete` for both. The API declares
  `GatewayExtensionStatus.Conditions` and the CRD carries
  `gatewayextensions/status` RBAC markers, but no code populates it — a
  schema is not evidence that a controller writes it. Same case as
  `GatewayParameters`. Filed as
  [kgateway#14792](https://github.com/kgateway-dev/kgateway/issues/14792) — a
  product gap rather than a design choice; fixing it would unblock a real check
  later.

The upstream PR folds into the branch held from phase 1, so one PR covers all
six kinds. Per the roadmap's delivery model, the `argocd-cm` package ships
first; the PR follows.

---

## Section 2 — Two scripts, not six

### The constraint

argo-cd's Lua VM loads each `health.lua` as a standalone string from an
embedded filesystem. There is no package path and no file loader, so `require`
cannot reach our own code — verified against `util/lua/lua.go`, and no upstream
script uses module loading. The only preloaded module is a stubbed `os`
exposing `time` and `date`.

So logic cannot be shared by importing it. Writing six separate scripts means
six copies of the same logic, and phase 1 already demonstrated the failure mode:
the empty-message bug was fixed in `Backend/health.lua` and left in
`TrafficPolicy/health.lua`, because they were edited independently.

### The approach

Make the scripts **byte-identical** across kinds of the same status shape by
reading `obj.kind` instead of hardcoding the name. The only per-kind difference
in phase 1's scripts is message text like `"Waiting for TrafficPolicy status"`;
written as `"Waiting for " .. obj.kind .. " status"` it renders identically and
the files become interchangeable. 21 upstream checks already do this — flux's
use it for exactly this purpose.

```
healthchecks/lua/
├── ancestors/health.lua    → TrafficPolicy, ListenerPolicy,
│                             BackendConfigPolicy, DirectResponse
└── conditions/health.lua   → Backend
```

A sync script copies each into its kinds' directories under
`out/resource_customizations/`, and a test asserts the copies are byte-identical
to their source. Drift becomes impossible rather than merely discouraged.

No code generation. The file in the repo is the file that ships; there is no
template language to read through, and upstream receives six ordinary per-kind
scripts exactly like every other `resource_customizations` entry.

### What this changes in phase 1's code

Phase 1's two scripts are refactored onto the shared form. This is a change to
already-reviewed, already-passing code, so it needs justifying:

- The change is **behaviour-preserving**. `obj.kind` for a `TrafficPolicy` is
  the string `TrafficPolicy`, so every rendered message is byte-identical.
- The existing 11 fixtures and their expected messages are therefore unchanged,
  and act as the regression test. **If any of the 11 fail after the refactor,
  the refactor is wrong** — not the fixtures.

### Trade-off

If one kind ever needs genuinely divergent logic, it has to fork out of the
shared file at that point. That is a real cost, accepted deliberately: four
hand-maintained copies that drift is the worse failure, and we have already
seen it happen once.

---

## Section 3 — Coverage app and fixtures

### Where the new kinds live

`manifests/demo/` is **not touched**. It stays the minimal narrative — one
workload, two routes, one TrafficPolicy, one Backend — that you can walk a
customer through in two minutes.

A third ArgoCD Application, `kgw-coverage`, manual-sync like `kgw-scenarios`,
holds healthy and deliberately-broken instances of the four new kinds. Its
purpose is to generate status for capture, and its README says so. This keeps
"demo" and "fixture source" as separate concerns.

### Fixture count

Six new fixtures — healthy and degraded for each of the three new kinds — plus
four pinning failure modes that no feature test would otherwise catch. See the
implementation plan's Review Focus for the latter.

The reasoning follows from Section 2. Because the four ancestors kinds share one
byte-identical script, TrafficPolicy's existing 8 fixtures already prove the
logic: precedence, reason branching, controller scoping, staleness gating,
empty-message handling. Per-kind fixtures only need to prove two further things
— that the script is wired to the right kind, and that the kind's real status
matches the shape assumed here. Healthy plus Degraded does both, and the
Degraded fixture captures each kind's actual error text.

A full matrix per kind (~43 fixtures) would re-test identical code paths four
times and invite a reviewer to ask why.

### Probe-first, with confidence stated

Phase 1's probe caught two API errors that would otherwise have shipped as
broken fixtures. The same discipline applies, and the candidate mechanisms
below are **predictions, not observations**:

| Fixture | Candidate mechanism | Confidence |
|---|---|---|
| `ListenerPolicy` healthy | attach to `demo-gateway`'s `http` listener | high |
| `ListenerPolicy` degraded | config that fails translation, e.g. route-level tracing with no listener-level provider | **low — mechanism unverified** |
| `BackendConfigPolicy` healthy | attach to `httpbin-static` with simple TLS or timeout settings | high |
| `BackendConfigPolicy` degraded | TLS config referencing a Secret that does not exist | medium |
| `DirectResponse` healthy | referenced by an HTTPRoute `ExtensionRef` filter; response code goes in `spec.status` | medium — attachment is filter-based, not `targetRefs` |
| `DirectResponse` degraded | referenced by nothing, or an invalid status code / body combination | **low** |

**Two things the probe must establish before any Lua is written:**

1. ~~`GatewayExtension`'s condition vocabulary.~~ **Settled 2026-10-06 by
   testing it: there is no vocabulary, because there is no status.** The kind
   is excluded; see the exclusions above. The earlier decision to add a third
   script rather than drop the kind was made for a situation that does not
   apply — it covered a *differing* vocabulary, not an absent one. A third
   script would have nothing to read.

2. **Whether the three new ancestors kinds really carry `Accepted` + `Attached`
   against a Gateway ancestor**, as `TrafficPolicy` does. `DirectResponse`'s
   printcolumns say yes for it; the other two are assumed.

The governing constraint from phase 1 still applies: **broken manifests must
pass CRD admission but fail translation.** A manifest rejected by admission
produces no resource and therefore no status, which is useless as a fixture.

If a Degraded state turns out to be unreachable for a kind, that is recorded as
a finding — and checked against whether "unreachable" is simply *correct* for
that kind before anyone calls it a kgateway bug.

---

## Section 4 — Delivery

### Order

1. Implement and test against the live cluster via `argocd-cm`.
2. Regenerate `healthchecks/argocd-cm-patch.yaml` — it gains four keys, going
   from two to six.
3. Refresh `docs/evidence/` — the before/after capture now covers six kinds.
4. Ship the **OSS ConfigMap package** with its own documentation (see below).
5. Open the upstream PR.

### The upstream PR

The held branch (`feat/kgateway-health-checks`, local, based on current
`upstream/master`) gains the four new kinds and is rewritten to describe a
**complete** contribution rather than a partial one. Specifically the drafts
must change:

- "partial contribution … the other 6 are tracked as follow-ups" becomes a
  statement of complete coverage with two documented exclusions
- the fixture-provenance section grows to 19
- the issue comment changes from "stays open for the remainder" to closing it

Everything else in the drafts stands: the `Pending`→Progressing divergence from
Envoy Gateway's model, the deliberate `controllerName` scoping and its relation
to argo-cd#29823, and the honest declaration of untested branches
(`EndpointsDiscovered` failure modes, `Accepted=False/Pending`, and the
unrecognised-reason fallback).

### Documentation — a phase 2 deliverable, not an afterthought

The roadmap identifies this as a gap. Phase 2 ships **one** of the four doc
deliverables:

**Product A's ConfigMap package** — for a kgateway user who wants health checks
today. This is product A's package and covers `gateway.kgateway.dev` only; a
SEFK customer additionally applies product B's package, which is out of scope
here and must not be mentioned in any public artifact this phase produces.
Covers: what it does and why ArgoCD shows `(none)` without it; how to apply it;
which six kinds are covered and which two are not, with reasons; what each
health state means for a kgateway resource; the `controller.resource.health.persist`
requirement for CLI verification; and when it is safe to remove, given that
`argocd-cm` entries override bundled checks even after the PR merges.

Product B's package docs are B1's deliverable. The product-docs entries have no
owner yet.

---

## Open questions

- Exact timing of the upstream PR relative to the OSS ConfigMap release. The
  roadmap records both orders as compatible; the decision is Duncan's.
- Whether the OSS package is a documented snippet in this repo, a release
  artifact, or both.
