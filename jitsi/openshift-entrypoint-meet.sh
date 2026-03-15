#!/bin/bash
# openshift-entrypoint-meet.sh
# Replaces s6-overlay for jitsi/web on CentOS Stream 10.
# Runs cont-init.d scripts in order (config generation via tpl),
# then execs nginx directly. No init system, no CAP_SYS_ADMIN needed.
set -e

echo "[entrypoint] Running cont-init.d config scripts..."
for script in $(ls /etc/cont-init.d/ | sort); do
    path="/etc/cont-init.d/${script}"
    if [ -x "${path}" ]; then
        echo "[entrypoint] ${script}"
        "${path}" || { echo "[entrypoint] ERROR: ${script} failed"; exit 1; }
    fi
done
echo "[entrypoint] Config complete. Starting nginx..."

exec nginx -g 'daemon off;'
