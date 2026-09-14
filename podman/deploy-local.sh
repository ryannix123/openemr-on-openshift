#!/bin/bash

##############################################################################
# OpenEMR on Podman — Local Deployment
#
# Runs the same OpenEMR 8.4.0 stack locally with `podman kube play`. Works on
# x86_64 and Apple Silicon.
#
# Quadlet was the other option and was rejected: Quadlet units are systemd
# units, and macOS has no systemd, so they would live inside the podman machine
# VM. `kube play` behaves identically on both platforms.
#
# Author: Ryan Nix <ryan.nix@gmail.com>
# Version: 1.0
##############################################################################

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
print_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
print_header()  { echo; echo "=========================================="; echo "$1"; echo "=========================================="; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── Configuration ────────────────────────────────────────────────────────────
POD_NAME="openemr"
HOST_PORT="${HOST_PORT:-8080}"
REMOTE_IMAGE="${OPENEMR_IMAGE:-quay.io/ryan_nix/openemr-openshift:latest}"
LOCAL_IMAGE="localhost/openemr-openshift:local"
MARIADB_IMAGE="${MARIADB_IMAGE:-quay.io/fedora/mariadb-118:latest}"
REDIS_IMAGE="${REDIS_IMAGE:-docker.io/redis:8-alpine}"

DB_VOLUME="openemr-mariadb-data"
SITES_VOLUME="openemr-sites"

GENERATED_DIR="${SCRIPT_DIR}/.generated"
PLAY_FILE="${GENERATED_DIR}/openemr-pod.yaml"
CREDS_FILE="${SCRIPT_DIR}/openemr-local-credentials.txt"

##############################################################################
# Preflight
##############################################################################

preflight() {
    print_header "Preflight"

    command -v podman &>/dev/null || { print_error "podman not found."; exit 1; }

    # On macOS and Windows the engine lives in a VM; `podman info` fails when it
    # is not running, with an error that does not mention the machine at all.
    if ! podman info &>/dev/null; then
        print_error "Cannot reach the Podman engine."
        print_info  "On macOS or Windows, start it first:  podman machine start"
        exit 1
    fi

    HOST_ARCH="$(podman info --format '{{.Host.Arch}}')"
    print_success "Podman engine reachable (arch: ${HOST_ARCH})"
}

##############################################################################
# Image selection
##############################################################################

# The published image is built by GitHub Actions on an x64 runner, so on Apple
# Silicon it is the wrong architecture. Emulating a supervisord stack is slow
# and unreliable, so build from the Containerfile instead. CentOS Stream 10,
# EPEL 10, Remi EL10 and NodeSource all publish aarch64, so the build works.
resolve_image() {
    print_header "Resolving Image"

    if [[ "${BUILD_LOCAL:-0}" == "1" ]]; then
        build_local
        return
    fi

    print_info "Pulling ${REMOTE_IMAGE}..."
    if ! podman pull "${REMOTE_IMAGE}"; then
        print_warning "Pull failed — building locally instead."
        build_local
        return
    fi

    local image_arch
    image_arch="$(podman image inspect "${REMOTE_IMAGE}" --format '{{.Architecture}}')"

    if [[ "${image_arch}" != "${HOST_ARCH}" ]]; then
        print_warning "Image is ${image_arch}, this host is ${HOST_ARCH}."
        print_warning "Running it would mean emulation — slow, and unreliable for this stack."
        print_info    "Building from ${REPO_ROOT}/Containerfile instead (expect 5-15 minutes)."
        build_local
        return
    fi

    OPENEMR_RESOLVED_IMAGE="${REMOTE_IMAGE}"
    print_success "Using ${REMOTE_IMAGE} (${image_arch})"
}

build_local() {
    print_info "Building ${LOCAL_IMAGE} for linux/${HOST_ARCH}..."
    podman build \
        --platform "linux/${HOST_ARCH}" \
        -t "${LOCAL_IMAGE}" \
        -f "${REPO_ROOT}/Containerfile" \
        "${REPO_ROOT}"
    OPENEMR_RESOLVED_IMAGE="${LOCAL_IMAGE}"
    print_success "Built ${LOCAL_IMAGE}"
}

##############################################################################
# Credentials
##############################################################################

# Reused across runs so a redeploy still matches the schema on the volumes. The
# container refuses to start when the database was configured with a different
# password, and regenerating here would cause exactly that.
resolve_passwords() {
    print_header "Credentials"

    if [[ -f "${CREDS_FILE}" ]]; then
        print_info "Reusing credentials from ${CREDS_FILE}"
        DB_PASSWORD=$(grep '^db_password=' "${CREDS_FILE}" | cut -d= -f2-)
        DB_ROOT_PASSWORD=$(grep '^db_root_password=' "${CREDS_FILE}" | cut -d= -f2-)
        OE_ADMIN_PASSWORD=$(grep '^admin_password=' "${CREDS_FILE}" | cut -d= -f2-)
        return
    fi

    DB_PASSWORD="$(openssl rand -hex 24)"
    DB_ROOT_PASSWORD="$(openssl rand -hex 24)"
    OE_ADMIN_PASSWORD="$(openssl rand -hex 12)"

    umask 077
    cat > "${CREDS_FILE}" <<EOF
# OpenEMR local Podman deployment — generated $(date)
# Keep this file. Deleting it and redeploying onto existing volumes will
# generate new passwords that do not match the configured database.
admin_username=admin
admin_password=${OE_ADMIN_PASSWORD}
db_name=openemr
db_user=openemr
db_password=${DB_PASSWORD}
db_root_password=${DB_ROOT_PASSWORD}
EOF
    print_success "Credentials written to ${CREDS_FILE} (mode 0600)"
}

##############################################################################
# Manifest
##############################################################################

# One pod, three containers: they share a network namespace, so MariaDB and
# Redis are reachable on 127.0.0.1 with no DNS and no service discovery.
write_manifest() {
    print_header "Generating Manifest"

    mkdir -p "${GENERATED_DIR}"

    cat > "${PLAY_FILE}" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_NAME}
  labels:
    app: openemr
spec:
  restartPolicy: Always
  containers:
    - name: mariadb
      image: ${MARIADB_IMAGE}
      env:
        - name: MYSQL_ROOT_PASSWORD
          value: "${DB_ROOT_PASSWORD}"
        - name: MYSQL_DATABASE
          value: "openemr"
        - name: MYSQL_USER
          value: "openemr"
        - name: MYSQL_PASSWORD
          value: "${DB_PASSWORD}"
      volumeMounts:
        - name: mariadb-data
          mountPath: /var/lib/mysql

    - name: redis
      image: ${REDIS_IMAGE}
      args:
        - redis-server
        - --save
        - ""
        - --appendonly
        - "no"
        - --maxmemory
        - 256mb
        - --maxmemory-policy
        - allkeys-lru

    - name: openemr
      image: ${OPENEMR_RESOLVED_IMAGE}
      ports:
        - containerPort: 8080
          hostPort: ${HOST_PORT}
      env:
        # Same pod, so these are loopback rather than service names.
        - name: MYSQL_HOST
          value: "127.0.0.1"
        - name: MYSQL_PORT
          value: "3306"
        - name: MYSQL_DATABASE
          value: "openemr"
        - name: MYSQL_USER
          value: "openemr"
        - name: MYSQL_PASS
          value: "${DB_PASSWORD}"
        - name: REDIS_HOST
          value: "127.0.0.1"
        - name: REDIS_PORT
          value: "6379"
        - name: OE_USER
          value: "admin"
        - name: OE_PASS
          value: "${OE_ADMIN_PASSWORD}"
        - name: CQM_SERVICE_URL
          value: "http://localhost:6660"
        # No TLS in front of this, so Secure cookies would never come back.
        - name: OPENEMR_INSECURE_COOKIES
          value: "1"
      volumeMounts:
        - name: openemr-sites
          mountPath: /var/www/html/openemr/sites/default

  volumes:
    - name: mariadb-data
      persistentVolumeClaim:
        claimName: ${DB_VOLUME}
    - name: openemr-sites
      persistentVolumeClaim:
        claimName: ${SITES_VOLUME}
EOF

    chmod 600 "${PLAY_FILE}"
    print_success "Wrote ${PLAY_FILE}"
}

