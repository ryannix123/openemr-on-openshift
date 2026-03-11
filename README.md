# OpenEMR on OpenShift

[![OpenEMR Version](https://img.shields.io/badge/OpenEMR-8.0.0-blue?style=flat-square&logo=data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHdpZHRoPSIyNCIgaGVpZ2h0PSIyNCIgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9IndoaXRlIiBzdHJva2Utd2lkdGg9IjIiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCI+PHBhdGggZD0iTTE0IDJINmEyIDIgMCAwIDAtMiAydjE2YTIgMiAwIDAgMCAyIDJoMTJhMiAyIDIgMCAwIDAtMlY4eiI+PC9wYXRoPjxwb2x5bGluZSBwb2ludHM9IjE0IDIgMTQgOCAyMCA4Ij48L3BvbHlsaW5lPjxsaW5lIHgxPSIxNiIgeTE9IjEzIiB4Mj0iOCIgeTI9IjEzIj48L2xpbmU+PGxpbmUgeDE9IjE2IiB5MT0iMTciIHgyPSI4IiB5Mj0iMTciPjwvbGluZT48cG9seWxpbmUgcG9pbnRzPSIxMCA5IDkgOSA4IDkiPjwvcG9seWxpbmU+PC9zdmc+)](https://www.open-emr.org/)
[![PHP Version](https://img.shields.io/badge/PHP-8.5-777BB4?style=flat-square&logo=php&logoColor=white)](https://www.php.net/)
[![MariaDB Version](https://img.shields.io/badge/MariaDB-11.8-003545?style=flat-square&logo=mariadb&logoColor=white)](https://mariadb.org/)
[![Redis Version](https://img.shields.io/badge/Redis-8-DC382D?style=flat-square&logo=redis&logoColor=white)](https://redis.io/)
[![CentOS Stream](https://img.shields.io/badge/CentOS%20Stream-10-262577?style=flat-square&logo=centos&logoColor=white)](https://www.centos.org/centos-stream/)
[![Container Registry](https://img.shields.io/badge/Registry-Quay.io-40B4E5?style=flat-square&logo=docker&logoColor=white)](https://quay.io/repository/ryan_nix/openemr-openshift)
[![License](https://img.shields.io/badge/License-GPL%20v3-green?style=flat-square&logo=gnu&logoColor=white)](LICENSE)
[![ONC Certified](https://img.shields.io/badge/ONC-Certified-success?style=flat-square&logo=check-circle&logoColor=white)](https://chpl.healthit.gov/#/listing/10938)
[![Build and Push OpenEMR](https://github.com/ryannix123/openemr-on-openshift/actions/workflows/build-image.yml/badge.svg)](https://github.com/ryannix123/openemr-on-openshift/actions/workflows/build-image.yml)

Production-ready deployment of OpenEMR 8.0.0 on Red Hat OpenShift using a custom CentOS 10 Stream container with PHP 8.5 from Remi's repository. Compatible with Developer Sandbox, Single Node OpenShift (SNO), and full OpenShift clusters.

## Overview

This project provides a complete containerized deployment of OpenEMR (Open-source Electronic Medical Records) on Red Hat OpenShift. The deploy script auto-detects the cluster's default storage class, so the same script works on Developer Sandbox (AWS EBS), Single Node OpenShift with LVM Storage, ODF-backed clusters, and any other OpenShift environment without modification.

### 🚀 Technology Stack

| Component | Version | Purpose |
|-----------|---------|---------|
| **OpenEMR** | 8.0.0 | Electronic Medical Records System |
| **PHP** | 8.5 | Runtime (Remi's Repository) |
| **MariaDB** | 11.8 | Database Backend |
| **Redis** | 8 Alpine | Session Storage & Cache |
| **nginx** | 1.26 | Web Server |
| **CentOS Stream** | 10 | Base Container OS |
| **Node.js** | 22 LTS | Frontend Build (build-time only) |

### ✨ Key Features

- **Custom OpenEMR Container**: Built on CentOS 10 Stream with Remi's PHP 8.5
- **Redis Session Storage**: Redis 8 Alpine for improved performance and scalability
- **MariaDB 11.8**: Latest Fedora MariaDB for robust database backend
- **Platform Agnostic**: Auto-detects the cluster default storage class — works on Developer Sandbox, SNO, ODF, and full clusters without modification
- **OpenShift Native**: Designed for OpenShift SCCs and security constraints
- **Production Ready**: Includes health checks, resource limits, and monitoring
- **HIPAA Considerations**: Encrypted transport, audit logging capabilities
- **Auto-Configuration**: Zero-touch deployment with automated setup
- **US Core 8.0 / USCDI v5**: Latest FHIR interoperability standards

**Note**: OpenEMR runs as a single replica because it uses ReadWriteOnce (RWO) persistent storage. This is suitable for development, demo, and small practice environments. For high availability, use a storage class that supports ReadWriteMany (RWX), such as ODF CephFS, and scale to multiple replicas.

## Why OpenEMR?

OpenEMR stands as the world's most popular open-source electronic health records and medical practice management solution, and for good reason:

**Certified Excellence**: OpenEMR 7.0 achieved [ONC 2015 Cures Update Certification](https://chpl.healthit.gov/#/listing/10938), meeting rigorous U.S. federal standards for interoperability, security, and clinical quality measures. This certification enables providers to participate in Quality Payment Programs (QPP/MIPS) and demonstrates commitment to healthcare standards.

**Global Impact at Scale**: With over 100,000 medical providers serving more than 200 million patients across 100+ countries, OpenEMR has proven its reliability in diverse healthcare settings. The software is translated into 36 languages and downloaded 2,500+ times monthly, reflecting its worldwide trust and adoption.

**True Interoperability**: OpenEMR implements modern healthcare standards including FHIR APIs, SMART on FHIR, OAuth2, CCDA, Direct messaging, and Clinical Quality Measures (eCQMs). This extensive interoperability enables seamless integration with labs, hospitals, health information exchanges, and third-party applications—eliminating data silos and vendor lock-in.

**Cost-Effective Freedom**: As genuinely free and open-source software (no licensing fees, ever), OpenEMR provides an economically sustainable alternative to proprietary systems. Healthcare organizations maintain complete control over their data and infrastructure, with the freedom to customize, extend, or migrate without vendor restrictions or hidden costs.

**Community-Driven Innovation**: Developed since 2002 by physicians for physicians, OpenEMR benefits from contributions by hundreds of developers and support from 40+ professional companies. This vibrant ecosystem ensures continuous improvement, long-term sustainability, and responsive support options ranging from community forums to professional vendors.

**Healthcare Without Boundaries**: OpenEMR's mission ensures that quality healthcare technology remains accessible regardless of practice size, geographic location, or economic resources. This democratization of healthcare IT particularly benefits underserved communities, small practices, and international healthcare providers who were left behind by commercial EHR systems.

Whether you're a solo practitioner, a community health center, or a large healthcare system, OpenEMR provides enterprise-grade capabilities without enterprise-grade costs—proving that world-class healthcare software should be accessible to all.

## Architecture

```
┌─────────────────────────────────────────────┐
│          OpenShift Route (HTTPS)            │
│    openemr-openemr.apps.sandbox.xxx.xxx     │
└─────────────────┬───────────────────────────┘
                  │
┌─────────────────▼───────────────────────────┐
│         OpenEMR Service (ClusterIP)         │
│                Port 8080                    │
└─────────────────┬───────────────────────────┘
                  │
        ┌─────────▼──────────┐
        │  OpenEMR Pod       │
        │  (single replica)  │
        │  nginx + PHP-FPM   │
        └────┬───────────┬───┘
             │           │
    ┌────────▼───┐  ┌───▼──────────┐
    │ Redis Svc  │  │ MariaDB Svc  │
    │ Port 6379  │  │ Port 3306    │
    └────┬───────┘  └───┬──────────┘
         │              │
    ┌────▼────────┐ ┌──▼───────────┐
    │ Redis Pod   │ │ MariaDB      │
    │ (sessions)  │ │ StatefulSet  │
    └────┬────────┘ └──┬───────────┘
         │             │
    ┌────▼────────┐ ┌─▼────────────┐
    │ Redis PVC   │ │ Database PVC │
    │ (RWO - 1Gi) │ │ (RWO - 5Gi)  │
    └─────────────┘ └──────────────┘
         
        ┌─────────────────┐
        │  Documents PVC  │
        │  (RWO - 10Gi)   │
        │  gp3 storage    │
        └─────────────────┘
```

**Storage Notes:**
- The deploy script auto-detects the cluster default storage class (e.g. `lvms-vg1` on SNO, `gp3-csi` on Developer Sandbox, `ocs-storagecluster-ceph-rbd` on ODF)
- Override with: `STORAGE_CLASS=my-class ./deploy-openemr.sh`
- Single OpenEMR replica due to ReadWriteOnce (RWO) storage — scale with RWX storage if needed
- Total storage: 16Gi (5Gi database + 10Gi documents + 1Gi Redis)

## Components

### OpenEMR Container
- **Base**: CentOS 10 Stream
- **PHP**: 8.5 (from Remi's repository)
- **Web Server**: nginx + PHP-FPM (via supervisord)
- **OpenEMR**: 8.0.0
- **Session Storage**: Redis (tcp://redis:6379)
- **Features**:
  - OpenShift SCC compliant (runs as arbitrary UID)
  - Health check endpoints
  - OPcache enabled for performance
  - All required PHP extensions
  - Redis session handler for scalability

### Redis Cache
- **Image**: Redis 8 Alpine (docker.io/redis:8-alpine)
- **Storage**: 1Gi RWO persistent volume (gp3)
- **Purpose**: PHP session storage
- **Configuration**: 
  - maxmemory: 256MB with LRU eviction policy
  - Persistence: AOF (Append Only File)
  - Non-root execution (OpenShift restricted SCC)

### Database
- **Image**: Fedora MariaDB 11.8 (quay.io/fedora/mariadb-118)
- **Storage**: 5Gi RWO persistent volume (gp3)
- **Credentials**: Auto-generated secure passwords

### Storage
- **Documents**: 10Gi RWO volume (for patient documents, images) - gp3 EBS
- **Database**: 5Gi RWO volume (for MariaDB data) - gp3 EBS
- **Redis**: 1Gi RWO volume (for session persistence) - gp3 EBS
- **Storage Class**: `gp3` (AWS EBS CSI driver, default in Developer Sandbox)
- **Total**: 16Gi

## Prerequisites

- Red Hat OpenShift cluster — any of:
  - [Developer Sandbox](https://developers.redhat.com/developer-sandbox) (free, no cluster-admin required)
  - Single Node OpenShift (SNO)
  - Full OpenShift cluster
- `oc` CLI tool installed and configured
- Access to Quay.io for pulling container images (or build your own)
- Basic understanding of Kubernetes/OpenShift concepts

**Developer Sandbox specific limitations:**
- Projects expire after 30 days of inactivity
- Storage limited to ~40GB total per namespace
- Resource quotas: Limited CPU/memory per namespace
- No cluster-admin access (Service Mesh sub-project not supported)

## Quick Start

### 1. Clone the Repository

```bash
git clone https://github.com/ryannix123/openemr-openshift.git
cd openemr-openshift
```

### 2. Build the Container (Optional)

If you want to build your own container:

```bash
# Build the container (creates both :latest and :8.0.0 tags)
podman build -t quay.io/ryan_nix/openemr-openshift:latest .

# Push to Quay.io
podman login quay.io
podman push quay.io/ryan_nix/openemr-openshift:latest
```

Or use the pre-built image: `quay.io/ryan_nix/openemr-openshift:latest`

### 3. Configure the Deployment (Optional)

The script auto-detects the cluster's default storage class and works without any configuration changes. To override the storage class:

```bash
export STORAGE_CLASS=lvms-vg1   # SNO with LVM Storage
# or
export STORAGE_CLASS=ocs-storagecluster-ceph-rbd   # ODF
# or just run without setting it — the default is auto-detected
```

Storage sizes can be adjusted by editing the variables at the top of `deploy-openemr.sh` if needed.

### 4. Login to OpenShift Developer Sandbox

```bash
# Get your login command from the Developer Sandbox web console
oc login --token=sha256~xxxxx --server=https://api.sandbox.xxxxx.openshiftapps.com:6443
```

### 5. Deploy OpenEMR

```bash
chmod +x deploy-openemr.sh
./deploy-openemr.sh
```

The script will:
1. Create the OpenShift project
2. Deploy MariaDB with persistent storage
3. Deploy OpenEMR application
4. Create routes for external access
5. Display access credentials

### 6. Complete OpenEMR Setup

1. Navigate to the URL provided in the deployment summary
2. Follow the OpenEMR setup wizard
3. Use the database credentials from `openemr-credentials.txt`

## Configuration

### Storage Classes

The deploy script auto-detects the cluster's default storage class at runtime. No configuration is needed for standard environments:

| Environment | Typical Default Storage Class | Access Mode |
|---|---|---|
| Developer Sandbox | `gp3-csi` | RWO |
| SNO with LVM Storage | `lvms-vg1` | RWO |
| ODF (full cluster) | `ocs-storagecluster-ceph-rbd` | RWO / RWX |

To override the auto-detected class:
```bash
STORAGE_CLASS=my-storage-class ./deploy-openemr.sh
```

OpenEMR runs as a single replica with RWO storage, suitable for development, testing, and small practice environments.

### Scaling

**Important**: Scaling to multiple replicas requires ReadWriteMany (RWX) storage. With the default RWO storage class, OpenEMR runs as a single replica.

To scale:
1. Use an RWX-capable storage class (e.g., ODF CephFS: `ocs-storagecluster-cephfs`)
2. Redeploy with: `STORAGE_CLASS=ocs-storagecluster-cephfs ./deploy-openemr.sh`
3. Change `ReadWriteOnce` to `ReadWriteMany` in the documents PVC
4. Then scale: `oc scale deployment/openemr --replicas=3`

### Resource Limits

Current resource allocations (optimized for Developer Sandbox):

**OpenEMR Pod:**
- Requests: 384Mi RAM, 200m CPU
- Limits: 768Mi RAM, 500m CPU

**MariaDB:**
- Requests: 512Mi RAM, 200m CPU
- Limits: 1Gi RAM, 500m CPU

**Redis:**
- Requests: 128Mi RAM, 100m CPU
- Limits: 256Mi RAM, 250m CPU

**Total Namespace Usage:**
- RAM: ~1Gi requests, ~2Gi limits
- CPU: ~500m requests, ~1250m limits
- Storage: 16Gi (5Gi DB + 10Gi documents + 1Gi Redis)

These values fit within typical Developer Sandbox namespace quotas.

## Container Details

### PHP Configuration

The container includes these PHP settings optimized for OpenEMR:

```ini
upload_max_filesize = 128M
post_max_size = 128M
memory_limit = 512M
max_execution_time = 300

# Session storage via Redis
session.save_handler = redis
session.save_path = "tcp://redis:6379"
```

### PHP Extensions

All required OpenEMR extensions are included:
- php-mysqlnd (database)
- php-gd (image processing)
- php-xml (XML processing)
- php-mbstring (multi-byte strings)
- php-zip (compression)
- php-curl (HTTP requests)
- php-opcache (performance)
- php-ldap (LDAP authentication)
- php-soap (web services)
- php-imap (email)
- php-sodium (encryption)
- php-pecl-redis5 (session storage)

### Health Checks

The container exposes these endpoints:

- `/health` - General health check (returns 200)
- `/fpm-status` - PHP-FPM status page

## Troubleshooting

### View Logs

```bash
# OpenEMR application logs
oc logs -f deployment/openemr -n openemr

# MariaDB logs
oc logs -f statefulset/mariadb -n openemr

# Get all pods
oc get pods -n openemr
```

### Common Issues

**Pod not starting:**
```bash
# Describe the pod for events
oc describe pod <pod-name> -n openemr

# Check for image pull errors
oc get events -n openemr --sort-by='.lastTimestamp'
```

**Storage issues:**
```bash
# Check PVC status
oc get pvc -n openemr

# Describe PVC for binding issues
oc describe pvc <pvc-name> -n openemr
```

**Database connection errors:**
```bash
# Verify MariaDB is running
oc get pods -l app=mariadb -n openemr

# Test database connectivity from OpenEMR pod
oc exec -it deployment/openemr -n openemr -- bash
# Inside the pod:
php -r "mysqli_connect('mariadb', 'openemr', 'password', 'openemr') or die(mysqli_connect_error());"
```

### Reset Deployment

To completely remove and redeploy:

```bash
oc delete project openemr
# Wait for project to fully delete, then re-run:
./deploy-openemr.sh
```

## Security Considerations

### HIPAA Compliance

This deployment includes several security features for healthcare environments:

1. **Encryption in Transit**: TLS/HTTPS via OpenShift routes
2. **Encryption at Rest**: Enable encrypted storage classes
3. **Access Controls**: Leverage OpenShift RBAC
4. **Audit Logging**: OpenEMR's built-in audit log
5. **Network Policies**: Implement NetworkPolicy objects

### Recommended Enhancements

For production healthcare deployments:

1. **Enable Encryption at Rest**:
   ```bash
   # Use an encrypted storage class (ODF example)
   STORAGE_CLASS=ocs-storagecluster-ceph-rbd-encrypted ./deploy-openemr.sh
   ```

2. **Implement Network Policies**:
   ```yaml
   # Deny all traffic except necessary connections
   kind: NetworkPolicy
   apiVersion: networking.k8s.io/v1
   metadata:
     name: openemr-netpol
   spec:
     podSelector:
       matchLabels:
         app: openemr
     policyTypes:
     - Ingress
     - Egress
     ingress:
     - from:
       - namespaceSelector:
           matchLabels:
             name: openshift-ingress
     egress:
     - to:
       - podSelector:
           matchLabels:
             app: mariadb
       ports:
       - protocol: TCP
         port: 3306
   ```

3. **Configure Backup Strategy**:
   ```bash
   # Use OADP or Velero for backup/restore
   # Schedule regular database backups
   ```

4. **Enable Pod Security Standards**:
   ```bash
   oc label namespace openemr \
     pod-security.kubernetes.io/enforce=restricted \
     pod-security.kubernetes.io/warn=restricted
   ```

## Service Mesh — Zero Trust Networking

The `service-mesh/` sub-project adds a zero-trust networking layer using **OpenShift Service Mesh 3 (OSSM 3) in ambient mode**. This is an optional but strongly recommended addition for any environment handling real patient data.

### Why Service Mesh for a Healthcare Workload?

The base deployment secures the perimeter — TLS on the route, resource isolation via namespaces — but by default, pod-to-pod traffic inside the cluster is unencrypted and unrestricted. Any workload that gains a foothold in the `openemr` namespace can freely connect to MariaDB or Redis and sniff credentials or patient data in transit. The service mesh closes this gap.

### What OSSM 3 Ambient Mode Adds

| Layer | What It Does |
|-------|-------------|
| **Automatic mTLS (ztunnel)** | All pod-to-pod traffic is encrypted and mutually authenticated without any changes to OpenEMR, MariaDB, or Redis |
| **Identity-based AuthorizationPolicies** | Only OpenEMR's service account identity can reach MariaDB (port 3306) and Redis (port 6379) — no other pod can connect regardless of IP |
| **Waypoint Proxy** | Enforces L7 policies via an Envoy-based proxy deployed per namespace, required for fine-grained HTTP-level controls |
| **NetworkPolicies** | L3/L4 isolation enforced by OVN-Kubernetes independent of the mesh — defense in depth |
| **EgressFirewall** | Pods may only initiate outbound connections to an explicit allow-list; a compromised pod cannot phone home |

### Ambient Mode vs. Traditional Sidecar (OSSM 2.x)

OSSM 3 uses a fundamentally different architecture. Instead of injecting an Envoy sidecar into every pod (which requires pod restarts and shows as `2/2` containers), ambient mode deploys a `ztunnel` DaemonSet that intercepts traffic at the Linux network namespace level on each node. Pods remain `1/1` and are enrolled simply by labeling the namespace — no rollout required. A separate waypoint proxy handles L7 policy enforcement only where needed.

> **Requirement**: OSSM 3 requires cluster-admin access to install the Sail Operator and the `IstioCNI` DaemonSet. It is **not compatible with the Developer Sandbox**. Use a full OpenShift cluster or Single Node OpenShift (SNO).

### Quick Start

```bash
cd service-mesh/
chmod +x deploy-mesh.sh

# Full install: operators, control plane, policies, Kiali
./deploy-mesh.sh --full

# Or step by step — useful if OpenEMR is already deployed:
./deploy-mesh.sh --operators      # Install Sail + Kiali operators, Gateway API CRDs
./deploy-mesh.sh --control-plane  # Deploy Istio + ztunnel
./deploy-mesh.sh --policies       # Enroll namespace, waypoint, AuthZ, NetworkPolicy, Egress

# Check status at any point
./deploy-mesh.sh --status
```

See [`service-mesh/README.md`](service-mesh/README.md) for the full deployment guide, manifest reference, HIPAA alignment table, and troubleshooting steps.

## Project Structure

```
openemr-on-openshift/
├── Containerfile                  # Container build instructions
├── deploy-openemr.sh              # Automated deployment script
├── README.md                      # This file
├── .containerignore               # Files to ignore during build
├── manifests/                     # Individual YAML manifests
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── route.yaml
│   └── mariadb/
│       ├── statefulset.yaml
│       └── service.yaml
└── service-mesh/                  # Zero-trust networking sub-project (OSSM 3)
    ├── README.md                  # Service mesh deployment guide
    ├── deploy-mesh.sh             # Operator + mesh deployment script
    └── manifests/
        ├── 00-sail-operator.yaml  # Sail Operator subscription (OLM)
        ├── 00-kiali-operator.yaml # Kiali Operator subscription + Kiali CR
        ├── 01-istio.yaml          # Istio CR (ambient profile)
        ├── 02-istiocni.yaml       # IstioCNI CR (ztunnel DaemonSet)
        ├── 03-namespace.yaml      # Namespace with ambient enrollment label
        ├── 04-waypoint.yaml       # Waypoint proxy (L7 policy enforcement)
        ├── 05-authz-policies.yaml # AuthorizationPolicies (default-deny + allows)
        ├── 06-network-policies.yaml # NetworkPolicies (L3/L4 CNI isolation)
        └── 07-egress-firewall.yaml  # EgressFirewall (OVN-Kubernetes)
```

## Contributing

Contributions are welcome! Areas for improvement:

- [ ] Helm chart version
- [ ] GitOps/ArgoCD manifests
- [ ] Automated database migrations
- [ ] Prometheus metrics exporters
- [ ] Custom Operator
- [ ] Multi-tenancy support

## Resources

- [OpenEMR Official Site](https://www.open-emr.org/)
- [OpenEMR Documentation](https://www.open-emr.org/wiki/index.php/OpenEMR_Wiki_Home_Page)
- [Red Hat OpenShift Documentation](https://docs.openshift.com/)
- [OpenShift Service Mesh 3 Documentation](https://docs.openshift.com/container-platform/latest/service_mesh/v3x/ossm-about.html)
- [OpenShift Data Foundation](https://www.redhat.com/en/technologies/cloud-computing/openshift-data-foundation)

## License

This project follows OpenEMR's licensing. OpenEMR is licensed under GPL v3.

## Author

**Ryan Nix**
- Senior Solutions Architect, Red Hat
- GitHub: [@ryannix123](https://github.com/ryannix123)
- Quay.io: [ryan_nix](https://quay.io/user/ryan_nix)

## Acknowledgments

- OpenEMR development team
- Red Hat OpenShift team
- Based on the Nextcloud on OpenShift pattern

---

**Note**: This is designed for healthcare environments. Ensure compliance with HIPAA, HITECH, and other applicable regulations in your jurisdiction before deploying with real patient data. Test thoroughly in a non-production environment before any clinical use.