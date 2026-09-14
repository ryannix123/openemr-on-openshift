# OpenEMR Container — CentOS Stream 10 + Remi PHP 8.5
# nginx + PHP-FPM + CQM under supervisord, OpenShift arbitrary-UID safe

# ============================================================================
# Stage 1: Builder
# ============================================================================
FROM quay.io/centos/centos:stream10 AS builder

ARG OPENEMR_VERSION=8.4.0

RUN dnf config-manager --set-enabled crb \
    && dnf install -y \
        https://dl.fedoraproject.org/pub/epel/epel-release-latest-10.noarch.rpm \
        https://rpms.remirepo.net/enterprise/remi-release-10.rpm \
    && dnf module switch-to php:remi-8.5 -y \
    && dnf install -y \
        git curl unzip \
        php-cli php-json php-mbstring php-xml php-zip \
        php-process \
        php-pecl-redis5 \
    && dnf clean all && rm -rf /var/cache/dnf /var/log/dnf*

RUN curl -sS https://getcomposer.org/installer | php -- \
        --install-dir=/usr/local/bin --filename=composer

# NodeSource via explicit repo + imported GPG key — no `curl | bash`.
RUN rpm --import https://rpm.nodesource.com/gpgkey/ns-operations-public.key \
    && printf '%s\n' \
        '[nodesource-nodejs]' \
        'name=Node.js 22' \
        'baseurl=https://rpm.nodesource.com/pub_22.x/nodistro/nodejs/$basearch' \
        'gpgkey=https://rpm.nodesource.com/gpgkey/ns-operations-public.key' \
        'gpgcheck=1' \
        'enabled=1' > /etc/yum.repos.d/nodesource.repo \
    && dnf install -y nodejs \
    && dnf clean all && rm -rf /var/cache/dnf \
    && npm install -g yarn --quiet

RUN git clone --depth 1 https://github.com/openemr/oe-cqm-service.git /opt/cqm-service \
    && cd /opt/cqm-service \
    && yarn install --production --non-interactive \
    && yarn cache clean

WORKDIR /tmp
RUN GIT_TAG="v$(echo ${OPENEMR_VERSION} | tr '.' '_')" \
    && echo "Cloning OpenEMR tag: ${GIT_TAG}" \
    && git clone https://github.com/openemr/openemr.git --branch "${GIT_TAG}" --depth 1

WORKDIR /tmp/openemr
RUN composer install --no-dev --no-interaction --optimize-autoloader

# Frontend build happens here so the runtime stage needs neither npm nor network.
RUN npm install --legacy-peer-deps \
    && npm run build \
    && rm -rf node_modules \
    && npm cache clean --force

# Prune. Scoped so vendor/ LICENSE files survive — we redistribute this image
# and MIT/Apache-2.0/BSD all require the license text be retained.
RUN rm -rf .git .github .travis* tests docker contrib/util/docker \
        Documentation swagger \
    && find . -maxdepth 2 -type f -name "*.md" -not -iname "LICENSE*" -delete \
    && find . -type f \( -name "*.jar" -o -name "*.war" \) -delete

RUN test -f /tmp/openemr/contrib/util/installScripts/InstallerAuto.php \
    || (echo "ERROR: InstallerAuto.php not found" && exit 1)

# Echo what the checkout actually is. A tag typo otherwise ships silently and
# only surfaces as a schema mismatch at first boot.
RUN php -r 'require "/tmp/openemr/version.php"; \
    printf("Built from version.php: %d.%d.%d  (schema version %d)\n", \
    $v_major, $v_minor, $v_patch, $v_database);'

# ============================================================================
# Stage 2: Runtime
# ============================================================================
FROM quay.io/centos/centos:stream10

ARG OPENEMR_VERSION=8.4.0

LABEL maintainer="Ryan Nix <ryan.nix@gmail.com>" \
      description="OpenEMR on CentOS Stream 10 - OpenShift Ready" \
      version="${OPENEMR_VERSION}" \
      io.k8s.description="OpenEMR Electronic Medical Records System" \
      io.openshift.tags="openemr,healthcare,php,medical" \
      io.openshift.expose-services="8080:http" \
      app.openshift.io/runtime=php

