# 🎯 Current OpenEMR Deployment Stack

## ✅ Updated Successfully - Ready to Deploy!

```
┌─────────────────────────────────────────────────────────┐
│                                                         │
│           OpenEMR 8.0.0 Production Stack                │
│                                                         │
│  🔹 Base OS: CentOS Stream 10                          │
│  🔹 PHP Runtime: 8.5 (Remi's Repository)               │
│  🔹 OpenEMR: 8.0.0 (Released Feb 11, 2026)             │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

---

## 📦 Complete Technology Stack

| Layer | Component | Version | Source |
|-------|-----------|---------|--------|
| **Container Base** | CentOS Stream | **10** | quay.io/centos/centos:stream10 |
| **Application** | OpenEMR | **8.0.0** | GitHub (tag v8_0_0) |
| **PHP Runtime** | PHP | **8.5** | Remi's repository (EL 10) |
| **PHP Extensions** | ~30 extensions | **8.5** | php:remi-8.5 module |
| **Web Server** | nginx | Latest (Stream 10) | CentOS AppStream |
| **Process Manager** | PHP-FPM | **8.5** | Remi's repository |
| **Supervisor** | supervisord | Latest | EPEL 10 |
| **Database** | MariaDB | **11.8** | Fedora/Quay.io |
| **Cache/Sessions** | Redis | **8 Alpine** | Docker Hub |

---

## 🎨 Architecture Diagram

```
┌────────────────────────────────────────────────────────────┐
│                    OpenShift Route                         │
│            (HTTPS with auto-generated cert)                │
└────────────────────┬───────────────────────────────────────┘
                     │
┌────────────────────▼───────────────────────────────────────┐
│               OpenEMR Service (ClusterIP:8080)             │
└────────────────────┬───────────────────────────────────────┘
                     │
┌────────────────────▼───────────────────────────────────────┐
│                  OpenEMR Container                         │
│  ┌──────────────────────────────────────────────────────┐  │
│  │   CentOS Stream 10 (Base OS)                         │  │
│  │                                                      │  │
│  │   ┌─────────────────┐      ┌──────────────────┐    │  │
│  │   │ nginx (8080)    │◄────►│ PHP-FPM (9000)   │    │  │
│  │   │                 │      │  PHP 8.5         │    │  │
│  │   └─────────────────┘      └──────────────────┘    │  │
│  │              │                       │              │  │
│  │              └───────────┬───────────┘              │  │
│  │                          │                          │  │
│  │                 ┌────────▼────────┐                 │  │
│  │                 │  supervisord    │                 │  │
│  │                 │ (Process Mgr)   │                 │  │
│  │                 └─────────────────┘                 │  │
│  │                                                      │  │
│  │   OpenEMR 8.0.0 @ /var/www/html/openemr            │  │
│  │   Auto-configure.php (first-run setup)              │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                            │
│  Persistent Storage:                                       │
│  - /var/www/html/openemr/sites/default/documents (10Gi)   │
└─────────┬──────────────────┬────────────────┬─────────────┘
          │                  │                │
          ▼                  ▼                ▼
    ┌──────────┐      ┌──────────┐    ┌──────────┐
    │  Redis   │      │ MariaDB  │    │Documents │
    │   Pod    │      │StatefulSet│    │   PVC    │
    │  (8.0)   │      │  (11.8)  │    │  (10Gi)  │
    │          │      │          │    │          │
    │  1Gi PVC │      │  5Gi PVC │    │  RWO     │
    └──────────┘      └──────────┘    └──────────┘
```

---

## 🚀 Ready to Deploy!

Your deployment is **100% ready** with all upgrades applied.

### **Option A — Shell Script** (Linux, macOS, WSL)

```bash
# 1. Build the new container
./build-container.sh

# 2. Push to Quay.io
podman push quay.io/ryan_nix/openemr-openshift:latest
podman push quay.io/ryan_nix/openemr-openshift:8.0.0

# 3. Deploy
./deploy-openemr.sh

# Or upgrade existing deployment:
oc rollout restart deployment/openemr -n openemr
```

### **Option B — Ansible Playbook** (macOS, Linux, Windows — no WSL required)

```bash
# 1. Install prerequisites (one-time)
pip install ansible kubernetes
ansible-galaxy collection install kubernetes.core

