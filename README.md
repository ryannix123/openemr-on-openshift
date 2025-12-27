# OpenEMR on OpenShift Developer Sandbox

Production-ready deployment of OpenEMR 7.0.5 on Red Hat OpenShift Developer Sandbox using a custom CentOS 9 Stream container with PHP 8.4 from Remi's repository.

## Overview

This project provides a complete containerized deployment of OpenEMR (Open-source Electronic Medical Records) on Red Hat OpenShift Developer Sandbox. It includes:

- **Custom OpenEMR Container**: Built on CentOS 9 Stream with Remi's PHP 8.4
- **Developer Sandbox Ready**: Optimized for Developer Sandbox storage and resource constraints
- **OpenShift Native**: Designed for OpenShift SCCs and security constraints
- **Production Ready**: Includes health checks, resource limits, and monitoring
- **HIPAA Considerations**: Encrypted transport, audit logging capabilities

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
        └─────────┬──────────┘
                  │
        ┌─────────▼──────────┐
        │  Documents PVC     │
        │  (RWO - 10Gi)      │
        │  gp3 storage       │
        └────────────────────┘
                  │
        ┌─────────▼──────────┐
        │  MariaDB Service   │
        │    Port 3306       │
        └─────────┬──────────┘
                  │
        ┌─────────▼──────────┐
        │  MariaDB StatefulSet│
        │  (1 replica)       │
        └─────────┬──────────┘
                  │
        ┌─────────▼──────────┐
        │   Database PVC     │
        │   (RWO - 5Gi)      │
        │   gp3 storage      │
        └────────────────────┘
```

**Developer Sandbox Constraints:**
- AWS EBS storage (gp3) provides ReadWriteOnce (RWO) volumes only
- Single OpenEMR replica due to RWO storage limitation
- Resource quotas: ~768Mi RAM and ~500m CPU per container
- Total storage: 15Gi (5Gi database + 10Gi documents)

## Components

### OpenEMR Container
- **Base**: CentOS 9 Stream
- **PHP**: 8.4 (from Remi's repository)
- **Web Server**: nginx + PHP-FPM (via supervisord)
- **OpenEMR**: 7.0.5
- **Features**:
  - OpenShift SCC compliant (runs as arbitrary UID)
  - Health check endpoints
  - OPcache enabled for performance
  - All required PHP extensions

### Database
- **Image**: Red Hat MariaDB 10.11
- **Storage**: 5Gi RWO persistent volume (gp3)
- **Credentials**: Auto-generated secure passwords

### Storage
- **Documents**: 10Gi RWO volume (for patient documents, images) - gp3 EBS
- **Database**: 5Gi RWO volume (for MariaDB data) - gp3 EBS
- **Storage Class**: `gp3` (AWS EBS CSI driver, default in Developer Sandbox)

## Prerequisites

- Red Hat OpenShift Developer Sandbox account ([Get free access](https://developers.redhat.com/developer-sandbox))
- `oc` CLI tool installed and configured
- Access to Quay.io for pulling container images (or build your own)
- Basic understanding of Kubernetes/OpenShift concepts

**Developer Sandbox Limitations to be aware of:**
- Projects expire after 30 days of inactivity
- Storage limited to ~40GB total per namespace
- Resource quotas: Limited CPU/memory per namespace
- No cluster-admin access
- Single replica deployments recommended for persistent storage

## Quick Start

### 1. Clone the Repository

```bash
git clone https://github.com/ryannix123/openemr-openshift.git
cd openemr-openshift
```

### 2. Build the Container (Optional)

If you want to build your own container:

```bash
# Build the container
podman build -t quay.io/ryan_nix/openemr-openshift:7.0.5 .

# Push to Quay.io
podman login quay.io
podman push quay.io/ryan_nix/openemr-openshift:7.0.5
```

Or use the pre-built image: `quay.io/ryan_nix/openemr-openshift:7.0.5`

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
4. Then scale: `oc scale deployment/openemr --replicas=3 -n openemr`

### Resource Limits

Current resource allocations (optimized for Developer Sandbox):

**OpenEMR Pod:**
- Requests: 384Mi RAM, 200m CPU
- Limits: 768Mi RAM, 500m CPU

**MariaDB:**
- Requests: 512Mi RAM, 200m CPU
- Limits: 1Gi RAM, 500m CPU

**Total Namespace Usage:**
- RAM: ~896Mi requests, ~1.75Gi limits
- CPU: ~400m requests, ~1000m limits
- Storage: 15Gi (5Gi DB + 10Gi documents)

These values fit within typical Developer Sandbox namespace quotas.

## Container Details

### PHP Configuration

The container includes these PHP settings optimized for OpenEMR:

```ini
upload_max_filesize = 128M
post_max_size = 128M
memory_limit = 512M
max_execution_time = 300
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
oc exec -it statefulset/mariadb -n openemr -- \
  mysqldump -u root -p"$DB_ROOT_PASSWORD" openemr > openemr-backup-$(date +%Y%m%d).sql
```

**Document backup:**
```bash
# Backup documents PVC
oc rsync openemr-pod:/var/www/html/openemr/sites/default/documents ./backup/documents/
```

### Updates

**Update OpenEMR container:**
```bash
# Build new version
podman build -t quay.io/ryan_nix/openemr-openshift:7.0.6 .
podman push quay.io/ryan_nix/openemr-openshift:7.0.6

# Update deployment
oc set image deployment/openemr \
  openemr=quay.io/ryan_nix/openemr-openshift:7.0.6 -n openemr
```

## Project Structure

```
openemr-openshift/
├── Containerfile              # Container build instructions
├── deploy-openemr.sh          # Automated deployment script
├── README.md                  # This file
├── .containerignore           # Files to ignore during build
└── manifests/                 # (Optional) Individual YAML files
    ├── deployment.yaml
    ├── service.yaml
    ├── route.yaml
    └── mariadb/
        ├── statefulset.yaml
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

**Ryan Nix**
- Senior Solutions Architect, Red Hat
- GitHub: [@ryannix123](https://github.com/ryannix123)
- Quay.io: [ryan_nix](https://quay.io/user/ryan_nix)

## Acknowledgments

- OpenEMR development team
- Red Hat OpenShift team
- Based on the Nextcloud on OpenShift pattern

---

**Note**: This is designed for healthcare environments. Ensure compliance with HIPAA, HITECH, and other applicable regulations in your jurisdiction before deploying with real patient data.
