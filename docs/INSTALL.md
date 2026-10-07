# ArgoCD health checks for kgateway

Teach ArgoCD to report the health of kgateway's `gateway.kgateway.dev` resources, by adding five entries to your `argocd-cm` ConfigMap. No ArgoCD upgrade, no plugin, no restart. Takes about ten minutes, most of it reading.

Tracks [kgateway#13871](https://github.com/kgateway-dev/kgateway/issues/13871). Verified against kgateway v2.4.5 and ArgoCD chart 10.9.2 (see [`env.sh`](../env.sh) for the exact pins).

## The problem

ArgoCD has no built-in health checks for kgateway's custom resources. In the resource tree a `TrafficPolicy` or `Backend` shows no health badge (`(none)` in the CLI), even when kgateway has written a perfectly clear status such as `Accepted=False, reason=Invalid, "Secret httpbin/no-such-tls-secret not found"`.

The missing badge is the lesser problem. ArgoCD derives an Application's health from its resources, and a resource it cannot assess is simply ignored. So an Application whose kgateway policies and backends are all rejected still reports **Healthy**. A sync that deploys a broken `TrafficPolicy` goes green, and any automation gating on Application health (progressive rollouts, sync waves, notifications, `argocd app wait --health`) proceeds as if nothing were wrong.

Real output from the demo in this repo, same cluster, same resources, before and after installing the entries (full captures in [`docs/evidence/`](evidence/)):

```
                                           before        after
Backend/backend-degraded                   (none)        Degraded
TrafficPolicy/tp-degraded                  (none)        Degraded
TrafficPolicy/tp-progressing               (none)        Progressing
BackendConfigPolicy/bcp-degraded           (none)        Degraded
BackendConfigPolicy/bcp-healthy            (none)        Healthy
ListenerPolicy/lp-unattached               (none)        Progressing
DirectResponse/dr-healthy                  (none)        Healthy
```

## Install

**What has been tested.** Executed live: the install, the removal, hard refresh, and the UI-visible result via the Application status. Not executed: the argo-helm (`configs.cm`, `configs.params`) paths, behaviour with `controller.resource.health.persist` unset, the `curl` alternative, and the controller-restart steps. Treat those as higher risk.

You need `kubectl` access to the namespace ArgoCD runs in (`argocd` below) and a copy of the patch file, which is checked into this repo:

```bash
git clone https://github.com/DuncanDoyle/kgateway-argocd-demo.git
cd kgateway-argocd-demo

# Pin to the commit this guide was verified against; `main` may move.
git checkout d034785778416113695a3f7b2f339bbd6c14f2e5

# This file contains Lua that will run inside your ArgoCD. Read it first.
less healthchecks/argocd-cm-patch.yaml

# Adds five resource.customizations.health.gateway.kgateway.dev_<Kind> keys
# to argocd-cm. A merge patch: your other argocd-cm keys are untouched.
kubectl -n argocd patch configmap argocd-cm \
  --patch-file healthchecks/argocd-cm-patch.yaml
```

Without cloning, download just the file: `curl -sLO https://raw.githubusercontent.com/DuncanDoyle/kgateway-argocd-demo/d034785778416113695a3f7b2f339bbd6c14f2e5/healthchecks/argocd-cm-patch.yaml`. Either way, review the file before applying it: it is Lua executed by your ArgoCD application controller.

ArgoCD reads `argocd-cm` live, so nothing needs restarting. But **Applications cache per-resource health and do not re-evaluate it when `argocd-cm` changes**; badges stay blank until the next reconcile, which can be minutes away. Force it:

```bash
# Hard-refresh each Application that contains kgateway resources.
kubectl -n argocd annotate application <your-app> \
  argocd.argoproj.io/refresh=hard --overwrite
```

(In the UI: the Application's Refresh button, "Hard Refresh".) Within a few seconds the badges appear.

Overrides in `argocd-cm` take precedence over anything ArgoCD later bundles, so read [When it is safe to remove](#when-it-is-safe-to-remove) before you forget these are installed.

If you manage `argocd-cm` declaratively (the argo-helm chart, a GitOps repo, Kustomize), the patch will be reverted the next time that source is applied. Put the five keys in that source instead; for argo-helm they go under `configs.cm`.

## What is covered

Five kinds, all in the `gateway.kgateway.dev` group:

| Kind | Status shape |
|---|---|
| `Backend` | `status.conditions[]` (`Accepted`, `EndpointsDiscovered`) |
| `TrafficPolicy` | `status.ancestors[].conditions[]` (`Accepted`, `Attached`) |
| `ListenerPolicy` | same |
| `BackendConfigPolicy` | same |
| `DirectResponse` | same |

### Not covered, and why

These three have no check, each for a different reason. If one of them shows no badge after installing, that is expected.

- **`GatewayParameters`** has no status. The CRD schema says so outright, so there is nothing for a health check to read.
- **`HTTPListenerPolicy`** is deprecated as of kgateway 2.4.x in favour of `ListenerPolicy.spec.httpSettings`, and is already gone from kgateway `main`. A check would ship for a kind that disappears. Migrate to `ListenerPolicy`, which is covered.
- **`GatewayExtension`** writes no status at all. This was verified on a live v2.4.5 cluster: a valid and an invalid instance both ended up with no `status` block while the controller logged successful reconciliation. Until kgateway populates it there is nothing to check; it is tracked in [kgateway#14792](https://github.com/kgateway-dev/kgateway/issues/14792).

## What each health state means

The checks read only conditions written by the kgateway controller (`controllerName: kgateway.dev/kgateway`); status written by other controllers is ignored. The message on the badge is taken from the kgateway condition, so it normally says what is wrong.

| State | Meaning | Typical causes |
|---|---|---|
| **Healthy** | kgateway accepted the resource (`Accepted=True`) and, for policies, attached it (`Attached=True`). | Normal operation. |
| **Degraded** | kgateway rejected the resource, or part of it: a condition with reason `Invalid`, `PartiallyValid` or `Overridden`, or any other `False` condition except `Pending`. For `Backend`, any failing `Accepted` or `EndpointsDiscovered` condition. | A reference to a Secret or Service that does not exist (for example `BackendConfigPolicy.spec.tls.secretRef`, or a `ListenerPolicy` access log backend); an invalid spec; a policy overridden by another. |
| **Progressing** | kgateway has not reached a verdict yet. Reason `Pending`; status that describes an older `metadata.generation` than the current spec; or no status at all. | Just applied, or just edited. Also **a policy that attaches to nothing**: a `ListenerPolicy` targeting a Gateway that does not exist, or a `DirectResponse` no route references, gets no `status` from kgateway and so stays Progressing indefinitely. |

Two things worth knowing:

- **A Degraded policy often takes its target down with it.** A broken `BackendConfigPolicy` also marks the `Backend` it targets `Accepted=False`; a broken `ListenerPolicy` does the same to its `Gateway`. You will see both go Degraded; the policy is the one to fix. The error is per target, so a healthy sibling policy stays Healthy.
- **Not every dangling reference is caught by kgateway.** On v2.4.5, a missing Secret or Service is rejected, but a missing ConfigMap in `ListenerPolicy` `caCertificateRefs` is accepted, so that policy is Healthy. The health check reports what kgateway reports; it cannot see further than kgateway does. The demo's [`COVERAGE.md`](../COVERAGE.md) records the observed status of every case.

A stuck Progressing on a policy is the signal most worth investigating: "Waiting for ListenerPolicy status" means kgateway did not find anything to attach it to.

## Verifying it

### In the UI

Open the Application. Each kgateway resource has a health icon; the badge message appears on hover. This works with no extra configuration.

### From the CLI

```bash
kubectl -n argocd get application <your-app> \
  -o jsonpath='{range .status.resources[?(@.group=="gateway.kgateway.dev")]}{.kind}{"/"}{.name}{" -> "}{.health.status}{"\n"}{end}'
```

This path reads `Application.status.resources[].health`, and **ArgoCD does not write that field by default** (true of ArgoCD 3.x, which is what this was verified on, chart 10.9.2; 2.x defaulted the other way, so on 2.x you may not need the setting). The 3.x default (`resourceHealthSource: appTree`) keeps per-resource health only in the UI's resource tree. With the default, the command above prints every resource with an empty health, whether or not the checks work. Do not read that as a failed install.

To make the CLI path work, enable persistence in `argocd-cmd-params-cm` and restart the application controller:

```bash
kubectl -n argocd patch configmap argocd-cmd-params-cm --type=merge \
  -p '{"data":{"controller.resource.health.persist":"true"}}'
kubectl -n argocd rollout restart statefulset argo-cd-argocd-application-controller   # name varies by install
kubectl -n argocd rollout status statefulset argo-cd-argocd-application-controller
```

(With argo-helm: `configs.params."controller.resource.health.persist": "true"`, and the chart restarts the controller for you.) Then hard-refresh the Application again. To summarise: the **UI never needs this**; only reading health from `kubectl` does. Note that the Application's own overall health (`status.health.status`) is computed either way, so `kubectl get application` shows the rolled-up result without it.

## When it is safe to remove

These entries are an override, and they stay valid after ArgoCD ships its own kgateway checks. The intent is to propose these checks upstream to `argoproj/argo-cd`, but nothing is filed or scheduled yet, so there is no release to wait for. If and when ArgoCD does ship kgateway checks, you have a choice:

- **Do nothing.** Your `argocd-cm` entries keep working indefinitely.
- **Switch to ArgoCD's bundled checks**, by deleting these keys. Check the release notes of the ArgoCD version you run, confirm it includes `gateway.kgateway.dev` checks, then:

```bash
# Remove all five keys. Absent keys are an error to the JSON patch, hence the guard.
for k in Backend TrafficPolicy ListenerPolicy BackendConfigPolicy DirectResponse; do
  key="resource.customizations.health.gateway.kgateway.dev_${k}"
  if kubectl -n argocd get cm argocd-cm -o json | jq -e --arg key "$key" '.data | has($key)' >/dev/null; then
    kubectl -n argocd patch cm argocd-cm --type=json \
      -p "[{\"op\":\"remove\",\"path\":\"/data/${key}\"}]"
  fi
done
kubectl -n argocd annotate application <your-app> argocd.argoproj.io/refresh=hard --overwrite
```

`argocd-cm` entries take precedence over bundled checks. **Upgrading ArgoCD to a version that bundles its own checks does not switch you over, and nothing will warn you**: these entries keep silently winning, so you will never see any difference in the bundled version's behaviour, or its fixes, until the keys are deleted.

Removing the keys without a bundled replacement puts you back in the situation described at the top: no badges, and Applications reporting Healthy over rejected resources.

## Regenerating and testing

The health scripts are tested with argo-cd's own Lua test harness against fixtures captured from a real cluster. See the [README](../README.md) for how to run it, regenerate the before/after evidence, and use `hack/check-generated.sh` to confirm the patch file matches the scripts.
