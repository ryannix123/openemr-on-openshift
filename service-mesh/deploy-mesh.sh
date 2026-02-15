#!/bin/bash
# ==============================================================================
# OpenEMR Service Mesh Deployment
# Zero-trust networking for OpenEMR on OpenShift
#
# Ryan Nix <ryan.nix@gmail.com> - projects are personal, not official Red Hat
# ==============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="${SCRIPT_DIR}/manifests"
OPENEMR_NAMESPACE="${OPENEMR_NAMESPACE:-openemr}"

print_info()    { echo -e "${CYAN}ℹ  $1${NC}"; }
print_success() { echo -e "${GREEN}✓  $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠  $1${NC}"; }
print_error()   { echo -e "${RED}✗  $1${NC}"; }

print_banner() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║         OpenEMR Service Mesh — Zero Trust Networking        ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# ─── Pre-flight checks ───────────────────────────────────────────────────────

check_prerequisites() {
    print_info "Running pre-flight checks..."

    # Check oc CLI
    if ! command -v oc &>/dev/null; then
        print_error "oc CLI not found. Install from: https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/"
        exit 1
    fi

    # Check cluster connection
    if ! oc whoami &>/dev/null; then
        print_error "Not logged into an OpenShift cluster. Run: oc login ..."
        exit 1
    fi

    # Check for cluster-admin or sufficient privileges
    local user
    user=$(oc whoami)
    print_info "Logged in as: ${user}"

    # Check if OpenEMR is deployed
    if ! oc get namespace "${OPENEMR_NAMESPACE}" &>/dev/null; then
        print_error "Namespace '${OPENEMR_NAMESPACE}' not found. Deploy OpenEMR first."
        print_info "See: https://github.com/ryannix123/openemr-on-openshift"
        exit 1
    fi

    if ! oc get deployment openemr -n "${OPENEMR_NAMESPACE}" &>/dev/null; then
        print_error "OpenEMR deployment not found in '${OPENEMR_NAMESPACE}'. Deploy OpenEMR first."
        exit 1
    fi

    print_success "Pre-flight checks passed"
}

# ─── Operator installation check ─────────────────────────────────────────────

check_operators() {
    print_info "Checking required operators..."

    local missing=0

    # Check for OpenShift Service Mesh operator
    if oc get csv -n openshift-operators 2>/dev/null | grep -q "servicemeshoperator"; then
        print_success "OpenShift Service Mesh operator: installed"
    else
        print_warning "OpenShift Service Mesh operator: NOT installed"
        echo "    Install from OperatorHub: Red Hat OpenShift Service Mesh"
        missing=1
    fi

    # Check for Kiali operator
    if oc get csv -n openshift-operators 2>/dev/null | grep -q "kiali"; then
        print_success "Kiali operator: installed"
    else
        print_warning "Kiali operator: NOT installed"
        echo "    Install from OperatorHub: Kiali Operator (provided by Red Hat)"
        missing=1
    fi

    # Check for Jaeger/Tempo operator
    if oc get csv -n openshift-operators 2>/dev/null | grep -q -E "jaeger|tempo"; then
        print_success "Tracing operator: installed"
    else
        print_warning "Tracing operator: NOT installed"
        echo "    Install from OperatorHub: Red Hat OpenShift distributed tracing platform"
        missing=1
    fi

    if [[ $missing -eq 1 ]]; then
        echo ""
        print_error "Required operators are missing. Install them from OperatorHub and re-run."
        print_info "See README.md for installation instructions."
        exit 1
    fi

    print_success "All required operators installed"
}

# ─── Deploy Service Mesh control plane ────────────────────────────────────────