##############################################################################
# Actions
##############################################################################

do_up() {
    print_header "OpenEMR on Podman — Local Deployment"
    preflight
    resolve_image
    resolve_passwords
    write_manifest

    print_header "Starting Pod"
    podman kube play --replace "${PLAY_FILE}"

    print_info "Waiting for OpenEMR to answer (first run loads the schema, ~2-3 min)..."
    local ready=0
    for _ in $(seq 1 90); do
        if curl -sS -o /dev/null --connect-timeout 2 --max-time 5 \
             "http://localhost:${HOST_PORT}/ready" 2>/dev/null; then
            ready=1
            break
        fi
        sleep 5
    done

    if [[ "${ready}" != 1 ]]; then
        print_warning "OpenEMR did not answer in time. Check the logs:"
        print_info    "  podman logs ${POD_NAME}-openemr"
        exit 1
    fi

    print_header "Ready"
    echo
    echo "  URL      : http://localhost:${HOST_PORT}/"
    echo "  Username : admin"
    echo "  Password : ${OE_ADMIN_PASSWORD}"
    echo
    echo "  Credentials file : ${CREDS_FILE}"
    echo
    echo "  Logs   : $0 --logs"
    echo "  Stop   : $0 --down"
    echo "  Reset  : $0 --wipe     (DELETES ALL DATA)"
    echo
    print_warning "Session cookies are not marked Secure in this mode. Local use only."
}

