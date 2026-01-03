#!/bin/bash

##############################################################################
# OpenEMR on OpenShift Developer Sandbox - Deployment Script
# 
# This script deploys OpenEMR 7.0.4 with MariaDB on OpenShift Developer Sandbox
# Based on the nextcloud-simple-custom deployment pattern
#
# Note: Developer Sandbox uses AWS EBS storage (RWO only), so OpenEMR runs
# as a single replica. This is suitable for development/demo environments.
#
# Updated: Uses current namespace instead of creating a new project
#          (Developer Sandbox doesn't allow project creation)
#
# Author: Ryan Nix
# Version: 1.1
##############################################################################

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration - PROJECT_NAME will be set dynamically from current context
OPENEMR_IMAGE="quay.io/ryan_nix/openemr-openshift:7.0.4"
MARIADB_IMAGE="quay.io/fedora/mariadb-118:latest"
REDIS_IMAGE="docker.io/redis:8-alpine"

# Storage configuration for Developer Sandbox (AWS EBS - RWO only)
STORAGE_CLASS="gp3-csi"  # Default Developer Sandbox storage class
DB_STORAGE_SIZE="5Gi"
DOCUMENTS_STORAGE_SIZE="10Gi"
REDIS_STORAGE_SIZE="1Gi"

# Database configuration
DB_NAME="openemr"
DB_USER="openemr"
DB_PASSWORD="$(openssl rand -hex 24)"
DB_ROOT_PASSWORD="$(openssl rand -hex 24)"

# OpenEMR admin configuration
OE_ADMIN_USER="admin"
OE_ADMIN_PASSWORD="$(openssl rand -hex 12)"

# OpenEMR configuration
# Note: Route will auto-generate with Developer Sandbox domain

##############################################################################
# Helper Functions
##############################################################################

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_header() {
    echo ""
    echo "=========================================="
    echo "$1"
    echo "=========================================="
}

