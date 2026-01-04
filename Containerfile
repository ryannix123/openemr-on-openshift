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
    # PHP Core
    php \
    php-fpm \
    php-cli \
    php-common \
    # Database
    php-mysqlnd \
    php-pdo \
    # OpenEMR Required Extensions
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
    # OpenEMR Recommended Extensions
    php-imap \
    php-tidy \
    php-xmlrpc \
    php-sodium \
    # Session handling
    php-pecl-redis5 \
    # Process management
    supervisor \
    # Utilities
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
# PHP Configuration
# ============================================================================

# Create custom PHP configuration for OpenEMR
RUN cat > /etc/php.d/99-openemr.ini <<'EOF'
; OpenEMR PHP Configuration
; File Upload Settings (for medical documents, images, lab results)
upload_max_filesize = 128M
post_max_size = 128M
max_input_vars = 3000

; Memory and Execution
memory_limit = 512M
max_execution_time = 300
max_input_time = 300

; Session Configuration (Redis-backed for multi-pod deployments)
session.save_handler = redis
session.save_path = "tcp://redis:6379"
session.gc_maxlifetime = 7200
session.cookie_httponly = 1
session.cookie_secure = 1
session.use_strict_mode = 1

; Error Handling (Production)
display_errors = Off
display_startup_errors = Off
error_reporting = E_ALL & ~E_DEPRECATED & ~E_STRICT
log_errors = On
error_log = /dev/stderr

; Security
expose_php = Off
allow_url_fopen = On
allow_url_include = Off

; Date/Time
date.timezone = UTC

; OPcache (Performance)
opcache.enable = 1
opcache.memory_consumption = 256
opcache.interned_strings_buffer = 16
opcache.max_accelerated_files = 10000
opcache.validate_timestamps = 0
opcache.revalidate_freq = 0
opcache.save_comments = 1
opcache.fast_shutdown = 1
EOF

# ============================================================================
# PHP-FPM Configuration
# ============================================================================

RUN cat > /etc/php-fpm.d/www.conf <<'EOF'
[www]
; Unix socket or TCP (we use TCP for easier container networking)
listen = 127.0.0.1:9000

; Process ownership (OpenShift uses arbitrary UIDs, group 0)
listen.owner = nginx
listen.group = root
listen.mode = 0660

; Process manager configuration
user = nginx
group = root

; Dynamic process management
pm = dynamic
pm.max_children = 50
pm.start_servers = 5
pm.min_spare_servers = 5
pm.max_spare_servers = 35
pm.process_idle_timeout = 10s
pm.max_requests = 500

; Logging
access.log = /dev/stdout
catch_workers_output = yes
decorate_workers_output = no

; Health check endpoint
pm.status_path = /fpm-status
ping.path = /fpm-ping
ping.response = pong

; Session configuration (Redis)
php_value[session.save_handler] = redis
php_value[session.save_path] = "tcp://redis:6379"
php_value[session.gc_maxlifetime] = 7200

; Security
php_admin_flag[log_errors] = on
php_admin_value[error_log] = /dev/stderr
EOF

# ============================================================================
# nginx Configuration
# ============================================================================

RUN cat > /etc/nginx/nginx.conf <<'EOF'
# nginx configuration for OpenEMR
user nginx;
worker_processes auto;
error_log /dev/stderr warn;
pid /run/nginx.pid;

events {
    worker_connections 1024;
    use epoll;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    # Logging
    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';
    access_log /dev/stdout main;

    # Performance
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;

    # Gzip Compression
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml application/json application/javascript 
               application/xml application/xml+rss text/javascript application/x-font-ttf
               font/opentype image/svg+xml;

    server {
        listen 8080 default_server;
        listen [::]:8080 default_server;
        server_name _;
        root /var/www/html/openemr;
        index index.php index.html;

        # Health check endpoints
        location /health {
            access_log off;
            return 200 "healthy\n";
            add_header Content-Type text/plain;
        }

        location /fpm-status {
            access_log off;
            fastcgi_pass 127.0.0.1:9000;
            fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
            include fastcgi_params;
        }

        # OpenEMR main application
        location / {
            try_files $uri $uri/ /index.php?$query_string;
        }

        # PHP processing
        location ~ \.php$ {
            try_files $uri =404;
            fastcgi_split_path_info ^(.+\.php)(/.+)$;
            fastcgi_pass 127.0.0.1:9000;
            fastcgi_index index.php;
            fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
            include fastcgi_params;
            
            # Increased timeouts for long-running reports
            fastcgi_read_timeout 300;
            fastcgi_send_timeout 300;
        }

        # Deny access to sensitive files
        location ~ /\.ht {
            deny all;
        }
        
        location ~ /\.git {
            deny all;
        }

        # OpenEMR specific denies
        location ~ ^/sites/.*/documents {
            deny all;
        }

        location ~ ^/sites/default/sqlconf.php {
            deny all;
        }

        # Allow larger uploads for medical documents
        client_max_body_size 128M;
        client_body_buffer_size 128k;
    }
}
EOF

