# OpenEMR on OpenShift Developer Sandbox

[![OpenEMR Version](https://img.shields.io/badge/OpenEMR-8.0.0-blue?style=flat-square&logo=data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHdpZHRoPSIyNCIgaGVpZ2h0PSIyNCIgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9IndoaXRlIiBzdHJva2Utd2lkdGg9IjIiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCI+PHBhdGggZD0iTTE0IDJINmEyIDIgMCAwIDAtMiAydjE2YTIgMiAwIDAgMCAyIDJoMTJhMiAyIDAgMCAwIDItMlY4eiI+PC9wYXRoPjxwb2x5bGluZSBwb2ludHM9IjE0IDIgMTQgOCAyMCA4Ij48L3BvbHlsaW5lPjxsaW5lIHgxPSIxNiIgeTE9IjEzIiB4Mj0iOCIgeTI9IjEzIj48L2xpbmU+PGxpbmUgeDE9IjE2IiB5MT0iMTciIHgyPSI4IiB5Mj0iMTciPjwvbGluZT48cG9seWxpbmUgcG9pbnRzPSIxMCA5IDkgOSA4IDkiPjwvcG9seWxpbmU+PC9zdmc+)](https://www.open-emr.org/)
[![PHP Version](https://img.shields.io/badge/PHP-8.5-777BB4?style=flat-square&logo=php&logoColor=white)](https://www.php.net/)
[![MariaDB Version](https://img.shields.io/badge/MariaDB-11.8-003545?style=flat-square&logo=mariadb&logoColor=white)](https://mariadb.org/)
[![Redis Version](https://img.shields.io/badge/Redis-8-DC382D?style=flat-square&logo=redis&logoColor=white)](https://redis.io/)
[![CentOS Stream](https://img.shields.io/badge/CentOS%20Stream-10-262577?style=flat-square&logo=centos&logoColor=white)](https://www.centos.org/centos-stream/)
[![Container Registry](https://img.shields.io/badge/Registry-Quay.io-40B4E5?style=flat-square&logo=docker&logoColor=white)](https://quay.io/repository/ryan_nix/openemr-openshift)
[![License](https://img.shields.io/badge/License-GPL%20v3-green?style=flat-square&logo=gnu&logoColor=white)](LICENSE)
[![ONC Certified](https://img.shields.io/badge/ONC-Certified-success?style=flat-square&logo=check-circle&logoColor=white)](https://chpl.healthit.gov/#/listing/10938)
[![Build and Push OpenEMR](https://github.com/ryannix123/openemr-on-openshift/actions/workflows/build-image.yml/badge.svg)](https://github.com/ryannix123/openemr-on-openshift/actions/workflows/build-image.yml)

Production-ready deployment of OpenEMR 8.0.0 on Red Hat OpenShift Developer Sandbox using a custom CentOS 10 Stream container with PHP 8.5 from Remi's repository.

<p align="center">
  <img src="https://www.open-emr.org/images/openemr-blue-logo.png" alt="OpenEMR Logo" width="300">
</p>

## Overview

This project provides a complete containerized deployment of OpenEMR (Open-source Electronic Medical Records) on Red Hat OpenShift Developer Sandbox.

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
- **CI/CD Pipeline**: GitHub Actions builds and pushes to Quay.io on every change, with weekly rebuilds for security patches
- **Redis Session Storage**: Redis 8 Alpine for improved performance and scalability
- **MariaDB 11.8**: Latest Fedora MariaDB for robust database backend
- **Developer Sandbox Ready**: Optimized for Developer Sandbox storage and resource constraints
- **OpenShift Native**: Designed for OpenShift SCCs and security constraints
- **Production Ready**: Includes health checks, resource limits, and monitoring
- **HIPAA Considerations**: Encrypted transport, audit logging capabilities
- **Auto-Configuration**: Zero-touch deployment with automated setup
- **US Core 8.0 / USCDI v5**: Latest FHIR interoperability standards

**Note**: This deployment is configured for OpenShift Developer Sandbox which uses AWS EBS storage (ReadWriteOnce only). OpenEMR runs as a single replica, suitable for development, demo, and small practice environments.

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
│    openemr.apps.project-namespace.apps.rm3.7wse.p1.openshiftapps.com    │
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
    │ (sessions)  │ │ Deployment   │
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

**Developer Sandbox Constraints:**
- AWS EBS storage (gp3) provides ReadWriteOnce (RWO) volumes only
- Single OpenEMR replica due to RWO storage limitation
- Resource quotas: ~768Mi RAM and ~500m CPU per container
- Total storage: 16Gi (5Gi database + 10Gi documents + 1Gi Redis)
- Redis 8 Alpine for PHP session storage

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

- Red Hat OpenShift Developer Sandbox account ([Get free access](https://developers.redhat.com/developer-sandbox))
- `oc` CLI tool installed and configured
- Access to Quay.io for pulling container images (or build your own)
- Basic understanding of Kubernetes/OpenShift concepts

**Developer Sandbox Limitations to be aware of:**
- Access to Sandbox must renewed every 30 days
- Storage limited to ~40GB total per namespace
- Resource quotas: Limited CPU/memory per namespace
- No cluster-admin access
- Single replica deployments recommended for persistent storage
- Sandbox is not for production deployments.

## Quick Start

### 1. Clone the Repository

```bash
git clone https://github.com/ryannix123/openemr-on-openshift.git
cd openemr-openshift
```

### 2. Build the Container (Optional)

The container is automatically built and pushed to Quay.io via GitHub Actions CI/CD. You can use the pre-built image directly:

```
quay.io/ryan_nix/openemr-openshift:latest
```

The CI/CD pipeline:
- Builds on every push to `main` when container-related files change
- Rebuilds weekly (Mondays at 6am UTC) to pick up base image security patches
- Can be triggered manually via GitHub Actions with optional version override
- Caches layers with GitHub Actions cache for fast rebuilds

If you want to build locally instead:

```bash
# Build the container
podman build --platform linux/amd64 \
  -t quay.io/ryan_nix/openemr-openshift:8.0.0 \
  -t quay.io/ryan_nix/openemr-openshift:latest \
  -f Containerfile .

# Push to Quay.io
podman login quay.io
podman push quay.io/ryan_nix/openemr-openshift:8.0.0
podman push quay.io/ryan_nix/openemr-openshift:latest
```

> **Note**: Building with `--platform linux/amd64` on Apple Silicon (M1/M2/M3/M4) may fail with CentOS Stream 10 due to QEMU userspace emulation issues. Use the GitHub Actions pipeline or build on a native x86_64 host.

### 3. Configure the Deployment (Optional)

The script is pre-configured for Developer Sandbox with sensible defaults:
- Storage: `gp3` (default Developer Sandbox storage class)
- Database: 5Gi
- Documents: 10Gi

You can optionally adjust these in `deploy-openemr.sh` if needed, but defaults work well for most cases.

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

### Waking Up Your Deployment

The Developer Sandbox automatically scales deployments to zero after 12 hours of inactivity. When you return and find your pods stopped, run:

```bash
# Scale all deployments back to 1 replica
oc scale deployment --all --replicas=1

# Watch pods come back up
oc get pods -w
```

Your data persists in the PVCs — only the pods are stopped during hibernation. OpenEMR will be ready once all three pods (OpenEMR, MariaDB, Redis) show `Running`.

### Storage Classes

The deployment uses **AWS EBS gp3** storage (default in Developer Sandbox):

- **Access Mode**: ReadWriteOnce (RWO) only
- **Storage Class**: `gp3` (default)
- **Available**: gp2, gp2-csi, gp3, gp3-csi (all RWO)
- **Not Available**: ReadWriteMany (RWX) storage

**Note**: Due to RWO storage limitations, OpenEMR runs as a single replica. This is suitable for development, testing, and small practice environments.

### Scaling

**Important**: Scaling to multiple replicas is not supported with RWO storage. If you need high availability:

1. Deploy on a full OpenShift cluster with RWX storage (e.g., ODF CephFS)
2. Update storage class to RWX-capable storage
3. Change `ReadWriteOnce` to `ReadWriteMany` in documents PVC
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
- php-bcmath (arbitrary precision math)
- php-intl (internationalization)
- php-tidy (HTML cleanup)
- php-xmlrpc (XML-RPC)

### Health Checks

The container exposes these endpoints:

- `/health` - General health check (returns 200)
- `/fpm-status` - PHP-FPM status page

## Troubleshooting

### View Logs

```bash
# OpenEMR application logs
oc logs -f $(oc get pod -l app=openemr -o name)

# MariaDB logs
oc logs -f $(oc get pod -l app=mariadb -o name)

# Get all pods
oc get pods
```

### Common Issues

**Pod not starting:**
```bash
# Describe the pod for events
oc describe pod <pod-name>

# Check for image pull errors
oc get events --sort-by='.lastTimestamp'
```

**Storage issues:**
```bash
# Check PVC status
oc get pvc

# Describe PVC for binding issues
oc describe pvc <pvc-name>
```

**Database connection errors:**
```bash
# Verify MariaDB is running
oc get pods -l app=mariadb

# Test database connectivity from OpenEMR pod
oc exec -it $(oc get pod -l app=openemr -o name) -- bash
# Inside the pod:
php -r "mysqli_connect('mariadb', 'openemr', 'password', 'openemr') or die(mysqli_connect_error());"
```

### Reset Deployment

To completely remove and redeploy:

```bash
# Run the cleanup script
./deploy-openemr.sh --cleanup
# Wait for all pods to terminate, then re-run:
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
   # Use encrypted storage classes
   STORAGE_CLASS="ocs-storagecluster-ceph-rbd-encrypted"
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

## Maintenance

### Backup

**Database backup:**
```bash
# Create database dump
oc exec -it $(oc get pod -l app=mariadb -o name) -- \
  mysqldump -u root -p"$DB_ROOT_PASSWORD" openemr > openemr-backup-$(date +%Y%m%d).sql
```

**Document backup:**
```bash
# Backup documents PVC
oc rsync openemr-pod:/var/www/html/openemr/sites/default/documents ./backup/documents/
```

### Updates

Container updates are handled automatically by the CI/CD pipeline. To update to a new OpenEMR version:

1. Update `OPENEMR_VERSION` in the `Containerfile`
2. Push to `main` — GitHub Actions will build and push the new image
3. Roll out the update to your cluster:

```bash
# Update deployment to use the new image tag
oc set image deployment/openemr \
  openemr=quay.io/ryan_nix/openemr-openshift:8.0.1
```

To manually trigger a rebuild (e.g., to pick up security patches immediately):
1. Go to **Actions** → **Build and Push OpenEMR** → **Run workflow**
2. Optionally check **Force rebuild** to rebuild even if the tag already exists

## Project Structure

```
openemr-openshift/
├── Containerfile                          # Multi-stage container build
├── deploy-openemr.sh                     # Automated deployment script
├── build-container.sh                    # Local container build helper
├── README.md                             # This file
├── .containerignore                      # Files to ignore during build
├── .github/
│   └── workflows/
│       └── build-image.yml               # CI/CD: build & push to Quay.io
└── manifests/                            # (Optional) Individual YAML files
    ├── deployment.yaml
    ├── service.yaml
    ├── route.yaml
    └── mariadb/
        ├── deployment.yaml
        └── service.yaml
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
- [OpenShift Data Foundation](https://www.redhat.com/en/technologies/cloud-computing/openshift-data-foundation)

## License

This project follows OpenEMR's licensing. OpenEMR is licensed under GPL v3.

## Author

**Ryan Nix** — projects are personal, not official Red Hat
- Senior Solutions Architect, Red Hat
- GitHub: [@ryannix123](https://github.com/ryannix123)
- Quay.io: [ryan_nix](https://quay.io/user/ryan_nix)

## Acknowledgments

- OpenEMR development team
- Red Hat OpenShift team
- Based on the Nextcloud on OpenShift pattern

---

**Note**: This is designed for healthcare environments. Ensure compliance with HIPAA, HITECH, and other applicable regulations in your jurisdiction before deploying with real patient data.