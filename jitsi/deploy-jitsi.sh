#!/usr/bin/env bash
# =============================================================================
# deploy-jitsi.sh — Deploy OpenShift-compatible Jitsi Meet
#
# Usage:
#   ./deploy-jitsi.sh                      # deploy into current oc project
#   ./deploy-jitsi.sh --namespace my-ns    # target a specific namespace
#   ./deploy-jitsi.sh --cleanup            # remove all Jitsi resources
#   ./deploy-jitsi.sh --dry-run            # print manifests, no apply
#
# Prerequisites:
#   - oc CLI logged in
#   - Images built and pushed: ./build-push.sh
#
# Architecture:
#   prosody  — XMPP server        (ClusterIP, internal only)
#   jicofo   — Conference focus   (ClusterIP, internal only)
#   jvb      — Video bridge       (NodePort UDP/10000 or LoadBalancer)
#   meet     — Web frontend       (OpenShift Route, TLS edge)
#
# JVB networking:
#   Default: NodePort UDP/30000 (works on SNO + bare-metal OCP)
#   Override: JVB_SERVICE_TYPE=LoadBalancer JVB_ADVERTISE_IPS=<ip>
#
# OpenShift topology grouping:
#   All Jitsi resources use app.kubernetes.io/part-of=jitsi so they
#   appear grouped in the OpenShift Developer topology view.
#
# Maintainer: Ryan Nix <ryan.nix@gmail.com>
# =============================================================================

set -euo pipefail

REGISTRY="quay.io"
NAMESPACE_REGISTRY="ryan_nix"
REPO="jitsi-openshift"

IMAGE_MEET="${REGISTRY}/${NAMESPACE_REGISTRY}/${REPO}:meet"
IMAGE_PROSODY="${REGISTRY}/${NAMESPACE_REGISTRY}/${REPO}:prosody"
IMAGE_JICOFO="${REGISTRY}/${NAMESPACE_REGISTRY}/${REPO}:jicofo"
IMAGE_JVB="${REGISTRY}/${NAMESPACE_REGISTRY}/${REPO}:jvb"

NAMESPACE="${NAMESPACE:-}"
JVB_SERVICE_TYPE="${JVB_SERVICE_TYPE:-NodePort}"
JVB_NODEPORT="${JVB_NODEPORT:-30000}"
DRY_RUN=false
CLEANUP=false

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()    { echo -e "${CYAN}[jitsi]${RESET}  $*"; }
ok()     { echo -e "${GREEN}[ok]${RESET}     $*"; }
warn()   { echo -e "${YELLOW}[warn]${RESET}   $*"; }
error()  { echo -e "${RED}[error]${RESET}  $*" >&2; }
die()    { error "$*"; exit 1; }
banner() { echo -e "\n${BOLD}${CYAN}── $* ──${RESET}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace|-n) NAMESPACE="$2"; shift 2 ;;
    --cleanup)      CLEANUP=true; shift ;;
    --dry-run)      DRY_RUN=true; shift ;;
    --help|-h)      sed -n '3,20p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *)              die "Unknown argument: $1" ;;
  esac
done

oc_apply() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "--- DRY RUN ---"; cat; echo "---------------"
  else
    oc apply -f -
  fi
}

if [[ "${CLEANUP}" == "true" ]]; then
  banner "Cleanup"
  [[ -z "${NAMESPACE}" ]] && NAMESPACE=$(oc project -q 2>/dev/null)
  warn "Removing all Jitsi resources from '${NAMESPACE}'..."
  read -rp "  Are you sure? (yes/no): " confirm
  [[ "${confirm}" == "yes" ]] || { log "Aborted."; exit 0; }
  for r in deployment/jitsi-meet deployment/jitsi-prosody \
            deployment/jitsi-jicofo deployment/jitsi-jvb; do
    oc delete "${r}" -n "${NAMESPACE}" --ignore-not-found
  done
  for r in service/jitsi-meet service/jitsi-prosody service/jitsi-jicofo \
            service/jitsi-jvb-http service/jitsi-jvb-udp; do
    oc delete "${r}" -n "${NAMESPACE}" --ignore-not-found
  done
  oc delete route/jitsi-meet configmap/jitsi-config \
     secret/jitsi-secrets pvc/jitsi-prosody-data \
     -n "${NAMESPACE}" --ignore-not-found
  ok "Cleanup complete."
  exit 0
fi

