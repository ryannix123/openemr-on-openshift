#!/usr/bin/env bash
# =============================================================================
# deploy-jitsi.sh — Deploy OpenShift-compatible Jitsi Meet into an existing
#                   OpenShift namespace alongside OpenEMR
#
# Usage:
#   ./deploy-jitsi.sh                         # deploy with prompts
#   ./deploy-jitsi.sh --namespace openemr     # target namespace directly
#   ./deploy-jitsi.sh --cleanup               # remove all Jitsi resources
#   ./deploy-jitsi.sh --dry-run               # print manifests, no apply
#
# Prerequisites:
#   - oc CLI logged in with sufficient permissions (admin or edit + route/service create)
#   - Namespace already exists (created by deploy-openemr.sh)
#   - Images built and pushed to quay.io/ryan_nix/jitsi-openshift
#
# Architecture deployed:
#   prosody  — XMPP server        (ClusterIP only, internal)
#   jicofo   — Conference focus   (ClusterIP only, internal)
#   jvb      — Video bridge       (NodePort UDP/10000 for media)
#   meet     — Web frontend       (OpenShift Route, TLS edge)
#
# JVB media port: NodePort (default, works on SNO + bare-metal OCP)
#   To use LoadBalancer instead, set: JVB_SERVICE_TYPE=LoadBalancer
#   before running, and set JVB_ADVERTISE_IPS to the LB external IP.
#
# Maintainer: Ryan Nix <ryan.nix@gmail.com>
# =============================================================================

set -euo pipefail

# ── Registry / image config ───────────────────────────────────────────────────
REGISTRY="quay.io"
NAMESPACE_REGISTRY="ryan_nix"
REPO="jitsi-openshift"
IMAGE_TAG="stable"

IMAGE_MEET="${REGISTRY}/${NAMESPACE_REGISTRY}/${REPO}:meet"
IMAGE_PROSODY="${REGISTRY}/${NAMESPACE_REGISTRY}/${REPO}:prosody"
IMAGE_JICOFO="${REGISTRY}/${NAMESPACE_REGISTRY}/${REPO}:jicofo"
IMAGE_JVB="${REGISTRY}/${NAMESPACE_REGISTRY}/${REPO}:jvb"

# ── Defaults (override via env or --flag) ─────────────────────────────────────
NAMESPACE="${NAMESPACE:-}"
JVB_SERVICE_TYPE="${JVB_SERVICE_TYPE:-NodePort}"
JVB_NODEPORT="${JVB_NODEPORT:-30000}"       # UDP NodePort for media (30000-32767)
DRY_RUN=false
CLEANUP=false

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()   { echo -e "${CYAN}[jitsi]${RESET}  $*"; }
ok()    { echo -e "${GREEN}[ok]${RESET}     $*"; }
warn()  { echo -e "${YELLOW}[warn]${RESET}   $*"; }
error() { echo -e "${RED}[error]${RESET}  $*" >&2; }
die()   { error "$*"; exit 1; }
banner(){ echo -e "\n${BOLD}${CYAN}── $* ──${RESET}"; }

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace|-n) NAMESPACE="$2"; shift 2 ;;
    --cleanup)      CLEANUP=true; shift ;;
    --dry-run)      DRY_RUN=true; shift ;;
    --help|-h)
      sed -n '3,20p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *)
      die "Unknown argument: $1" ;;
  esac
done

# Wrapper: apply or dry-run print
oc_apply() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "--- DRY RUN: would apply ---"
    cat
    echo "----------------------------"
  else
    oc apply -f -
  fi
}

# ── Teardown ──────────────────────────────────────────────────────────────────
if [[ "${CLEANUP}" == "true" ]]; then
  banner "Tearing down Jitsi from namespace: ${NAMESPACE}"
  warn "This removes all Jitsi Deployments, Services, Routes, ConfigMaps, and Secrets."
  read -rp "  Are you sure? (yes/no): " confirm
  [[ "${confirm}" == "yes" ]] || { log "Aborted."; exit 0; }

  for resource in deployment/jitsi-meet deployment/jitsi-prosody \
                  deployment/jitsi-jicofo deployment/jitsi-jvb; do
    oc delete "${resource}" -n "${NAMESPACE}" --ignore-not-found
  done
  for resource in service/jitsi-meet service/jitsi-prosody \
                  service/jitsi-jicofo service/jitsi-jvb-http service/jitsi-jvb-udp; do
    oc delete "${resource}" -n "${NAMESPACE}" --ignore-not-found
  done
  oc delete route/jitsi-meet -n "${NAMESPACE}" --ignore-not-found
  oc delete configmap/jitsi-config -n "${NAMESPACE}" --ignore-not-found
  oc delete secret/jitsi-secrets -n "${NAMESPACE}" --ignore-not-found
  ok "Jitsi resources removed from namespace '${NAMESPACE}'."
  exit 0