# ============================================================================
# Supervisor Configuration (manages nginx + PHP-FPM)
# ============================================================================

RUN mkdir -p /var/log/supervisor

RUN cat > /etc/supervisord.conf <<'EOF'
[supervisord]
nodaemon=true
logfile=/dev/stdout
logfile_maxbytes=0
loglevel=info
pidfile=/run/supervisord.pid

[program:php-fpm]
command=/usr/sbin/php-fpm --nodaemonize --fpm-config /etc/php-fpm.conf
autostart=true
autorestart=true
priority=5
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
stdout_events_enabled=true
stderr_events_enabled=true

[program:nginx]
command=/usr/sbin/nginx -g 'daemon off;'
autostart=true
autorestart=true
priority=10
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
stdout_events_enabled=true
stderr_events_enabled=true
EOF

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
    && chmod -R g=u \
    ${OPENEMR_WEB_ROOT} \
    /var/log/nginx \
    /var/log/php-fpm \
    /var/lib/nginx \
    /var/lib/php \
    /run \
    /tmp/sessions \
    /etc/nginx \
    /etc/php-fpm.d

# Make specific OpenEMR directories writable
RUN chmod -R 770 ${OPENEMR_WEB_ROOT}/sites/default/documents \
    && chmod -R 770 ${OPENEMR_WEB_ROOT}/sites \
    && chmod -R 770 ${OPENEMR_WEB_ROOT}/interface/modules/zend_modules/config \
    && mkdir -p ${OPENEMR_WEB_ROOT}/sites/default/documents/logs_and_misc/methods \
    && chmod -R 770 ${OPENEMR_WEB_ROOT}/sites/default/documents/logs_and_misc

# Create entrypoint script
RUN cat > /entrypoint.sh <<'ENTRYPOINT'
#!/bin/bash
set -e

echo "=========================================="
echo "Starting OpenEMR Container"
echo "=========================================="
echo "OpenEMR Version: ${OPENEMR_VERSION}"
echo "PHP Version: $(php -v | head -n 1)"
echo "Web Root: ${OPENEMR_WEB_ROOT}"
echo ""
echo "Configuration:"
echo "  - PHP-FPM: 127.0.0.1:${PHP_FPM_PORT}"
echo "  - nginx: 0.0.0.0:${NGINX_PORT}"
echo "  - UID: $(id -u), GID: $(id -g)"
echo "=========================================="

# Ensure permissions are correct (OpenShift may assign random UID)
echo "Setting permissions for UID $(id -u)..."
chmod -R g=u ${OPENEMR_WEB_ROOT}/sites 2>/dev/null || true
chmod -R g=u /tmp/sessions 2>/dev/null || true
chmod -R g=u /var/lib/php/session 2>/dev/null || true

# Create crypto keys directory (may be on mounted PVC, so create at runtime)
mkdir -p ${OPENEMR_WEB_ROOT}/sites/default/documents/logs_and_misc/methods 2>/dev/null || true
chmod -R 770 ${OPENEMR_WEB_ROOT}/sites/default/documents/logs_and_misc 2>/dev/null || true

# Test Redis connectivity and fall back to file sessions if needed
echo "Testing session storage..."
if php -r "try { \$r = new Redis(); \$r->connect('redis', 6379, 2); echo 'OK'; } catch (Exception \$e) { echo 'FAIL'; exit(1); }" 2>/dev/null; then
    echo "✓ Redis session storage available"
else
    echo "⚠ Redis unavailable, falling back to file-based sessions"
    # Update PHP-FPM to use file sessions
    sed -i 's|php_value\[session.save_handler\] = redis|php_value\[session.save_handler\] = files|' /etc/php-fpm.d/www.conf
    sed -i 's|php_value\[session.save_path\].*|php_value\[session.save_path\] = "/var/lib/php/session"|' /etc/php-fpm.d/www.conf
fi