banner "Pre-flight"
command -v oc &>/dev/null    || die "'oc' not found."
command -v openssl &>/dev/null || die "'openssl' not found."

OC_USER=$(oc whoami 2>/dev/null) || die "Not logged in. Run: oc login <cluster>"
ok "Logged in as: ${BOLD}${OC_USER}${RESET}"

[[ -z "${NAMESPACE}" ]] && \
  NAMESPACE=$(oc project -q 2>/dev/null) || \
  die "Could not determine current project."
log "Namespace: ${BOLD}${NAMESPACE}${RESET}"

APPS_DOMAIN=$(oc get ingresses.config.openshift.io cluster \
              -o jsonpath='{.spec.domain}' 2>/dev/null || true)
if [[ -z "${APPS_DOMAIN}" ]]; then
  SAMPLE_HOST=$(oc get routes -n "${NAMESPACE}" \
    -o jsonpath='{.items[0].spec.host}' 2>/dev/null || true)
  [[ -n "${SAMPLE_HOST}" ]] && APPS_DOMAIN="${SAMPLE_HOST#*.}"
fi
if [[ -z "${APPS_DOMAIN}" ]]; then
  CONSOLE_URL=$(oc whoami --show-console 2>/dev/null || true)
  [[ -n "${CONSOLE_URL}" ]] && \
    APPS_DOMAIN=$(echo "${CONSOLE_URL}" | sed 's|https://console-openshift-console\.||')
fi
[[ -z "${APPS_DOMAIN}" ]] && \
  die "Could not auto-detect apps domain. Set: APPS_DOMAIN=apps.x.example.com"

JITSI_HOSTNAME="jitsi.${APPS_DOMAIN}"
log "Jitsi URL: ${BOLD}https://${JITSI_HOSTNAME}${RESET}"

banner "JVB networking"
if [[ "${JVB_SERVICE_TYPE}" == "LoadBalancer" ]]; then
  if [[ -z "${JVB_ADVERTISE_IPS:-}" ]]; then
    read -rp "  LoadBalancer IP for JVB_ADVERTISE_IPS: " JVB_ADVERTISE_IPS
  fi
  log "Service type : LoadBalancer"
  log "Advertise IP : ${JVB_ADVERTISE_IPS}"
