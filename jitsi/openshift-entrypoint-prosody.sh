#!/bin/bash
# openshift-entrypoint-prosody.sh
# Replaces s6-overlay for jitsi/prosody on CentOS Stream 10.
# Runs cont-init.d scripts in order (generates prosody.cfg.lua via tpl),
# then execs prosody directly.
set -e

echo "[entrypoint] Running cont-init.d config scripts..."
for script in $(ls /etc/cont-init.d/ | sort); do
    path="/etc/cont-init.d/${script}"
    if [ -x "${path}" ]; then
        echo "[entrypoint] ${script}"
        "${path}" || { echo "[entrypoint] ERROR: ${script} failed"; exit 1; }
    fi
done
echo "[entrypoint] Config complete. Starting prosody..."

exec prosody