ENV OPENEMR_VERSION=${OPENEMR_VERSION} \
    OPENEMR_WEB_ROOT=/var/www/html/openemr \
    OPENEMR_DEFAULTS=/opt/openemr/sites-default \
    OPENEMR_SITE=default \
    PHP_FPM_PORT=9000 \
    NGINX_PORT=8080 \
    REDIS_HOST=redis \
    REDIS_PORT=6379 \
    OPCACHE_VALIDATE_TIMESTAMPS=1 \
    OPENEMR_DEBUG=0

RUN dnf config-manager --set-enabled crb \
    && dnf install -y \
        https://dl.fedoraproject.org/pub/epel/epel-release-latest-10.noarch.rpm \
        https://rpms.remirepo.net/enterprise/remi-release-10.rpm \
    && dnf upgrade -y \
    && dnf module switch-to php:remi-8.5 -y \
    && dnf install -y \
        nginx \
        php php-fpm php-cli php-common \
        php-mysqlnd php-pdo \
        php-gd php-xml php-mbstring php-json php-zip \
        php-curl php-opcache php-ldap php-soap php-bcmath php-intl \
        php-imap php-tidy php-sodium \
        php-process \
        php-pecl-redis5 \
        supervisor \
    && dnf clean all && rm -rf /var/cache/dnf /var/log/dnf* /tmp/dnf*

# Node is needed at runtime for the CQM service only.
RUN rpm --import https://rpm.nodesource.com/gpgkey/ns-operations-public.key \
    && printf '%s\n' \
        '[nodesource-nodejs]' \
        'name=Node.js 22' \
        'baseurl=https://rpm.nodesource.com/pub_22.x/nodistro/nodejs/$basearch' \
        'gpgkey=https://rpm.nodesource.com/gpgkey/ns-operations-public.key' \
        'gpgcheck=1' \
        'enabled=1' > /etc/yum.repos.d/nodesource.repo \
    && dnf install -y nodejs \
    && dnf clean all && rm -rf /var/cache/dnf /var/log/dnf*

COPY --from=builder /tmp/openemr ${OPENEMR_WEB_ROOT}
COPY --from=builder /opt/cqm-service /opt/cqm-service

# Pristine default site OUTSIDE the web root. The deploy script mounts the PVC
# at sites/default, so anything staged inside it is invisible at runtime.
RUN mkdir -p /opt/openemr \
    && cp -a ${OPENEMR_WEB_ROOT}/sites/default ${OPENEMR_DEFAULTS}

# ============================================================================
# PHP
# ============================================================================
RUN cat > /etc/php.d/99-openemr.ini <<'EOF'
upload_max_filesize = 128M
post_max_size = 128M
max_input_vars = 3000

memory_limit = 512M
max_execution_time = 300
max_input_time = 300

session.gc_maxlifetime = 7200
session.cookie_httponly = 1
session.cookie_secure = 1
session.use_strict_mode = 1

display_errors = Off
display_startup_errors = Off
error_reporting = E_ALL & ~E_DEPRECATED
log_errors = On
; /dev/stderr breaks across PHP-FPM worker re-exec — errors silently vanish.
error_log = /proc/self/fd/2

expose_php = Off
allow_url_fopen = On
allow_url_include = Off

date.timezone = UTC

opcache.enable = 1
opcache.memory_consumption = 256
opcache.interned_strings_buffer = 16
opcache.max_accelerated_files = 10000
opcache.save_comments = 1
EOF

# listen.owner/group/mode are inert on a TCP listener; user/group are ignored
# when the FPM master isn't root, which it never is on OpenShift. Both removed
# rather than left implying isolation that isn't happening.
RUN cat > /etc/php-fpm.d/www.conf <<'EOF'
[www]
listen = 127.0.0.1:9000

pm = dynamic
pm.max_children = 50
pm.start_servers = 5
pm.min_spare_servers = 5
pm.max_spare_servers = 35
pm.process_idle_timeout = 10s
pm.max_requests = 500

