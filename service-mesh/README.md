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
- Faster rollout — mesh enrollment is a namespace label, no rollout required

## Architecture

```
                    ┌──────────────────────────────────┐
                    │    OpenShift Router / Ingress     │
                    │    (TLS termination at edge)      │
                    └──────────────┬───────────────────┘
                                   │ HBONE tunnel (ztunnel)
          ╔════════════════════════╪══════════════════════════════╗
          ║  openemr namespace     │   Ambient Mesh enforced      ║
          ║                        ▼                              ║
          ║         ┌──────────────────────────┐                  ║
          ║         │      Waypoint Proxy       │ ← L7 AuthzPolicy║
          ║         │  (Gateway API / Envoy)    │   enforced here  ║
          ║         └──────┬─────────────┬──────┘                  ║
          ║                │             │                         ║
          ║    ztunnel 🔒  │  mTLS/HBONE │  🔒 ztunnel            ║
          ║    (auto-encrypt all traffic)│                         ║
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

### Required Operators / CRDs

**1. Sail Operator** (replaces the old `servicemeshoperator` in OSSM 3):
```bash
# Install from OperatorHub — search "Red Hat OpenShift Service Mesh" or "Sail"
# Alternatively via CLI:
oc apply -f https://raw.githubusercontent.com/istio-ecosystem/sail-operator/main/bundle/manifests/sail-operator.clusterserviceversionversion.yaml
```

**2. Gateway API CRDs** (required for waypoint proxy):
```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.1.0/standard-install.yaml
```

**3. Verify:**
```bash
oc get crd istioes.sailoperator.io istiocnis.sailoperator.io gateways.gateway.networking.k8s.io
```

## Quick Start

```bash
git clone https://github.com/ryannix123/openemr-on-openshift.git
cd openemr-on-openshift/service-mesh

chmod +x deploy-mesh.sh

# Full deployment: control plane + waypoint + policies + egress
./deploy-mesh.sh --full

# Check status
./deploy-mesh.sh --status
```

### Individual Steps

```bash
./deploy-mesh.sh --policies      # Policies only (control plane already running)
./deploy-mesh.sh --netpol-only   # NetworkPolicies only (no operators needed)
./deploy-mesh.sh --egress-only   # EgressFirewall only
./deploy-mesh.sh --cleanup       # Remove mesh config (keep control plane)
```

## What Gets Deployed

| File | Purpose |
|------|---------|
| `01-istio.yaml` | `Istio` CR — Sail Operator deploys Istiod with ambient profile |
| `02-istiocni.yaml` | `IstioCNI` CR — deploys ztunnel DaemonSet to all nodes |
| `03-namespace.yaml` | Labels `openemr` namespace with `istio.io/dataplane-mode: ambient` |
| `04-waypoint.yaml` | Gateway API `Gateway` CR — deploys waypoint proxy for L7 policies |
| `05-authz-policies.yaml` | AuthorizationPolicies — default deny + allow rules via waypoint |
| `06-network-policies.yaml` | NetworkPolicies — L3/L4 isolation (works without mesh) |
| `07-egress-firewall.yaml` | EgressFirewall — restrict outbound to allow-list |

## Key Differences from OSSM 2.x

If you're migrating from the OSSM 2.x configuration in this repo:

| OSSM 2.x | OSSM 3 Ambient | Notes |
|---|---|---|
| `ServiceMeshControlPlane` | `Istio` CR | Different CRD, different operator |
| `ServiceMeshMemberRoll` | Namespace label | `istio.io/dataplane-mode: ambient` |
| `sidecar.istio.io/inject: "true"` annotation | Not needed | ztunnel handles enrollment |
| `PeerAuthentication` (strict mTLS) | Not needed | ztunnel always encrypts |
| `Sidecar` scope resources | Not needed | No sidecars |
| AuthorizationPolicy targeting pods | AuthorizationPolicy targeting `waypoint` | `targetRef` on the Gateway |
| 2/2 pod containers | 1/1 pod containers | No sidecar container |

## Verifying the Mesh

### Check ztunnel is intercepting traffic

```bash
# Pods should show the ambient redirection annotation
oc get pod -n openemr -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.ambient\.istio\.io/redirection}{"\n"}{end}'
# Expected: enabled

