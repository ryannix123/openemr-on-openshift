#!/bin/bash

##############################################################################
# OpenEMR Container Build Script
# 
# This script builds the OpenEMR container and pushes it to Quay.io
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
OPENEMR_VERSION="8.0.0"
IMAGE_NAME="openemr-openshift"
REGISTRY="quay.io/ryan_nix"
FULL_IMAGE="${REGISTRY}/${IMAGE_NAME}"

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

##############################################################################
# Main Functions
##############################################################################

preflight_checks() {
    print_header "Preflight Checks"
    
    # Check if podman or docker is available
    if command -v podman &> /dev/null; then
        CONTAINER_CMD="podman"
        print_success "Using podman"
    elif command -v docker &> /dev/null; then
        CONTAINER_CMD="docker"
        print_success "Using docker"
    else
        print_error "Neither podman nor docker found. Please install one."
        exit 1
    fi
    
    # Check if Containerfile exists
    if [ ! -f "Containerfile" ]; then
        print_error "Containerfile not found in current directory"
        exit 1
    fi
    
    print_success "Containerfile found"
}

build_container() {
    print_header "Building Container"
    
    print_info "Building OpenEMR ${OPENEMR_VERSION} container..."
    print_info "Target platform: linux/amd64 (for OpenShift compatibility)"
    print_info "This may take several minutes..."
    
    $CONTAINER_CMD build \
        --platform linux/amd64 \
        --build-arg OPENEMR_VERSION=${OPENEMR_VERSION} \
        -t ${FULL_IMAGE}:${OPENEMR_VERSION} \
        -t ${FULL_IMAGE}:latest \
        -f Containerfile \
        .
    
    print_success "Container built successfully"
    
    # Display image info
    print_info "Image details:"
    $CONTAINER_CMD images ${FULL_IMAGE}
}

test_container() {
    print_header "Testing Container"
    
    print_info "Running basic container tests..."
    
    # Test 1: Check PHP version
    print_info "Test 1: Checking PHP version..."
    PHP_VERSION=$($CONTAINER_CMD run --rm --entrypoint php ${FULL_IMAGE}:${OPENEMR_VERSION} -v | head -n 1)
    print_success "PHP Version: $PHP_VERSION"
    
    # Test 2: Check nginx version
    print_info "Test 2: Checking nginx version..."
    NGINX_VERSION=$($CONTAINER_CMD run --rm --entrypoint nginx ${FULL_IMAGE}:${OPENEMR_VERSION} -v 2>&1)
    print_success "nginx Version: $NGINX_VERSION"
    
    # Test 3: Check PHP modules
    print_info "Test 3: Checking required PHP modules..."
    REQUIRED_MODULES=("gd" "mysqlnd" "xml" "mbstring" "zip" "curl" "soap" "ldap")
    
    for module in "${REQUIRED_MODULES[@]}"; do
        if $CONTAINER_CMD run --rm --entrypoint php ${FULL_IMAGE}:${OPENEMR_VERSION} -m | grep -q "^${module}$"; then
            print_success "  ✓ ${module} module installed"
        else
            print_error "  ✗ ${module} module missing"
            exit 1
        fi
    done
    
    # Special check for OPcache (listed as "Zend OPcache" in php -m)
    if $CONTAINER_CMD run --rm --entrypoint php ${FULL_IMAGE}:${OPENEMR_VERSION} -m | grep -q "Zend OPcache"; then
        print_success "  ✓ opcache module installed"
    else
        print_error "  ✗ opcache module missing"
        exit 1
    fi
    
    print_success "All tests passed!"
}

push_container() {
    print_header "Pushing Container to Registry"
    
    print_info "Logging into Quay.io..."
    print_warning "You will be prompted for your Quay.io credentials"
    
    $CONTAINER_CMD login quay.io
    
    print_info "Pushing ${FULL_IMAGE}:${OPENEMR_VERSION}..."
    $CONTAINER_CMD push ${FULL_IMAGE}:${OPENEMR_VERSION}
    
    print_info "Pushing ${FULL_IMAGE}:latest..."
    $CONTAINER_CMD push ${FULL_IMAGE}:latest
    
    print_success "Container pushed successfully!"
    print_info "Image available at: ${FULL_IMAGE}:${OPENEMR_VERSION}"
}

display_summary() {
    print_header "Build Summary"
    
    echo ""
    echo -e "${GREEN}Container built and pushed successfully!${NC}"
    echo ""
    echo "Image Information:"
    echo "  Name: ${IMAGE_NAME}"
    echo "  Registry: ${REGISTRY}"
    echo "  Version: ${OPENEMR_VERSION}"
    echo ""
    echo "Pull Commands:"
    echo "  podman pull ${FULL_IMAGE}:${OPENEMR_VERSION}"
    echo "  podman pull ${FULL_IMAGE}:latest"
    echo ""
    echo "Next Steps:"
    echo "  1. Update deploy-openemr.sh with this image"
    echo "  2. Run ./deploy-openemr.sh to deploy to OpenShift"
    echo ""
}

##############################################################################
# Main Execution
##############################################################################

main() {
    print_header "OpenEMR Container Build Script"
    
    preflight_checks
    
    # Parse command line arguments
    BUILD_ONLY=false
    SKIP_TESTS=false
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --build-only)
                BUILD_ONLY=true
                shift
                ;;
            --skip-tests)
                SKIP_TESTS=true
                shift
                ;;
            --version)
                OPENEMR_VERSION="$2"
                shift 2
                ;;
            --help)
                echo "Usage: $0 [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --build-only    Only build the container, don't push"
                echo "  --skip-tests    Skip container testing"
                echo "  --version VER   Specify OpenEMR version (default: 7.0.4)"
                echo "  --help          Show this help message"
                echo ""
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done
    
    build_container
    
    if [ "$SKIP_TESTS" = false ]; then
        test_container
    fi
    
    if [ "$BUILD_ONLY" = false ]; then
        push_container
        display_summary
    else
        print_success "Build complete (not pushed)"
    fi
}

# Run main function
main "$@"