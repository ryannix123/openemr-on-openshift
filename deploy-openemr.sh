#!/bin/bash

##############################################################################
# OpenEMR on OpenShift - Deployment Script
#
# Deploys OpenEMR 8.0.0 with MariaDB and Redis on OpenShift.
# Works on Developer Sandbox, Single Node OpenShift (SNO), and full clusters.
#
# Storage class is auto-detected from the cluster default unless overridden:
#   STORAGE_CLASS=lvms-vg1 ./deploy-openemr.sh
#
# Author: Ryan Nix <ryan.nix@gmail.com>
# Version: 1.2
##############################################################################

set -e

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ── Images ───────────────────────────────────────────────────────────────────
OPENEMR_IMAGE="quay.io/ryan_nix/openemr-openshift:latest"
MARIADB_IMAGE="quay.io/fedora/mariadb-118:latest"
REDIS_IMAGE="docker.io/redis:8-alpine"

# ── Storage ──────────────────────────────────────────────────────────────────
# Auto-detect the cluster's default StorageClass unless the caller sets
# STORAGE_CLASS explicitly. Works on SNO (lvms-vg1), ODF, and Developer
# Sandbox (gp3-csi) without any script changes.
if [[ -z "${STORAGE_CLASS:-}" ]]; then
  STORAGE_CLASS=$(oc get storageclass \
    -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' \
    2>/dev/null || true)
fi
# storageClassName is omitted from PVCs when empty — Kubernetes will then
# use the cluster default, which is equivalent but avoids an explicit name.
DB_STORAGE_SIZE="5Gi"
DOCUMENTS_STORAGE_SIZE="10Gi"
REDIS_STORAGE_SIZE="1Gi"

# ── Database ─────────────────────────────────────────────────────────────────
DB_NAME="openemr"
DB_USER="openemr"
DB_PASSWORD="$(openssl rand -hex 24)"
DB_ROOT_PASSWORD="$(openssl rand -hex 24)"

# ── OpenEMR admin ─────────────────────────────────────────────────────────────
OE_ADMIN_USER="admin"
OE_ADMIN_PASSWORD="$(openssl rand -hex 12)"

##############################################################################
# Helper Functions
##############################################################################

print_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

print_header() {
    echo ""
    echo "=========================================="
    echo "$1"
    echo "=========================================="
}

check_command() {
    if ! command -v "$1" &>/dev/null; then
        print_error "$1 command not found. Please install it first."
        exit 1
    fi
}

wait_for_pod() {
    local label=$1
    local timeout=${2:-300}
    print_info "Waiting for pod with label $label to be ready..."
    oc wait --for=condition=ready pod \
        -l "$label" \
        --timeout="${timeout}s"
}

# Emit a storageClassName field only when STORAGE_CLASS is set.
# When empty, the field is omitted so Kubernetes uses the cluster default.
storage_class_yaml() {
  if [[ -n "${STORAGE_CLASS:-}" ]]; then
    echo "  storageClassName: ${STORAGE_CLASS}"
  fi
}

##############################################################################
# Preflight Checks
##############################################################################

preflight_checks() {
    print_header "Preflight Checks"

    check_command oc

    if ! oc whoami &>/dev/null; then
        print_error "Not logged into OpenShift. Please login first."
        exit 1
    fi

    print_success "Logged in as: $(oc whoami)"
    print_success "Using cluster: $(oc whoami --show-server)"

    # Resolve and display the storage class that will be used
    if [[ -n "${STORAGE_CLASS:-}" ]]; then
        print_success "Storage class: ${STORAGE_CLASS} (explicit)"
    else
        local default_sc
        default_sc=$(oc get storageclass \
          -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' \
          2>/dev/null || true)
        if [[ -z "$default_sc" ]]; then
            print_error "No default StorageClass found and STORAGE_CLASS is not set."
            print_info  "Set it explicitly: STORAGE_CLASS=lvms-vg1 ./deploy-openemr.sh"
            print_info  "Available storage classes:"
            oc get storageclass
            exit 1
        fi
        print_success "Storage class: ${default_sc} (cluster default — auto-detected)"
        # Set it now so storage_class_yaml() emits the explicit name in PVCs,
        # making the credentials file and summary accurate.
        STORAGE_CLASS="$default_sc"
    fi
}

##############################################################################
# Detect Current Project
##############################################################################

detect_project() {
    print_header "Detecting Current Project"

    PROJECT_NAME=$(oc project -q 2>/dev/null)

    if [[ -z "$PROJECT_NAME" ]]; then
        print_error "No project selected. Please switch to a project first:"
        print_info  "  oc project <project-name>"
        print_info  "Available projects:"
        oc projects
        exit 1
    fi

    print_success "Using current project: $PROJECT_NAME"

    if ! oc get project "$PROJECT_NAME" &>/dev/null; then
        print_error "Cannot access project $PROJECT_NAME"
        exit 1
    fi

    export PROJECT_NAME
}

##############################################################################
# MariaDB Deployment
##############################################################################

deploy_mariadb() {
    print_header "Deploying MariaDB Database"

    print_info "Creating database secret..."
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: mariadb-secret
  labels:
    app: mariadb
    app.kubernetes.io/name: mariadb
    app.kubernetes.io/component: database
    app.kubernetes.io/part-of: openemr
    app.kubernetes.io/runtime: mariadb
type: Opaque
stringData:
  database-name: $DB_NAME
  database-user: $DB_USER
  database-password: $DB_PASSWORD
  database-root-password: $DB_ROOT_PASSWORD
EOF
    print_success "Database secret created"

    print_info "Creating persistent volume for database..."
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mariadb-data
  labels:
    app: mariadb
    app.kubernetes.io/name: mariadb
    app.kubernetes.io/component: database
    app.kubernetes.io/part-of: openemr
    app.kubernetes.io/runtime: mariadb
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: $DB_STORAGE_SIZE
$(storage_class_yaml)
EOF
    print_success "Database PVC created"

    print_info "Deploying MariaDB..."
    cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mariadb
  labels:
    app: mariadb
    app.kubernetes.io/name: mariadb
    app.kubernetes.io/component: database
    app.kubernetes.io/part-of: openemr
    app.kubernetes.io/runtime: mariadb
    app.kubernetes.io/version: "11.8"
    app.kubernetes.io/managed-by: kubectl
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: mariadb
  template:
    metadata:
      labels:
        app: mariadb
        app.kubernetes.io/name: mariadb
        app.kubernetes.io/component: database
        app.kubernetes.io/part-of: openemr
        app.kubernetes.io/runtime: mariadb
        app.kubernetes.io/version: "11.8"
    spec:
      containers:
      - name: mariadb
        image: $MARIADB_IMAGE
        ports:
        - containerPort: 3306
          name: mysql
        env:
        - name: MYSQL_ROOT_PASSWORD
          valueFrom:
            secretKeyRef:
              name: mariadb-secret
              key: database-root-password
        - name: MYSQL_DATABASE
          valueFrom:
            secretKeyRef:
              name: mariadb-secret
              key: database-name
        - name: MYSQL_USER
          valueFrom:
            secretKeyRef:
              name: mariadb-secret
              key: database-user
        - name: MYSQL_PASSWORD
          valueFrom:
            secretKeyRef:
              name: mariadb-secret
              key: database-password
        volumeMounts:
        - name: mariadb-data
          mountPath: /var/lib/mysql
        livenessProbe:
          tcpSocket:
            port: 3306
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          tcpSocket:
            port: 3306
          initialDelaySeconds: 5
          periodSeconds: 10
        resources:
          limits:
            memory: 1Gi
            cpu: 500m
          requests:
            memory: 512Mi
            cpu: 200m
      volumes:
      - name: mariadb-data
        persistentVolumeClaim:
          claimName: mariadb-data
EOF
    print_success "MariaDB deployment created"

    print_info "Creating MariaDB service..."
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: Service
metadata:
  name: mariadb
  labels:
    app: mariadb
    app.kubernetes.io/name: mariadb
    app.kubernetes.io/component: database
    app.kubernetes.io/part-of: openemr
    app.kubernetes.io/runtime: mariadb
spec:
  ports:
  - port: 3306
    targetPort: 3306
    name: mysql
  selector:
    app: mariadb
  type: ClusterIP
EOF
    print_success "MariaDB service created"

    wait_for_pod "app=mariadb" 300
    print_success "MariaDB is ready"
}

##############################################################################
# Redis Deployment
##############################################################################

deploy_redis() {
    print_header "Deploying Redis Cache"

    print_info "Deploying Redis..."
    cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
  labels:
    app: redis
    app.kubernetes.io/name: redis
    app.kubernetes.io/component: cache
    app.kubernetes.io/part-of: openemr
    app.kubernetes.io/managed-by: kubectl
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis
  template:
    metadata:
      labels:
        app: redis
        app.kubernetes.io/name: redis
        app.kubernetes.io/component: cache
        app.kubernetes.io/part-of: openemr
    spec:
      containers:
      - name: redis
        image: $REDIS_IMAGE
        command: ["redis-server", "--save", "", "--appendonly", "no", "--maxmemory", "256mb", "--maxmemory-policy", "allkeys-lru"]
        ports:
        - containerPort: 6379
          name: redis
        resources:
          limits:
            memory: 256Mi
            cpu: 250m
          requests:
            memory: 64Mi
            cpu: 50m
        securityContext:
          allowPrivilegeEscalation: false
          runAsNonRoot: true
          capabilities:
            drop:
            - ALL
          seccompProfile:
            type: RuntimeDefault
EOF
    print_success "Redis deployment created"

    print_info "Creating Redis service..."
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: Service
metadata:
  name: redis
  labels:
    app: redis
    app.kubernetes.io/name: redis
    app.kubernetes.io/component: cache
    app.kubernetes.io/part-of: openemr
spec:
  ports:
  - port: 6379
    targetPort: 6379
    name: redis
  selector:
    app: redis
  type: ClusterIP
EOF
    print_success "Redis service created"

    wait_for_pod "app=redis" 300
    print_success "Redis is ready"
}

##############################################################################
# OpenEMR Deployment
##############################################################################

deploy_openemr() {
    print_header "Deploying OpenEMR Application"

    print_info "Creating persistent volume for documents..."
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: openemr-sites
  labels:
    app: openemr
    app.kubernetes.io/name: openemr
    app.kubernetes.io/component: application
    app.kubernetes.io/part-of: openemr
    app.kubernetes.io/runtime: php
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: $DOCUMENTS_STORAGE_SIZE
$(storage_class_yaml)
EOF
    print_success "Sites PVC created"

    print_info "Creating OpenEMR admin secret..."
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: openemr-secret
  labels:
    app: openemr
    app.kubernetes.io/name: openemr
    app.kubernetes.io/component: application
    app.kubernetes.io/part-of: openemr
    app.kubernetes.io/runtime: php
type: Opaque
stringData:
  admin-username: $OE_ADMIN_USER
  admin-password: $OE_ADMIN_PASSWORD
EOF
    print_success "OpenEMR secret created"

    print_info "Deploying OpenEMR application..."
    cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: openemr
  labels:
    app: openemr
    app.kubernetes.io/name: openemr
    app.kubernetes.io/component: application
    app.kubernetes.io/part-of: openemr
    app.kubernetes.io/runtime: php
    app.kubernetes.io/version: "8.0.0"
    app.kubernetes.io/managed-by: kubectl
  annotations:
    app.openshift.io/runtime: php
spec:
  replicas: 1
  selector:
    matchLabels:
      app: openemr
  template:
    metadata:
      labels:
        app: openemr
        app.kubernetes.io/name: openemr
        app.kubernetes.io/component: application
        app.kubernetes.io/part-of: openemr
        app.kubernetes.io/runtime: php
        app.kubernetes.io/version: "8.0.0"
    spec:
      containers:
      - name: openemr
        image: $OPENEMR_IMAGE
        ports:
        - containerPort: 8080
          name: http
        env:
        - name: MYSQL_HOST
          value: mariadb
        - name: MYSQL_DATABASE
          valueFrom:
            secretKeyRef:
              name: mariadb-secret
              key: database-name
        - name: MYSQL_USER
          valueFrom:
            secretKeyRef:
              name: mariadb-secret
              key: database-user
        - name: MYSQL_PASS
          valueFrom:
            secretKeyRef:
              name: mariadb-secret
              key: database-password
        - name: OE_USER
          value: admin
        - name: OE_PASS
          valueFrom:
            secretKeyRef:
              name: openemr-secret
              key: admin-password
        - name: DB_HOST
          value: mariadb
        - name: DB_PORT
          value: "3306"
        - name: DB_DATABASE
          valueFrom:
            secretKeyRef:
              name: mariadb-secret
              key: database-name
        - name: DB_USER
          valueFrom:
            secretKeyRef:
              name: mariadb-secret
              key: database-user
        - name: DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: mariadb-secret
              key: database-password
        - name: CQM_SERVICE_URL
          value: "http://localhost:6660"
        volumeMounts:
        - name: openemr-sites
          mountPath: /var/www/html/openemr/sites/default
        startupProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 30
        livenessProbe:
          httpGet:
            path: /health
            port: 8080
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3
        readinessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 10
          timeoutSeconds: 5
        resources:
          limits:
            memory: 768Mi
            cpu: 500m
          requests:
            memory: 384Mi
            cpu: 200m
      volumes:
      - name: openemr-sites
        persistentVolumeClaim:
          claimName: openemr-sites
EOF
    print_success "OpenEMR deployment created"

    print_info "Creating OpenEMR service..."
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: Service
metadata:
  name: openemr
  labels:
    app: openemr
    app.kubernetes.io/name: openemr
    app.kubernetes.io/component: application
    app.kubernetes.io/part-of: openemr
    app.kubernetes.io/runtime: php
spec:
  ports:
  - port: 8080
    targetPort: 8080
    name: http
  selector:
    app: openemr
  type: ClusterIP
EOF
    print_success "OpenEMR service created"

    print_info "Creating OpenEMR route..."
    cat <<EOF | oc apply -f -
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: openemr
  labels:
    app: openemr
    app.kubernetes.io/name: openemr
    app.kubernetes.io/component: application
    app.kubernetes.io/part-of: openemr
    app.kubernetes.io/runtime: php
spec:
  to:
    kind: Service
    name: openemr
  port:
    targetPort: http
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
EOF
    print_success "OpenEMR route created"

    wait_for_pod "app=openemr" 300
    print_success "OpenEMR is ready"

    print_info "Creating crypto keys directory..."
    oc exec deployment/openemr -- mkdir -p /var/www/html/openemr/sites/default/documents/logs_and_misc/methods
    oc exec deployment/openemr -- chmod -R 770 /var/www/html/openemr/sites/default/documents/logs_and_misc
    print_success "Crypto directory created"
}

##############################################################################
# Display Summary
##############################################################################

display_summary() {
    print_header "Deployment Summary"

    ROUTE_URL=$(oc get route openemr -o jsonpath='{.spec.host}')

    echo ""
    echo -e "${GREEN}OpenEMR has been successfully deployed!${NC}"
    echo ""
    echo "Access Information:"
    echo "  URL: https://$ROUTE_URL"
    echo ""
    echo "OpenEMR Admin Credentials:"
    echo "  Username: $OE_ADMIN_USER"
    echo "  Password: $OE_ADMIN_PASSWORD"
    echo ""
    echo "Database Information:"
    echo "  Host: mariadb.$PROJECT_NAME.svc.cluster.local"
    echo "  Port: 3306"
    echo "  Database: $DB_NAME"
    echo "  Username: $DB_USER"
    echo "  Password: $DB_PASSWORD"
    echo ""
    echo "Storage:"
    echo "  Storage class:   ${STORAGE_CLASS} (auto-detected default)"
    echo "  Database:        ${DB_STORAGE_SIZE} (MariaDB 11.8)"
    echo "  Documents:       ${DOCUMENTS_STORAGE_SIZE}"
    echo "  Redis:           in-memory (no persistence)"
    echo ""
    echo "Next Steps:"
    echo "  1. Wait 2-3 minutes for auto-configuration to complete"
    echo "  2. Navigate to: https://$ROUTE_URL"
    echo "  3. Login with admin credentials above"
    echo ""
    echo "Useful Commands:"
    echo "  View pods:        oc get pods"
    echo "  View logs:        oc logs -f deployment/openemr"
    echo "  View database:    oc logs -f deployment/mariadb"
    echo "  Restart OpenEMR:  oc rollout restart deployment/openemr"
    echo ""

    CREDS_FILE="openemr-credentials.txt"
    cat > "$CREDS_FILE" <<EOF
OpenEMR Deployment Credentials
==============================
Date: $(date)
Project: $PROJECT_NAME
Cluster: $(oc whoami --show-server)

Access URL: https://$ROUTE_URL

OpenEMR Admin Credentials:
  Username: $OE_ADMIN_USER
  Password: $OE_ADMIN_PASSWORD

Database Information:
  Host: mariadb.$PROJECT_NAME.svc.cluster.local
  Port: 3306
  Database: $DB_NAME
  Username: $DB_USER
  Password: $DB_PASSWORD
  Root Password: $DB_ROOT_PASSWORD

Storage:
  Class:     $STORAGE_CLASS
  Database:  $DB_STORAGE_SIZE
  Documents: $DOCUMENTS_STORAGE_SIZE

OpenShift Project: $PROJECT_NAME
EOF

    print_success "Credentials saved to: $CREDS_FILE"
    print_warning "Keep this file secure — it contains sensitive passwords."
}

##############################################################################
# Cleanup
##############################################################################

cleanup() {
    print_header "Cleaning Up OpenEMR Deployment"

    print_info "Deleting deployments..."
    oc delete deployment openemr redis mariadb --ignore-not-found

    print_info "Deleting services..."
    oc delete service openemr redis mariadb --ignore-not-found

    print_info "Deleting routes..."
    oc delete route openemr --ignore-not-found

    print_info "Deleting secrets..."
    oc delete secret openemr-secret mariadb-secret --ignore-not-found

    print_info "Deleting ConfigMaps..."
    oc delete configmap redis-config --ignore-not-found

    print_warning "Deleting PVCs (this will DELETE ALL DATA!)..."
    oc delete pvc openemr-sites mariadb-data --ignore-not-found

    print_success "Cleanup complete."
}

##############################################################################
# Status
##############################################################################

show_status() {
    print_header "OpenEMR Deployment Status"

    echo ""
    print_info "Project: $PROJECT_NAME"
    print_info "Storage class: ${STORAGE_CLASS:-<cluster default>}"
    echo ""

    echo "=== Pods ==="
    oc get pods -l app.kubernetes.io/part-of=openemr 2>/dev/null || echo "No pods found"
    echo ""

    echo "=== Services ==="
    oc get svc -l app.kubernetes.io/part-of=openemr 2>/dev/null || echo "No services found"
    echo ""

    echo "=== Routes ==="
    oc get routes openemr 2>/dev/null || echo "No routes found"
    echo ""

    echo "=== PVCs ==="
    oc get pvc -l app.kubernetes.io/part-of=openemr 2>/dev/null || echo "No PVCs found"
    echo ""

    ROUTE_URL=$(oc get route openemr -o jsonpath='{.spec.host}' 2>/dev/null)
    if [[ -n "$ROUTE_URL" ]]; then
        print_success "OpenEMR URL: https://$ROUTE_URL"
    fi
}

##############################################################################
# Usage
##############################################################################

show_help() {
    echo "OpenEMR on OpenShift — Deployment Script"
    echo ""
    echo "Usage: $0 [OPTION]"
    echo ""
    echo "Options:"
    echo "  --deploy    Deploy OpenEMR (default)"
    echo "  --cleanup   Remove all resources INCLUDING PVCs (DELETES ALL DATA!)"
    echo "  --status    Show deployment status"
    echo "  --help      Show this help message"
    echo ""
    echo "Environment variables:"
    echo "  STORAGE_CLASS   Override the auto-detected default storage class"
    echo ""
    echo "Examples:"
    echo "  $0                                  # deploy using cluster default storage class"
    echo "  STORAGE_CLASS=lvms-vg1 $0           # deploy using a specific storage class"
    echo "  $0 --status                         # check deployment status"
    echo "  $0 --cleanup                        # remove all resources and data"
    echo ""
    echo "WARNING: --cleanup permanently deletes all patient data and documents!"
}

##############################################################################
# Main
##############################################################################

main() {
    case "${1:-}" in
        --help|-h)
            show_help
            exit 0
            ;;
        --cleanup)
            print_header "OpenEMR on OpenShift — Cleanup"
            preflight_checks
            detect_project
            cleanup
            exit 0
            ;;
        --status)
            preflight_checks
            detect_project
            show_status
            exit 0
            ;;
        --deploy|"")
            print_header "OpenEMR on OpenShift — Deployment"
            preflight_checks
            detect_project
            deploy_mariadb
            deploy_redis
            deploy_openemr
            display_summary
            print_success "Deployment complete!"
            ;;
        *)
            print_error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
}

main "$@"