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
