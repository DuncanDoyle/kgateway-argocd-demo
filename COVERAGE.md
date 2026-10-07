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
| BackendConfigPolicy `bcp-healthy` | Accepted+Attached True | As predicted. Ancestor is the **Backend** `httpbin/httpbin-static` (`group: gateway.kgateway.dev`), not a Gateway. |
| BackendConfigPolicy `bcp-degraded` | Degraded | Reached: `Accepted=False/Invalid` ("failed to extract TLS data: Secret httpbin/no-such-tls-secret not found"), `Attached=False/Pending` (empty message). |
| DirectResponse `dr-healthy` | Accepted+Attached True | As predicted. Ancestor is Gateway `httpbin/demo-gateway` (not the HTTPRoute). |
| DirectResponse `dr-unreferenced` | No status (Progressing) | **No `status` at all**, still none after 60s. |

Full status YAML for each is in `out/probe/a2-status.txt` and the task report.

## Blocking question: do the three kinds carry Accepted + Attached against a Gateway ancestor?

Accepted and Attached, yes: all three write `status.ancestors[]` with `controllerName: kgateway.dev/kgateway` and condition types `Accepted` and `Attached`, reasons `Valid`/`Attached` when healthy. Gateway ancestor, **no for BackendConfigPolicy**: its `ancestorRef` is `kind: Backend, group: gateway.kgateway.dev`. Condition types and healthy reasons are the ones the shared ancestors script already expects; the unhealthy reasons seen are `Invalid` (Accepted) and `Pending` (Attached). Whether the shared script handles a non-Gateway ancestorRef and `Pending` is for Tasks 3/4 to check.

## Findings

1. **No Degraded for ListenerPolicy or DirectResponse.** An unattached/unreferenced instance gets no status at all: the controller only writes ancestors once something attaches. This looks correct for these kinds (nothing to report against) rather than a bug. The health script must treat "no status" as Progressing, and the fixtures for these two kinds have no Degraded; the "unhealthy" fixture is the empty-status one.
2. **BackendConfigPolicy is the only reachable Degraded**, via a missing TLS Secret.
3. **Side effect on the demo app.** `bcp-degraded` targets the demo's `Backend/httpbin-static`, and the `Backend` health check surfaces the policy error: `Backend error: "gateway.kgateway.dev/BackendConfigPolicy/httpbin/bcp-degraded: failed to extract TLS data: ..."`. This turned `kgw-demo` from Synced/Healthy to **Synced/Degraded**. The coverage fixture must target its own Backend, not the demo's.
4. `kgw-coverage` itself reports Healthy because no health checks for these kinds exist yet (default treats them as healthy).
