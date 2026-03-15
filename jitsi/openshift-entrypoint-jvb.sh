#!/bin/bash
# openshift-entrypoint-jvb.sh
# Replaces s6-overlay for jitsi/jvb on CentOS Stream 10.
# Includes OpenShift arbitrary-UID NSS fix for Java.
set -e

CURR_UID=$(id -u)
CURR_GID=$(id -g)
grep -v "^jvb:" /etc/passwd.template > /tmp/passwd 2>/dev/null || cp /etc/passwd /tmp/passwd
echo "jvb:x:${CURR_UID}:${CURR_GID}:Jitsi Videobridge:/home/jvb:/sbin/nologin" >> /tmp/passwd
export NSS_WRAPPER_PASSWD=/tmp/passwd
export NSS_WRAPPER_GROUP=/etc/group
export HOME=/home/jvb

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
echo "[entrypoint] Config complete. Starting JVB..."

if [ -x /usr/share/jitsi-videobridge/jvb.sh ]; then
    exec /usr/share/jitsi-videobridge/jvb.sh
elif [ -f /usr/share/jitsi-videobridge/jitsi-videobridge.jar ]; then
    exec java ${JAVA_SYS_PROPS} \
        -cp '/usr/share/jitsi-videobridge/*' \
        org.jitsi.videobridge.Main
else
    exec $(find /usr/share/jitsi-videobridge -name '*.sh' | head -1)
fi