fi

# ── Pre-flight ────────────────────────────────────────────────────────────────
banner "Pre-flight checks"

command -v oc &>/dev/null    || die "'oc' not found. Install the OpenShift CLI."
command -v openssl &>/dev/null || die "'openssl' not found."

log "Verifying OpenShift login..."
OC_USER=$(oc whoami 2>/dev/null) || die "Not logged into OpenShift. Run: oc login <cluster>"
ok "Logged in as: ${BOLD}${OC_USER}${RESET}"

# Use current oc project if namespace not set via --namespace flag or NAMESPACE env var
if [[ -z "${NAMESPACE}" ]]; then
  NAMESPACE=$(oc project -q 2>/dev/null) || die "Could not determine current project. Run: oc login <cluster>"
fi
log "Deploying into namespace: ${BOLD}${NAMESPACE}${RESET}"

ok "Namespace: ${BOLD}${NAMESPACE}${RESET}"

# Auto-detect the cluster apps domain without requiring cluster-reader permissions.
# Strategy (tried in order):
#   1. Cluster ingress config  — works on SNO / self-managed OCP (needs cluster-reader)
#   2. Existing Route hostname — works on Developer Sandbox / ROSA / ARO (any user)
#   3. oc whoami --show-console — parse domain from console URL (always available)
APPS_DOMAIN=$(oc get ingresses.config.openshift.io cluster \
              -o jsonpath='{.spec.domain}' 2>/dev/null || true)

if [[ -z "${APPS_DOMAIN}" ]]; then
  # Try to sniff domain from any existing Route in the current namespace
  SAMPLE_HOST=$(oc get routes -n "${NAMESPACE}" \
                -o jsonpath='{.items[0].spec.host}' 2>/dev/null || true)
  if [[ -n "${SAMPLE_HOST}" ]]; then
    # Strip the first label (app name) to get the shared apps domain
    APPS_DOMAIN="${SAMPLE_HOST#*.}"
  fi
fi

if [[ -z "${APPS_DOMAIN}" ]]; then
  # Derive from the console URL: https://console-openshift-console.apps.<domain>
  CONSOLE_URL=$(oc whoami --show-console 2>/dev/null || true)
  if [[ -n "${CONSOLE_URL}" ]]; then
    APPS_DOMAIN=$(echo "${CONSOLE_URL}" | sed 's|https://console-openshift-console\.||')
  fi
fi

if [[ -z "${APPS_DOMAIN}" ]]; then
  die "Could not auto-detect cluster apps domain. Set it manually: APPS_DOMAIN=apps.my-cluster.example.com sh deploy-jitsi.sh"
fi

JITSI_HOSTNAME="jitsi.${APPS_DOMAIN}"
log "Jitsi URL will be: ${BOLD}https://${JITSI_HOSTNAME}${RESET}"

# ── Secret generation ─────────────────────────────────────────────────────────
banner "Generating Jitsi secrets"

# Check if secrets already exist (idempotent re-runs)
if oc get secret jitsi-secrets -n "${NAMESPACE}" &>/dev/null; then
  warn "Secret 'jitsi-secrets' already exists — reusing existing passwords."
  warn "To regenerate, run: oc delete secret jitsi-secrets -n ${NAMESPACE}"
  JICOFO_AUTH_PASSWORD=$(oc get secret jitsi-secrets -n "${NAMESPACE}" \
                         -o jsonpath='{.data.JICOFO_AUTH_PASSWORD}' | base64 -d)
  JVB_AUTH_PASSWORD=$(oc get secret jitsi-secrets -n "${NAMESPACE}" \
                      -o jsonpath='{.data.JVB_AUTH_PASSWORD}' | base64 -d)
  JICOFO_COMPONENT_SECRET=$(oc get secret jitsi-secrets -n "${NAMESPACE}" \
                             -o jsonpath='{.data.JICOFO_COMPONENT_SECRET}' | base64 -d)