access.log = /dev/stdout
catch_workers_output = yes
decorate_workers_output = no

pm.status_path = /fpm-status
ping.path = /fpm-ping
ping.response = pong

php_admin_flag[log_errors] = on
php_admin_value[error_log] = /proc/self/fd/2
EOF

# ============================================================================
# nginx
# ============================================================================
RUN cat > /etc/nginx/nginx.conf <<'EOF'
# `user` omitted deliberately: nginx warns and ignores it when the master
# process is not root, which is always the case on OpenShift.
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

    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';
    access_log /dev/stdout main;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;

    client_body_temp_path /tmp/nginx-client-body;
    proxy_temp_path       /tmp/nginx-proxy;
    fastcgi_temp_path     /tmp/nginx-fastcgi;
    uwsgi_temp_path       /tmp/nginx-uwsgi;
    scgi_temp_path        /tmp/nginx-scgi;

    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml application/json application/javascript
               application/xml application/xml+rss text/javascript application/x-font-ttf
               font/opentype image/svg+xml;

    # The OpenShift router terminates TLS at the edge, so nginx and PHP both
    # see plain HTTP on the wire. Without translating the router's header,
    # OpenEMR builds http:// self-URLs while the browser holds Secure-only
    # cookies it will not send back. That disagreement presents as a blank
    # page or a login that loops — never as a visible error.
    map $http_x_forwarded_proto $fcgi_https {
        default "";
        https   on;
    }

    server {
        listen 8080 default_server;
        listen [::]:8080 default_server;
        server_name _;
        root /var/www/html/openemr;
        index index.php index.html;

        # Emit relative Location headers. With absolute_redirect on (the
        # default) nginx expands `return 302 /path` into an absolute URL built
        # from the Host header and its own listen port -- so behind a Route it
        # sends the browser to http://<public-host>:8080/, a port nothing
        # outside the pod can reach. The request looks like a healthy 302 in
        # the access log and dies in the browser.
        absolute_redirect off;
        port_in_redirect off;
        server_name_in_redirect off;

        # OpenEMR resolves site_id from $_GET['site'] then $_SESSION['site_id'].
        # A cold request to / has neither, and 8.4.0 raises
        # MissingSiteIdException rather than defaulting. Seed it explicitly.
        location = / {
            return 302 /interface/login/login.php?site=default;
        }

        # Liveness: is nginx alive. Says nothing about PHP.
        location = /health {
            access_log off;
            return 200 "healthy\n";
            add_header Content-Type text/plain;
        }

        # Readiness: traverses FastCGI, so a dead PHP-FPM fails the probe
        # instead of reporting Ready while serving 500s.
        # Deliberately NOT FPM's ping.path. FPM matches ping.path against
        # REQUEST_URI, so /ready can never reach it without faking the URI --
        # and the ping handler answers inside FPM without executing any PHP,
        # which is a weaker signal than this probe should carry. Point at a
        # real one-line script instead: nginx, FastCGI, FPM and the PHP
        # interpreter all have to work for it to answer.
        location = /ready {
            access_log off;
            include fastcgi_params;
            fastcgi_param SCRIPT_FILENAME $document_root/oe-ready.php;
            fastcgi_param SCRIPT_NAME /oe-ready.php;
            fastcgi_pass 127.0.0.1:9000;
        }

        # This one works because the location path and pm.status_path are the
        # same string, so REQUEST_URI matches with no override needed.
        location = /fpm-status {
            access_log off;
            allow 127.0.0.1;
            deny all;
            include fastcgi_params;
            fastcgi_param SCRIPT_FILENAME $document_root/oe-ready.php;
            fastcgi_pass 127.0.0.1:9000;
        }

        location /interface/modules/zend_modules/public/ {
            try_files $uri $uri/ /interface/modules/zend_modules/public/index.php?$query_string;
        }

        location / {
            try_files $uri $uri/ /index.php?$query_string;
        }

        location ~ \.php$ {
            try_files $uri =404;
            fastcgi_split_path_info ^(.+\.php)(/.+)$;
            fastcgi_pass 127.0.0.1:9000;
            fastcgi_index index.php;
            include fastcgi_params;
            fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
            fastcgi_param PATH_INFO $fastcgi_path_info;
            fastcgi_param HTTPS $fcgi_https;
            fastcgi_read_timeout 300;
            fastcgi_send_timeout 300;
        }

        location ~ /\.ht  { deny all; }
        location ~ /\.git { deny all; }
        location ~ ^/sites/.*/documents { deny all; }
        location ~ ^/sites/default/sqlconf.php { deny all; }

        client_max_body_size 128M;
        client_body_buffer_size 128k;
    }
}
EOF

