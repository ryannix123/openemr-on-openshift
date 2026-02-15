<p align="center">
  <img src="https://www.open-emr.org/images/openemr-blue-logo.png" alt="OpenEMR Logo" width="300">
</p>

# OpenEMR Service Mesh — Zero Trust Networking

[![OpenShift Service Mesh](https://img.shields.io/badge/Service%20Mesh-2.6-EE0000?style=flat-square&logo=redhatopenshift&logoColor=white)](https://docs.openshift.com/container-platform/latest/service_mesh/v2x/ossm-about.html)
[![Istio](https://img.shields.io/badge/Istio-Based-466BB0?style=flat-square&logo=istio&logoColor=white)](https://istio.io/)
[![mTLS](https://img.shields.io/badge/mTLS-Strict-brightgreen?style=flat-square)](https://istio.io/latest/docs/concepts/security/)

Zero-trust networking layer for [OpenEMR on OpenShift](https://github.com/ryannix123/openemr-on-openshift). Adds mutual TLS, identity-based authorization, network isolation, and egress control — critical for healthcare workloads handling PHI.

## Why This Matters for Healthcare

The base OpenEMR deployment secures the perimeter (TLS on the route, IP whitelisting), but inside the cluster, pod-to-pod traffic is **plaintext and unrestricted**. Any workload in the namespace — or an attacker with a foothold — can:

- Sniff OpenEMR ↔ MariaDB traffic (credentials, patient data)
- Connect directly to MariaDB or Redis without authentication
- Exfiltrate data to any external endpoint

This sub-project closes those gaps with defense-in-depth:

| Layer | What It Does | Without It |
|-------|-------------|------------|
| **mTLS** | Encrypts all pod-to-pod traffic with auto-rotated certs | Traffic is plaintext inside the cluster |
| **AuthorizationPolicy** | Only OpenEMR can talk to MariaDB/Redis (identity-based, not IP-based) | Any pod can connect to any service |
| **NetworkPolicy** | L3/L4 isolation enforced by the CNI plugin | No network segmentation between pods |
| **Egress Firewall** | Pods can only reach approved external destinations | Compromised pod can phone home anywhere |
| **Sidecar Scoping** | Each proxy only knows about services it needs | Full service discovery across the mesh |

## Prerequisites

- **OpenShift 4.12+** with cluster-admin access (not Developer Sandbox — mesh requires operator installation)
- **OpenEMR deployed** via [openemr-on-openshift](https://github.com/ryannix123/openemr-on-openshift)
- **OVN-Kubernetes CNI** (default on OpenShift 4.12+) for egress firewall support

### Required Operators

Install these from **OperatorHub** before running the deploy script:

1. **Red Hat OpenShift Service Mesh** (`servicemeshoperator`)
2. **Kiali Operator** (provided by Red Hat)
3. **Red Hat OpenShift distributed tracing platform** (Jaeger or Tempo)

```bash
# Verify operators are installed
oc get csv -n openshift-operators | grep -E "servicemesh|kiali|jaeger|tempo"
```

## Quick Start

### Full Zero-Trust Deployment

```bash
# Clone the repo
git clone https://github.com/ryannix123/openemr-on-openshift.git
cd openemr-on-openshift/service-mesh

# Deploy everything: mTLS + AuthZ + NetworkPolicy + Egress Firewall
chmod +x deploy-mesh.sh
./deploy-mesh.sh --full
```

### NetworkPolicy Only (No Operators Required)

If you can't install operators (e.g., shared cluster without admin), you can still get L3/L4 isolation:

```bash
./deploy-mesh.sh --netpol-only
```

This applies NetworkPolicies that restrict MariaDB and Redis to only accept connections from the OpenEMR pod. No mesh operators needed.

### Egress Firewall Only

```bash
./deploy-mesh.sh --egress-only
```

## Architecture

```
                    ┌──────────────────────────────┐
                    │   OpenShift Router / Ingress  │
                    │   (TLS termination)           │
                    └──────────────┬───────────────┘
                                   │
                    ┌──────────────▼───────────────┐
                    │     Istio Ingress Gateway     │
                    │     (or direct from Router)   │
                    └──────────────┬───────────────┘
                                   │
          ╔════════════════════════╪════════════════════════════╗
          ║  openemr namespace     │    STRICT mTLS enforced   ║
          ║                        │                           ║
          ║         ┌──────────────▼───────────────┐           ║
          ║         │     ┌─────────────────┐      │           ║
          ║         │     │   OpenEMR App   │      │           ║
          ║         │     └────────┬────────┘      │           ║
          ║         │     ┌────────┴────────┐      │           ║
          ║         │     │  Envoy Sidecar  │      │           ║
          ║         │     └───┬─────────┬───┘      │           ║
          ║         └─────────┼─────────┼──────────┘           ║
          ║                   │         │                      ║
          ║            mTLS 🔒│         │🔒 mTLS               ║
          ║                   │         │                      ║
          ║    ┌──────────────▼──┐  ┌──▼──────────────┐       ║
          ║    │  ┌───────────┐  │  │  ┌───────────┐  │       ║
          ║    │  │  MariaDB  │  │  │  │   Redis   │  │       ║
          ║    │  └───────────┘  │  │  └───────────┘  │       ║
          ║    │  ┌───────────┐  │  │  ┌───────────┐  │       ║
          ║    │  │  Envoy    │  │  │  │  Envoy    │  │       ║
          ║    │  └───────────┘  │  │  └───────────┘  │       ║
          ║    └─────────────────┘  └─────────────────┘       ║
          ║                                                    ║
          ║    ┌────────────────────────────────────────┐      ║
          ║    │          Egress Firewall                │      ║
          ║    │  ✓ quay.io, docker.io (image pulls)    │      ║
          ║    │  ✓ open-emr.org (project resources)    │      ║
          ║    │  ✓ NTP (time sync)                     │      ║
          ║    │  ✗ Everything else DENIED               │      ║
          ║    └────────────────────────────────────────┘      ║
          ╚════════════════════════════════════════════════════╝
```

## What Gets Deployed

### Manifests

| File | Purpose |
|------|---------|
| `01-smcp.yaml` | ServiceMeshControlPlane — deploys Istiod, Envoy, Kiali, Jaeger, Grafana |
| `02-smmr.yaml` | ServiceMeshMemberRoll — enrolls the openemr namespace in the mesh |
| `03-peer-authentication.yaml` | PeerAuthentication — enforces strict mTLS for all pods |
| `04-authz-deny-all.yaml` | AuthorizationPolicy — default deny for all traffic in namespace |
| `05-authz-allow-ingress-openemr.yaml` | AuthorizationPolicy — allow Router/Gateway → OpenEMR |
| `06-authz-allow-openemr-mariadb.yaml` | AuthorizationPolicy — allow OpenEMR → MariaDB (identity-verified) |
| `07-authz-allow-openemr-redis.yaml` | AuthorizationPolicy — allow OpenEMR → Redis (identity-verified) |
| `08-network-policies.yaml` | NetworkPolicies — L3/L4 isolation (works without mesh too) |
| `09-egress-firewall.yaml` | EgressFirewall — restrict outbound to allow-list only |
| `10-sidecars.yaml` | Sidecar — limit Envoy proxy scope per workload |

### Script Options

```bash
./deploy-mesh.sh --full          # Full deployment (mesh + policies + egress)
./deploy-mesh.sh --netpol-only   # NetworkPolicies only (no operators needed)
./deploy-mesh.sh --egress-only   # Egress firewall only
./deploy-mesh.sh --status        # Show current status
./deploy-mesh.sh --cleanup       # Remove everything
```

## Observability

The full deployment includes Kiali, Jaeger, and Grafana. After deploying:

```bash
# Get Kiali URL (live traffic topology)
oc get route kiali -n istio-system -o jsonpath='{.spec.host}'; echo

# Get Jaeger URL (distributed tracing)
oc get route jaeger -n istio-system -o jsonpath='{.spec.host}'; echo
```

**Kiali** gives you a live graph of traffic flows between OpenEMR, MariaDB, and Redis — with mTLS lock icons showing encrypted connections. This is invaluable for verifying your policies work and for troubleshooting connectivity issues.

## Customization

### Adding FHIR / HIE Endpoints

Edit `09-egress-firewall.yaml` to allow outbound connections to your Health Information Exchange:

```yaml
    # FHIR endpoint
    - type: Allow
      to:
        dnsName: "fhir.yourhie.org"
    # Direct messaging gateway
    - type: Allow
      to:
        dnsName: "direct.yourhie.org"
```

### Using a Custom Service Account

The AuthorizationPolicies use `cluster.local/ns/openemr/sa/default` as the source principal. If your OpenEMR deployment uses a dedicated ServiceAccount:

```bash
# Update the principal in manifests 06 and 07
sed -i 's|sa/default|sa/openemr-sa|g' manifests/06-authz-allow-openemr-mariadb.yaml
sed -i 's|sa/default|sa/openemr-sa|g' manifests/07-authz-allow-openemr-redis.yaml
```

### Changing the Namespace

```bash
OPENEMR_NAMESPACE=my-emr ./deploy-mesh.sh --full
```

You'll also need to update the namespace references in the manifest files, or use:

```bash
# Update all manifests to use a different namespace
sed -i 's/namespace: openemr/namespace: my-emr/g' manifests/*.yaml
```

## Troubleshooting

### Pods show 1/1 instead of 2/2

The Envoy sidecar isn't being injected. Check:

```bash
# Verify the namespace is in the mesh member roll
oc get smmr default -n istio-system -o jsonpath='{.status.configuredMembers}'; echo

# Verify the injection annotation exists
oc get deployment openemr -n openemr -o jsonpath='{.spec.template.metadata.annotations}'; echo

# Force restart
oc rollout restart deployment/openemr -n openemr
```

### OpenEMR can't reach MariaDB after enabling mesh

The deny-all policy is working but the allow policy may not match. Check:

```bash
# Verify the service account principal
oc get pod -l app=openemr -n openemr -o jsonpath='{.items[0].spec.serviceAccountName}'; echo

# Check Envoy access logs for RBAC denials
oc logs $(oc get pod -l app=openemr -n openemr -o name) -c istio-proxy -n openemr | grep "RBAC"
```

### EgressFirewall not taking effect

```bash
# Verify OVN-Kubernetes is the CNI
oc get network.config/cluster -o jsonpath='{.spec.networkType}'; echo

# Check firewall status
oc get egressfirewall -n openemr -o yaml
```

## HIPAA Alignment

| HIPAA Requirement | How This Addresses It |
|---|---|
| §164.312(e)(1) — Transmission Security | mTLS encrypts all pod-to-pod communication |
| §164.312(a)(1) — Access Control | AuthorizationPolicies enforce identity-based access |
| §164.312(b) — Audit Controls | Kiali + Jaeger provide full traffic audit trail |
| §164.312(e)(2)(ii) — Encryption | Automatic certificate rotation via mesh CA |
| §164.308(a)(4) — Information Access Management | Egress firewall prevents unauthorized data flows |

## Cleanup

```bash
# Remove mesh config but keep control plane
./deploy-mesh.sh --cleanup

# Full removal including control plane
./deploy-mesh.sh --cleanup
oc delete smcp basic -n istio-system
oc delete namespace istio-system
```

## Author

**Ryan Nix** <ryan.nix@gmail.com> — projects are personal, not official Red Hat

## License

This project follows OpenEMR's licensing. OpenEMR is licensed under GPL v3.