else
  JICOFO_AUTH_PASSWORD=$(openssl rand -hex 16)
  JVB_AUTH_PASSWORD=$(openssl rand -hex 16)
  JICOFO_COMPONENT_SECRET=$(openssl rand -hex 16)
  ok "Generated JICOFO_AUTH_PASSWORD, JVB_AUTH_PASSWORD, JICOFO_COMPONENT_SECRET"
fi

# ── JVB external IP / NodePort info ───────────────────────────────────────────
banner "JVB media networking"

if [[ "${JVB_SERVICE_TYPE}" == "LoadBalancer" ]]; then
  if [[ -z "${JVB_ADVERTISE_IPS:-}" ]]; then
    read -rp "  Enter the LoadBalancer external IP for JVB_ADVERTISE_IPS: " JVB_ADVERTISE_IPS
  fi
  log "JVB service type : LoadBalancer"
  log "JVB advertise IP : ${JVB_ADVERTISE_IPS}"
else
  # Try to auto-detect the first node's internal IP (works on SNO / bare-metal OCP).
  # In restricted environments (Developer Sandbox, ROSA, ARO) node listing is not
  # permitted — fall back to the cluster apps hostname so the deployment proceeds.
  # JVB_ADVERTISE_IPS can always be patched later via:
  #   oc set env deployment/jitsi-jvb JVB_ADVERTISE_IPS=<ip> -n <namespace>
  NODE_IP=$(oc get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)
  if [[ -n "${NODE_IP}" ]]; then
    JVB_ADVERTISE_IPS="${NODE_IP}"
    log "JVB service type : NodePort (${JVB_NODEPORT}/UDP)"
    log "JVB advertise IP : ${JVB_ADVERTISE_IPS} (auto-detected node IP)"
    warn "Ensure UDP/${JVB_NODEPORT} is open in your firewall/security group for WebRTC media."
  else
    # Sandbox / managed cluster — no node access. Use apps domain as placeholder.
    # Video calls will work only once JVB_ADVERTISE_IPS is set to a reachable IP
    # or a TURN server is configured. All other Jitsi components deploy normally.
    JVB_ADVERTISE_IPS="${APPS_DOMAIN}"
    log "JVB service type : NodePort (${JVB_NODEPORT}/UDP)"
    warn "Could not detect node IP (restricted cluster / Developer Sandbox)."
    warn "JVB_ADVERTISE_IPS set to '${APPS_DOMAIN}' as placeholder."
    warn "WebRTC media will not work until you set a reachable IP or TURN server:"
    warn "  oc set env deployment/jitsi-jvb JVB_ADVERTISE_IPS=<ip> -n ${NAMESPACE}"
  fi
fi

# ── Secret manifest ───────────────────────────────────────────────────────────
banner "Applying Secret"

cat <<EOF | oc_apply
apiVersion: v1
kind: Secret
metadata:
  name: jitsi-secrets
  namespace: ${NAMESPACE}
  labels:
    app: jitsi
type: Opaque
stringData:
  JICOFO_AUTH_PASSWORD: "${JICOFO_AUTH_PASSWORD}"
  JVB_AUTH_PASSWORD: "${JVB_AUTH_PASSWORD}"
  JICOFO_COMPONENT_SECRET: "${JICOFO_COMPONENT_SECRET}"
EOF
ok "Secret 'jitsi-secrets' applied."

# ── ConfigMap ─────────────────────────────────────────────────────────────────
banner "Applying ConfigMap"

cat <<EOF | oc_apply
apiVersion: v1
kind: ConfigMap
metadata:
  name: jitsi-config
  namespace: ${NAMESPACE}
  labels:
    app: jitsi
