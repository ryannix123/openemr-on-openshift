# OpenEMR Service Mesh — Ansible Deployment

Ansible replacement for `deploy-mesh.sh`. Deploys OpenShift Service Mesh 3
in ambient mode. Runs identically on macOS, Linux, and Windows — no shell
compatibility concerns.

## Why Ansible over the shell script?

The shell script accumulated platform-specific workarounds (BSD vs GNU sed,
multi-document YAML splitting, `oc apply -f -` pipes). The Ansible playbook
replaces all of that with:

- `kubernetes.core.k8s` — applies manifests directly via the Python
  Kubernetes client, no pipes or document parsing required
- `kubernetes.core.k8s_info` with `until` loops — portable waiting with no
  `oc wait` timeouts or shell polling
- Jinja2 templating — `{{ namespace }}` substitution is native, no `sed`
  pipelines needed
- Idempotent by default — re-running is always safe

## Prerequisites

```bash
pip install ansible kubernetes
ansible-galaxy collection install kubernetes.core

# Log into OpenShift before running
oc login --token=<token> --server=<url>
oc project <your-namespace>   # or set namespace in vars/mesh-main.yml
```

**Note**: cluster-admin is required for operator installation and IstioCNI
(a node-level DaemonSet). See the [privilege requirements](../service-mesh/README.md#privilege-requirements)
section in the service mesh README for details.

## Usage

```bash
# Full deployment — operators, control plane, policies, Kiali
ansible-playbook deploy-mesh.yml

# Deploy to a different namespace
ansible-playbook deploy-mesh.yml -e "namespace=my-emr"

# Staged deployment
ansible-playbook deploy-mesh.yml -e "action=operators"
ansible-playbook deploy-mesh.yml -e "action=control-plane"
ansible-playbook deploy-mesh.yml -e "action=policies"

# Status and cleanup
ansible-playbook deploy-mesh.yml -e "action=status"
ansible-playbook deploy-mesh.yml -e "action=cleanup"

# Use a custom vars file
ansible-playbook deploy-mesh.yml -e "@vars/prod.yml"
```

## Configuration — `vars/mesh-main.yml`

| Variable             | Default          | Description                              |
|----------------------|------------------|------------------------------------------|
| `action`             | `full`           | `full`, `operators`, `control-plane`, `policies`, `status`, `cleanup` |
| `namespace`          | `openemr`        | Namespace where OpenEMR is deployed      |
| `istio_namespace`    | `istio-system`   | Istio control plane namespace            |
| `cni_namespace`      | `istio-cni`      | IstioCNI namespace                       |
| `istio_version`      | `v1.23.3`        | Istio version deployed by Sail Operator  |
| `gateway_api_version`| `v1.1.0`         | Gateway API CRD version                  |
| `csv_retries`        | `60`             | CSV Succeeded retries (× 10s = 600s)    |
| `crd_retries`        | `60`             | CRD Established retries (× 5s = 300s)  |
| `istio_retries`      | `36`             | Istio CR Ready retries (× 5s = 180s)   |
| `waypoint_retries`   | `18`             | Waypoint Programmed retries (× 5s = 90s)|

## Recommended Deployment Order

Deploy OpenEMR first, verify it works, then apply the mesh:

```bash
# 1. Deploy OpenEMR
cd ..
ansible-playbook ansible/deploy-openemr.yml

# 2. Verify OpenEMR is healthy before adding mesh complexity
ansible-playbook ansible/deploy-openemr.yml -e "action=status"

# 3. Install mesh operators (requires cluster-admin)
ansible-playbook ansible/deploy-mesh.yml -e "action=operators"

# 4. Deploy control plane
ansible-playbook ansible/deploy-mesh.yml -e "action=control-plane"

# 5. Apply policies and enroll namespace
ansible-playbook ansible/deploy-mesh.yml -e "action=policies"
```

## Author

**Ryan Nix** <ryan.nix@gmail.com> — projects are personal, not official Red Hat