# View ztunnel's view of workloads
oc exec -n istio-system ds/ztunnel -- pilot-agent request GET /config_dump | jq '.workloads'
```

### Verify mTLS is active (L4)

```bash
# ztunnel logs show HBONE connections
oc logs -n istio-system ds/ztunnel -c ztunnel | grep "openemr" | head -20
```

### Verify waypoint is enforcing L7 policies

```bash
# Check waypoint pod is running
oc get pod -n openemr -l gateway.istio.io/managed=istio.io-mesh-controller

# Watch waypoint access logs during a test request
oc logs -n openemr -l gateway.istio.io/managed=istio.io-mesh-controller -f
```

### Test AuthorizationPolicy is blocking unauthorized access

```bash
# This should be DENIED (random pod trying to reach MariaDB)
oc run test-denial --image=nicolaka/netshoot -it --rm --restart=Never -n openemr -- \
  nc -zv mariadb 3306
# Expected: connection refused or timeout (RBAC deny)
```

## Observability

OSSM 3 separates observability from the control plane. Deploy Kiali separately:

```bash
# Install Kiali Operator from OperatorHub, then:
cat <<EOF | oc apply -f -
apiVersion: kiali.io/v1alpha1
kind: Kiali
metadata:
  name: kiali
  namespace: istio-system
spec:
  auth:
    strategy: openshift
  deployment:
    accessible_namespaces: ["openemr"]
EOF

# Get Kiali URL
oc get route kiali -n istio-system -o jsonpath='{.spec.host}'; echo
```

For distributed tracing, deploy **Tempo** (Jaeger is deprecated in OSSM 3):

```bash
# Install Tempo Operator from OperatorHub
# Kiali connects to Tempo automatically when configured
```

## Troubleshooting

### Pods show 1/1 — is the mesh working?

Yes! In ambient mode, **1/1 is correct**. There is no sidecar. Verify ambient enrollment:

```bash
oc get pod -n openemr -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.ambient\.istio\.io/redirection}{"\n"}{end}'
```

### OpenEMR can't reach MariaDB after applying policies

The waypoint targetRef or service account principal may not match. Debug:

```bash
# Check the actual service account OpenEMR is using
oc get pod -l app=openemr -n openemr -o jsonpath='{.items[0].spec.serviceAccountName}'; echo

# Check waypoint logs for RBAC denials
oc logs -n openemr -l gateway.istio.io/managed=istio.io-mesh-controller | grep -i "rbac\|deny"

# Temporarily disable deny-all to confirm connectivity works without policies
oc delete authorizationpolicy deny-all -n openemr
# (re-apply after confirming)
```

### Waypoint not becoming Programmed

```bash
oc describe gateway/waypoint -n openemr
# Ensure GatewayClass 'istio-waypoint' exists
oc get gatewayclass istio-waypoint
```

### ztunnel DaemonSet pods not starting

```bash
oc describe daemonset/ztunnel -n istio-system
# Common cause: SCC permissions — ztunnel needs privileged SCC
oc adm policy add-scc-to-user privileged -z ztunnel -n istio-system
```

## HIPAA Alignment

| HIPAA Requirement | How This Addresses It |
|---|---|
| §164.312(e)(1) — Transmission Security | ztunnel auto-encrypts all pod-to-pod traffic with mTLS |
| §164.312(a)(1) — Access Control | AuthorizationPolicies (via waypoint) enforce identity-based access |
| §164.312(b) — Audit Controls | Kiali + Tempo provide full traffic audit trail |
| §164.312(e)(2)(ii) — Encryption | Automatic cert rotation via mesh CA (no config needed) |
| §164.308(a)(4) — Information Access Management | Egress firewall prevents unauthorized data flows |

## Cleanup

```bash
# Remove mesh config from namespace only
./deploy-mesh.sh --cleanup

# Full removal
oc delete istio/default -n istio-system
oc delete istiocni/default -n istio-cni
oc delete namespace istio-system istio-cni
```

## Author

**Ryan Nix** <ryan.nix@gmail.com> — projects are personal, not official Red Hat

## License

This project follows OpenEMR's licensing. OpenEMR is licensed under GPL v3.