data:
  # Shared domain used by all components for XMPP routing
  XMPP_DOMAIN: "meet.jitsi"
  XMPP_AUTH_DOMAIN: "auth.meet.jitsi"
  XMPP_INTERNAL_MUC_DOMAIN: "internal-muc.meet.jitsi"
  XMPP_MUC_DOMAIN: "muc.meet.jitsi"
  XMPP_GUEST_DOMAIN: "guest.meet.jitsi"
  XMPP_SERVER: "jitsi-prosody"     # ClusterIP Service name
  XMPP_PORT: "5222"
  XMPP_BOSH_URL_BASE: "http://jitsi-prosody:5280"

  # Public-facing URL (used by jitsi-meet web and jicofo)
  PUBLIC_URL: "https://${JITSI_HOSTNAME}"

  # JVB
  JVB_AUTH_USER: "jvb"
  JVB_PORT: "10000"
  JVB_ADVERTISE_IPS: "${JVB_ADVERTISE_IPS}"
  JVB_TCP_HARVESTER_DISABLED: "true"   # UDP-only, no TCP fallback needed via Route

  # Jicofo
  JICOFO_AUTH_USER: "focus"

  # Jitsi Meet web
  ENABLE_AUTH: "0"                     # set to 1 to require login
  ENABLE_GUESTS: "1"
  ENABLE_LETSENCRYPT: "0"              # TLS handled by OpenShift Route
  DISABLE_HTTPS: "1"                   # meet container speaks HTTP; Route does TLS
  HTTP_PORT: "8080"
  HTTPS_PORT: "8443"
  TZ: "America/Chicago"

EOF
ok "ConfigMap 'jitsi-config' applied."

# ── Prosody Deployment + Service ──────────────────────────────────────────────
banner "Deploying Prosody (XMPP)"

cat <<EOF | oc_apply
apiVersion: apps/v1
kind: Deployment
metadata:
  name: jitsi-prosody
  namespace: ${NAMESPACE}
  labels:
    app: jitsi
    component: prosody
spec:
  replicas: 1
  selector:
    matchLabels:
      app: jitsi
      component: prosody
  template:
    metadata:
      labels:
        app: jitsi
        component: prosody
    spec:
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      volumes:
        - name: s6-run
          emptyDir:
            medium: Memory
      containers:
        - name: prosody
          image: ${IMAGE_PROSODY}
          imagePullPolicy: Always
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          ports:
            - containerPort: 5222   # XMPP client
            - containerPort: 5269   # XMPP s2s
            - containerPort: 5280   # BOSH / WebSocket
            - containerPort: 5347   # XMPP component (JVB)
          envFrom:
            - configMapRef:
                name: jitsi-config
          env:
            - name: JICOFO_AUTH_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: jitsi-secrets
                  key: JICOFO_AUTH_PASSWORD
            - name: JVB_AUTH_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: jitsi-secrets
                  key: JVB_AUTH_PASSWORD
            - name: JICOFO_COMPONENT_SECRET
              valueFrom:
                secretKeyRef:
                  name: jitsi-secrets
                  key: JICOFO_COMPONENT_SECRET
          readinessProbe:
            tcpSocket:
              port: 5222
            initialDelaySeconds: 15
            periodSeconds: 10
          livenessProbe:
            tcpSocket:
              port: 5222
            initialDelaySeconds: 30
            periodSeconds: 20
          resources:
            requests:
              memory: "256Mi"
              cpu: "100m"
            limits:
          volumeMounts:
            - name: s6-run
              mountPath: /run/s6
              memory: "512Mi"
              cpu: "500m"
---
apiVersion: v1
kind: Service
metadata:
  name: jitsi-prosody
  namespace: ${NAMESPACE}
  labels:
    app: jitsi
    component: prosody
spec:
  selector:
    app: jitsi
    component: prosody
  ports:
    - name: xmpp-client
      port: 5222
      targetPort: 5222
    - name: xmpp-s2s
      port: 5269
      targetPort: 5269
    - name: bosh
      port: 5280
      targetPort: 5280
    - name: xmpp-component
      port: 5347
      targetPort: 5347
EOF
ok "Prosody deployed."

# ── Jicofo Deployment + Service ───────────────────────────────────────────────
banner "Deploying Jicofo (Conference Focus)"

cat <<EOF | oc_apply
apiVersion: apps/v1
kind: Deployment
metadata:
  name: jitsi-jicofo
  namespace: ${NAMESPACE}
  labels:
    app: jitsi
    component: jicofo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: jitsi
      component: jicofo
  template:
    metadata:
      labels:
        app: jitsi
        component: jicofo
    spec:
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      volumes:
        - name: s6-run
          emptyDir:
            medium: Memory
      containers:
        - name: jicofo
          image: ${IMAGE_JICOFO}
          imagePullPolicy: Always
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          ports:
            - containerPort: 8888   # REST API / health
          envFrom:
            - configMapRef:
                name: jitsi-config
          env:
            - name: JICOFO_AUTH_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: jitsi-secrets
                  key: JICOFO_AUTH_PASSWORD
            - name: JICOFO_COMPONENT_SECRET
              valueFrom:
                secretKeyRef:
                  name: jitsi-secrets
                  key: JICOFO_COMPONENT_SECRET
          readinessProbe:
            httpGet:
              path: /about/health
              port: 8888
            initialDelaySeconds: 20
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /about/health
              port: 8888
            initialDelaySeconds: 40
            periodSeconds: 20
          resources:
            requests:
              memory: "256Mi"
              cpu: "100m"
            limits:
          volumeMounts:
            - name: s6-run
              mountPath: /run/s6
              memory: "512Mi"
              cpu: "500m"
