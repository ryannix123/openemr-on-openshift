# lldap-on-openshift

<p align="center">
  <img src="https://miro.medium.com/v2/resize:fit:598/format:webp/1*KanqkJzW8EURgM86TePD0w.jpeg" alt="lldap" width="220">
</p>

<p align="center">
  <a href="https://github.com/ryannix123/lldap-on-openshift/actions/workflows/build.yaml">
    <img src="https://img.shields.io/github/actions/workflow/status/ryannix123/lldap-on-openshift/build.yaml?branch=main&label=build&logo=github" alt="Build Status">
  </a>
  <a href="https://quay.io/repository/ryan_nix/lldap-openshift">
    <img src="https://img.shields.io/badge/quay.io-ryan__nix%2Flldap--openshift-1f6feb?logo=redhat" alt="Quay.io">
  </a>
  <img src="https://img.shields.io/badge/lldap-0.6.2-brightgreen" alt="lldap version">
  <img src="https://img.shields.io/badge/base-lldap%3Astable-4b8bbe" alt="lldap stable">
  <img src="https://img.shields.io/badge/arch-amd64%20%7C%20arm64-6e7681" alt="Multi-arch">
  <img src="https://img.shields.io/badge/OpenShift-compatible-EE0000?logo=redhat&logoColor=white" alt="OpenShift compatible">
  <img src="https://img.shields.io/badge/RAM-~20MB-success" alt="Low memory footprint">
</p>

> **Lightweight in-cluster LDAP authentication for OpenEMR on OpenShift.**

