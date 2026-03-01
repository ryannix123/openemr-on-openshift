#!/usr/bin/env bash
# deploy-mesh.sh — OpenEMR Service Mesh (OpenShift Service Mesh 3, Ambient Mode)
# Author: Ryan Nix <ryan.nix@gmail.com>
#
# Fully self-contained. Running --full will:
#   1. Install the Sail Operator (OSSM 3) via OLM
#   2. Install the Kiali Operator via OLM
#   3. Install Gateway API CRDs (required for waypoint proxy)
#   4. Deploy the Istio control plane and IstioCNI (ztunnel)
#   5. Enroll the target namespace in ambient mode
#   6. Deploy the waypoint proxy for L7 policy enforcement
#   7. Apply zero-trust AuthorizationPolicies
#   8. Apply NetworkPolicies (L3/L4, no mesh dependency)
#   9. Apply EgressFirewall (OVN-Kubernetes)
#  10. Deploy a Kiali instance for observability
#
# The OPENEMR_NAMESPACE variable controls which namespace is targeted.
# All manifest files are templated at apply time — no static files are modified.
#
# Prerequisites: oc CLI, cluster-admin access, internet or mirrored catalog
set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
NAMESPACE="${OPENEMR_NAMESPACE:-openemr}"
ISTIO_NS="istio-system"
CNI_NS="istio-cni"
MANIFESTS_DIR="$(cd "$(dirname "$0")/manifests" && pwd)"

GATEWAY_API_VERSION="v1.1.0"
GATEWAY_API_URL="https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

OLM_TIMEOUT=300

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
section() { echo -e "\n${BOLD}${CYAN}══ $* ══${NC}"; }

# ── Namespace templating ──────────────────────────────────────────────────────
#
# All manifest files use "openemr" as the placeholder namespace. Rather than
# maintaining separate copies or modifying files on disk, every oc apply call
# is piped through this function which substitutes the target namespace at
# runtime. The static YAML files are never modified.
#
# Substitutions performed:
#   namespace: openemr            → namespace: <NAMESPACE>
#   name: openemr  (ns object)    → name: <NAMESPACE>
#   kubernetes.io/metadata.name   → updated label on the namespace object
#   /ns/openemr/  (SPIFFE URIs)   → /ns/<NAMESPACE>/
#   - openemr  (Kiali list entry) → - <NAMESPACE>
#
# app: openemr labels are intentionally left unchanged — they are pod label
# selectors that refer to the OpenEMR application, not the namespace name.
#
render() {
  local file="$1"
  sed \
    -e "s|namespace: openemr|namespace: ${NAMESPACE}|g" \
    -e "s|/ns/openemr/|/ns/${NAMESPACE}/|g" \
    -e "s|kubernetes\.io/metadata\.name: openemr|kubernetes.io/metadata.name: ${NAMESPACE}|g" \
    -e "/^  name: openemr$/s|openemr|${NAMESPACE}|g" \
    -e "s|      - openemr$|      - ${NAMESPACE}|g" \
    "$file"
}

# Render a manifest and apply it. Accepts the same flags as oc apply.
apply_manifest() {
  local file="$1"; shift
  render "$file" | oc apply -f - "$@"
}

# ── Helpers ───────────────────────────────────────────────────────────────────