---
apiVersion: v1
kind: Service
metadata:
  name: jitsi-jicofo
  namespace: ${NAMESPACE}
  labels:
    app: jitsi
    component: jicofo
spec:
  selector:
    app: jitsi
    component: jicofo
  ports:
    - name: rest-api
      port: 8888
      targetPort: 8888
EOF
ok "Jicofo deployed."

# ── JVB Deployment + Services ─────────────────────────────────────────────────
banner "Deploying JVB (Videobridge)"

# JVB Deployment + ClusterIP TCP service (Colibri WS + health)
cat <<EOF | oc_apply
apiVersion: apps/v1
kind: Deployment
metadata:
  name: jitsi-jvb
  namespace: ${NAMESPACE}
  labels:
    app: jitsi
    component: jvb
spec:
  # Do not scale JVB replicas > 1 without configuring Octo cascade mode
  replicas: 1
  selector:
    matchLabels:
      app: jitsi
      component: jvb
  template:
    metadata:
      labels:
        app: jitsi
        component: jvb
    spec:
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      volumes:
        - name: s6-run
          emptyDir:
            medium: Memory
      containers:
        - name: jvb
          image: ${IMAGE_JVB}
          imagePullPolicy: Always
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          ports:
            - containerPort: 10000
              protocol: UDP
              name: media-udp
            - containerPort: 9090
              protocol: TCP
              name: colibri-ws
            - containerPort: 8080
              protocol: TCP
              name: health
          envFrom:
            - configMapRef:
                name: jitsi-config
          env:
            - name: JVB_AUTH_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: jitsi-secrets
                  key: JVB_AUTH_PASSWORD
            # Colibri2 WebSocket — used by jitsi-meet to signal JVB directly
            - name: JVB_WS_DOMAIN
              value: "${JITSI_HOSTNAME}"
            - name: JVB_WS_SERVER_ID
              value: "jvb-1"
          readinessProbe:
            httpGet:
              path: /about/health
              port: 8080
            initialDelaySeconds: 20
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /about/health
              port: 8080
            initialDelaySeconds: 40
            periodSeconds: 20
          resources:
            requests:
              memory: "512Mi"
              cpu: "200m"
            limits:
          volumeMounts:
            - name: s6-run
              mountPath: /run/s6
              memory: "1Gi"
              cpu: "1000m"
---
# TCP Service: Colibri WebSocket signaling + health (ClusterIP)
apiVersion: v1
kind: Service
metadata:
  name: jitsi-jvb-http
  namespace: ${NAMESPACE}
  labels:
    app: jitsi
    component: jvb
spec:
  selector:
    app: jitsi
    component: jvb
  ports:
    - name: colibri-ws
      port: 9090
      targetPort: 9090
    - name: health
      port: 8080
      targetPort: 8080
EOF

# UDP Service: split into its own heredoc so the nodePort field can be
# conditionally included with a plain bash if — no inline substitutions.
if [[ "${JVB_SERVICE_TYPE}" == "NodePort" ]]; then
  cat <<EOF | oc_apply
apiVersion: v1
kind: Service
metadata:
  name: jitsi-jvb-udp
  namespace: ${NAMESPACE}
  labels:
    app: jitsi
    component: jvb
  annotations:
    # To switch to LoadBalancer on AWS/Azure set JVB_SERVICE_TYPE=LoadBalancer
    # and add: service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
spec:
  type: NodePort
  selector:
    app: jitsi
    component: jvb
  ports:
    - name: media-udp
      port: 10000
      targetPort: 10000
      nodePort: ${JVB_NODEPORT}
      protocol: UDP
EOF
else
  cat <<EOF | oc_apply
apiVersion: v1
kind: Service
metadata:
  name: jitsi-jvb-udp
  namespace: ${NAMESPACE}
  labels:
    app: jitsi
    component: jvb