deploy_control_plane() {
    print_info "Deploying Service Mesh control plane..."

    # Create istio-system namespace if it doesn't exist
    if ! oc get namespace istio-system &>/dev/null; then
        oc create namespace istio-system
        print_success "Created istio-system namespace"
    fi

    # Apply SMCP
    oc apply -f "${MANIFESTS_DIR}/01-smcp.yaml"
    print_info "ServiceMeshControlPlane applied. Waiting for readiness..."

    # Wait for control plane to be ready (up to 5 minutes)
    local retries=30
    local i=0
    while [[ $i -lt $retries ]]; do
        local status
        status=$(oc get smcp basic -n istio-system -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
        if [[ "$status" == "True" ]]; then
            print_success "Service Mesh control plane is ready"
            break
        fi
        echo -n "."
        sleep 10
        ((i++))
    done

    if [[ $i -eq $retries ]]; then
        print_warning "Control plane is still initializing. Check: oc get smcp basic -n istio-system"
        print_info "Continuing — it may take a few more minutes..."
    fi

    # Apply SMMR
    oc apply -f "${MANIFESTS_DIR}/02-smmr.yaml"
    print_success "ServiceMeshMemberRoll applied — '${OPENEMR_NAMESPACE}' enrolled in mesh"
}

# ─── Enable sidecar injection ─────────────────────────────────────────────────

enable_sidecar_injection() {
    print_info "Enabling sidecar injection on OpenEMR deployments..."

    for deploy in openemr mariadb redis; do
        if oc get deployment "${deploy}" -n "${OPENEMR_NAMESPACE}" &>/dev/null; then
            oc patch deployment "${deploy}" -n "${OPENEMR_NAMESPACE}" \
                --type merge \
                -p '{"spec":{"template":{"metadata":{"annotations":{"sidecar.istio.io/inject":"true"}}}}}'
            print_success "Sidecar injection enabled: ${deploy}"
        else
            print_warning "Deployment '${deploy}' not found — skipping"
        fi
    done

    print_info "Pods will restart with Envoy sidecars..."
    oc rollout status deployment/openemr -n "${OPENEMR_NAMESPACE}" --timeout=120s 2>/dev/null || true
}

# ─── Apply security policies ─────────────────────────────────────────────────

apply_security_policies() {
    print_info "Applying zero-trust security policies..."

    # mTLS
    oc apply -f "${MANIFESTS_DIR}/03-peer-authentication.yaml"
    print_success "PeerAuthentication: strict mTLS enforced"

    # Authorization policies
    oc apply -f "${MANIFESTS_DIR}/04-authz-deny-all.yaml"
    print_success "AuthorizationPolicy: default deny-all"

    oc apply -f "${MANIFESTS_DIR}/05-authz-allow-ingress-openemr.yaml"
    print_success "AuthorizationPolicy: allow ingress → OpenEMR"

    oc apply -f "${MANIFESTS_DIR}/06-authz-allow-openemr-mariadb.yaml"
    print_success "AuthorizationPolicy: allow OpenEMR → MariaDB"

    oc apply -f "${MANIFESTS_DIR}/07-authz-allow-openemr-redis.yaml"
    print_success "AuthorizationPolicy: allow OpenEMR → Redis"

    # Network policies (defense-in-depth)
    oc apply -f "${MANIFESTS_DIR}/08-network-policies.yaml"
    print_success "NetworkPolicies: L3/L4 isolation applied"

    # Sidecar scope limiting
    oc apply -f "${MANIFESTS_DIR}/10-sidecars.yaml"
    print_success "Sidecar: proxy scope limited per workload"
}

# ─── Apply egress firewall ────────────────────────────────────────────────────

apply_egress_firewall() {
    print_info "Applying egress firewall..."

    # Check if OVN-Kubernetes is the CNI
    local cni
    cni=$(oc get network.config/cluster -o jsonpath='{.spec.networkType}' 2>/dev/null || echo "Unknown")

    if [[ "$cni" != "OVNKubernetes" ]]; then
        print_warning "CNI is '${cni}', not OVN-Kubernetes. EgressFirewall may not work."
        print_info "Skipping egress firewall. Apply manually if your CNI supports it."
        return
    fi

    oc apply -f "${MANIFESTS_DIR}/09-egress-firewall.yaml"
    print_success "EgressFirewall: outbound traffic restricted to allow-list only"
}

# ─── NetworkPolicy-only mode ─────────────────────────────────────────────────

apply_network_policies_only() {
    print_info "Applying NetworkPolicies (no mesh required)..."
    oc apply -f "${MANIFESTS_DIR}/08-network-policies.yaml"
    print_success "NetworkPolicies applied"
    echo ""
    print_info "This provides L3/L4 pod isolation without requiring the service mesh."
    print_info "For mTLS and L7 authorization, run: $0 --full"
}

# ─── Status ───────────────────────────────────────────────────────────────────

show_status() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo " Service Mesh Status"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""

    # Control plane
    echo "── Control Plane ──"
    oc get smcp -n istio-system 2>/dev/null || echo "No SMCP found"
    echo ""

    # Member roll
    echo "── Member Roll ──"
    oc get smmr -n istio-system 2>/dev/null || echo "No SMMR found"
    echo ""

    # Pods with sidecars
    echo "── Pods (look for 2/2 Ready = sidecar injected) ──"
    oc get pods -n "${OPENEMR_NAMESPACE}" -o wide 2>/dev/null
    echo ""

    # Policies
    echo "── Authorization Policies ──"
    oc get authorizationpolicy -n "${OPENEMR_NAMESPACE}" 2>/dev/null || echo "None"
    echo ""

    echo "── Peer Authentication ──"
    oc get peerauthentication -n "${OPENEMR_NAMESPACE}" 2>/dev/null || echo "None"
    echo ""

    echo "── Network Policies ──"
    oc get networkpolicy -n "${OPENEMR_NAMESPACE}" 2>/dev/null || echo "None"
    echo ""

    echo "── Egress Firewall ──"
    oc get egressfirewall -n "${OPENEMR_NAMESPACE}" 2>/dev/null || echo "None"
    echo ""

    # Kiali URL
    local kiali_url
    kiali_url=$(oc get route kiali -n istio-system -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    if [[ -n "$kiali_url" ]]; then
        echo "── Observability ──"
        echo "  Kiali:   https://${kiali_url}"
        local jaeger_url
        jaeger_url=$(oc get route jaeger -n istio-system -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
        if [[ -n "$jaeger_url" ]]; then
            echo "  Jaeger:  https://${jaeger_url}"
        fi
        local grafana_url
        grafana_url=$(oc get route grafana -n istio-system -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
        if [[ -n "$grafana_url" ]]; then
            echo "  Grafana: https://${grafana_url}"
        fi
    fi
    echo ""
}

# ─── Cleanup ──────────────────────────────────────────────────────────────────

cleanup() {
    print_warning "Removing service mesh configuration from OpenEMR..."

    # Remove sidecar injection annotations
    for deploy in openemr mariadb redis; do
        if oc get deployment "${deploy}" -n "${OPENEMR_NAMESPACE}" &>/dev/null; then
            oc patch deployment "${deploy}" -n "${OPENEMR_NAMESPACE}" \
                --type json \
                -p '[{"op":"remove","path":"/spec/template/metadata/annotations/sidecar.istio.io~1inject"}]' 2>/dev/null || true
            print_info "Removed sidecar annotation: ${deploy}"
        fi
    done

    # Remove policies
    oc delete authorizationpolicy --all -n "${OPENEMR_NAMESPACE}" --ignore-not-found
    oc delete peerauthentication --all -n "${OPENEMR_NAMESPACE}" --ignore-not-found
    oc delete networkpolicy --all -n "${OPENEMR_NAMESPACE}" --ignore-not-found
    oc delete sidecar --all -n "${OPENEMR_NAMESPACE}" --ignore-not-found
    oc delete egressfirewall --all -n "${OPENEMR_NAMESPACE}" --ignore-not-found
    print_success "Policies removed"

    # Remove from member roll
    oc delete smmr default -n istio-system --ignore-not-found
    print_success "Namespace removed from mesh"

    print_info "Pods will restart without sidecars..."
    for deploy in openemr mariadb redis; do
        oc rollout restart deployment/"${deploy}" -n "${OPENEMR_NAMESPACE}" 2>/dev/null || true
    done

    print_success "Service mesh configuration removed"
    echo ""
    print_info "The control plane (istio-system) was left in place."
    print_info "To remove it: oc delete smcp basic -n istio-system"
}

# ─── Usage ────────────────────────────────────────────────────────────────────

usage() {
    echo "Usage: $0 [OPTION]"
    echo ""
    echo "Options:"
    echo "  --full              Deploy full service mesh (mTLS + AuthZ + NetworkPolicy + Egress)"
    echo "  --netpol-only       Apply NetworkPolicies only (no mesh operators required)"
    echo "  --egress-only       Apply EgressFirewall only (requires OVN-Kubernetes)"
    echo "  --status            Show current mesh and policy status"
    echo "  --cleanup           Remove all mesh config from OpenEMR namespace"
    echo "  -h, --help          Show this help"
    echo ""
    echo "Environment variables:"
    echo "  OPENEMR_NAMESPACE   Target namespace (default: openemr)"
    echo ""
    echo "Examples:"
    echo "  $0 --full                                    # Full zero-trust deployment"
    echo "  $0 --netpol-only                             # Just L3/L4 isolation"
    echo "  OPENEMR_NAMESPACE=my-emr $0 --full           # Custom namespace"
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
    print_banner

    case "${1:-}" in
        --full)
            check_prerequisites
            check_operators
            deploy_control_plane
            enable_sidecar_injection
            apply_security_policies
            apply_egress_firewall
            echo ""
            print_success "Zero-trust networking deployed!"
            echo ""
            echo "What's active:"
            echo "  ✓ Mutual TLS between all pods (encrypted east-west traffic)"
            echo "  ✓ Identity-based authorization (only OpenEMR can reach MariaDB/Redis)"
            echo "  ✓ Default deny-all (no unauthorized traffic flows)"
            echo "  ✓ L3/L4 NetworkPolicies (defense-in-depth)"
            echo "  ✓ Envoy proxy scope limited per workload"
            echo "  ✓ Egress firewall (outbound restricted to allow-list)"
            echo "  ✓ Kiali, Jaeger, Grafana for observability"
            echo ""
            show_status
            ;;
        --netpol-only)
            check_prerequisites
            apply_network_policies_only
            ;;
        --egress-only)
            check_prerequisites
            apply_egress_firewall
            ;;
        --status)
            show_status
            ;;
        --cleanup)
            check_prerequisites
            cleanup
            ;;
        -h|--help)
            usage
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

main "$@"