check_command() {
    if ! command -v $1 &> /dev/null; then
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

##############################################################################
# Preflight Checks
##############################################################################

preflight_checks() {
    print_header "Preflight Checks"
    
    # Check if oc command exists
    check_command oc
    
    # Check if logged into OpenShift
    if ! oc whoami &> /dev/null; then
        print_error "Not logged into OpenShift. Please login first."
        exit 1
    fi
    
    print_success "Logged in as: $(oc whoami)"
    print_success "Using cluster: $(oc whoami --show-server)"
}

##############################################################################
# Detect Current Project
##############################################################################

detect_project() {
    print_header "Detecting Current Project"
    
    # Get the current project/namespace from context
    PROJECT_NAME=$(oc project -q 2>/dev/null)
    
    if [ -z "$PROJECT_NAME" ]; then
        print_error "No project selected. Please switch to a project first with: oc project <project-name>"
        print_info "Available projects:"
        oc projects
        exit 1
    fi
    
    print_success "Using current project: $PROJECT_NAME"
    
    # Verify we have access to the project
    if ! oc get project "$PROJECT_NAME" &> /dev/null; then
        print_error "Cannot access project $PROJECT_NAME"
        exit 1
    fi
    
    # Export PROJECT_NAME so it's available to all functions
    export PROJECT_NAME
}

##############################################################################
# MariaDB Deployment
##############################################################################

deploy_mariadb() {
    print_header "Deploying MariaDB Database"
    
    # Create MariaDB secret
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
    
    # Create PVC for MariaDB
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
  storageClassName: $STORAGE_CLASS
EOF
    
    print_success "Database PVC created"
    
    # Deploy MariaDB StatefulSet
    print_info "Deploying MariaDB StatefulSet..."
    cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: StatefulSet
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
  serviceName: mariadb
  replicas: 1
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
          exec:
            command:
            - /bin/sh
            - -c
            - mysqladmin ping -h localhost
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
    
    print_success "MariaDB StatefulSet created"
    
    # Create MariaDB Service
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
    
    # Wait for MariaDB to be ready
    wait_for_pod "app=mariadb" 300
    print_success "MariaDB is ready"
}

##############################################################################
# Redis Deployment
##############################################################################

deploy_redis() {
    print_header "Deploying Redis Cache"
    
    # Deploy Redis (no persistence needed for cache, avoids permission issues)
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
    
    # Create Redis Service
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
    
    # Wait for Redis to be ready
    wait_for_pod "app=redis" 300
    print_success "Redis is ready"
}

##############################################################################
# OpenEMR Deployment
##############################################################################

deploy_openemr() {
    print_header "Deploying OpenEMR Application"
    
    # Create PVC for OpenEMR documents (RWO for Developer Sandbox)
    print_info "Creating persistent volume for documents..."
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: openemr-documents
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
  storageClassName: $STORAGE_CLASS
EOF
    
    print_success "Documents PVC created"
    
    # Create OpenEMR admin secret
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
    
    # Create OpenEMR Deployment (single replica for RWO storage)
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
    app.kubernetes.io/version: "7.0.4"
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
        app.kubernetes.io/version: "7.0.4"
    spec:
      containers:
      - name: openemr
        image: $OPENEMR_IMAGE
        ports:
        - containerPort: 8080
          name: http
        env:
        # Database connection
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
        # OpenEMR admin credentials
        - name: OE_USER
          value: admin
        - name: OE_PASS
          valueFrom:
            secretKeyRef:
              name: openemr-secret
              key: admin-password
        # Legacy env vars for compatibility
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
        volumeMounts:
        - name: openemr-documents
          mountPath: /var/www/html/openemr/sites/default/documents
        livenessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 60
          periodSeconds: 10
          timeoutSeconds: 5
        readinessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 30
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
      - name: openemr-documents
        persistentVolumeClaim:
          claimName: openemr-documents
EOF
    
    print_success "OpenEMR deployment created"
    
    # Create OpenEMR Service
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
    
    # Create OpenEMR Route (auto-generate hostname)
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
    
    # Wait for OpenEMR to be ready
    wait_for_pod "app=openemr" 300
    print_success "OpenEMR is ready"
    
    # Create crypto keys directory (PVC mount overwrites this from image)
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
    echo "Next Steps:"
    echo "  1. Wait 2-3 minutes for auto-configuration to complete"
    echo "  2. Navigate to: https://$ROUTE_URL"
    echo "  3. Login with admin credentials above"
    echo ""
    echo "Note: This deployment runs on Developer Sandbox with:"
    echo "  - Single replica (RWO storage limitation)"
    echo "  - 5Gi database storage (MariaDB 11.8)"
    echo "  - 10Gi document storage"
    echo "  - Redis cache (in-memory, no persistence)"
    echo "  - Auto-configuration enabled"
    echo ""
    echo "Useful Commands:"
    echo "  View pods:        oc get pods"
    echo "  View logs:        oc logs -f deployment/openemr"
    echo "  View database:    oc logs -f statefulset/mariadb"
    echo "  Restart OpenEMR:  oc rollout restart deployment/openemr"
    echo ""
    
    # Save credentials to file
    CREDS_FILE="openemr-credentials.txt"
    cat > "$CREDS_FILE" <<EOF
OpenEMR Deployment Credentials
==============================
Date: $(date)
Project: $PROJECT_NAME

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

OpenShift Project: $PROJECT_NAME

Notes:
  - OpenEMR will auto-configure on first run
  - Wait 2-3 minutes after deployment for setup to complete
  - Login with admin credentials above
EOF
    
    print_success "Credentials saved to: $CREDS_FILE"
    print_warning "Keep this file secure! It contains sensitive passwords."
}

##############################################################################
# Cleanup Function (can be called with --cleanup flag)
##############################################################################

cleanup() {
    print_header "Cleaning Up OpenEMR Deployment"
    
    print_info "Cleaning up OpenEMR deployment..."
    
    oc delete deployment openemr redis --ignore-not-found
    oc delete statefulset mariadb --ignore-not-found
    oc delete service openemr redis mariadb --ignore-not-found
    oc delete route openemr --ignore-not-found
    oc delete secret openemr-secret mariadb-secret --ignore-not-found
    
    print_warning "PVCs are NOT deleted automatically. To delete them:"
    echo "  oc delete pvc openemr-documents mariadb-data"
    
    print_success "Cleanup complete!"
}

##############################################################################
# Usage Help
##############################################################################

show_help() {
    echo "OpenEMR on OpenShift - Deployment Script"
    echo ""
    echo "Usage: $0 [OPTION]"
    echo ""
    echo "Options:"
    echo "  --deploy    Deploy OpenEMR (default if no option specified)"
    echo "  --cleanup   Remove all OpenEMR resources from current project"
    echo "  --status    Show status of OpenEMR deployment"
    echo "  --help      Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0              # Deploy OpenEMR"
    echo "  $0 --deploy     # Deploy OpenEMR"
    echo "  $0 --cleanup    # Remove all OpenEMR resources"
    echo "  $0 --status     # Check deployment status"
    echo ""
}

##############################################################################
# Status Function
##############################################################################

show_status() {
    print_header "OpenEMR Deployment Status"
    
    echo ""
    print_info "Project: $PROJECT_NAME"
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
    
    # Show URL if route exists
    ROUTE_URL=$(oc get route openemr -o jsonpath='{.spec.host}' 2>/dev/null)
    if [ -n "$ROUTE_URL" ]; then
        echo ""
        print_success "OpenEMR URL: https://$ROUTE_URL"
    fi
}

##############################################################################
# Main Execution
##############################################################################

main() {
    case "${1:-}" in
        --help|-h)
            show_help
            exit 0
            ;;
        --cleanup)
            print_header "OpenEMR on OpenShift - Cleanup"
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
            print_header "OpenEMR on OpenShift - Deployment Script"
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

# Run main function with any passed arguments
main "$@"