else
  NODE_IP=$(oc get nodes \
    -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' \
    2>/dev/null || true)
  if [[ -n "${NODE_IP}" ]]; then
    JVB_ADVERTISE_IPS="${NODE_IP}"
    log "Service type : NodePort (${JVB_NODEPORT}/UDP)"
    log "Advertise IP : ${JVB_ADVERTISE_IPS} (node IP)"
    warn "Ensure UDP/${JVB_NODEPORT} is open in your firewall."
  else
    JVB_ADVERTISE_IPS="${APPS_DOMAIN}"
    warn "Restricted cluster — JVB_ADVERTISE_IPS set to apps domain (placeholder)."
    warn "Real-time video needs a reachable UDP IP or TURN server."
  fi
fi

banner "Secrets"
if oc get secret jitsi-secrets -n "${NAMESPACE}" &>/dev/null; then
  warn "Secret 'jitsi-secrets' exists — reusing passwords."
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
  ok "Generated new passwords."
fi

cat <<EOF | oc_apply
apiVersion: v1
kind: Secret
metadata:
  name: jitsi-secrets
  namespace: ${NAMESPACE}
  labels:
    app: jitsi
    app.kubernetes.io/part-of: jitsi
type: Opaque
stringData:
  JICOFO_AUTH_PASSWORD: "${JICOFO_AUTH_PASSWORD}"
  JVB_AUTH_PASSWORD: "${JVB_AUTH_PASSWORD}"
  JICOFO_COMPONENT_SECRET: "${JICOFO_COMPONENT_SECRET}"
EOF
ok "Secret applied."

banner "Prosody PVC"
cat <<EOF | oc_apply
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: jitsi-prosody-data
  namespace: ${NAMESPACE}
  labels:
    app: jitsi
    app.kubernetes.io/part-of: jitsi
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
EOF
ok "PVC applied."

banner "ConfigMap"
cat <<EOF | oc_apply
apiVersion: v1
kind: ConfigMap
metadata:
  name: jitsi-config
  namespace: ${NAMESPACE}
  labels:
    app: jitsi
    app.kubernetes.io/part-of: jitsi
data:
  XMPP_DOMAIN: "meet.jitsi"
  XMPP_AUTH_DOMAIN: "auth.meet.jitsi"
  XMPP_INTERNAL_MUC_DOMAIN: "internal-muc.meet.jitsi"
  XMPP_MUC_DOMAIN: "muc.meet.jitsi"
  XMPP_GUEST_DOMAIN: "guest.meet.jitsi"
  XMPP_SERVER: "jitsi-prosody"
  XMPP_PORT: "5222"
  XMPP_BOSH_URL_BASE: "http://jitsi-prosody:5280"
  PUBLIC_URL: "https://${JITSI_HOSTNAME}"
  JVB_AUTH_USER: "jvb"
  JVB_PORT: "10000"
  JVB_ADVERTISE_IPS: "${JVB_ADVERTISE_IPS}"
  JVB_TCP_HARVESTER_DISABLED: "true"
  DISABLE_AWS_HARVESTER: "true"
  JVB_STUN_SERVERS: "meet-jit-si-turnserver.services.staging.jitsi.net:443"
  JICOFO_AUTH_USER: "focus"
  ENABLE_AUTH: "0"
  ENABLE_GUESTS: "1"
  ENABLE_LETSENCRYPT: "0"
  DISABLE_HTTPS: "1"
  HTTP_PORT: "8080"
  HTTPS_PORT: "8443"
  TZ: "America/Chicago"
EOF
ok "ConfigMap applied."

banner "Deploying Prosody"
cat <<EOF | oc_apply
apiVersion: apps/v1
kind: Deployment
metadata:
  name: jitsi-prosody
  namespace: ${NAMESPACE}
  labels:
    app: jitsi
    app.kubernetes.io/part-of: jitsi
  annotations:
    app.openshift.io/connects-to: '[{"apiVersion":"apps/v1","kind":"Deployment","name":"jitsi-jicofo"},{"apiVersion":"apps/v1","kind":"Deployment","name":"jitsi-jvb"}]'
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
        app.kubernetes.io/part-of: jitsi
    spec:
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      volumes:
        - name: prosody-data
          persistentVolumeClaim:
            claimName: jitsi-prosody-data
      containers:
        - name: prosody
          image: ${IMAGE_PROSODY}
          imagePullPolicy: Always
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          ports:
            - containerPort: 5222
            - containerPort: 5269
            - containerPort: 5280
            - containerPort: 5347
          volumeMounts:
            - name: prosody-data
              mountPath: /config/data
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
          resources:
            requests:
              memory: "256Mi"
              cpu: "100m"
            limits:
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
    app.kubernetes.io/part-of: jitsi
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

banner "Deploying Jicofo"
cat <<EOF | oc_apply
apiVersion: apps/v1
kind: Deployment
metadata:
  name: jitsi-jicofo
  namespace: ${NAMESPACE}
  labels:
    app: jitsi
    app.kubernetes.io/part-of: jitsi
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
        app.kubernetes.io/part-of: jitsi
    spec:
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: jicofo
          image: ${IMAGE_JICOFO}
          imagePullPolicy: Always
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          ports:
            - containerPort: 8888
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
          # No liveness/readiness probes — jicofo health endpoint binds to
          # 127.0.0.1:8888 (loopback only), unreachable by the kubelet probe.
          resources:
            requests:
              memory: "256Mi"
              cpu: "100m"
            limits:
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
    app.kubernetes.io/part-of: jitsi
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

banner "Deploying JVB"
cat <<EOF | oc_apply
apiVersion: apps/v1
kind: Deployment
metadata:
  name: jitsi-jvb
  namespace: ${NAMESPACE}
  labels:
    app: jitsi
    app.kubernetes.io/part-of: jitsi
spec:
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
        app.kubernetes.io/part-of: jitsi
    spec:
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
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
            - name: JVB_WS_DOMAIN
              value: "${JITSI_HOSTNAME}"
            - name: JVB_WS_SERVER_ID
              value: "jvb-1"
          # DOCKER_HOST_ADDRESS injected post-deploy from Service ClusterIP.
          # No liveness/readiness probes — JVB health check fails when UDP/10000
          # is not externally reachable (Developer Sandbox, ROSA). Re-enable on
          # SNO/bare-metal where the NodePort is open.
          resources:
            requests:
              memory: "512Mi"
              cpu: "200m"
            limits:
              memory: "1Gi"
              cpu: "1000m"
---
apiVersion: v1
kind: Service
metadata:
  name: jitsi-jvb-http
  namespace: ${NAMESPACE}
  labels:
    app: jitsi
    app.kubernetes.io/part-of: jitsi
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

if [[ "${JVB_SERVICE_TYPE}" == "NodePort" ]]; then
  cat <<EOF | oc_apply
apiVersion: v1
kind: Service
metadata:
  name: jitsi-jvb-udp
  namespace: ${NAMESPACE}
  labels:
    app: jitsi
    app.kubernetes.io/part-of: jitsi
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
    app.kubernetes.io/part-of: jitsi
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

banner "Deploying Meet"
cat <<EOF | oc_apply
apiVersion: apps/v1
kind: Deployment
metadata:
  name: jitsi-meet
  namespace: ${NAMESPACE}
  labels:
    app: jitsi
    app.kubernetes.io/part-of: jitsi
  annotations:
    app.openshift.io/connects-to: '[{"apiVersion":"apps/v1","kind":"Deployment","name":"jitsi-prosody"}]'
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
        app.kubernetes.io/part-of: jitsi
    spec:
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
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
    app.kubernetes.io/part-of: jitsi
spec:
  selector:
    app: jitsi
    component: meet
  ports:
    - name: http
      port: 8080
      targetPort: 8080
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: jitsi-meet
  namespace: ${NAMESPACE}
  labels:
    app: jitsi
    app.kubernetes.io/part-of: jitsi
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
ok "Meet deployed."

if [[ "${DRY_RUN}" == "false" ]]; then
  banner "Post-deploy configuration"

  log "Waiting for prosody to be ready..."
  oc rollout status deployment/jitsi-prosody -n "${NAMESPACE}" --timeout=120s
  ok "Prosody ready."

  log "Setting JVB ClusterIP for ICE harvesting..."
  JVB_CLUSTER_IP=$(oc get service jitsi-jvb-udp -n "${NAMESPACE}" \
    -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
  if [[ -n "${JVB_CLUSTER_IP}" ]]; then
    oc set env deployment/jitsi-jvb \
      DOCKER_HOST_ADDRESS="${JVB_CLUSTER_IP}" \
      -n "${NAMESPACE}" &>/dev/null
    ok "JVB DOCKER_HOST_ADDRESS → ${JVB_CLUSTER_IP}"
  else
    warn "Could not determine JVB Service ClusterIP."
  fi

  log "Registering XMPP users in prosody..."
  sleep 5
  oc exec deployment/jitsi-prosody -n "${NAMESPACE}" -- \
    prosodyctl --config /config/prosody.cfg.lua \
    register focus auth.meet.jitsi "${JICOFO_AUTH_PASSWORD}" 2>/dev/null && \
    ok "Registered: focus@auth.meet.jitsi" || \
    warn "focus already registered (PVC persisted from previous deploy)"
  oc exec deployment/jitsi-prosody -n "${NAMESPACE}" -- \
    prosodyctl --config /config/prosody.cfg.lua \
    register jvb auth.meet.jitsi "${JVB_AUTH_PASSWORD}" 2>/dev/null && \
    ok "Registered: jvb@auth.meet.jitsi" || \
    warn "jvb already registered (PVC persisted from previous deploy)"

  banner "Done"
  echo ""
  echo -e "  ${BOLD}Jitsi Meet:${RESET}  https://${JITSI_HOSTNAME}"
  echo ""
  echo -e "  ${BOLD}OpenEMR telehealth:${RESET}"
  echo -e "  Administration → Globals → Telehealth → Jitsi Server"
  echo -e "  → ${CYAN}https://${JITSI_HOSTNAME}${RESET}"
  echo ""
  echo -e "  ${BOLD}JVB media:${RESET}"
  if [[ "${JVB_SERVICE_TYPE}" == "NodePort" ]]; then
    echo -e "  → NodePort UDP/${JVB_NODEPORT} — ensure this port is open in your firewall"
  else
    echo -e "  → LoadBalancer UDP/10000 — IP: ${JVB_ADVERTISE_IPS:-<pending>}"
  fi
  echo ""
  echo -e "  ${BOLD}Useful commands:${RESET}"
  echo -e "  oc get pods -l app=jitsi -n ${NAMESPACE}"
  echo -e "  oc logs -l component=prosody -n ${NAMESPACE} -f"
  echo -e "  oc logs -l component=jicofo -n ${NAMESPACE} -f"
  echo ""
  ok "Jitsi is running."
fi