# ============================================================================
# supervisord
# ============================================================================
RUN cat > /etc/supervisord.conf <<'EOF'
[supervisord]
nodaemon=true
logfile=/dev/stdout
logfile_maxbytes=0
loglevel=info
pidfile=/run/supervisord.pid

[supervisorctl]
serverurl=unix:///run/supervisor.sock

[unix_http_server]
file=/run/supervisor.sock
chmod=0700

[rpcinterface:supervisor]
supervisor.rpcinterface_factory=supervisor.rpcinterface:make_main_rpcinterface

[program:php-fpm]
command=/usr/sbin/php-fpm --nodaemonize --fpm-config /etc/php-fpm.conf
autostart=true
autorestart=true
priority=5
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0

[program:nginx]
command=/usr/sbin/nginx -g 'daemon off;'
autostart=true
autorestart=true
priority=10
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0

[program:cqm]
command=node /opt/cqm-service/server.js
autostart=true
autorestart=true
priority=20
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
EOF

# ============================================================================
# Redis probe
# ============================================================================
# A file, not a php -r string spliced from a double-quoted and a single-quoted
# shell fragment. The old form could not report why it failed, because the only
# way to keep the quoting readable was to discard stderr.
RUN cat > /usr/local/bin/oe-redis-probe.php <<'EOF'
<?php
try {
    $r = new Redis();
    if (!$r->connect(getenv('REDIS_HOST'), (int) (getenv('REDIS_PORT') ?: 6379), 2)) {
        fwrite(STDERR, "connect() returned false\n");
        exit(1);
    }
    $pass = getenv('REDIS_PASSWORD');
    if ($pass) {
        $r->auth($pass);
    }
    // connect() alone proves nothing about persistence -- write and read back.
    $r->set('__probe', 'ok', 10);
    if ($r->get('__probe') !== 'ok') {
        fwrite(STDERR, "read-back mismatch\n");
        exit(1);
    }
    exit(0);
} catch (Throwable $e) {
    fwrite(STDERR, get_class($e) . ': ' . $e->getMessage() . "\n");
    exit(1);
}
EOF

# ============================================================================
# Readiness target
# ============================================================================
# Intentionally trivial. Readiness answers "can this pod serve PHP", not "is
# the database healthy" -- probing the database here would take the pod out of
# rotation during any MariaDB blip and turn one outage into two.
RUN cat > ${OPENEMR_WEB_ROOT}/oe-ready.php <<'EOF'
<?php
header('Content-Type: text/plain');
echo "ok\n";
EOF

# ============================================================================
# Schema version check
# ============================================================================
# OpenEMR records the schema revision it expects in version.php and the
# revision actually applied in the `version` table. They are the same pair of
# values the application itself compares to decide an upgrade is due.
RUN cat > /usr/local/bin/oe-schema-check.php <<'EOF'
<?php
$webRoot = getenv('OPENEMR_WEB_ROOT');
require "$webRoot/version.php";

if (!isset($v_database)) {
    fwrite(STDERR, "schema-check: version.php has no \$v_database\n");
    exit(2);
}

$c = @mysqli_connect(
    getenv('MYSQL_HOST'),
    getenv('MYSQL_USER'),
    getenv('MYSQL_PASS'),
    getenv('MYSQL_DATABASE'),
    (int) (getenv('MYSQL_PORT') ?: 3306)
);
if (!$c) {
    fwrite(STDERR, "schema-check: cannot connect to database\n");
    exit(2);
}