wait_for_csv() {
  local ns="$1" prefix="$2" timeout="$3"
  info "Waiting for CSV '${prefix}' in '${ns}' to succeed (timeout: ${timeout}s)..."
  local elapsed=0 interval=10 csv_name phase
  while [[ $elapsed -lt $timeout ]]; do
    csv_name=$(oc get csv -n "$ns" --no-headers 2>/dev/null \
      | awk -v p="$prefix" '$1 ~ p {print $1}' | head -1)
    if [[ -n "$csv_name" ]]; then
      phase=$(oc get csv "$csv_name" -n "$ns" \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
      if [[ "$phase" == "Succeeded" ]]; then
        ok "CSV '${csv_name}' Succeeded."
        return 0
      fi
      info "  ${csv_name}: ${phase:-Pending} (${elapsed}s)"
    else
      info "  Waiting for '${prefix}' CSV to appear... (${elapsed}s)"
    fi
    sleep $interval
    elapsed=$((elapsed + interval))
  done
  error "Timed out waiting for CSV '${prefix}' after ${timeout}s."
}

wait_for_crd() {
  local crd="$1"
  local elapsed=0 interval=5
  info "Waiting for CRD '${crd}'..."
  while ! oc get crd "$crd" &>/dev/null; do
    sleep $interval
    elapsed=$((elapsed + interval))
    [[ $elapsed -gt 120 ]] && error "Timed out waiting for CRD '${crd}'."
  done
  ok "CRD '${crd}' available."
}

# ── Step 1: Preflight ─────────────────────────────────────────────────────────
preflight() {
  section "Preflight Checks"

  oc auth can-i create namespaces --all-namespaces &>/dev/null \
    || error "cluster-admin required. Developer Sandbox will not work — use SNO or a full cluster."
  ok "cluster-admin confirmed."

  command -v oc &>/dev/null || error "'oc' not found in PATH."
  ok "oc CLI found."

  # Verify OpenEMR namespace exists (warn if not, don't block — user may be
  # doing a staged install where OpenEMR is deployed after --operators)
  if oc get ns "$NAMESPACE" &>/dev/null; then
    ok "Target namespace '${NAMESPACE}' exists."
  else
    warn "Namespace '${NAMESPACE}' does not exist yet — it will be created during enrollment."
  fi

  local cni
  cni=$(oc get network.config/cluster -o jsonpath='{.spec.networkType}' 2>/dev/null || echo "unknown")
  if [[ "$cni" != "OVNKubernetes" ]]; then
    warn "CNI is '${cni}' — EgressFirewall requires OVNKubernetes. Egress step will be skipped."
    SKIP_EGRESS=true
  else
    SKIP_EGRESS=false
    ok "OVN-Kubernetes CNI confirmed."
  fi

  oc get catalogsource redhat-operators -n openshift-marketplace &>/dev/null \
    || warn "CatalogSource 'redhat-operators' not found — operator install may fail on disconnected clusters."

  info "Target namespace: ${NAMESPACE}"
}

# ── Step 2: Gateway API CRDs ─────────────────────────────────────────────────
install_gateway_api_crds() {
  section "Gateway API CRDs"

  if oc get crd gateways.gateway.networking.k8s.io &>/dev/null; then
    ok "Gateway API CRDs already installed — skipping."
    return
  fi

  info "Installing Gateway API CRDs (${GATEWAY_API_VERSION})..."
  oc apply -f "${GATEWAY_API_URL}" \
    || error "Failed to apply Gateway API CRDs. Check network access to github.com."

  wait_for_crd "gateways.gateway.networking.k8s.io"
  wait_for_crd "httproutes.gateway.networking.k8s.io"
  ok "Gateway API CRDs installed."
}

# ── Step 3: Operators via OLM ────────────────────────────────────────────────
install_operators() {
  section "Operator Installation (OLM)"

  # Sail Operator
  if oc get subscription servicemeshoperator3 -n openshift-operators &>/dev/null; then
    ok "Sail Operator subscription already exists — skipping."
  else
    info "Creating Sail Operator subscription..."
    # 00-sail-operator.yaml has no namespace references to template — apply directly
    oc apply -f "${MANIFESTS_DIR}/00-sail-operator.yaml"
    ok "Sail Operator subscription created."
  fi
  wait_for_csv "openshift-operators" "servicemeshoperator3" "$OLM_TIMEOUT"
  wait_for_crd "istioes.sailoperator.io"
  wait_for_crd "istiocnis.sailoperator.io"

  # Kiali Operator — Subscription document only (Kiali CR is applied later)
  if oc get subscription kiali-ossm -n openshift-operators &>/dev/null; then
    ok "Kiali Operator subscription already exists — skipping."
  else
    info "Creating Kiali Operator subscription..."
    awk 'p && /^---/{exit} /kind: Subscription/{p=1} p' \
      "${MANIFESTS_DIR}/00-kiali-operator.yaml" \
      | oc apply -f -
    ok "Kiali Operator subscription created."
  fi
  wait_for_csv "openshift-operators" "kiali-ossm" "$OLM_TIMEOUT"
  wait_for_crd "kialis.kiali.io"

  ok "All operators ready."
}

# ── Step 4: Istio control plane ───────────────────────────────────────────────
install_control_plane() {
  section "Istio Control Plane"

  oc get ns "$ISTIO_NS" &>/dev/null || oc create ns "$ISTIO_NS"
  oc get ns "$CNI_NS"   &>/dev/null || oc create ns "$CNI_NS"

  # 01 and 02 deploy to istio-system / istio-cni, no NAMESPACE substitution needed
  info "Deploying IstioCNI (ztunnel DaemonSet)..."
  oc apply -f "${MANIFESTS_DIR}/02-istiocni.yaml"

  info "Deploying Istio CR (ambient profile)..."
  oc apply -f "${MANIFESTS_DIR}/01-istio.yaml"

  info "Waiting for Istio CR to become Ready (2–3 minutes)..."
  oc wait istio/default -n "$ISTIO_NS" \
    --for=condition=Ready --timeout=180s \
    || error "Istio CR not Ready. Debug: oc describe istio/default -n ${ISTIO_NS}"

  info "Waiting for ztunnel rollout..."
  oc rollout status daemonset/ztunnel -n "$ISTIO_NS" --timeout=120s

  info "Waiting for Istiod rollout..."
  oc rollout status deployment/istiod -n "$ISTIO_NS" --timeout=120s

  ok "Control plane ready."
}

# ── Step 5: Enroll namespace ──────────────────────────────────────────────────
enroll_namespace() {
  section "Namespace Enrollment"

  oc get ns "$NAMESPACE" &>/dev/null || oc create ns "$NAMESPACE"

  # 03-namespace.yaml contains the namespace name itself — needs templating
  apply_manifest "${MANIFESTS_DIR}/03-namespace.yaml"

  ok "Namespace '${NAMESPACE}' enrolled in ambient mode."
  info "  ztunnel will intercept pods without restarts."
}

# ── Step 6: Waypoint proxy ────────────────────────────────────────────────────
deploy_waypoint() {
  section "Waypoint Proxy"

  info "Creating waypoint Gateway in '${NAMESPACE}'..."
  apply_manifest "${MANIFESTS_DIR}/04-waypoint.yaml"

  oc wait gateway/waypoint -n "$NAMESPACE" \
    --for=condition=Programmed --timeout=90s \
    || warn "Waypoint not Programmed yet. Check: oc describe gateway/waypoint -n ${NAMESPACE}"

  ok "Waypoint proxy ready."
}

# ── Step 7: AuthorizationPolicies ─────────────────────────────────────────────
apply_policies() {
  section "AuthorizationPolicies"

  # Contains namespace refs and SPIFFE URIs — must be templated
  apply_manifest "${MANIFESTS_DIR}/05-authz-policies.yaml"

  ok "AuthorizationPolicies applied to '${NAMESPACE}'."
  warn "  Default-deny is now active. Verify OpenEMR can reach MariaDB and Redis."
}

# ── Step 8: NetworkPolicies ───────────────────────────────────────────────────
apply_netpol() {
  section "NetworkPolicies"

  apply_manifest "${MANIFESTS_DIR}/06-network-policies.yaml"

  ok "NetworkPolicies applied to '${NAMESPACE}'."
}

# ── Step 9: EgressFirewall ────────────────────────────────────────────────────
apply_egress() {
  section "EgressFirewall"

  if [[ "${SKIP_EGRESS:-false}" == "true" ]]; then
    warn "Skipping — requires OVNKubernetes CNI."
    return
  fi

  apply_manifest "${MANIFESTS_DIR}/07-egress-firewall.yaml"

  ok "EgressFirewall applied to '${NAMESPACE}'."
}

# ── Step 10: Kiali ────────────────────────────────────────────────────────────
deploy_kiali() {
  section "Kiali"

  info "Creating Kiali instance (watching namespace '${NAMESPACE}')..."
  # Extract the Kiali CR (second document) and template the accessible_namespaces entry
  awk '/kind: Kiali/{p=1} p' "${MANIFESTS_DIR}/00-kiali-operator.yaml" \
    | sed -e "s|      - openemr$|      - ${NAMESPACE}|g" \
    | oc apply -f -

  info "Waiting for Kiali deployment..."
  oc rollout status deployment/kiali -n "$ISTIO_NS" --timeout=120s \
    || warn "Kiali not yet ready. Check: oc get pod -n ${ISTIO_NS} -l app=kiali"

  local kiali_url
  kiali_url=$(oc get route kiali -n "$ISTIO_NS" \
    -o jsonpath='{.spec.host}' 2>/dev/null || echo "route pending")
  ok "Kiali: https://${kiali_url}"
}

# ── Status ────────────────────────────────────────────────────────────────────
show_status() {
  echo ""
  echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}${CYAN}  OpenEMR Ambient Mesh Status${NC}"
  echo -e "${BOLD}${CYAN}  Namespace: ${NAMESPACE}${NC}"
  echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════${NC}"

  echo ""
  echo "▶ Sail Operator CSV:"
  oc get csv -n openshift-operators --no-headers 2>/dev/null \
    | awk '/servicemeshoperator3/ {printf "  %-50s %s\n", $1, $7}' \
    || echo "  Not found"

  echo ""
  echo "▶ Istio control plane:"
  oc get istio/default -n "$ISTIO_NS" --no-headers 2>/dev/null \
    | awk '{printf "  %-30s %s\n", $1, $2}' || echo "  Not found"

  echo ""
  echo "▶ ztunnel DaemonSet:"
  oc get daemonset/ztunnel -n "$ISTIO_NS" --no-headers 2>/dev/null \
    | awk '{printf "  desired=%-4s ready=%-4s\n", $2, $4}' || echo "  Not found"

  echo ""
  echo "▶ Namespace ambient label:"
  local label
  label=$(oc get ns "$NAMESPACE" \
    -o jsonpath='{.metadata.labels.istio\.io/dataplane-mode}' 2>/dev/null || echo "")
  echo "  ${label:-NOT SET}"

  echo ""
  echo "▶ Waypoint proxy:"
  oc get gateway/waypoint -n "$NAMESPACE" --no-headers 2>/dev/null \
    | awk '{printf "  %-30s %s\n", $1, $3}' || echo "  Not deployed"

  echo ""
  echo "▶ AuthorizationPolicies:"
  oc get authorizationpolicy -n "$NAMESPACE" --no-headers 2>/dev/null \
    | awk '{printf "  %s\n", $1}' || echo "  None"

  echo ""
  echo "▶ NetworkPolicies:"
  oc get networkpolicy -n "$NAMESPACE" --no-headers 2>/dev/null \
    | awk '{printf "  %s\n", $1}' || echo "  None"

  echo ""
  echo "▶ EgressFirewall:"
  oc get egressfirewall -n "$NAMESPACE" --no-headers 2>/dev/null \
    | awk '{printf "  %s\n", $1}' || echo "  None"

  echo ""
  echo "▶ Pod ambient enrollment (should show 'enabled'):"
  oc get pod -n "$NAMESPACE" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.ambient\.istio\.io/redirection}{"\n"}{end}' \
    2>/dev/null | awk '{printf "  %-40s %s\n", $1, $2}' \
    || echo "  No pods found"

  echo ""
  echo "▶ Kiali:"
  oc get route kiali -n "$ISTIO_NS" \
    -o jsonpath='  https://{.spec.host}{"\n"}' 2>/dev/null \
    || echo "  Not deployed"
  echo ""
}