[lldap](https://github.com/lldap/lldap) is a Rust-based lightweight LDAP server purpose-built for authentication. It runs at ~20MB RAM, stores users in a single SQLite file, and includes a built-in web UI for user and group management — no `ldapadd` commands, no schema files, no LDIF.

---

## Why lldap alongside OpenEMR on OpenShift?

OpenEMR supports LDAP authentication but is typically configured to reach an external directory service — Active Directory or a corporate LDAP server sitting outside the cluster. That introduces external dependencies, firewall rules, and a hard coupling that breaks whenever the upstream service is unreachable.

This project deploys lldap directly into the same OpenShift namespace as OpenEMR. Authentication traffic stays on the pod network, never crosses a namespace boundary, and requires no external infrastructure.

### OpenShift SCC compatibility

Getting any LDAP server running under OpenShift's restricted Security Context Constraints is non-trivial. The restricted SCC:

- Assigns a random UID from the namespace's allocated range at runtime — hardcoded UIDs fail
- Prohibits `fsGroup: 0` on newer clusters — blocking the standard Docker pattern of fixing PVC ownership at startup
- Prevents `chown` and `gosu` at container runtime — which most LDAP images depend on for initialization

lldap's Rust binary runs natively as any UID and needs no privilege escalation. This image patches the upstream `docker-entrypoint.sh` at build time to remove the `chown` and `gosu` calls that would fail under the restricted SCC, replacing them with a direct `exec` of the lldap binary. No custom SCC, no `anyuid`, no cluster-admin required.

### Why not OpenLDAP or 389 DS?

| | OpenLDAP | 389 DS | **lldap** |
|---|---|---|---|
| Restricted SCC compatible | ❌ Requires patching | ❌ Needs systemd | ✅ Native |
| Runtime `chown`/`gosu` | ✅ Required | ✅ Required | ❌ Not needed |
| Memory footprint | ~150MB | ~300MB+ | ~20MB |
| Bootstrap complexity | High (OLC, slapadd, mdb) | High (dscreate) | None |
| Storage backend | MDB (file-per-instance) | LMDB + indexes | SQLite (single file) |
| Built-in web UI | ❌ | ✅ | ✅ |

`openldap-servers` was removed from RHEL 8 and all downstream distributions including CentOS Stream 10. 389 DS requires systemd socket activation and cluster-admin to install its operator. lldap works out of the box.

---

## Architecture

```
OpenShift Namespace
├── Deployment/openemr
├── Deployment/lldap
│     ├── LDAP  :3890  (ClusterIP — in-cluster auth only)
│     ├── LDAPS :6360  (ClusterIP — TLS via OpenShift service cert)
│     └── Web   :17170 (Route — admin UI)
├── Service/lldap         (ClusterIP — unreachable from outside the cluster)
├── Route/lldap-web       (HTTPS edge termination for web UI only)
├── Secret/lldap-secret   (jwt-secret + admin-password)
├── Secret/lldap-tls      (auto-injected by OpenShift cert controller)
├── ConfigMap/lldap-ca-bundle (cluster CA for LDAPS client verification)
└── PVC/lldap-data        (SQLite database — 256Mi)
```

The `lldap` Service is `ClusterIP` only. There is no `NodePort`, no `LoadBalancer`, and no LDAP `Route`. Authentication traffic between OpenEMR and lldap physically cannot leave the cluster.

---

## Deployment

### Prerequisites

```bash
pip install kubernetes
ansible-galaxy collection install kubernetes.core
oc login --token=<token> --server=<api-url>
```

### Run the playbook

Switch to the namespace where OpenEMR is running, then:

```bash
ansible-playbook -i localhost, deploy.yml
```

The playbook prompts for:
- **LDAP base DN** — defaults to `dc=example,dc=com`, press Enter to accept
- **JWT secret** — press Enter to auto-generate, or paste your own
- **Admin password** — 8 character minimum

It detects your current namespace from `oc project`, creates the secret, applies the Service first so OpenShift's cert controller can inject the TLS secret, then deploys everything else and prints the web UI URL.

### Removing lldap

```bash
ansible-playbook -i localhost, deploy.yml -e deploy_action=delete
```

Removes all resources including the PVC and all user data. No prompts.

### Manual deployment

```bash
oc create secret generic lldap-secret \
  --from-literal=jwt-secret="$(openssl rand -hex 32)" \
  --from-literal=admin-password='<8-char-minimum>'

oc apply -f manifests/service.yaml
oc apply -k manifests/
```

---

## Connecting OpenEMR to lldap

### Step 1 — Create the user in lldap

Log in to the lldap web UI (URL is printed at the end of the playbook run) and create a user. The **User ID** field is what OpenEMR will use as the login username.

### Step 2 — Create a matching user in OpenEMR

Navigate to **Admin → User Administration → Add User** and create a user with the **exact same username** as the lldap User ID. The password set here is ignored once LDAP is enabled — lldap handles authentication — but the user record must exist in OpenEMR's database.

### Step 3 — Enable LDAP in OpenEMR 8.x

Navigate to **Admin → Config → Security** and configure:

| Setting | Value |
|---|---|
| Use LDAP for Authentication | ✅ Enabled |
| LDAP - Server Name or URI | `ldap://lldap:3890` |
| LDAP - Distinguished Name of User | `uid={login},ou=people,dc=example,dc=com` |

Save and log out. Log back in using the lldap username and password.

> **Note:** OpenEMR validates the password against lldap but still requires the user to exist in its own database. Both records must be present for login to succeed.

---

## Managing users

Users are managed entirely through the lldap web UI. No LDIF files or command-line tools required.

- **Create a user** — Users → Create a user
- **Reset a password** — click the user → Change password
- **Assign groups** — useful for role-based access if OpenEMR group filtering is configured

After creating a user in lldap, remember to also create the matching record in OpenEMR under **Admin → User Administration**.

---

## Directory layout

| DN | Purpose |
|---|---|
| `uid=admin,ou=people,<base>` | lldap admin — web UI and LDAP bind |
| `ou=people,<base>` | OpenEMR user accounts |
| `ou=groups,<base>` | Groups for role-based access |

---

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `LLDAP_LDAP_BASE_DN` | `dc=example,dc=com` | Root suffix — set before first deploy |
| `LLDAP_JWT_SECRET` | *(from Secret)* | Token signing secret — auto-generated if not provided |
| `LLDAP_LDAP_USER_PASS` | *(from Secret)* | Admin password — 8 character minimum |
| `LLDAP_DATABASE_URL` | `sqlite:///data/users.db?mode=rwc` | SQLite path — leave as default |
| `LLDAP_LDAPS_OPTIONS__ENABLED` | `true` | Enable LDAPS |
| `LLDAP_LDAPS_OPTIONS__PORT` | `6360` | LDAPS port (non-privileged) |

---

## Securing the web UI Route

By default the Route is publicly accessible. Restrict it to a specific IP range — useful for limiting access to a VPN or office network:

```bash
oc annotate route lldap-web \
  haproxy.router.openshift.io/ip_whitelist="10.0.0.0/8 192.168.1.0/24" \
  --overwrite
```

Or set it in `manifests/route.yaml` before deploying:

```yaml
metadata:
  annotations:
    haproxy.router.openshift.io/ip_whitelist: "10.0.0.0/8"
```

LDAP and LDAPS traffic on ports 3890 and 6360 are ClusterIP only — the Route only exposes the web UI.

---

## Image

`quay.io/ryan_nix/lldap-openshift:latest`

Built weekly from `lldap:stable`. Multi-arch: `linux/amd64` and `linux/arm64`. The upstream `docker-entrypoint.sh` is patched at build time to remove `chown` and `gosu` calls incompatible with OpenShift's restricted SCC.