$r = @mysqli_query($c, 'SELECT v_major, v_minor, v_patch, v_database FROM version LIMIT 1');
if (!$r || !($row = mysqli_fetch_assoc($r))) {
    fwrite(STDERR, "schema-check: no readable version table\n");
    exit(2);
}

printf(
    "database is %d.%d.%d (schema %d) / image is %d.%d.%d (schema %d)",
    $row['v_major'], $row['v_minor'], $row['v_patch'], $row['v_database'],
    $v_major, $v_minor, $v_patch, $v_database
);

exit(((int) $row['v_database'] === (int) $v_database) ? 0 : 1);
EOF

# ============================================================================
# Entrypoint
# ============================================================================
RUN cat > /entrypoint.sh <<'ENTRYPOINT'
#!/bin/bash
set -euo pipefail

echo "=========================================="
echo "OpenEMR ${OPENEMR_VERSION}"
echo "PHP: $(php -v | head -n 1)"
echo "UID: $(id -u)  GID: $(id -g)"
echo "=========================================="

# OpenShift assigns a UID with no /etc/passwd entry. Some PHP and Node calls
# (getpwuid, os.userInfo) throw without one.
if ! whoami &>/dev/null && [ -w /etc/passwd ]; then
    echo "openemr:x:$(id -u):0:OpenEMR:${OPENEMR_WEB_ROOT}:/sbin/nologin" >> /etc/passwd
fi

mkdir -p /tmp/nginx-client-body /tmp/nginx-proxy /tmp/nginx-fastcgi \
         /tmp/nginx-uwsgi /tmp/nginx-scgi /var/lib/php/session

SITE_DIR="${OPENEMR_WEB_ROOT}/sites/${OPENEMR_SITE}"

# Restore anything the PVC mount is hiding. Source lives outside the web root,
# so it survives a mount at sites/ OR sites/default/.
if [ -d "${OPENEMR_DEFAULTS}" ]; then
    mkdir -p "${SITE_DIR}"
    echo "Restoring default site files into ${SITE_DIR}..."
    cp -an "${OPENEMR_DEFAULTS}/." "${SITE_DIR}/" 2>/dev/null || true
else
    echo "FATAL: ${OPENEMR_DEFAULTS} missing — image built incorrectly." >&2
    exit 1
fi

mkdir -p "${SITE_DIR}/documents/logs_and_misc/methods"
chmod -R g=u "${OPENEMR_WEB_ROOT}/sites" 2>/dev/null || true
chmod -R g=u /var/lib/php/session 2>/dev/null || true

# --- Redis endpoint --------------------------------------------------------
# Kubernetes injects Docker-link-style variables for every Service in the
# namespace. A Service named "redis" yields REDIS_PORT=tcp://<clusterIP>:6379,
# which silently overrides this image's ENV REDIS_PORT=6379 -- the collision is
# purely the variable name. Left alone it produces a save_path of
# tcp://redis:tcp://<ip>:6379, PHP reads the port as "tcp", and session reads
# fail with getaddrinfo errors while the startup banner still claims success.
#
# OPENEMR_REDIS_* wins when set, because nothing injects those names.
REDIS_HOST="${OPENEMR_REDIS_HOST:-${REDIS_HOST:-redis}}"
REDIS_PORT="${OPENEMR_REDIS_PORT:-${REDIS_PORT:-6379}}"

# Recover the port from the injected form rather than discarding it.
case "$REDIS_PORT" in
    tcp://*) REDIS_PORT="${REDIS_PORT##*:}" ;;
esac
case "$REDIS_PORT" in
    ''|*[!0-9]*)
        echo "⚠ REDIS_PORT was not a port number — falling back to 6379"
        REDIS_PORT=6379
        ;;
esac
export REDIS_HOST REDIS_PORT

