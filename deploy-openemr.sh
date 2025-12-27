#!/bin/bash

##############################################################################
# OpenEMR on OpenShift Developer Sandbox - Deployment Script
# 
# This script deploys OpenEMR 7.0.5 with MariaDB on OpenShift Developer Sandbox
# Based on the nextcloud-simple-custom deployment pattern
#
# Note: Developer Sandbox uses AWS EBS storage (RWO only), so OpenEMR runs
# as a single replica. This is suitable for development/demo environments.
#
# Author: Ryan Nix
# Version: 1.0
##############################################################################

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
PROJECT_NAME="openemr"
OPENEMR_IMAGE="quay.io/ryan_nix/openemr-openshift:7.0.5"
MARIADB_IMAGE="registry.redhat.io/rhel9/mariadb-1011:latest"

# Storage configuration for Developer Sandbox (AWS EBS - RWO only)
STORAGE_CLASS="gp3"  # Default Developer Sandbox storage class
DB_STORAGE_SIZE="5Gi"
DOCUMENTS_STORAGE_SIZE="10Gi"

# Database configuration
DB_NAME="openemr"
DB_USER="openemr"
DB_PASSWORD="$(openssl rand -base64 32)"
DB_ROOT_PASSWORD="$(openssl rand -base64 32)"

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
    local namespace=$2
    local timeout=${3:-300}
    
    print_info "Waiting for pod with label $label to be ready..."
    oc wait --for=condition=ready pod \
        -l "$label" \
        -n "$namespace" \
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
# Project Creation
##############################################################################

create_project() {
    print_header "Creating OpenShift Project"
    
    if oc get project "$PROJECT_NAME" &> /dev/null; then
        print_warning "Project $PROJECT_NAME already exists"
        read -p "Do you want to delete and recreate it? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            print_info "Deleting existing project..."
            oc delete project "$PROJECT_NAME"
            # Wait for project to be fully deleted
            while oc get project "$PROJECT_NAME" &> /dev/null; do
                sleep 2
            done
            print_success "Project deleted"
        else
            print_info "Using existing project"
            oc project "$PROJECT_NAME"
            return
        fi
    fi
    
    print_info "Creating project: $PROJECT_NAME"
    oc new-project "$PROJECT_NAME" \
        --description="OpenEMR Electronic Medical Records System" \
        --display-name="OpenEMR"
    
    print_success "Project created successfully"
}

##############################################################################
# MariaDB Deployment
##############################################################################

deploy_mariadb() {
    print_header "Deploying MariaDB Database"
    
    # Create MariaDB secret
    print_info "Creating database secret..."
    oc create secret generic mariadb-secret \
        --from-literal=database-name="$DB_NAME" \
        --from-literal=database-user="$DB_USER" \
        --from-literal=database-password="$DB_PASSWORD" \
        --from-literal=database-root-password="$DB_ROOT_PASSWORD" \
        -n "$PROJECT_NAME"
    
    print_success "Database secret created"
    
    # Create PVC for MariaDB
    print_info "Creating persistent volume for database..."
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mariadb-data
  namespace: $PROJECT_NAME
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
  namespace: $PROJECT_NAME
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
  namespace: $PROJECT_NAME
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
    wait_for_pod "app=mariadb" "$PROJECT_NAME" 300
    print_success "MariaDB is ready"
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
  namespace: $PROJECT_NAME
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: $DOCUMENTS_STORAGE_SIZE
  storageClassName: $STORAGE_CLASS
EOF
    
    print_success "Documents PVC created"
    
    # Create OpenEMR Deployment (single replica for RWO storage)
    print_info "Deploying OpenEMR application..."
    cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: openemr
  namespace: $PROJECT_NAME
spec:
  replicas: 1
  selector:
    matchLabels:
      app: openemr
  template:
    metadata:
      labels:
        app: openemr
    spec:
      containers:
      - name: openemr
        image: $OPENEMR_IMAGE
        ports:
        - containerPort: 8080
          name: http
        env:
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
  namespace: $PROJECT_NAME
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
  namespace: $PROJECT_NAME
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
    wait_for_pod "app=openemr" "$PROJECT_NAME" 300
    print_success "OpenEMR is ready"
}

##############################################################################
# Display Summary
##############################################################################

display_summary() {
    print_header "Deployment Summary"
    
    ROUTE_URL=$(oc get route openemr -n "$PROJECT_NAME" -o jsonpath='{.spec.host}')
    
    echo ""
    echo -e "${GREEN}OpenEMR has been successfully deployed!${NC}"
    echo ""
    echo "Access Information:"
    echo "  URL: https://$ROUTE_URL"
    echo ""
    echo "Database Information:"
    echo "  Host: mariadb.$PROJECT_NAME.svc.cluster.local"
    echo "  Port: 3306"
    echo "  Database: $DB_NAME"
    echo "  Username: $DB_USER"
    echo "  Password: $DB_PASSWORD"
    echo ""
    echo "Next Steps:"
    echo "  1. Navigate to: https://$ROUTE_URL"
    echo "  2. Complete the OpenEMR setup wizard"
    echo "  3. Use the database credentials above when prompted"
    echo ""
    echo "Note: This deployment runs on Developer Sandbox with:"
    echo "  - Single replica (RWO storage limitation)"
    echo "  - 5Gi database storage"
    echo "  - 10Gi document storage"
    echo ""
    echo "Useful Commands:"
    echo "  View pods:        oc get pods -n $PROJECT_NAME"
    echo "  View logs:        oc logs -f deployment/openemr -n $PROJECT_NAME"
    echo "  View database:    oc logs -f statefulset/mariadb -n $PROJECT_NAME"
    echo "  Restart OpenEMR:  oc rollout restart deployment/openemr -n $PROJECT_NAME"
    echo ""
    
    # Save credentials to file
    CREDS_FILE="openemr-credentials.txt"
    cat > "$CREDS_FILE" <<EOF
OpenEMR Deployment Credentials
==============================
Date: $(date)

Access URL: https://$ROUTE_URL

Database Information:
  Host: mariadb.$PROJECT_NAME.svc.cluster.local
  Port: 3306
  Database: $DB_NAME
  Username: $DB_USER
  Password: $DB_PASSWORD
  Root Password: $DB_ROOT_PASSWORD

OpenShift Project: $PROJECT_NAME
EOF
    
    print_success "Credentials saved to: $CREDS_FILE"
    print_warning "Keep this file secure! It contains sensitive passwords."
}

##############################################################################
# Main Execution
##############################################################################

main() {
    print_header "OpenEMR on OpenShift - Deployment Script"
    
    preflight_checks
    create_project
    deploy_mariadb
    deploy_openemr
    display_summary
    
    print_success "Deployment complete!"
}

# Run main function
main
