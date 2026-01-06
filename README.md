# OpenEMR on OpenShift

Deploy [OpenEMR](https://www.open-emr.org/) 7.0.4 - the most popular open-source Electronic Health Records (EHR) system - on [Red Hat OpenShift](https://www.redhat.com/en/technologies/cloud-computing/openshift), the world's leading enterprise Kubernetes platform.

![OpenEMR Logo](https://www.open-emr.org/wiki/images/b/b2/Login-logo.png)

## Overview

This project provides a production-ready container image and deployment script for running OpenEMR on OpenShift, including the free [Developer Sandbox](https://developers.redhat.com/developer-sandbox).

**Stack:**
- **OpenEMR 7.0.4** - Electronic Health Records system
- **CentOS 9 Stream*** - Base container image
- **PHP 8.4** - Via Remi repository
- **nginx + PHP-FPM** - Web server (supervisord managed)
- **MariaDB 11.8** - Database
- **Redis 8** - Session caching

*\*CentOS Stream 9 is the upstream development branch for RHEL 9.x (Fedora → CentOS Stream → RHEL). It provides a stable, enterprise-grade foundation with the latest updates before they land in RHEL.*

## Benefits of Running on OpenShift

| Benefit | Description |
|---------|-------------|
| **Enterprise Security** | Containers run as non-root with arbitrary UIDs, SecurityContext constraints, and network policies |
| **Automated TLS** | Routes automatically provide HTTPS with valid certificates |
| **Self-Healing** | Failed pods are automatically restarted; health checks ensure availability |
| **Declarative Configuration** | Infrastructure as code - entire deployment defined in scripts |
| **Persistent Storage** | Managed persistent volumes for database and documents |
| **Resource Management** | CPU/memory limits prevent runaway processes |
| **Easy Scaling** | Scale replicas with a single command (with shared storage) |
| **Built-in Monitoring** | OpenShift console provides metrics, logs, and topology visualization |
| **Developer Sandbox** | Free 30-day environment for testing - no credit card required |

## Prerequisites

### 1. OpenShift CLI (oc)

Download the `oc` CLI tool for your platform:

**macOS:**
```bash
brew install openshift-cli
```

**Linux:**
```bash
curl -LO https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz
tar xvf openshift-client-linux.tar.gz
sudo mv oc /usr/local/bin/
```

**Windows:**
Download from [OpenShift Mirror](https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/) and add to PATH.

Verify installation:
```bash
oc version
```

### 2. OpenShift Environment

**Option A: Developer Sandbox (Free)**

1. Sign up at [developers.redhat.com/developer-sandbox](https://developers.redhat.com/developer-sandbox)
2. Click "Start your sandbox"
3. Log in with your Red Hat account
4. Click the "Copy login command" link in the OpenShift console
5. Run the `oc login` command in your terminal

**Option B: Your Own Cluster**

Log in to your cluster:
```bash
oc login --server=https://your-cluster-api:6443
```

### 3. Container Tools (for building)

If you want to build the image yourself:
- [Podman](https://podman.io/getting-started/installation) (recommended) or Docker
- Account on [Quay.io](https://quay.io) or another container registry

## Quick Start

### Deploy with Pre-built Image

```bash
# Clone or download the deployment script
chmod +x deploy-openemr.sh

# Deploy OpenEMR
./deploy-openemr.sh --deploy
```

The script will:
1. Detect your current OpenShift project
2. Deploy MariaDB with persistent storage
3. Deploy Redis for session caching
4. Deploy OpenEMR with auto-configuration
5. Create a TLS-secured route
6. Display login credentials

### Access OpenEMR

After deployment completes, access OpenEMR at the URL shown in the output:
```
https://openemr-<namespace>.apps.<cluster-domain>/
```

Login with the credentials displayed (also saved to `openemr-credentials.txt`).

## Building the Container Image

To build and push your own image:

```bash
# Build for linux/amd64 (required for OpenShift)
podman build --platform linux/amd64 -t quay.io/<your-username>/openemr-openshift:7.0.4 -f Containerfile .

# Push to registry
podman push quay.io/<your-username>/openemr-openshift:7.0.4
```

Update `OPENEMR_IMAGE` in `deploy-openemr.sh` to use your image.

## Deployment Commands

```bash
# Deploy OpenEMR
./deploy-openemr.sh --deploy

# Check status
./deploy-openemr.sh --status

# Clean up (preserves PVCs)
./deploy-openemr.sh --cleanup

# Full cleanup including data
./deploy-openemr.sh --cleanup
oc delete pvc openemr-documents mariadb-data
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     OpenShift Cluster                        │
│  ┌─────────────────────────────────────────────────────┐    │
│  │                    Project/Namespace                 │    │
│  │                                                      │    │
│  │  ┌──────────┐    ┌──────────┐    ┌──────────┐      │    │
│  │  │  Route   │───▶│ Service  │───▶│ OpenEMR  │      │    │
│  │  │  (TLS)   │    │  :8080   │    │   Pod    │      │    │
│  │  └──────────┘    └──────────┘    └────┬─────┘      │    │
│  │                                       │             │    │
│  │                    ┌──────────────────┼──────┐     │    │
│  │                    │                  │      │     │    │
│  │                    ▼                  ▼      │     │    │
│  │              ┌──────────┐      ┌──────────┐  │     │    │
│  │              │ MariaDB  │      │  Redis   │  │     │    │
│  │              │   Pod    │      │   Pod    │  │     │    │
│  │              └────┬─────┘      └──────────┘  │     │    │
│  │                   │                          │     │    │
│  │                   ▼                          ▼     │    │
│  │              ┌──────────┐           ┌──────────┐  │    │
│  │              │   PVC    │           │   PVC    │  │    │
│  │              │ (5Gi DB) │           │ (10Gi)   │  │    │
│  │              └──────────┘           └──────────┘  │    │
│  └─────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

## Technical Challenges Solved

Building OpenEMR for OpenShift required solving several non-obvious issues:

### 1. InstallerAuto.php Parameter Naming
**Problem:** The auto-installer uses `server=` for the database host, not `host=` as you might expect.

**Solution:** Use the correct parameter name:
```bash
php -f InstallerAuto.php server=mariadb  # ✓ Correct
php -f InstallerAuto.php host=mariadb    # ✗ Silently fails
```

### 2. OPcache Caching Stale Configuration
**Problem:** PHP's OPcache caches bytecode, so updates to `sqlconf.php` weren't reflected until cache expired.

**Solution:** Fresh deployments avoid this issue. For debugging, invalidate cache:
```bash
php -r "opcache_invalidate('/path/to/sqlconf.php', true);"
```

### 3. PVC Mount Overwrites Crypto Directory
**Problem:** OpenEMR needs `/sites/default/documents/logs_and_misc/methods/` for encryption keys, but mounting a PVC on `/documents` overwrites it.

**Solution:** Create the directory at runtime after pod starts:
```bash
mkdir -p /var/www/html/openemr/sites/default/documents/logs_and_misc/methods
chmod -R 770 /var/www/html/openemr/sites/default/documents/logs_and_misc
```

### 4. Password Special Characters
**Problem:** Base64-encoded passwords contain `/`, `+`, `=` which break shell argument parsing.

**Solution:** Use hex-encoded passwords:
```bash
openssl rand -hex 24  # ✓ Only 0-9, a-f characters
openssl rand -base64 24  # ✗ Contains special characters
```

### 5. Node.js Version for Frontend Build
**Problem:** OpenEMR's npm build requires Node.js 18+, but CentOS 9 ships with Node.js 16.

**Solution:** Install Node.js 22 from NodeSource:
```# Install Node.js 22 LTS from AppStream (required for OpenEMR frontend build)
RUN dnf module enable nodejs:22 -y \
    && dnf install -y nodejs npm \
    && dnf clean all \
    && node --version && npm --version
```

### 6. OpenShift Arbitrary User IDs
**Problem:** OpenShift runs containers with random UIDs for security, breaking file permissions.

**Solution:** Ensure group 0 (root) has same permissions as owner:
```dockerfile
RUN chgrp -R 0 /var/www/html && chmod -R g=u /var/www/html
```

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MYSQL_HOST` | `mariadb` | Database hostname |
| `MYSQL_PORT` | `3306` | Database port |
| `MYSQL_DATABASE` | `openemr` | Database name |
| `MYSQL_USER` | `openemr` | Database username |
| `MYSQL_PASS` | (generated) | Database password |
| `OE_USER` | `admin` | OpenEMR admin username |
| `OE_PASS` | (generated) | OpenEMR admin password |

### Storage

| PVC | Size | Purpose |
|-----|------|---------|
| `mariadb-data` | 5Gi | Database files |
| `openemr-sites` | 10Gi | Site configuration, patient documents, logs |

### Resource Limits

| Component | CPU Request | CPU Limit | Memory Request | Memory Limit |
|-----------|-------------|-----------|----------------|--------------|
| OpenEMR | 200m | 500m | 384Mi | 768Mi |
| MariaDB | 200m | 500m | 512Mi | 1Gi |
| Redis | 100m | 200m | 128Mi | 256Mi |

### IP Whitelisting

To restrict access to OpenEMR to specific IP addresses, annotate the route:

```bash
# Allow only specific IPs (comma-separated CIDR notation)
oc annotate route openemr haproxy.router.openshift.io/ip_whitelist="192.168.1.0/24,10.0.0.1" --overwrite

# Allow a single IP
oc annotate route openemr haproxy.router.openshift.io/ip_whitelist="203.0.113.42" --overwrite

# Remove IP restrictions
oc annotate route openemr haproxy.router.openshift.io/ip_whitelist- --overwrite
```

This is recommended for healthcare applications to limit access to known networks.

## Troubleshooting

### Check Pod Status
```bash
oc get pods
oc describe pod <pod-name>
```

### View Logs
```bash
# OpenEMR logs
oc logs deployment/openemr

# Database logs
oc logs deployment/mariadb

# Follow logs in real-time
oc logs -f deployment/openemr
```

### Access Pod Shell
```bash
oc exec -it deployment/openemr -- bash
```

### Common Issues

**500 Error on Login Page**
```bash
# Create crypto directory
oc exec deployment/openemr -- mkdir -p /var/www/html/openemr/sites/default/documents/logs_and_misc/methods
oc exec deployment/openemr -- chmod -R 770 /var/www/html/openemr/sites/default/documents/logs_and_misc
```

**Database Connection Failed**
```bash
# Verify MariaDB is running
oc get pods -l app=mariadb

# Test connection from OpenEMR pod
oc exec deployment/openemr -- php -r "new mysqli('mariadb', 'openemr', \$_ENV['MYSQL_PASS'], 'openemr') or die('Failed');"
```

**Setup Page Appears Instead of Login**
```bash
# Check if configuration completed
oc exec deployment/openemr -- grep "config = " /var/www/html/openemr/sites/default/sqlconf.php
# Should show: $config = 1
```

## Developer Sandbox Limitations

The free [Developer Sandbox](https://developers.redhat.com/developer-sandbox) is based on [Red Hat OpenShift 4.20](https://docs.openshift.com/container-platform/4.20/welcome/index.html) / [Kubernetes 1.33.5](https://github.com/kubernetes/kubernetes/releases/tag/v1.33.5). **The Sandbox is for testing and development only - not for production workloads.**

The Sandbox has some constraints:
- **Storage:** RWO (ReadWriteOnce) only - single replica deployments
- **Resources:** Limited CPU and memory quotas
- **Duration:** 30-day sandbox, renewable
- **Idle timeout:** Pods sleep after 12 hours of inactivity

### Waking Up After Hibernation

When you return after the sandbox has hibernated (scaled pods to 0), bring everything back up with:

```bash
# Scale all deployments back to 1 replica
oc scale deployment --all --replicas=1
```

Your data persists in the PVCs - only the pods are stopped during hibernation.

### Checking Your Quotas

View your resource quotas and usage:

```bash
# List all resource quotas
oc get resourcequota

# Get detailed quota information
oc describe resourcequota

# Check limit ranges (per-pod/container limits)
oc get limitrange
oc describe limitrange

# View current resource usage vs quotas
oc get quota -o yaml

# Check applied quotas for your project
oc describe project $(oc project -q)
```

For production deployments, use a full OpenShift cluster with:
- RWX storage for multi-replica scaling
- Redis persistence enabled
- Regular backups configured
- Custom domain with proper certificates

## Contributing

Contributions welcome! Please open issues or pull requests for:
- Bug fixes
- Documentation improvements
- Support for newer OpenEMR versions
- Helm chart creation
- Operator development

## License

OpenEMR is licensed under [GPL-3.0](https://github.com/openemr/openemr/blob/master/LICENSE).

## Acknowledgments

- [OpenEMR Project](https://www.open-emr.org/) - The open-source EHR community
- [Red Hat](https://www.redhat.com/) - OpenShift platform
- Claude Opus 4.5 (Anthropic) - AI-assisted debugging and documentation

---

**Note:** This project containerized OpenEMR for OpenShift in 2026. In 2020, I containerized OpenEMR for my Master's in Medical Informatics thesis targeting OpenShift 3.11 - what took months then now takes hours with modern tooling and AI assistance!
