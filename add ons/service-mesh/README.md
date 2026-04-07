<p align="center">
  <img src="https://www.open-emr.org/images/openemr-blue-logo.png" alt="OpenEMR Logo" width="300">
</p>

# OpenEMR Service Mesh — Zero Trust Networking

[![OpenShift Service Mesh](https://img.shields.io/badge/Service%20Mesh-3.x-EE0000?style=flat-square&logo=redhatopenshift&logoColor=white)](https://docs.openshift.com/container-platform/latest/service_mesh/v3x/ossm-about.html)
[![Istio Ambient](https://img.shields.io/badge/Istio-Ambient%20Mode-466BB0?style=flat-square&logo=istio&logoColor=white)](https://istio.io/latest/docs/ambient/)
[![mTLS](https://img.shields.io/badge/mTLS-Auto%20via%20ztunnel-brightgreen?style=flat-square)](https://istio.io/latest/docs/concepts/security/)

Zero-trust networking layer for [OpenEMR on OpenShift](https://github.com/ryannix123/openemr-on-openshift) using **OpenShift Service Mesh 3 in ambient mode**. Provides mutual TLS, identity-based authorization, network isolation, and egress control — without sidecar injection.

> ⚠️ **Developer Sandbox not supported.** OSSM 3 requires cluster-admin for Sail Operator installation and IstioCNI (a node-level DaemonSet). Use a full OpenShift cluster or Single Node OpenShift (SNO).

## Why Ambient Mode?

OSSM 3 drops the traditional sidecar model in favor of **ambient mesh**:

| | Sidecar (OSSM 2.x) | Ambient (OSSM 3) |
|---|---|---|
| Data plane | Envoy injected per pod | ztunnel (per node) + waypoint (per namespace) |
| Pod restart needed | Yes — for injection | **No** — label the namespace |
| Resource overhead | High (sidecar per pod) | Low (shared ztunnel DaemonSet) |
| mTLS | Configured via PeerAuthentication | **Automatic** — ztunnel always encrypts |
| L7 policies | Sidecar enforces | Waypoint proxy enforces |

For a healthcare workload like OpenEMR, ambient mode means:
- MariaDB and Redis traffic is **automatically mTLS-encrypted** without any pod changes
- No risk of pods running without sidecars (a common misconfiguration in sidecar mode)
- Faster rollout — mesh enrollment is a namespace label, no pod restart required

## Architecture

```
                    ┌──────────────────────────────────┐
                    │    OpenShift Router / Ingress     │
                    │    (TLS termination at edge)      │
                    └──────────────┬───────────────────┘
                                   │ HBONE tunnel (ztunnel)
          ╔════════════════════════╪══════════════════════════════╗
          ║  <namespace>           │   Ambient Mesh enforced      ║
          ║                        ▼                              ║
          ║         ┌──────────────────────────┐                  ║
          ║         │      Waypoint Proxy       │ ← L7 AuthzPolicy║
          ║         │  (Gateway API / Envoy)    │   enforced here  ║
          ║         └──────┬─────────────┬──────┘                  ║
          ║                │             │                         ║
          ║    ztunnel 🔒  │  mTLS/HBONE │  🔒 ztunnel            ║
          ║    (auto-encrypts all traffic)                         ║
          ║                │             │                         ║
          ║    ┌───────────▼──┐  ┌───────▼──────────┐             ║
          ║    │   OpenEMR    │  │   MariaDB/Redis   │             ║
          ║    │  (no sidecar)│  │   (no sidecar)    │             ║
          ║    └──────────────┘  └───────────────────┘             ║
          ║                                                        ║
          ║  Node: ztunnel DaemonSet intercepts all pod traffic    ║
          ║  transparently — pods are unaware of the mesh          ║
          ║                                                        ║
          ║    ┌─────────────────────────────────────────────┐     ║
          ║    │            Egress Firewall (OVN)             │     ║
          ║    │  ✓ quay.io, docker.io, open-emr.org         │     ║
          ║    │  ✗ Everything else DENIED                    │     ║
          ║    └─────────────────────────────────────────────┘     ║
          ╚════════════════════════════════════════════════════════╝
```

### Ambient Mode Data Plane — Two Layers

**ztunnel** (per-node DaemonSet):
- Intercepts all pod traffic at the Linux network namespace level
- Provides L4 mTLS (HBONE protocol) automatically for all enrolled pods
- Enforces L4 AuthorizationPolicies (source IP, port, service account)
- Zero pod configuration required

**Waypoint proxy** (Envoy, per-namespace Deployment):
- Required for L7 policy enforcement (HTTP methods, headers, JWT claims)
- Created via Gateway API (`gatewayClassName: istio-waypoint`)
- Only deployed where L7 policies are needed — keeps overhead low

## Prerequisites

- **OpenShift 4.15+** with cluster-admin access (4.15+ required for correct router NetworkPolicy label)
- **OVN-Kubernetes CNI** (default on OpenShift 4.12+)
- **OVN-K local gateway mode enabled** — required for ztunnel to intercept inbound traffic (see note below)
- **OpenEMR deployed** via [openemr-on-openshift](https://github.com/ryannix123/openemr-on-openshift)

The deploy script handles all operator and CRD installation automatically. No manual OperatorHub steps are required.

> ⚠️ **OVN-K local gateway mode is required.** Without `routingViaHost: true`, the OpenShift router can reach pods but ztunnel never intercepts the traffic, causing 408 timeouts. This is a one-time cluster-level change that triggers a node reboot on SNO:
> ```bash
> oc patch network.operator.openshift.io cluster --type=merge \
>   -p='{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"gatewayConfig":{"routingViaHost":true}}}}}'
> # Verify:
> oc get network.operator.openshift.io cluster \
>   -o jsonpath='{.spec.defaultNetwork.ovnKubernetesConfig.gatewayConfig}'; echo
> ```

## Privilege Requirements

Ambient mode has a better privilege story than OSSM 2.x sidecars. The distinction is between one-time cluster infrastructure (requires cluster-admin) and ongoing application workloads (no elevation needed).

**Requires cluster-admin — performed once by `deploy-mesh.sh`:**
- Installing the Sail and Kiali Operators via OLM
- Creating the `Istio`, `IstioCNI`, and `ZTunnel` CRs
- The `ztunnel` DaemonSet runs privileged at the node level to intercept traffic outside of pods — this is the root reason the Developer Sandbox is unsupported

**One-time RBAC grant — cluster-admin runs once per user:**

Labeling a namespace is a cluster-scoped operation. Regular users need a ClusterRole binding to enroll namespaces in ambient mode:

```bash
oc apply -f - <<EOF2
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ambient-namespace-enroller
rules:
- apiGroups: [""]
  resources: ["namespaces"]
  verbs: ["get", "list", "patch", "update"]
EOF2

oc adm policy add-cluster-role-to-user ambient-namespace-enroller <username>
```

After this grant, the user can run `deploy-mesh.sh --policies` or `ansible-playbook deploy-mesh.yml -e "action=policies"` without cluster-admin.

**No elevated privileges required — regular namespace users:**
- OpenEMR, MariaDB, and Redis pods run completely unmodified under OpenShift's standard **restricted SCC** — the mesh is transparent to them
- `AuthorizationPolicy`, `NetworkPolicy`, and `Gateway` resources can be managed by namespace-scoped users with appropriate RBAC

This is a meaningful improvement over OSSM 2.x, where sidecar injection required `NET_ADMIN` capabilities inside each pod, which frequently conflicted with OpenShift's restricted SCCs and needed annotation workarounds. In ambient mode, ztunnel handles all traffic interception at the node level — entirely outside the pod — so application workloads need no special permissions.

**Additional one-time RBAC grants for non-admin deployment users:**

Namespace labeling (ambient enrollment + waypoint) requires a ClusterRole grant. Run these once as cluster-admin:

```bash
# 1. Allow user to label namespaces for ambient enrollment and use-waypoint
oc apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ambient-namespace-enroller
rules:
- apiGroups: [""]
  resources: ["namespaces"]
  verbs: ["get", "list", "patch", "update"]
EOF
oc adm policy add-cluster-role-to-user ambient-namespace-enroller <username>

# 2. Allow user to manage mesh resources in the target namespace
oc apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: mesh-deployer
  namespace: openemr
rules:
- apiGroups: ["gateway.networking.k8s.io"]
  resources: ["gateways"]
  verbs: ["get", "list", "create", "update", "patch", "delete"]
- apiGroups: ["security.istio.io"]
  resources: ["authorizationpolicies"]
  verbs: ["get", "list", "create", "update", "patch", "delete"]
- apiGroups: ["networking.k8s.io"]
  resources: ["networkpolicies"]
  verbs: ["get", "list", "create", "update", "patch", "delete"]
- apiGroups: ["k8s.ovn.org"]
  resources: ["egressfirewalls"]
  verbs: ["get", "list", "create", "update", "patch", "delete"]
EOF
# Use oc create rolebinding (NOT oc adm policy add-role-to-user — that creates a
# ClusterRoleBinding when the Role is not found at cluster scope)
oc create rolebinding mesh-deployer --role=mesh-deployer --user=<username> --namespace=openemr
```

## Quick Start

```bash
git clone https://github.com/ryannix123/openemr-on-openshift.git
cd openemr-on-openshift/service-mesh
chmod +x deploy-mesh.sh

# Full install — operators, control plane, policies, and Kiali in one shot
./deploy-mesh.sh --full

# If OpenEMR is deployed in a namespace other than 'openemr':
OPENEMR_NAMESPACE=my-emr ./deploy-mesh.sh --full

# Check status at any time
./deploy-mesh.sh --status
```

### Staged Deployment

Useful when OpenEMR is being deployed to a fresh cluster alongside the mesh, or when you want to verify each phase before proceeding:

```bash
# 1. Install Sail Operator, Kiali Operator, and Gateway API CRDs
./deploy-mesh.sh --operators

# 2. Deploy OpenEMR (if not already running)
#    cd .. && ./deploy-openemr.sh

# 3. Deploy Istio control plane and enroll the namespace
./deploy-mesh.sh --control-plane

# 4. Apply waypoint, AuthorizationPolicies, NetworkPolicies, and EgressFirewall
./deploy-mesh.sh --policies
```

### Other Options

```bash
./deploy-mesh.sh --netpol-only      # NetworkPolicies only (no mesh operators required)
./deploy-mesh.sh --egress-only      # EgressFirewall only
./deploy-mesh.sh --monitoring-only  # PodMonitor + Prometheus RBAC only (re-apply if Kiali graph is empty)
./deploy-mesh.sh --cleanup          # Remove mesh config from namespace (keep control plane)
```

## What Gets Deployed

| File | Purpose |
|------|---------|
| `00-sail-operator.yaml` | OLM Subscription — installs the Sail Operator (OSSM 3) from `redhat-operators` |
| `00-kiali-operator.yaml` | OLM Subscription + Kiali CR — installs Kiali Operator and creates a Kiali instance |
| `01-istio.yaml` | `Istio` CR — Sail Operator deploys Istiod with the ambient profile |
| `02-ztunnel.yaml` | `IstioCNI` CR (CNI plugin) + `ZTunnel` CR (ztunnel DaemonSet) — both use `sailoperator.io/v1` |
| `03-namespace.yaml` | Target namespace labeled `istio.io/dataplane-mode: ambient` |
| `04-waypoint.yaml` | Gateway API `Gateway` CR — deploys waypoint proxy for L7 policy enforcement |
| `05-authz-policies.yaml` | AuthorizationPolicies — default deny + identity-based allow rules enforced by ztunnel (L4). No `targetRef` — adding a waypoint later upgrades enforcement to L7 automatically |
| `06-network-policies.yaml` | NetworkPolicy — allow-all ingress; enforcement fully delegated to ztunnel AuthorizationPolicies (see note below) |
| `07-egress-firewall.yaml` | EgressFirewall — restricts outbound connections to an explicit allow-list |
| `08-monitoring.yaml` | PodMonitor + Prometheus RBAC — enables Kiali traffic graph by scraping waypoint Envoy metrics |

> **Why allow-all NetworkPolicy?** In ambient mode, ztunnel intercepts all pod traffic at the node level using HBONE tunnels. From the Kubernetes NetworkPolicy controller's perspective, every inbound packet appears to come from ztunnel — not from the original source pod or namespace. Per-service allow rules (e.g., "allow router → openemr:8080") never match because the actual source is always ztunnel. The mesh AuthorizationPolicies in `05-authz-policies.yaml` provide equivalent or stronger enforcement using SPIFFE workload identities rather than IP addresses. See the [Istio ambient NetworkPolicy docs](https://istio.io/latest/docs/ambient/usage/networkpolicy/) for details.

The Gateway API CRDs (`gateways.gateway.networking.k8s.io`, `httproutes.gateway.networking.k8s.io`) are fetched from the upstream GitHub release at deploy time and are not stored as manifest files.

### Namespace Templating

All manifests use `openemr` as a placeholder namespace. The deploy script rewrites namespace references at apply time using the `OPENEMR_NAMESPACE` environment variable — no manifest files are modified on disk. This includes `namespace:` metadata fields, SPIFFE identity URIs (`cluster.local/ns/<namespace>/sa/default`), and the Kiali `accessible_namespaces` list.

## Key Differences from OSSM 2.x

| OSSM 2.x | OSSM 3 Ambient | Notes |
|---|---|---|
| `ServiceMeshControlPlane` | `Istio` CR | Different CRD, different operator (Sail) |
| `ServiceMeshMemberRoll` | Namespace label | `istio.io/dataplane-mode: ambient` |
| `sidecar.istio.io/inject: "true"` annotation | Not needed | ztunnel handles enrollment |
| `PeerAuthentication` (strict mTLS) | Not needed | ztunnel always encrypts |
| `Sidecar` scope resources | Not needed | No sidecars |
| AuthorizationPolicy targeting pods | AuthorizationPolicy without `targetRef` | ztunnel enforces L4; add waypoint for L7 |
| 2/2 pod containers | 1/1 pod containers | No sidecar container |

## Verifying the Mesh

Set `NS` to your target namespace before running these commands:

```bash
NS="${OPENEMR_NAMESPACE:-openemr}"
```

### Check ztunnel is intercepting traffic

```bash
# Pods should show the ambient redirection annotation
oc get pod -n "$NS" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.ambient\.istio\.io/redirection}{"\n"}{end}'
# Expected: enabled

# View ztunnel's view of enrolled workloads
oc exec -n istio-system ds/ztunnel -- pilot-agent request GET /config_dump | jq '.workloads'
```

### Verify mTLS is active (L4)

```bash
# ztunnel logs show HBONE connections for your namespace
oc logs -n istio-system ds/ztunnel -c ztunnel | grep "$NS" | head -20
```

### Verify the waypoint is enforcing L7 policies

```bash
# Check waypoint pod is running
oc get pod -n "$NS" -l gateway.istio.io/managed=istio.io-mesh-controller

# Watch waypoint access logs during a test request
oc logs -n "$NS" -l gateway.istio.io/managed=istio.io-mesh-controller -f
```

### Test that AuthorizationPolicies are blocking unauthorized access

```bash
# This should be DENIED — a random pod attempting to reach MariaDB directly
oc run test-denial --image=nicolaka/netshoot -it --rm --restart=Never -n "$NS" -- \
  nc -zv mariadb 3306
# Expected: connection refused or timeout (RBAC deny in waypoint logs)
```

## Observability

Kiali and Grafana are deployed automatically by `./deploy-mesh.sh --full`. After deployment:

```bash
oc get route kiali -n istio-system -o jsonpath='https://{.spec.host}'; echo
oc get route grafana-route -n istio-system -o jsonpath='https://{.spec.host}'; echo
```

### How the Kiali traffic graph works

Kiali's traffic graph is powered by `istio_requests_total` Prometheus metrics emitted by the **waypoint proxy** (Envoy). Getting this working on OpenShift requires four things all being true simultaneously:

| Requirement | How it's handled |
|---|---|
| `istio.io/waypoint-for: all` on the Gateway | `04-waypoint.yaml` — must be `all` not `service` |
| `istio.io/use-waypoint=waypoint` label + annotation on namespace | `deploy-mesh.sh enroll_namespace()` |
| User-workload monitoring enabled | `08-monitoring.yaml` + `cluster-monitoring-config` |
| PodMonitor scraping port 15090 + Prometheus RBAC | `08-monitoring.yaml` |

If any one of these is missing, the graph stays empty even though traffic is flowing correctly through the mesh.

> **`waypoint-for: all` is critical.** The default `service` value only intercepts traffic to ClusterIP addresses. Pod-to-pod traffic bypasses the waypoint entirely, no L7 metrics are generated, and Kiali shows nothing. Setting `all` forces ztunnel to route all traffic through the waypoint.

> **Kiali queries Thanos, not Prometheus directly.** The Kiali CR is pre-configured to use `thanos-querier.openshift-monitoring.svc.cluster.local:9091`. The kiali-service-account needs `cluster-monitoring-view` to authenticate — `deploy-mesh.sh` applies this automatically.

After a fresh deploy, allow ~60 seconds for the first Prometheus scrape before expecting data in the graph. Use "Last 5m" or longer as the time window — "Last 1m" may show nothing if traffic was sparse.

For distributed tracing, deploy **Tempo** (Jaeger is deprecated in OSSM 3) from OperatorHub and configure the `external_services.tracing` section of the Kiali CR in `manifests/00-kiali-operator.yaml`.

## Troubleshooting

### Kiali traffic graph is empty / shows no edges

Even with traffic flowing, the graph can stay empty. Work through this checklist:

```bash
NS="${OPENEMR_NAMESPACE:-openemr}"

# 1. Is waypoint-for set to "all"?
oc get gateway waypoint -n "$NS" -o jsonpath='{.metadata.labels.istio\.io/waypoint-for}'; echo
# Must be: all  (not "service" or "namespace")
# Fix: oc annotate gateway waypoint -n "$NS" istio.io/waypoint-for=all --overwrite

# 2. Is use-waypoint set on the namespace?
oc get namespace "$NS" -o jsonpath='{.metadata.labels.istio\.io/use-waypoint}'; echo
# Must be: waypoint
# Fix: oc label namespace "$NS" istio.io/use-waypoint=waypoint --overwrite
#      oc annotate namespace "$NS" istio.io/use-waypoint=waypoint --overwrite

# 3. Is ztunnel actually routing through the waypoint?
oc logs -n istio-system ds/ztunnel | grep "$NS" | grep waypoint | tail -5
# Must show: dst.workload="waypoint-..." — if missing, bounce the pods:
# oc delete pod --all -n "$NS"

# 4. Is Prometheus scraping the waypoint?
oc exec -n openshift-user-workload-monitoring pod/prometheus-user-workload-0   -c prometheus --   curl -sg 'http://localhost:9090/api/v1/targets?state=active'   | python3 -m json.tool | grep -A3 openemr
# Must show a target — if empty, re-apply 08-monitoring.yaml:
# ./deploy-mesh.sh --monitoring-only

# 5. Does Prometheus have the metric yet?
oc exec -n openshift-user-workload-monitoring pod/prometheus-user-workload-0   -c prometheus --   curl -sg "http://localhost:9090/api/v1/query?query=istio_requests_total{namespace=\"$NS\"}"   | python3 -m json.tool | grep -c result
# Must be > 0 — if 0, wait 60s after fixing #4 and try again
```

### Readiness probes failing / pods not becoming ready

In ambient mode, kubelet health probes (readiness, liveness, startup) originate from the node IP with no SPIFFE identity. If a `deny-all` AuthorizationPolicy is active, ztunnel blocks probe traffic because it has no matching ALLOW policy.

**Fix: switch to `exec`-based probes** that run inside the container and bypass ztunnel entirely:

```bash
# MariaDB
oc patch deployment mariadb -n openemr --type=json -p='[
  {"op": "replace", "path": "/spec/template/spec/containers/0/readinessProbe", "value": {
    "exec": {"command": ["sh", "-c", "mysqladmin ping -h 127.0.0.1 -u root -p${MYSQL_ROOT_PASSWORD} 2>/dev/null"]},
    "initialDelaySeconds": 5, "periodSeconds": 10, "failureThreshold": 3
  }},
  {"op": "replace", "path": "/spec/template/spec/containers/0/livenessProbe", "value": {
    "exec": {"command": ["sh", "-c", "mysqladmin ping -h 127.0.0.1 -u root -p${MYSQL_ROOT_PASSWORD} 2>/dev/null"]},
    "initialDelaySeconds": 30, "periodSeconds": 10, "failureThreshold": 3
  }}
]'

# OpenEMR (all three probe types must be patched — startup probe is also http-get by default)
oc patch deployment openemr -n openemr --type=json -p='[
  {"op": "replace", "path": "/spec/template/spec/containers/0/readinessProbe", "value": {
    "exec": {"command": ["sh", "-c", "curl -sf http://localhost:8080/health || exit 1"]},
    "initialDelaySeconds": 10, "periodSeconds": 10, "failureThreshold": 3, "timeoutSeconds": 5
  }},
  {"op": "replace", "path": "/spec/template/spec/containers/0/livenessProbe", "value": {
    "exec": {"command": ["sh", "-c", "curl -sf http://localhost:8080/health || exit 1"]},
    "initialDelaySeconds": 30, "periodSeconds": 10, "failureThreshold": 3, "timeoutSeconds": 5
  }},
  {"op": "replace", "path": "/spec/template/spec/containers/0/startupProbe", "value": {
    "exec": {"command": ["sh", "-c", "curl -sf http://localhost:8080/health || exit 1"]},
    "initialDelaySeconds": 10, "periodSeconds": 10, "failureThreshold": 30, "timeoutSeconds": 5
  }}
]'
```

These patches should be applied to the base `openemr-on-openshift` deployment manifests so they are baked in by default.

### Pods show 1/1 — is the mesh working?

Yes. In ambient mode **1/1 is correct** — there is no sidecar container. Verify enrollment:

```bash
NS="${OPENEMR_NAMESPACE:-openemr}"
oc get pod -n "$NS" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.ambient\.istio\.io/redirection}{"\n"}{end}'
# Should show: enabled
```

### OpenEMR can't reach MariaDB or Redis after deploying the waypoint

When the waypoint is deployed and `istio.io/use-waypoint=waypoint` is set on the namespace, ztunnel routes traffic through the waypoint before delivering it to the destination pod. At the destination, the source identity is the **waypoint's service account** (`cluster.local/ns/openemr/sa/waypoint`), not the original OpenEMR pod SA.

ALLOW policies that only include `cluster.local/ns/openemr/sa/default` will reject this traffic. Add the waypoint SA:

```bash
oc patch authorizationpolicy allow-openemr-to-mariadb -n openemr --type=merge -p='{
  "spec": {"rules": [{"from": [{"source": {"principals": [
    "cluster.local/ns/openemr/sa/default",
    "cluster.local/ns/openemr/sa/waypoint"
  ]}}], "to": [{"operation": {"ports": ["3306"]}}]}]}
}'

oc patch authorizationpolicy allow-openemr-to-redis -n openemr --type=merge -p='{
  "spec": {"rules": [{"from": [{"source": {"principals": [
    "cluster.local/ns/openemr/sa/default",
    "cluster.local/ns/openemr/sa/waypoint"
  ]}}], "to": [{"operation": {"ports": ["6379"]}}]}]}
}'
```

This is already included in the `05-authz-policies.yaml` manifest and `deploy-mesh.yml` playbook.

### OpenEMR can't reach MariaDB or Redis after applying policies

The most common cause is `targetRef: waypoint` on the AuthorizationPolicies when no waypoint is deployed. Policies with a `targetRef` pointing to a non-existent Gateway report `not bound` and are never enforced — leaving only `deny-all` active.

```bash
NS="${OPENEMR_NAMESPACE:-openemr}"

# Check policy status — look for "not bound" / "TargetNotFound"
oc get authorizationpolicy -n "$NS" -o yaml | grep -A5 "status:"

# Fix: remove targetRef from ALLOW policies (ztunnel enforces at L4 without it)
# The corrected 05-authz-policies.yaml has no targetRef blocks
```

If policies look correct, check ztunnel for denial logs:

```bash
oc logs -n istio-system ds/ztunnel | grep -E "deny|error|reject" | grep "$NS"

# Check the SPIFFE principal OpenEMR is actually using
oc get pod -l app=openemr -n "$NS" \
  -o jsonpath='{.items[0].spec.serviceAccountName}'; echo
```

### Public URL returns 408 Request Timeout

This means traffic reaches the OpenShift router but times out waiting for the pod. Root cause is almost always `routingViaHost: false` on OVN-K — ztunnel never intercepts the inbound traffic.

```bash
# Check current setting
oc get network.operator.openshift.io cluster \
  -o jsonpath='{.spec.defaultNetwork.ovnKubernetesConfig.gatewayConfig}'; echo

# Fix (triggers node reboot on SNO):
oc patch network.operator.openshift.io cluster --type=merge \
  -p='{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"gatewayConfig":{"routingViaHost":true}}}}}'
```

### ztunnel workloads command returns empty / pods not enrolled

Two common causes:

```bash
# 1. Check istio-system has the required discovery label
oc get namespace istio-system --show-labels | grep istio-discovery
# Fix if missing:
oc label namespace istio-system istio-discovery=enabled
oc label namespace istio-cni istio-discovery=enabled

# 2. Check ztunnel impersonation RBAC exists
oc get clusterrolebinding ztunnel-impersonate
# Fix if missing — without this, ztunnel cannot get SPIFFE certs:
oc apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ztunnel-impersonate
rules:
- apiGroups: [""]
  resources: ["serviceaccounts"]
  verbs: ["impersonate"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ztunnel-impersonate
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ztunnel-impersonate
subjects:
- kind: ServiceAccount
  name: ztunnel
  namespace: istio-system
EOF

# 3. Pod missed CNI enrollment event — delete to re-enroll
oc delete pod -l app=openemr -n "$NS"
```

### istiod fails to issue certs / ztunnel impersonation errors

`trustedZtunnelNamespace` is missing from the Istio CR. Without it, istiod rejects ztunnel's certificate requests.

```bash
# Check
oc get istio default -o jsonpath='{.spec.values.pilot.trustedZtunnelNamespace}'; echo

# Fix
oc patch istio default --type=merge \
  -p='{"spec":{"values":{"pilot":{"trustedZtunnelNamespace":"istio-system"}}}}'
oc rollout restart deployment/istiod -n istio-system
```

### Ansible playbook fails with 403 on namespace patch

The `Enroll namespace in ambient mesh` task fails with `namespaces is forbidden: User cannot patch resource`. The user needs the `ambient-namespace-enroller` ClusterRole — see [Privilege Requirements](#privilege-requirements).

```bash
# Verify you have the binding
oc auth can-i patch namespaces --all-namespaces

# If not, ask a cluster-admin to run:
oc adm policy add-cluster-role-to-user ambient-namespace-enroller <username>
```

### Waypoint not becoming Programmed

```bash
NS="${OPENEMR_NAMESPACE:-openemr}"
oc describe gateway/waypoint -n "$NS"
# Ensure the GatewayClass exists
oc get gatewayclass istio-waypoint
```

### ztunnel DaemonSet pods not starting

```bash
# Check the ZTunnel CR status first
oc describe ztunnel/default -n istio-system

# Then check the DaemonSet
oc describe daemonset/ztunnel -n istio-system
# Common cause on OpenShift: missing SCC
oc adm policy add-scc-to-user privileged -z ztunnel -n istio-system
```

### Sail Operator CSV stuck in Installing

```bash
oc get csv -n openshift-operators | grep servicemeshoperator3
oc describe csv <csv-name> -n openshift-operators | grep -A5 "Conditions:"
# On disconnected clusters, ensure redhat-operators CatalogSource is mirrored
oc get catalogsource -n openshift-marketplace
```

## HIPAA Alignment

| HIPAA Requirement | How This Addresses It |
|---|---|
| §164.312(e)(1) — Transmission Security | ztunnel auto-encrypts all pod-to-pod traffic with mTLS |
| §164.312(a)(1) — Access Control | AuthorizationPolicies (via waypoint) enforce identity-based access |
| §164.312(b) — Audit Controls | Kiali + Tempo provide full traffic audit trail |
| §164.312(e)(2)(ii) — Encryption | Automatic certificate rotation via mesh CA |
| §164.308(a)(4) — Information Access Management | Egress firewall prevents unauthorized data exfiltration |

## Cleanup

```bash
# Remove mesh config from the namespace only (control plane left intact)
./deploy-mesh.sh --cleanup
# or with a custom namespace:
OPENEMR_NAMESPACE=my-emr ./deploy-mesh.sh --cleanup

# Full control plane removal
oc delete kiali/kiali -n istio-system
oc delete istio/default -n istio-system
oc delete istiocni/default -n istio-cni
oc delete ztunnel/default -n istio-system
oc delete namespace istio-system istio-cni

# Remove operators (only if no other mesh workloads depend on them)
oc delete subscription servicemeshoperator3 kiali-ossm -n openshift-operators
```

## Author

**Ryan Nix** <ryan.nix@gmail.com> — projects are personal, not official Red Hat

## License

This project follows OpenEMR's licensing. OpenEMR is licensed under GPL v3.