spec:
  type: LoadBalancer
  selector:
    app: jitsi
    component: jvb
  ports:
    - name: media-udp
      port: 10000
      targetPort: 10000
      protocol: UDP
EOF
fi
ok "JVB deployed."

# ── Meet Deployment + Service + Route ─────────────────────────────────────────
banner "Deploying Jitsi Meet (Web)"

cat <<EOF | oc_apply
apiVersion: apps/v1
kind: Deployment
metadata:
  name: jitsi-meet
  namespace: ${NAMESPACE}
  labels:
    app: jitsi
    component: meet
spec:
  replicas: 1
  selector:
    matchLabels:
      app: jitsi
      component: meet
  template:
    metadata:
      labels:
        app: jitsi
        component: meet
    spec:
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      volumes:
        - name: s6-run
          emptyDir:
            medium: Memory
      containers:
        - name: meet
          image: ${IMAGE_MEET}
          imagePullPolicy: Always
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          ports:
            - containerPort: 8080
              name: http
          envFrom:
            - configMapRef:
                name: jitsi-config
          readinessProbe:
            httpGet:
              path: /
              port: 8080
            initialDelaySeconds: 15
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /
              port: 8080
            initialDelaySeconds: 30
            periodSeconds: 20
          resources:
            requests:
              memory: "128Mi"
              cpu: "100m"
            limits:
          volumeMounts:
            - name: s6-run
              mountPath: /run/s6
              memory: "256Mi"
              cpu: "500m"
---
apiVersion: v1
kind: Service
metadata:
  name: jitsi-meet
  namespace: ${NAMESPACE}
  labels:
    app: jitsi
    component: meet
spec:
  selector:
    app: jitsi
    component: meet
  ports:
    - name: http
      port: 8080
      targetPort: 8080
---
# OpenShift Route: TLS edge termination (cert managed by cluster ingress)
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: jitsi-meet
  namespace: ${NAMESPACE}
  labels:
    app: jitsi
    component: meet
spec:
  host: ${JITSI_HOSTNAME}
  to:
    kind: Service
    name: jitsi-meet
  port:
    targetPort: http
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
EOF
ok "Jitsi Meet deployed."

# ── Wait for rollouts ─────────────────────────────────────────────────────────
if [[ "${DRY_RUN}" == "false" ]]; then
  banner "Waiting for rollouts"

  for component in prosody jicofo jvb meet; do
    log "Waiting for jitsi-${component}..."
    oc rollout status deployment/jitsi-${component} \
      -n "${NAMESPACE}" --timeout=180s || \
      warn "jitsi-${component} rollout timed out — check: oc logs -l component=${component} -n ${NAMESPACE}"
    ok "jitsi-${component} ready."
  done
fi

# ── Summary ───────────────────────────────────────────────────────────────────
banner "Deployment Complete"

if [[ "${DRY_RUN}" == "false" ]]; then
  echo ""
  echo -e "  ${BOLD}Jitsi Meet URL:${RESET}  https://${JITSI_HOSTNAME}"
  echo ""
  echo -e "  ${BOLD}OpenEMR telehealth config:${RESET}"
  echo -e "  Administration → Globals → Telehealth → Jitsi Server"
  echo -e "  → ${CYAN}https://${JITSI_HOSTNAME}${RESET}"
  echo ""
  echo -e "  ${BOLD}JVB media (WebRTC UDP):${RESET}"
  if [[ "${JVB_SERVICE_TYPE}" == "NodePort" ]]; then
    echo -e "  → Node IP ${JVB_ADVERTISE_IPS}, UDP port ${JVB_NODEPORT}"
    echo -e "  → ${YELLOW}Firewall rule required: allow UDP/${JVB_NODEPORT} inbound${RESET}"
  else
    echo -e "  → LoadBalancer IP: ${JVB_ADVERTISE_IPS}, UDP/10000"
  fi
  echo ""
  echo -e "  ${BOLD}Useful commands:${RESET}"
  echo -e "  oc get pods -l app=jitsi -n ${NAMESPACE}"
  echo -e "  oc logs -l component=jvb -n ${NAMESPACE} -f"
  echo -e "  oc logs -l component=prosody -n ${NAMESPACE} -f"
  echo ""
  ok "Done. Jitsi is running in namespace '${NAMESPACE}'."
fi