#!/bin/bash
# openshift-entrypoint-prosody.sh
# Replaces s6-overlay for jitsi/prosody on CentOS Stream 10.
set -e

echo "[entrypoint] Running cont-init.d config scripts..."
for script in $(ls /etc/cont-init.d/ | sort); do
    path="/etc/cont-init.d/${script}"
    shebang=$(head -1 "${path}" 2>/dev/null || true)
    # Skip timezone script — tries to chown /etc/localtime (needs root)
    if [ "${script}" = "01-set-timezone" ]; then
        echo "[entrypoint] ${script} (skipped - TZ set via env)"
        continue
    fi
    echo "[entrypoint] ${script}"
    if echo "${shebang}" | grep -qE "execlineb"; then
        echo "[entrypoint] ${script} (skipped - execlineb)"
        continue
    elif echo "${shebang}" | grep -q "with-contenv"; then
        # Strip apt-cache calls (Debian-only) before running via bash
        tmpscript=$(mktemp)
        sed             -e 's|.*apt-cache.*|: # apt-cache skipped (not Debian)|g'             -e 's|.*chown .*|: # chown skipped (OpenShift SCC)|g'             "${path}" > "${tmpscript}"
        # Run script; ignore chown/permission errors (files are already
        # owned correctly from Containerfile). Fail only on real errors.
        bash "${tmpscript}" || {
            rc=$?
            echo "[entrypoint] WARNING: ${script} exited with code ${rc} (likely chown — continuing)"
        }
        rm -f "${tmpscript}"
    elif [ -x "${path}" ]; then
        "${path}" || { echo "[entrypoint] ERROR: ${script} failed"; exit 1; }
    fi
done
echo "[entrypoint] Config complete. Starting prosody..."

# Ensure prosody.cfg.lua includes conf.d/ — CentOS default config
# does not have this directive unlike the Jitsi Debian base image.
if ! grep -q "conf.d" /config/prosody.cfg.lua 2>/dev/null; then
    echo "Include \"/config/conf.d/*.cfg.lua\"" >> /config/prosody.cfg.lua
    echo "[entrypoint] Added conf.d include to prosody.cfg.lua"
fi

# Register Jitsi users after prosody starts (upstream does this in services.d)
# Run in background, wait for prosody to be ready, then register users
register_users() {
    sleep 5
    echo "[entrypoint] Registering XMPP users..."
    prosodyctl --config /config/prosody.cfg.lua         register focus auth.meet.jitsi "${JICOFO_AUTH_PASSWORD}" 2>/dev/null &&         echo "[entrypoint] Registered: focus@auth.meet.jitsi" ||         echo "[entrypoint] Warning: focus registration failed (may already exist)"
    prosodyctl --config /config/prosody.cfg.lua         register jvb auth.meet.jitsi "${JVB_AUTH_PASSWORD}" 2>/dev/null &&         echo "[entrypoint] Registered: jvb@auth.meet.jitsi" ||         echo "[entrypoint] Warning: jvb registration failed (may already exist)"
}
register_users &

exec prosody --config /config/prosody.cfg.lua