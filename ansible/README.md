# OpenEMR on OpenShift — Ansible Deployment

Ansible replacement for `deploy-openemr.sh`. Runs on macOS, Linux, or any
system with Python and `oc` — no WSL or bash required.

## Prerequisites

```bash
# Python 3.9+ with pip
pip install ansible kubernetes

# kubernetes.core collection
ansible-galaxy collection install kubernetes.core

# OpenShift CLI — log in before running
oc login --token=<token> --server=<url>
oc project <your-namespace>
```

## Usage

```bash
# Deploy OpenEMR
ansible-playbook deploy-openemr.yml

# Check deployment status
ansible-playbook deploy-openemr.yml -e "action=status"

# Remove all resources (DELETES ALL DATA — prompts for confirmation)
ansible-playbook deploy-openemr.yml -e "action=cleanup"
```

## Configuration — `vars/main.yml`

All tunables live in `vars/main.yml`. Edit it directly or override at runtime.

| Variable                 | Default                                     | Description                   |
|--------------------------|---------------------------------------------|-------------------------------|
| `action`                 | `deploy`                                    | `deploy`, `status`, `cleanup` |
| `openemr_image`          | `quay.io/ryan_nix/openemr-openshift:latest` | OpenEMR container image       |
| `mariadb_image`          | `quay.io/fedora/mariadb-118:latest`         | MariaDB container image       |
| `redis_image`            | `docker.io/redis:8-alpine`                  | Redis container image         |
| `storage_class`          | `gp3-csi`                                   | StorageClass for PVCs         |
| `db_storage_size`        | `5Gi`                                       | MariaDB PVC size              |
| `documents_storage_size` | `10Gi`                                      | OpenEMR sites PVC size        |
| `redis_max_memory`       | `256mb`                                     | Redis maxmemory limit         |
| `redis_max_memory_policy`| `allkeys-lru`                               | Redis eviction policy         |
| `mariadb_resources`      | limits 1Gi/500m, req 512Mi/200m             | MariaDB resource block        |
| `redis_resources`        | limits 256Mi/250m, req 64Mi/50m             | Redis resource block          |
| `openemr_resources`      | limits 768Mi/500m, req 384Mi/200m           | OpenEMR resource block        |
| `mariadb_wait_timeout`   | `300`                                       | Pod ready wait (seconds)      |
| `redis_wait_timeout`     | `300`                                       | Pod ready wait (seconds)      |
| `openemr_wait_timeout`   | `300`                                       | Pod ready wait (seconds)      |
| `manifests_dir`          | `./openemr-manifests`                       | Where to write YAML exports   |
| `credentials_file`       | `./openemr-credentials.txt`                 | Path for credentials output   |

**Passwords** (`db_password`, `db_root_password`, `oe_admin_password`) are auto-generated
on first run. Uncomment and set them in `vars/main.yml` to pin specific values.

### Override examples

```bash
# Different storage class (ODF/Ceph)
ansible-playbook deploy-openemr.yml -e "storage_class=ocs-storagecluster-ceph-rbd"

# Use a custom vars file (e.g. for a prod environment)
ansible-playbook deploy-openemr.yml -e "@vars/prod.yml"

# Pin the admin password
ansible-playbook deploy-openemr.yml -e "oe_admin_password=MySecurePass123"
```

## Post-Deployment Outputs

After a successful deploy you'll find:

```
./openemr-credentials.txt          # Admin + DB passwords (mode 0600)
./openemr-manifests/
  ├── 01-mariadb-secret.yaml
  ├── 02-mariadb-pvc.yaml
  ├── 03-mariadb-deployment.yaml
  ├── 04-mariadb-service.yaml
  ├── 05-redis-deployment.yaml
  ├── 06-redis-service.yaml
  ├── 07-openemr-pvc.yaml
  ├── 08-openemr-secret.yaml
  ├── 09-openemr-deployment.yaml
  ├── 10-openemr-service.yaml
  ├── 11-openemr-route.yaml
  └── kustomization.yaml
```

The `kustomization.yaml` lets you re-apply everything with:

```bash
oc apply -k ./openemr-manifests/
```

## Idempotency

Re-running the playbook is safe — existing Secrets are detected and passwords
are preserved rather than regenerated.