# ── Cleanup ───────────────────────────────────────────────────────────────────
cleanup() {
  warn "Removing mesh config from '${NAMESPACE}'..."

  render "${MANIFESTS_DIR}/07-egress-firewall.yaml"  | oc delete -f - --ignore-not-found
  render "${MANIFESTS_DIR}/06-network-policies.yaml" | oc delete -f - --ignore-not-found
  render "${MANIFESTS_DIR}/05-authz-policies.yaml"   | oc delete -f - --ignore-not-found
  render "${MANIFESTS_DIR}/04-waypoint.yaml"          | oc delete -f - --ignore-not-found
  oc label ns "$NAMESPACE" istio.io/dataplane-mode- 2>/dev/null || true

  ok "Mesh config removed from '${NAMESPACE}'. Control plane left intact."
  echo ""
  echo "To remove the control plane:"
  echo "  oc delete kiali/kiali -n ${ISTIO_NS}"
  echo "  oc delete istio/default -n ${ISTIO_NS}"
  echo "  oc delete istiocni/default -n ${CNI_NS}"
  echo "  oc delete namespace ${ISTIO_NS} ${CNI_NS}"
  echo ""
  echo "To remove operators:"
  echo "  oc delete subscription servicemeshoperator3 kiali-ossm -n openshift-operators"
}

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
  echo ""
  echo -e "${BOLD}Usage:${NC} $0 [OPTION]"
  echo ""
  echo -e "${BOLD}Options:${NC}"
  echo "  --full           Complete install: operators, CRDs, control plane, policies, Kiali"
  echo "  --operators      Install Sail + Kiali operators and Gateway API CRDs only"
  echo "  --control-plane  Deploy Istio CR + IstioCNI (operators must already be installed)"
  echo "  --policies       Enroll namespace, waypoint, AuthZ + NetworkPolicy + EgressFirewall"
  echo "  --netpol-only    NetworkPolicies only (no mesh operators required)"
  echo "  --egress-only    EgressFirewall only"
  echo "  --status         Show mesh status"
  echo "  --cleanup        Remove mesh config from namespace (control plane left intact)"
  echo ""
  echo -e "${BOLD}Environment:${NC}"
  echo "  OPENEMR_NAMESPACE    Namespace where OpenEMR is deployed (default: openemr)"
  echo ""
  echo -e "${BOLD}Examples:${NC}"
  echo "  $0 --full                                    # deploy to 'openemr' namespace"
  echo "  OPENEMR_NAMESPACE=my-emr $0 --full           # deploy to 'my-emr' namespace"
  echo "  $0 --operators                               # install operators only"
  echo "  $0 --control-plane && $0 --policies          # staged deployment"
  echo ""
}

# ── Main ──────────────────────────────────────────────────────────────────────
case "${1:-}" in
  --full)
    preflight
    install_gateway_api_crds
    install_operators
    install_control_plane
    enroll_namespace
    deploy_waypoint
    apply_policies
    apply_netpol
    apply_egress
    deploy_kiali
    show_status
    echo -e "${GREEN}${BOLD}Full ambient mesh deployment complete! Namespace: ${NAMESPACE}${NC}"
    ;;
  --operators)
    preflight
    install_gateway_api_crds
    install_operators
    ok "Operators and CRDs ready. Deploy OpenEMR, then run --control-plane."
    ;;
  --control-plane)
    preflight
    install_control_plane
    enroll_namespace
    ok "Control plane ready. Run --policies next."
    ;;
  --policies)
    preflight
    enroll_namespace
    deploy_waypoint
    apply_policies
    apply_netpol
    apply_egress
    ok "All policies applied to '${NAMESPACE}'."
    ;;
  --netpol-only)
    preflight
    apply_netpol
    ;;
  --egress-only)
    preflight
    apply_egress
    ;;
  --status)
    show_status
    ;;
  --cleanup)
    preflight
    cleanup
    ;;
  *)
    usage
    ;;
esac