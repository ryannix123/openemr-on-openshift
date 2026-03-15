# Jitsi Meet on OpenShift

[![Quay.io](https://img.shields.io/badge/quay.io-ryan__nix%2Fjitsi--openshift-blue)](https://quay.io/repository/ryan_nix/jitsi-openshift)
[![OpenShift](https://img.shields.io/badge/OpenShift-4.x-red)](https://www.redhat.com/en/technologies/cloud-computing/openshift)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

OpenShift-native Jitsi Meet — rebuilt from the ground up to run under the `restricted-v2` Security Context Constraint with zero privilege escalation. Designed to deploy alongside OpenEMR for HIPAA-friendly, self-hosted telehealth video conferencing.

> **Part of the [openemr-on-openshift](https://github.com/ryannix123/openemr-on-openshift) project.**

---

## Why a custom build?

The upstream Jitsi Docker images use **s6-overlay** as an init system. s6-overlay requires `CAP_SYS_ADMIN` to mount a tmpfs over `/run` at container startup — a capability that OpenShift's `restricted-v2` SCC explicitly denies. Every container crashes before the application ever starts.

This project solves that by rebasing all four Jitsi components onto **CentOS Stream 10** with direct `bash` entrypoints that replace s6 entirely. The Jitsi config generation logic (`tpl` + `cont-init.d` scripts) is preserved intact; only the init system is replaced.

---

## Architecture

```
                        ┌─────────────────────────────────────┐
                        │  OpenShift namespace (any project)   │
                        │                                      │
  Browser ──HTTPS──▶  Route ──▶  jitsi-meet (nginx)           │
                        │              │                       │
                        │              ▼                       │
                        │        jitsi-prosody (XMPP)         │
                        │         ▲          ▲                 │
                        │         │          │                 │
                        │   jitsi-jicofo   jitsi-jvb          │
                        │  (conf focus)  (media relay)        │
                        └─────────────────────────────────────┘
                                         │
                              UDP/10000 (NodePort)
                                         │
                              WebRTC media to clients
```

| Component | Base image | Role | Port(s) |
|---|---|---|---|
| **jitsi-meet** | CentOS Stream 10 + nginx | Web UI + nginx reverse proxy | 8080 (HTTP) |
| **jitsi-prosody** | CentOS Stream 10 + prosody (EPEL) | XMPP server | 5222, 5269, 5280, 5347 |
| **jitsi-jicofo** | CentOS Stream 10 + Java 21 | Conference focus / signaling | 8888 (internal) |
| **jitsi-jvb** | CentOS Stream 10 + Java 21 | WebRTC media relay | 10000/UDP, 9090 |

---

## Prerequisites

- OpenShift 4.x cluster (Developer Sandbox, ROSA, ARO, SNO, or self-managed)
- `oc` CLI logged in
- `podman` >= 4.x (for building images)
- Quay.io account — images published to `quay.io/ryan_nix/jitsi-openshift`

---

## Quick start

```bash
# 1. Clone the repo and switch to this branch
git clone -b feat/jitsi-openshift-port \
  https://github.com/ryannix123/openemr-on-openshift.git
cd openemr-on-openshift/jitsi

# 2. Build and push all four images
./build-push.sh

# 3. Deploy into your current OpenShift project
sh deploy-jitsi.sh
```

The deploy script auto-detects your cluster's apps domain, generates secrets, provisions a PVC for prosody user data, deploys all four components, sets JVB's ICE harvesting IP, and registers the `focus` and `jvb` XMPP users — all in one run.

---

## Files

```
jitsi/
├── Containerfile.meet              # Jitsi Meet web frontend (CentOS Stream 10 + nginx)
├── Containerfile.prosody           # Prosody XMPP server (CentOS Stream 10 + EPEL)
├── Containerfile.jicofo            # Jicofo conference focus (CentOS Stream 10 + Java 21)
├── Containerfile.jvb               # Jitsi Videobridge (CentOS Stream 10 + Java 21)
├── openshift-entrypoint-meet.sh    # s6-replacement entrypoint for meet
├── openshift-entrypoint-prosody.sh # s6-replacement entrypoint for prosody
├── openshift-entrypoint-jicofo.sh  # s6-replacement entrypoint for jicofo (+ NSS fix)
├── openshift-entrypoint-jvb.sh     # s6-replacement entrypoint for JVB (+ NSS fix)
├── build-push.sh                   # Build and push all images to Quay.io
└── deploy-jitsi.sh                 # Deploy / cleanup script
```

---

## Building images

```bash
# Build all components (native x86_64 recommended — Apple Silicon requires QEMU)
./build-push.sh

# Build a single component
./build-push.sh --component prosody

# Build without pushing (local test)
./build-push.sh --component meet --skip-push

# Pin a specific upstream Jitsi version
VERSION=stable-9909 ./build-push.sh
```

> **Apple Silicon note**: Cross-building `linux/amd64` images on ARM Macs via QEMU
> causes RPM transaction failures during `dnf install`. Build on a native x86_64
> machine or use GitHub Actions with an `ubuntu-latest` runner.

---

## Deployment

### Basic deploy

```bash
sh deploy-jitsi.sh
```

Deploys into your current `oc project`. The script will:

1. Auto-detect the cluster apps domain from ingress config, existing Routes, or the console URL
2. Generate `JICOFO_AUTH_PASSWORD`, `JVB_AUTH_PASSWORD`, `JICOFO_COMPONENT_SECRET` (idempotent — reuses existing Secret on re-runs)
3. Provision a 1Gi PVC for prosody user data (`/config/data`)
4. Deploy prosody, jicofo, JVB, and meet with full `restricted-v2` SCC posture
5. Set `DOCKER_HOST_ADDRESS` on JVB from the Service ClusterIP for ICE harvesting
6. Register `focus@auth.meet.jitsi` and `jvb@auth.meet.jitsi` in prosody

### Options

```bash
sh deploy-jitsi.sh --namespace my-project  # target specific namespace
sh deploy-jitsi.sh --dry-run               # print manifests without applying
sh deploy-jitsi.sh --cleanup               # remove all Jitsi resources
```

### LoadBalancer (production)

For clusters with MetalLB or a cloud LoadBalancer:

```bash
JVB_SERVICE_TYPE=LoadBalancer \
JVB_ADVERTISE_IPS=<your-lb-ip> \
  sh deploy-jitsi.sh
```

---

## OpenShift topology grouping

All resources include `app.kubernetes.io/part-of: jitsi` so they appear grouped
together in the OpenShift Developer topology view — the same way the OpenEMR
stack groups its components. Connection arrows between components are drawn via
`app.openshift.io/connects-to` annotations.

---

## OpenEMR telehealth integration

Once Jitsi is running, configure OpenEMR to use it:

```
Administration → Globals → Telehealth → Jitsi Server
→ https://jitsi.apps.<your-cluster-domain>
```

---

## Key OpenShift compatibility notes

### Why CentOS Stream 10 instead of the upstream Debian images

The upstream `jitsi/web`, `jitsi/prosody`, `jitsi/jicofo`, and `jitsi/jvb` images
all use **s6-overlay v2** as their init system. s6-overlay attempts to mount a
tmpfs over `/run` at startup. In the Jitsi Debian images, `/var/run` is a symlink
to `/run`, and the container runtime mounts a fresh kernel tmpfs over `/run` at
pod start — wiping any build-time permissions. This causes s6 to fail to create
its supervision tree (`/var/run/s6/services/*/supervise/`) before the application
ever launches.

CentOS Stream 10 images with direct `bash` entrypoints bypass this entirely.

### s6 entrypoint replacement

Each entrypoint script:
1. Skips `01-set-timezone` (requires root to `chown /etc/localtime`)
2. Skips scripts with `execlineb` shebangs (pure s6 plumbing)
3. Runs scripts with `with-contenv` shebangs via `bash` directly — this is where
   Jitsi's `10-config` lives, which renders all application config from environment
   variables using the `tpl` Go template binary
4. Strips `apt-cache` and `chown` calls from `with-contenv` scripts (Debian-only
   commands, and chown fails in restricted SCC)
5. Launches the application directly with `exec`

### Java NSS fix (jicofo + JVB)

OpenShift injects an arbitrary UID at runtime. Java's `InetAddress` and libpthread
call `getpwuid()` via NSS, which fails when the injected UID has no `/etc/passwd`
entry. Both Java entrypoints build a `/tmp/passwd` at startup with the injected
UID mapped to the service username, then export `NSS_WRAPPER_PASSWD=/tmp/passwd`.

### nginx configuration

The Jitsi `10-config` script generates a full nginx config at runtime to
`/config/nginx/nginx.conf` — including port 80, `user nginx;`, and a root pid
path. The `openshift-entrypoint-meet.sh` patches all generated configs with `sed`
before starting nginx:
- Port 80 → 8080 (already patched in `/defaults` templates at build time)
- `user nginx;` removed (non-root process)
- `pid /run/nginx.pid` → `pid /tmp/nginx.pid`

### Health probes

| Component | Probes | Reason |
|---|---|---|
| **jitsi-meet** | ✅ HTTP GET `/` on 8080 | nginx binds to 0.0.0.0:8080 |
| **jitsi-prosody** | ❌ Removed | Health endpoint not configured |
| **jitsi-jicofo** | ❌ Removed | Health endpoint binds to `127.0.0.1:8888` (loopback only, unreachable by kubelet) |
| **jitsi-jvb** | ❌ Removed | Health check hard-fails when UDP/10000 is not externally reachable (Developer Sandbox, ROSA) |

### JVB ICE harvesting

JVB needs a bindable local IP for WebRTC ICE candidate harvesting. In managed
OpenShift environments (Sandbox, ROSA, ARO), `oc get nodes` is restricted, so
pod IPs can't be discovered. The deploy script sets `DOCKER_HOST_ADDRESS` to
the `jitsi-jvb-udp` Service ClusterIP — a stable address that persists across
pod restarts and rollouts.

The AWS candidate harvester is disabled (`DISABLE_AWS_HARVESTER=true`) because
the EC2 metadata endpoint times out in the Developer Sandbox, causing a hard
health failure.

### Prosody user registration

Jitsi's upstream `services.d` background service registers the `focus` and `jvb`
XMPP users after prosody starts. On CentOS without s6, this is handled by the
deploy script running `prosodyctl register` via `oc exec` after prosody is ready.
User data is stored in a PVC (`/config/data`) so registrations persist across
prosody pod restarts.

---

## Troubleshooting

### All pods crash on startup

Check the logs:
```bash
{
  echo "=== prosody ===" && oc logs deployment/jitsi-prosody --tail=30
  echo "=== jicofo ===" && oc logs deployment/jitsi-jicofo --tail=30
  echo "=== jvb ===" && oc logs deployment/jitsi-jvb --tail=30
  echo "=== meet ===" && oc logs deployment/jitsi-meet --tail=30
} | pbcopy
```

### Jicofo: `not-authorized` SASL error

The `focus` XMPP user isn't registered. Run:
```bash
JICOFO_PASS=$(oc get secret jitsi-secrets \
  -o jsonpath='{.data.JICOFO_AUTH_PASSWORD}' | base64 -d)
oc exec deployment/jitsi-prosody -- \
  prosodyctl --config /config/prosody.cfg.lua \
  register focus auth.meet.jitsi "${JICOFO_PASS}"
```

### JVB: `No valid IP addresses available for harvesting`

JVB can't find a bindable IP. Set `DOCKER_HOST_ADDRESS` from the Service:
```bash
JVB_IP=$(oc get service jitsi-jvb-udp \
  -o jsonpath='{.spec.clusterIP}')
oc set env deployment/jitsi-jvb DOCKER_HOST_ADDRESS="${JVB_IP}"
```

### Jicofo: `conflict - Replaced by new connection`

Two jicofo pods are running simultaneously during a rolling update. Scale to zero
and back to force a clean single pod:
```bash
oc scale deployment/jitsi-jicofo --replicas=0
sleep 3
oc scale deployment/jitsi-jicofo --replicas=1
```

### Meet: nginx exits immediately

Run an `nginx -t` inside a sleep pod to diagnose config errors:
```bash
oc patch deployment/jitsi-meet \
  -p '{"spec":{"template":{"spec":{"containers":[{"name":"meet","command":["sh","-c","sleep 600"]}]}}}}'
# Wait for Running, then:
oc exec deployment/jitsi-meet -- nginx -t -c /config/nginx/nginx.conf
# Restore:
oc patch deployment/jitsi-meet \
  -p '{"spec":{"template":{"spec":{"containers":[{"name":"meet","command":null}]}}}}'
```

---

## Known limitations

| Limitation | Context | Workaround |
|---|---|---|
| WebRTC video requires external UDP | Developer Sandbox / ROSA — UDP NodePort not reachable externally | Deploy a coturn TURN server; set `JVB_STUN_SERVERS` |
| Apple Silicon cross-build failures | QEMU RPM transaction bugs on arm64 hosts | Build on x86_64 or use GitHub Actions |
| JVB health probes disabled | UDP not reachable in managed clusters | Re-enable on SNO/bare-metal with open NodePort |
| `apt-cache` stripped from init scripts | Debian-only command, not present on CentOS | Harmless — only used for version logging |

---

## Maintainer

Ryan Nix &lt;ryan.nix@gmail.com&gt;  
Red Hat Senior Solutions Architect  
[github.com/ryannix123](https://github.com/ryannix123)  
[quay.io/ryan_nix](https://quay.io/ryan_nix)