# --- Session backend -------------------------------------------------------
# Written as a fresh drop-in rather than sed-patching managed config, which
# needs write access to /etc/php.d and dies under `set -e` without it.
#
# Retried, because the fallback is permanent for the life of the pod. A single
# 2s attempt at container start loses whenever the Redis Service endpoint is
# not programmed yet, and the pod then runs on file sessions -- which silently
# caps the deployment at one replica -- with nothing in the log saying why.
REDIS_OK=0
REDIS_ERR=""
for attempt in 1 2 3 4 5; do
    set +e
    REDIS_ERR=$(php /usr/local/bin/oe-redis-probe.php 2>&1)
    REDIS_RC=$?
    set -e
    if [ "$REDIS_RC" = 0 ]; then
        REDIS_OK=1
        break
    fi
    echo "  Redis attempt ${attempt}/5 failed: ${REDIS_ERR}"
    [ "$attempt" = 5 ] || sleep 2
done

if [ "$REDIS_OK" = 1 ]; then
    echo "✓ Redis sessions at ${REDIS_HOST}:${REDIS_PORT} (read/write verified)"
    SAVE_HANDLER=redis
    SAVE_PATH="tcp://${REDIS_HOST}:${REDIS_PORT}"
    [ -n "${REDIS_PASSWORD:-}" ] && SAVE_PATH="${SAVE_PATH}?auth=${REDIS_PASSWORD}"
else
    echo "⚠ Redis unusable after 5 attempts — file-based sessions (single pod only)"
    echo "  last error: ${REDIS_ERR}"
    SAVE_HANDLER=files
    SAVE_PATH=/var/lib/php/session
fi

cat > /etc/php.d/98-session.ini <<EOF
session.save_handler = ${SAVE_HANDLER}
session.save_path = "${SAVE_PATH}"
EOF

cat > /etc/php.d/97-runtime.ini <<EOF
opcache.validate_timestamps = ${OPCACHE_VALIDATE_TIMESTAMPS}
opcache.revalidate_freq = 60
EOF

if [ "${OPENEMR_DEBUG}" = "1" ]; then
    echo "⚠ OPENEMR_DEBUG=1 — errors render to the browser. Never in production."
    printf 'display_errors = On\ndisplay_startup_errors = On\n' > /etc/php.d/96-debug.ini
else
    rm -f /etc/php.d/96-debug.ini
fi

# --- First-run configuration ----------------------------------------------
SQLCONF="${SITE_DIR}/sqlconf.php"
INSTALLER="${OPENEMR_WEB_ROOT}/contrib/util/installScripts/InstallerAuto.php"

# Hoisted above the branch: the schema check needs them on the already-
# configured path too, not just the install path.
export MYSQL_HOST="${MYSQL_HOST:-mariadb}"
export MYSQL_PORT="${MYSQL_PORT:-3306}"
export MYSQL_DATABASE="${MYSQL_DATABASE:-openemr}"
export MYSQL_USER="${MYSQL_USER:-openemr}"
OE_USER="${OE_USER:-admin}"

if [ -f "$SQLCONF" ] && grep -q '\$config = 1' "$SQLCONF" 2>/dev/null; then
    echo "sqlconf.php present — skipping install, checking schema version..."

    # A configured site is not the same thing as a current one. The PVC mounted
    # at sites/default outlives the image, so an 8.4.0 container can boot onto a
    # schema written by 8.0.0. OpenEMR does not self-heal that gap — it runs the
    # new code against the old tables, and the browser gets a blank page. Refuse
    # instead, because a clear failure beats an EMR that silently half-works.
    set +e
    SCHEMA_INFO=$(php /usr/local/bin/oe-schema-check.php 2>&1)
    SCHEMA_RC=$?
    set -e
    echo "  ${SCHEMA_INFO}"

    case "$SCHEMA_RC" in
        0)
            echo "✓ Schema matches the image"
            ;;
        1)
            echo "FATAL: the database schema was written by a different release." >&2
            echo "" >&2
            echo "  Lab or demo — discard the old data:" >&2
            echo "    ./deploy-openemr.sh --cleanup && ./deploy-openemr.sh" >&2
            echo "" >&2
            echo "  Real data — upgrade the schema before serving traffic:" >&2
            echo "    set OPENEMR_SKIP_SCHEMA_CHECK=1, then visit /sql_upgrade.php" >&2
            echo "" >&2
            [ "${OPENEMR_SKIP_SCHEMA_CHECK:-0}" = "1" ] || exit 1
            echo "⚠ OPENEMR_SKIP_SCHEMA_CHECK=1 — starting anyway" >&2
            ;;
        *)
            echo "⚠ Could not verify the schema version — starting anyway"
            ;;
    esac