do_down() {
    print_header "Stopping"
    preflight
    if [[ -f "${PLAY_FILE}" ]]; then
        podman kube down "${PLAY_FILE}"
    else
        podman pod rm -f "${POD_NAME}" 2>/dev/null || true
    fi
    print_success "Stopped. Volumes kept — $0 --up to resume."
}

do_wipe() {
    print_header "Wiping"
    preflight
    print_warning "This deletes the database, documents, and saved credentials."
    read -r -p "Type 'yes' to continue: " confirm
    [[ "${confirm}" == "yes" ]] || { print_info "Aborted."; exit 0; }

    [[ -f "${PLAY_FILE}" ]] && podman kube down "${PLAY_FILE}" 2>/dev/null || true
    podman pod rm -f "${POD_NAME}" 2>/dev/null || true
    podman volume rm -f "${DB_VOLUME}" "${SITES_VOLUME}" 2>/dev/null || true
    rm -f "${CREDS_FILE}" "${PLAY_FILE}"
    print_success "Wiped."
}

do_status() {
    preflight
    print_header "Status"
    podman pod ps --filter "name=${POD_NAME}"
    echo
    podman ps --filter "pod=${POD_NAME}" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
    echo
    podman volume ls --filter "name=openemr"
}

do_logs() {
    preflight
    podman logs -f "${POD_NAME}-openemr"
}

show_help() {
    cat <<EOF
OpenEMR on Podman — Local Deployment

Usage: $0 [OPTION]

  --up        Deploy (default)
  --down      Stop the pod, keep the data
  --wipe      Remove everything including volumes (DELETES ALL DATA)
  --status    Show pod, container, and volume state
  --logs      Follow the OpenEMR container log
  --help      This message

Environment variables:
  HOST_PORT=8080          Host port to publish
  BUILD_LOCAL=1           Force a local build, skipping the published image
  OPENEMR_IMAGE=...       Override the published image
EOF
}

case "${1:-}" in
    --help|-h) show_help ;;
    --down)    do_down ;;
    --wipe)    do_wipe ;;
    --status)  do_status ;;
    --logs)    do_logs ;;
    --up|"")   do_up ;;
    *)         print_error "Unknown option: $1"; show_help; exit 1 ;;
esac
