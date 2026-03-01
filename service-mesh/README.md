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

- **OpenShift 4.14+** with cluster-admin access
- **OVN-Kubernetes CNI** (default on OpenShift 4.12+)
- **OpenEMR deployed** via [openemr-on-openshift](https://github.com/ryannix123/openemr-on-openshift)

The deploy script handles all operator and CRD installation automatically. No manual OperatorHub steps are required.

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
./deploy-mesh.sh --netpol-only   # NetworkPolicies only (no mesh operators required)
./deploy-mesh.sh --egress-only   # EgressFirewall only
./deploy-mesh.sh --cleanup       # Remove mesh config from namespace (keep control plane)
```

## What Gets Deployed

| File | Purpose |
|------|---------|
| `00-sail-operator.yaml` | OLM Subscription — installs the Sail Operator (OSSM 3) from `redhat-operators` |
| `00-kiali-operator.yaml` | OLM Subscription + Kiali CR — installs Kiali Operator and creates a Kiali instance |
| `01-istio.yaml` | `Istio` CR — Sail Operator deploys Istiod with the ambient profile |
| `02-istiocni.yaml` | `IstioCNI` CR — deploys the ztunnel DaemonSet to all nodes |
| `03-namespace.yaml` | Target namespace labeled `istio.io/dataplane-mode: ambient` |
| `04-waypoint.yaml` | Gateway API `Gateway` CR — deploys waypoint proxy for L7 policy enforcement |
| `05-authz-policies.yaml` | AuthorizationPolicies — default deny + identity-based allow rules via waypoint |
| `06-network-policies.yaml` | NetworkPolicies — L3/L4 CNI-level isolation (independent of the mesh) |
| `07-egress-firewall.yaml` | EgressFirewall — restricts outbound connections to an explicit allow-list |

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
| AuthorizationPolicy targeting pods | AuthorizationPolicy targeting `waypoint` | `targetRef` on the Gateway |
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

Kiali is deployed automatically by `./deploy-mesh.sh --full`. After deployment:

```bash
# Get the Kiali URL
oc get route kiali -n istio-system -o jsonpath='https://{.spec.host}'; echo
```

Kiali provides a live traffic topology graph showing encrypted connections between OpenEMR, MariaDB, and Redis with mTLS lock icons. This is the fastest way to confirm policies are working correctly.

For distributed tracing, deploy **Tempo** (Jaeger is deprecated in OSSM 3) from OperatorHub and configure the `external_services.tracing` section of the Kiali CR in `manifests/00-kiali-operator.yaml`.

## Troubleshooting

### Pods show 1/1 — is the mesh working?

Yes. In ambient mode **1/1 is correct** — there is no sidecar container. Verify enrollment:

```bash
NS="${OPENEMR_NAMESPACE:-openemr}"
oc get pod -n "$NS" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.ambient\.istio\.io/redirection}{"\n"}{end}'
# Should show: enabled
```

### OpenEMR can't reach MariaDB after applying policies

The waypoint `targetRef` or SPIFFE principal may not match the actual service account. Debug:

```bash
NS="${OPENEMR_NAMESPACE:-openemr}"

# Check the service account OpenEMR is actually using
oc get pod -l app=openemr -n "$NS" \
  -o jsonpath='{.items[0].spec.serviceAccountName}'; echo

# Check waypoint logs for RBAC denials
oc logs -n "$NS" -l gateway.istio.io/managed=istio.io-mesh-controller \
  | grep -i "rbac\|deny"

# Temporarily remove deny-all to confirm connectivity is otherwise healthy
oc delete authorizationpolicy deny-all -n "$NS"
# Re-apply once confirmed:
# OPENEMR_NAMESPACE=$NS ./deploy-mesh.sh --policies
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
oc delete namespace istio-system istio-cni

# Remove operators (only if no other mesh workloads depend on them)
oc delete subscription servicemeshoperator3 kiali-ossm -n openshift-operators
```

## Author

**Ryan Nix** <ryan.nix@gmail.com> — projects are personal, not official Red Hat

## License

This project follows OpenEMR's licensing. OpenEMR is licensed under GPL v3.