else
    : "${MYSQL_PASS:?MYSQL_PASS must be set (use a Secret)}"
    : "${OE_PASS:?OE_PASS must be set (use a Secret)}"

    echo "Waiting for database at ${MYSQL_HOST}:${MYSQL_PORT}..."
    for i in $(seq 1 30); do
        if php -r "mysqli_connect('${MYSQL_HOST}', '${MYSQL_USER}', '${MYSQL_PASS}', '${MYSQL_DATABASE}', ${MYSQL_PORT}) or exit(1);" 2>/dev/null; then
            echo "✓ Database reachable"
            break
        fi
        [ "$i" = 30 ] && { echo "FATAL: database unreachable after 60s" >&2; exit 1; }
        sleep 2
    done

    echo "Running InstallerAuto.php..."
    cd "${OPENEMR_WEB_ROOT}"
    export OPENEMR_ENABLE_INSTALLER_AUTO=1
    php -f "$INSTALLER" \
        no_root_db_access=1 \
        server="${MYSQL_HOST}" port="${MYSQL_PORT}" \
        login="${MYSQL_USER}" pass="${MYSQL_PASS}" \
        dbname="${MYSQL_DATABASE}" \
        iuser="${OE_USER}" iuserpass="${OE_PASS}" \
        iuname="Administrator" 2>&1 || true

    if ! grep -q '\$config = 1' "$SQLCONF" 2>/dev/null; then
        echo "FATAL: configuration did not complete — $SQLCONF has no \$config = 1" >&2
        exit 1
    fi

    # A written sqlconf.php is not proof of a loaded schema. 8.4.0 itself
    # added "fail loudly when the database upgrade fails" for this reason.
    TABLES=$(php -r "
        \$c = mysqli_connect('${MYSQL_HOST}', '${MYSQL_USER}', '${MYSQL_PASS}', '${MYSQL_DATABASE}', ${MYSQL_PORT});
        \$r = mysqli_query(\$c, \"SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${MYSQL_DATABASE}'\");
        echo mysqli_fetch_row(\$r)[0];
    " 2>/dev/null || echo 0)
    echo "Schema table count: ${TABLES}"
    if [ "${TABLES}" -lt 100 ]; then
        echo "FATAL: schema load incomplete (${TABLES} tables, expected several hundred)." >&2
        echo "       Wipe the mariadb-data PVC and redeploy." >&2
        exit 1
    fi
    echo "✓ Configured"
fi

exec /usr/bin/supervisord -c /etc/supervisord.conf
ENTRYPOINT

# ============================================================================
# Permissions — arbitrary UID, GID 0
# ============================================================================
RUN mkdir -p /var/log/nginx /var/lib/nginx /var/lib/php/session /run/php-fpm \
    && chmod +x /entrypoint.sh \
    && chgrp -R 0 \
        ${OPENEMR_WEB_ROOT} ${OPENEMR_DEFAULTS} /opt/cqm-service \
        /usr/local/bin/oe-schema-check.php /usr/local/bin/oe-redis-probe.php \
        /var/log/nginx /var/lib/nginx /var/lib/php /run \
        /etc/nginx /etc/php.d /etc/php-fpm.d /entrypoint.sh \
    && chmod -R g=u \
        ${OPENEMR_WEB_ROOT} ${OPENEMR_DEFAULTS} /opt/cqm-service \
        /usr/local/bin/oe-schema-check.php /usr/local/bin/oe-redis-probe.php \
        /var/log/nginx /var/lib/nginx /var/lib/php /run \
        /etc/nginx /etc/php.d /etc/php-fpm.d /entrypoint.sh \
    && chmod g=u /etc/passwd

EXPOSE 8080
USER 1001
WORKDIR ${OPENEMR_WEB_ROOT}
ENTRYPOINT ["/entrypoint.sh"]