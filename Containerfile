# OpenEMR Container - CentOS 9 Stream with Remi PHP 8.4
# Multi-stage build for optimized final image
# Runs nginx + PHP-FPM in single container with supervisord

# ============================================================================
# Stage 1: Builder - Download and prepare OpenEMR
# ============================================================================
FROM quay.io/centos/centos:stream9 AS builder

# OpenEMR version
ARG OPENEMR_VERSION=7.0.4

# Enable EPEL and CRB repositories for additional packages
RUN dnf install -y epel-release \
    && dnf config-manager --set-enabled crb \
    && dnf clean all

# Install Remi's repository for PHP 8.4
RUN dnf install -y \
    https://rpms.remirepo.net/enterprise/remi-release-9.rpm \
    && dnf clean all

# Enable Remi's PHP 8.4 repository
RUN dnf module reset php -y \
    && dnf module enable php:remi-8.4 -y

# Install build dependencies and tools
RUN dnf install -y \
    git \
    unzip \
    php-cli \
    php-json \
    php-mbstring \
    php-xml \
    php-zip \
    && dnf clean all

# Install Composer
RUN curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

# Clone OpenEMR from GitHub (shallow clone of specific tag)
WORKDIR /tmp
RUN git clone https://github.com/openemr/openemr.git --branch v7_0_4 --depth 1

# Install PHP dependencies with Composer
WORKDIR /tmp/openemr
RUN composer install --no-dev --no-interaction --optimize-autoloader

# Remove unnecessary files to reduce image size
RUN cd /tmp/openemr && \
    rm -rf .git .github .travis* tests docker contrib/util/docker \
    && find . -type f -name "*.md" -delete \
    && find . -type f -name "*.jar" -delete \
    && find . -type f -name "*.war" -delete

# Verify InstallerAuto.php exists before proceeding
RUN test -f /tmp/openemr/contrib/util/installScripts/InstallerAuto.php \
    && echo "✓ InstallerAuto.php found" \
    || (echo "ERROR: InstallerAuto.php not found!" && exit 1)

# ============================================================================
# Stage 2: Runtime - Build final container
# ============================================================================
FROM quay.io/centos/centos:stream9

LABEL maintainer="Ryan Nix <ryan_nix>" \
      description="OpenEMR on CentOS 9 Stream - OpenShift Ready" \
      version="7.0.4" \
      io.k8s.description="OpenEMR Electronic Medical Records System" \
      io.openshift.tags="openemr,healthcare,php,medical" \
      io.openshift.expose-services="8080:http" \
      app.openshift.io/runtime=php

# Environment variables
ENV OPENEMR_VERSION=7.0.4 \
    OPENEMR_WEB_ROOT=/var/www/html/openemr \
    PHP_FPM_PORT=9000 \
    NGINX_PORT=8080 \
    PHP_VERSION=8.4

# Enable EPEL and CRB repositories
RUN dnf install -y epel-release \
    && dnf config-manager --set-enabled crb \
    && dnf clean all

# Update all packages to get security patches
RUN dnf upgrade -y && dnf clean all

# Install Remi's repository for PHP 8.4
RUN dnf install -y \
    https://rpms.remirepo.net/enterprise/remi-release-9.rpm \
    && dnf clean all

# Enable Remi's PHP 8.4 repository and reset PHP module
RUN dnf module reset php -y \
    && dnf module enable php:remi-8.4 -y

# Install nginx
RUN dnf install -y nginx && dnf clean all

# Install PHP 8.4 and all required modules for OpenEMR from Remi's repo
RUN dnf install -y \
    php \
    php-fpm \
    php-cli \
    php-common \
    php-mysqlnd \
    php-pdo \
    php-gd \
    php-xml \
    php-mbstring \
    php-json \
    php-zip \
    php-curl \
    php-opcache \
    php-ldap \
    php-soap \
    php-bcmath \
    php-intl \
    php-imap \
    php-tidy \
    php-xmlrpc \
    php-sodium \
    php-pecl-redis5 \
    supervisor \
    unzip \
    wget \
    && dnf clean all \
    && rm -rf /var/cache/dnf

# Install Node.js 20 (required for OpenEMR frontend build)
RUN curl -fsSL https://rpm.nodesource.com/setup_20.x | bash - \
    && dnf install -y nodejs \
    && dnf clean all \
    && node --version && npm --version

# Copy OpenEMR from builder stage
COPY --from=builder /tmp/openemr ${OPENEMR_WEB_ROOT}

# Verify InstallerAuto.php was copied
RUN test -f ${OPENEMR_WEB_ROOT}/contrib/util/installScripts/InstallerAuto.php \
    && echo "✓ InstallerAuto.php present in final image"

# Build OpenEMR frontend assets
WORKDIR ${OPENEMR_WEB_ROOT}
RUN npm install --legacy-peer-deps \
    && npm run build \
    && rm -rf node_modules \
    && echo "✓ Frontend assets built successfully"

# ============================================================================
# Configuration Files (COPY instead of heredocs for CI/CD compatibility)
# ============================================================================

# Copy configuration files
COPY configs/99-openemr.ini /etc/php.d/99-openemr.ini
COPY configs/www.conf /etc/php-fpm.d/www.conf
COPY configs/nginx.conf /etc/nginx/nginx.conf
COPY configs/supervisord.conf /etc/supervisord.conf
COPY scripts/entrypoint.sh /entrypoint.sh

# Make entrypoint executable
RUN chmod +x /entrypoint.sh

# ============================================================================
# OpenShift Permissions and Security
# ============================================================================

# Create necessary directories with proper permissions
RUN mkdir -p \
    /var/log/php-fpm \
    /var/log/nginx \
    /var/lib/nginx \
    /var/lib/php/session \
    /run/php-fpm \
    /tmp/sessions \
    /var/log/supervisor \
    ${OPENEMR_WEB_ROOT}/sites/default/documents \
    && chmod -R 775 /tmp/sessions

# OpenShift runs containers with arbitrary UIDs but always group 0 (root)
# Need to give group 0 same permissions as owner
RUN chgrp -R 0 \
    ${OPENEMR_WEB_ROOT} \
    /var/log/nginx \
    /var/log/php-fpm \
    /var/lib/nginx \
    /var/lib/php \
    /run \
    /tmp/sessions \
    /etc/nginx \
    /etc/php-fpm.d \
    /entrypoint.sh \
    && chmod -R g=u \
    ${OPENEMR_WEB_ROOT} \
    /var/log/nginx \
    /var/log/php-fpm \
    /var/lib/nginx \
    /var/lib/php \
    /run \
    /tmp/sessions \
    /etc/nginx \
    /etc/php-fpm.d \
    /entrypoint.sh

# Make specific OpenEMR directories writable
RUN chmod -R 770 ${OPENEMR_WEB_ROOT}/sites/default/documents \
    && chmod -R 770 ${OPENEMR_WEB_ROOT}/sites \
    && chmod -R 770 ${OPENEMR_WEB_ROOT}/interface/modules/zend_modules/config \
    && mkdir -p ${OPENEMR_WEB_ROOT}/sites/default/documents/logs_and_misc/methods \
    && chmod -R 770 ${OPENEMR_WEB_ROOT}/sites/default/documents/logs_and_misc

# ============================================================================
# Health Checks and Metadata
# ============================================================================

# Expose nginx port (8080 for non-root)
EXPOSE 8080

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

# Switch to non-root user (OpenShift will override with arbitrary UID)
USER 1001

# Working directory
WORKDIR ${OPENEMR_WEB_ROOT}

# Start supervisor via entrypoint
ENTRYPOINT ["/entrypoint.sh"]