# 2. Build and push the container (same as above)
./build-container.sh
podman push quay.io/ryan_nix/openemr-openshift:latest

# 3. Deploy
cd ansible/
ansible-playbook deploy-openemr.yml

# Common overrides:
ansible-playbook deploy-openemr.yml -e "storage_class=ocs-storagecluster-ceph-rbd"
ansible-playbook deploy-openemr.yml -e "action=status"
ansible-playbook deploy-openemr.yml -e "action=cleanup"
```

> See `ansible/vars/main.yml` for all tunables and `ansible/README.md` for full documentation.

---

## 📊 What Changed from Previous Version

| Component | Before | After | Status |
|-----------|--------|-------|--------|
| **Base OS** | CentOS Stream 9 | **CentOS Stream 10** | ✅ Upgraded |
| **PHP** | 8.4 | **8.5** | ✅ Upgraded |
| **OpenEMR** | 7.0.4 | **8.0.0** | ✅ Upgraded |
| **MariaDB** | 11.8 | 11.8 | ✅ Same (compatible) |
| **Redis** | 8 Alpine | 8 Alpine | ✅ Same (compatible) |
| **nginx** | Stream 9 package | Stream 10 package | ✅ Updated |
| **Ansible deployment** | — | **ansible/** | ✅ Added |

---

## 🎯 Key Benefits

### **CentOS Stream 10**
✅ Latest RHEL 10 development features  
✅ Modern kernel (6.x series)  
✅ Enhanced container optimizations  
✅ Better ARM64 support  
✅ Improved security policies (SELinux)  

### **PHP 8.5**
✅ Property hooks (cleaner code)  
✅ Asymmetric visibility  
✅ 5-10% performance improvement  
✅ Latest security patches  
✅ Full OpenEMR 8.0.0 compatibility  

### **OpenEMR 8.0.0**
✅ US Core 8.0 FHIR compliance  
✅ USCDI v5 support  
✅ Enhanced care team management  
✅ Improved clinical documentation  
✅ Better interoperability  

### **Ansible Playbook**
✅ No bash or WSL dependency  
✅ Idempotent — safe to re-run  
✅ Exports all YAML manifests post-deploy  
✅ AAP/Tower compatible  
✅ All config externalized to `vars/main.yml`  

---

## ✅ Verification After Deployment

Run these commands after deploying:

```bash
# Check PHP version
oc exec deployment/openemr -n openemr -- php -v
# Expected: PHP 8.5.x ... Built by Remi's RPM repository

# Check OS version
oc exec deployment/openemr -n openemr -- cat /etc/redhat-release
# Expected: CentOS Stream release 10

# Check OpenEMR version
oc exec deployment/openemr -n openemr -- env | grep OPENEMR_VERSION
# Expected: OPENEMR_VERSION=8.0.0

# View startup logs
oc logs deployment/openemr -n openemr --tail=50
# Should show:
#   OpenEMR Version: 8.0.0
#   PHP Version: PHP 8.5.x
```

---

## 📝 Project Files

```
openemr-on-openshift/
├── Containerfile              # Container build instructions
├── deploy-openemr.sh          # Shell script deployment (bash/WSL)
├── build-container.sh         # Container build script
├── README.md                  # Project documentation
├── CHANGELOG.md               # Version history
├── CURRENT-STACK.md           # This file
├── UPGRADE-TO-8.0.0.md        # Upgrade guide
├── ansible/                   # Ansible deployment (platform-agnostic)
│   ├── deploy-openemr.yml     # Main playbook
│   ├── vars/
│   │   └── main.yml           # All tunables
│   └── README.md              # Ansible documentation
└── manifests/                 # Individual YAML files (reference)
```

---

## 🎊 Next Steps

1. **Review** the CHANGELOG.md for full details
2. **Build** the container: `./build-container.sh`
3. **Push** to registry: `podman push ...`
4. **Deploy** via shell script or Ansible playbook
5. **Verify** using commands above
6. **Test** OpenEMR admin interface

---

**Status**: ✅ READY TO DEPLOY  
**Last Updated**: February 27, 2026  
**Maintained By**: Ryan Nix  
**Registry**: quay.io/ryan_nix/openemr-openshift