# Check if OpenEMR is already configured (look for $config = 1 in sqlconf.php)
SQLCONF="${OPENEMR_WEB_ROOT}/sites/default/sqlconf.php"
INSTALLER="${OPENEMR_WEB_ROOT}/contrib/util/installScripts/InstallerAuto.php"

# Debug: Show what files exist
echo "Checking configuration status..."
echo "  - sqlconf.php exists: $(test -f "$SQLCONF" && echo 'yes' || echo 'no')"
echo "  - InstallerAuto.php exists: $(test -f "$INSTALLER" && echo 'yes' || echo 'no')"

# Check if already configured ($config = 1 means configured)
ALREADY_CONFIGURED=false
if [ -f "$SQLCONF" ] && grep -q '\$config = 1' "$SQLCONF" 2>/dev/null; then
    ALREADY_CONFIGURED=true
    echo "  - Configuration status: CONFIGURED"
else
    echo "  - Configuration status: NOT CONFIGURED"
fi

# Auto-configuration on first run
if [ "$ALREADY_CONFIGURED" = false ] && [ -f "$INSTALLER" ]; then
    echo "=========================================="
    echo "Running OpenEMR Auto-Configuration"
    echo "=========================================="
    
    # Set defaults if not provided
    export MYSQL_HOST=${MYSQL_HOST:-mariadb}
    export MYSQL_PORT=${MYSQL_PORT:-3306}
    export MYSQL_DATABASE=${MYSQL_DATABASE:-openemr}
    export MYSQL_USER=${MYSQL_USER:-openemr}
    export MYSQL_PASS=${MYSQL_PASS:-openemr}
    export OE_USER=${OE_USER:-admin}
    export OE_PASS=${OE_PASS:-pass}
    
    echo "Database connection settings:"
    echo "  - Host: ${MYSQL_HOST}"
    echo "  - Port: ${MYSQL_PORT}"
    echo "  - Database: ${MYSQL_DATABASE}"
    echo "  - User: ${MYSQL_USER}"
    echo "  - Admin User: ${OE_USER}"
    
    # Wait for database to be ready
    echo "Waiting for database at ${MYSQL_HOST}..."
    counter=0
    while ! php -r "mysqli_connect('${MYSQL_HOST}', '${MYSQL_USER}', '${MYSQL_PASS}', '${MYSQL_DATABASE}') or exit(1);" 2>/dev/null; do
        sleep 2
        counter=$((counter+1))
        echo "  Attempt $counter: waiting for database..."
        if [ $counter -gt 30 ]; then
            echo "ERROR: Database not ready after 60 seconds"
            echo "Check that MariaDB pod is running and credentials are correct"
            echo "Falling back to manual setup..."
            break
        fi
    done
    
    if [ $counter -le 30 ]; then
        echo "✓ Database connection successful"
        
        # Run InstallerAuto.php with no_root_db_access mode
        # This uses the pre-created database and user from MariaDB container
        echo "Running InstallerAuto.php (no_root_db_access mode)..."
        cd ${OPENEMR_WEB_ROOT}
        
        # Enable the installer script
        export OPENEMR_ENABLE_INSTALLER_AUTO=1
        
        php -f contrib/util/installScripts/InstallerAuto.php \
            no_root_db_access=1 \
            server="${MYSQL_HOST}" \
            port="${MYSQL_PORT}" \
            login="${MYSQL_USER}" \
            pass="${MYSQL_PASS}" \
            dbname="${MYSQL_DATABASE}" \
            iuser="${OE_USER}" \
            iuserpass="${OE_PASS}" \
            iuname="Administrator" \
            2>&1 \
            && echo "✓ Auto-configuration completed successfully!" \
            || echo "⚠ Auto-configuration had issues, check logs above"
        
        # Verify configuration was successful
        if grep -q '\$config = 1' "$SQLCONF" 2>/dev/null; then
            echo "✓ OpenEMR configured and ready!"
        else
            echo "⚠ Configuration may not be complete - manual setup may be required"
        fi
        
        echo "=========================================="
    fi
elif [ "$ALREADY_CONFIGURED" = true ]; then
    echo "✓ OpenEMR already configured, skipping auto-configuration"
else
    echo "⚠ InstallerAuto.php not found - manual setup required"
    echo "  Visit the web interface to complete setup"
fi

# Start supervisor (manages nginx + PHP-FPM)
echo "Starting services via supervisord..."
exec /usr/bin/supervisord -c /etc/supervisord.conf
ENTRYPOINT

RUN chmod +x /entrypoint.sh && chgrp 0 /entrypoint.sh && chmod g=u /entrypoint.sh

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
