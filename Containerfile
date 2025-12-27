# OpenEMR Container - CentOS 9 Stream with Remi PHP 8.4
# Multi-stage build for optimized final image
# Runs nginx + PHP-FPM in single container with supervisord

# ============================================================================
# Stage 1: Builder - Download and prepare OpenEMR
# ============================================================================
FROM quay.io/centos/centos:stream9 AS builder

# OpenEMR version
ARG OPENEMR_VERSION=7.0.5

# Install download tools
RUN dnf install -y \
    curl \
    tar \
    gzip \
    && dnf clean all

# Download OpenEMR source
WORKDIR /tmp
RUN curl -fsSL "https://github.com/openemr/openemr/archive/refs/tags/v${OPENEMR_VERSION}.tar.gz" \
    -o openemr.tar.gz \
    && tar -xzf openemr.tar.gz \
    && mv "openemr-${OPENEMR_VERSION}" openemr \
    && rm openemr.tar.gz

# Remove unnecessary files to reduce image size
RUN cd /tmp/openemr && \
    rm -rf .git* .travis* tests docker contrib/util/docker \
    && find . -type f -name "*.md" -delete

# ============================================================================
# Stage 2: Runtime - Build final container
# ============================================================================
FROM quay.io/centos/centos:stream9

LABEL maintainer="Ryan Nix <ryan_nix>" \
      description="OpenEMR on CentOS 9 Stream - OpenShift Ready" \
      version="7.0.5" \
      io.k8s.description="OpenEMR Electronic Medical Records System" \
      io.openshift.tags="openemr,healthcare,php,medical"

# Environment variables
ENV OPENEMR_VERSION=7.0.5 \
    OPENEMR_WEB_ROOT=/var/www/html/openemr \
    PHP_FPM_PORT=9000 \
    NGINX_PORT=8080 \
    PHP_VERSION=8.4

# Enable EPEL and CRB repositories
RUN dnf install -y epel-release \
    && dnf config-manager --set-enabled crb \
    && dnf clean all

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

# Copy OpenEMR from builder stage
COPY --from=builder /tmp/openemr ${OPENEMR_WEB_ROOT}

# ============================================================================
# PHP Configuration
# ============================================================================

# Create custom PHP configuration for OpenEMR
RUN cat > /etc/php.d/99-openemr.ini <<EOF
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
session.save_handler = files
session.save_path = "/tmp/sessions"
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
    client_max_body_size 128M;
    
    # Gzip
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_types text/plain text/css text/xml text/javascript 
               application/x-javascript application/xml+rss 
               application/javascript application/json;

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "no-referrer-when-downgrade" always;

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
user=root
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
    && chmod -R 770 ${OPENEMR_WEB_ROOT}/interface/modules/zend_modules/config

# Create entrypoint script
RUN cat > /entrypoint.sh <<'EOF'
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

# Start supervisor (manages nginx + PHP-FPM)
echo "Starting services via supervisord..."
exec /usr/bin/supervisord -c /etc/supervisord.conf
EOF

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
