# Coverage probe: observed status on kgateway v2.4.5

Everything below was observed on the live cluster (minikube `kgw-argocd`), not predicted. `GatewayExtension` is out of scope (writes no status on v2.4.5).

## CRD spec fields (Step 1)

- ListenerPolicy: `default, perPort, targetRefs, targetSelectors`
- BackendConfigPolicy: `circuitBreakers, commonHttpProtocolOptions, connectTimeout, dns, healthCheck, http1ProtocolOptions, http2ProtocolOptions, loadBalancer, outlierDetection, perConnectionBufferLimitBytes, targetRefs, targetSelectors, tcpKeepalive, tls, upstreamProxyProtocol` (`tls.secretRef` exists)
- DirectResponse: `body, bodyFormat, status`

## Predicted vs observed

| Resource | Predicted | Observed |
|---|---|---|
| ListenerPolicy `lp-healthy` | Accepted+Attached True | As predicted. Ancestor is Gateway `httpbin/demo-gateway`. |
| ListenerPolicy `lp-unattached` | No status (Progressing) | **No `status` at all**, still none after 60s. |
| BackendConfigPolicy `bcp-healthy` | Accepted+Attached True | As predicted. Ancestor is the **Backend** `httpbin/coverage-backend` (`group: gateway.kgateway.dev`), not a Gateway. |
| BackendConfigPolicy `bcp-degraded` | Degraded | Reached: `Accepted=False/Invalid` ("failed to extract TLS data: Secret httpbin/no-such-tls-secret not found"), `Attached=False/Pending` (empty message). |
| DirectResponse `dr-healthy` | Accepted+Attached True | As predicted. Ancestor is Gateway `httpbin/demo-gateway` (not the HTTPRoute). |
| DirectResponse `dr-unreferenced` | No status (Progressing) | **No `status` at all**, still none after 60s. |

Full status YAML: `out/probe/a2-status.txt` (first run; BackendConfigPolicy ancestorRef there names `httpbin-static`, superseded) and `out/probe/a2-status-bcp-v2.txt` (current, targets `coverage-backend`). Both are in the task report.

## Blocking question: do the three kinds carry Accepted + Attached against a Gateway ancestor?

Accepted and Attached, yes: all three write `status.ancestors[]` with `controllerName: kgateway.dev/kgateway` and condition types `Accepted` and `Attached`, reasons `Valid`/`Attached` when healthy. Gateway ancestor, **no for BackendConfigPolicy**: its `ancestorRef` is `kind: Backend, group: gateway.kgateway.dev`. Condition types and healthy reasons are the ones the shared ancestors script already expects; the unhealthy reasons seen are `Invalid` (Accepted) and `Pending` (Attached). Whether the shared script handles a non-Gateway ancestorRef and `Pending` is for Tasks 3/4 to check.

## Findings

1. **No Degraded for ListenerPolicy or DirectResponse.** An unattached/unreferenced instance gets no status at all: the controller only writes ancestors once something attaches. This looks correct for these kinds (nothing to report against) rather than a bug. The health script must treat "no status" as Progressing, and the fixtures for these two kinds have no Degraded; the "unhealthy" fixture is the empty-status one.
2. **BackendConfigPolicy is the only reachable Degraded**, via a missing TLS Secret.
3. **A BackendConfigPolicy error surfaces on the targeted Backend's own status, not only on the policy's.** With `bcp-degraded` targeting the demo's `Backend/httpbin-static`, that Backend went `Accepted=False/Invalid` with message `Backend error: "gateway.kgateway.dev/BackendConfigPolicy/httpbin/bcp-degraded: failed to extract TLS data: Secret httpbin/no-such-tls-secret not found"`, `kgw-demo` went Degraded, and the tracked `Backend/testdata/healthy.yaml` source was corrupted. Coverage resources must therefore never target demo resources. The first version of the manifests did, and was fixed by giving the coverage app its own `Backend/coverage-backend`.
4. **Recovery.** After the fix synced, `httpbin-static` returned to `Accepted=True/Accepted`, message `Backend accepted`, `observedGeneration: 21`, identical to the tracked fixture apart from `lastTransitionTime` (2026-10-07T08:20:04Z). `kgw-demo` is Synced/Healthy again; `kgw-scenarios` is still Synced/Degraded.
5. **The error is per-Backend, not per-policy.** `bcp-healthy` and `bcp-degraded` both target `coverage-backend`; the healthy policy stays Accepted+Attached True while the Backend itself is `Accepted=False/Invalid` because of its sibling. Consequently `kgw-coverage` is Synced/**Degraded** (the Backend is degraded) once the health scripts exist; this is expected.
6. **Hazard, untested for the other kinds.** `Gateway/demo-gateway` is clean (Accepted, Programmed, ResolvedRefs all True) and `lp-healthy`/`dr-healthy` are healthy, so nothing was corrupted. Whether a failing ListenerPolicy would propagate onto the Gateway the way BackendConfigPolicy does onto the Backend was NOT tested (no Degraded state was reachable). Anyone extending the coverage app with a failing policy must give it its own target.
7. `kgw-coverage` reports Healthy only while no health checks exist for these kinds (observed in the first run); with `coverage-backend` degraded it now shows Degraded via the existing Backend check.

## Fixtures available (for the next task: name files after the state captured)

| Kind | Healthy source | Second fixture available |
|---|---|---|
| ListenerPolicy | `lp-healthy` | **no-status** (`lp-unattached`). No degraded capture exists. |
| BackendConfigPolicy | `bcp-healthy` | **degraded** (`bcp-degraded`: Accepted=False/Invalid, Attached=False/Pending) |
| DirectResponse | `dr-healthy` | **no-status** (`dr-unreferenced`). No degraded capture exists. |

Note: `bcp-healthy` ancestorRef is a Backend (`coverage-backend`), not a Gateway.
